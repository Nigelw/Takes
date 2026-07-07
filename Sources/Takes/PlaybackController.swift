import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class PlaybackController {
    static let maximumTrackCount = 32

    private(set) var session = ComparisonSession()

    /// The window currently drawn, in absolute seconds — a sub-window of the
    /// content range `[timelineStart, timelineEnd]`; when it equals the content
    /// range the timeline is fully zoomed out ("fit"). See `TimelineViewport`.
    ///
    /// Stored OUTSIDE `session` on purpose: Observation tracks `session` as a
    /// single property, and `visibleStart` is written on every horizontal
    /// scroll event (and every zoomed playback-follow step). Keeping the
    /// window here means those writes invalidate only the small leaf views
    /// that read it, never the views that read `session`. All writes go
    /// through `setVisibleWindow` so `laneWindowStart` stays in sync.
    private(set) var visibleStart: TimeInterval = 0
    private(set) var visibleSpan: TimeInterval = 0

    var visibleEnd: TimeInterval {
        visibleStart + visibleSpan
    }

    /// Grid-quantized start of the lane drawing window: `visibleStart` rounded
    /// down to a half-viewport grid (the lanes draw a 2×-viewport window slid
    /// by a leaf offset — see `LaneViewport`). Written with an equality guard,
    /// so views keyed on the window re-run only when the viewport crosses a
    /// grid boundary or the zoom changes — not per scroll event.
    private(set) var laneWindowStart: TimeInterval = 0

    /// Sole mutation path for the visible window. Guards every write (with
    /// `@Observable`, assigning an equal value still invalidates observers).
    private func setVisibleWindow(start: TimeInterval? = nil, span: TimeInterval? = nil) {
        if let start, visibleStart != start { visibleStart = start }
        if let span, visibleSpan != span { visibleSpan = span }
        // Matches the view's `makeLaneViewport` span clamp.
        let quantum = max(visibleSpan, 0.001) / 2
        let windowStart = (visibleStart / quantum).rounded(.down) * quantum
        if laneWindowStart != windowStart { laneWindowStart = windowStart }
    }

    private(set) var playbackError: PlaybackError?
    /// Whether an auto-align run is in flight (drives the toolbar button's
    /// spinner and blocks re-entry).
    private(set) var isAligning = false
    /// Progress (0...1) of the tempo-analysis pass, or `nil` while idle or
    /// during the quick first pass (which shows an indeterminate spinner).
    private(set) var alignmentProgress: Double?
    /// Set when the quick pass leaves unaligned tracks: the UI surfaces a
    /// warning control beside the button whose popover offers the slower tempo
    /// analysis on them.
    private(set) var tempoAnalysisOffer: TempoAnalysisOffer?
    /// A brief success/failure flash on the Auto-Align button, auto-cleared a
    /// couple seconds after an alignment run finishes.
    private(set) var alignmentOutcome: AlignmentOutcome?
    /// The transport timestamp string shown while playing. Maintained by the
    /// transport tick but written only when the rendered text changes (~1×/s
    /// at mm:ss precision), so the readout re-renders per displayed second
    /// instead of per tick — and, unlike a `TimelineView(.animation)` readout,
    /// keeps the window's display-link layout cycle idle. While paused the
    /// readout derives directly from `transportPosition`.
    private(set) var playingReadoutText = 0.0.formattedSignedTimestamp
    @ObservationIgnored weak var settings: AppSettings?

    /// Tracks the quick alignment pass couldn't match, held while the user
    /// decides whether to run tempo analysis on them.
    struct TempoAnalysisOffer: Equatable {
        let trackIDs: [SessionTrack.ID]
        let trackNames: [String]
    }

    enum AlignmentOutcome: Equatable {
        case success
        case failure
    }

    @ObservationIgnored private var alignmentOutcomeClearTask: Task<Void, Never>?

    @ObservationIgnored private let loader: AudioFileLoading
    @ObservationIgnored private let libraryTrackSelector: LibraryTrackSelecting
    @ObservationIgnored private let streamingTrackResolver: StreamingTrackResolving
    @ObservationIgnored private let streamingDownloadCache: StreamingDownloadCache
    @ObservationIgnored private let ytdlpManager: YTDLPManaging
    @ObservationIgnored private let engine = AVAudioEngine()
    nonisolated private static let maximumSilenceBufferDuration: TimeInterval = 5

    @ObservationIgnored private var engineConfigured = false
    @ObservationIgnored private var runtimeTracksByID: [SessionTrack.ID: RuntimeTrack] = [:]
    /// Schedule anchors: the transport position playback started from and the
    /// host time it started at. Observable (not ignored) on purpose — they
    /// change exactly when the transport is re-anchored (play, pause, seek,
    /// loop wrap), so observers of `remotePlaybackSnapshot()` and the playhead
    /// can track those events without depending on the ticking
    /// `transportPosition`.
    private var playbackStartedAt: CFTimeInterval?
    private var playbackStartedFromTransport: TimeInterval = 0
    @ObservationIgnored private var transportStoppedAtTimelineStart = true
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var engineConfigurationObserver: NotificationObserverToken?
    @ObservationIgnored private var scrollAnimationTimer: Timer?
    @ObservationIgnored private var scrollAnimation: ScrollAnimation?
    @ObservationIgnored private var streamingCacheFilesByTrackID: [SessionTrack.ID: URL] = [:]

    /// A short tween of `visibleStart`, used to animate the catch-up scroll when
    /// playback starts with the playhead off-screen.
    private struct ScrollAnimation {
        let from: TimeInterval
        let to: TimeInterval
        let startedAt: CFTimeInterval
        let duration: CFTimeInterval
    }

    /// Kept quick so the animation finishes well before the first page jump.
    private static let scrollCatchUpDuration: CFTimeInterval = 0.2

    /// Duration of the animated page turn at the edge during playback. Shorter
    /// than the catch-up so it stays out of the way at high zoom, where pages
    /// come quickly.
    private static let pageAnimationDuration: CFTimeInterval = 0.15

    private struct RuntimeTrack {
        let file: AVAudioFile
        let player: AVAudioPlayerNode
        let mixer: AVAudioMixerNode
    }

    private struct PreparedTrackLoad {
        let metadata: LoadedTrack
        let file: AVAudioFile
    }

    private final class NotificationObserverToken {
        private let token: NSObjectProtocol

        init(_ token: NSObjectProtocol) {
            self.token = token
        }

        deinit {
            NotificationCenter.default.removeObserver(token)
        }
    }

    init(
        loader: AudioFileLoading = AudioFileLoader(),
        libraryTrackSelector: LibraryTrackSelecting = LibraryTrackSelectionLoader(),
        streamingTrackResolver: StreamingTrackResolving = StreamingTrackResolver(),
        streamingDownloadCache: StreamingDownloadCache = StreamingDownloadCache(
            rootURL: PlaybackController.defaultStreamingDownloadCacheRoot()
        ),
        ytdlpManager: YTDLPManaging = YTDLPManager()
    ) {
        self.loader = loader
        self.libraryTrackSelector = libraryTrackSelector
        self.streamingTrackResolver = streamingTrackResolver
        self.streamingDownloadCache = streamingDownloadCache
        self.ytdlpManager = ytdlpManager
        engineConfigurationObserver = NotificationObserverToken(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAudioEngineConfigurationChange()
            }
        })
        prepareStreamingDownloadCache()
    }

    var displayedTrackRowCount: Int {
        session.tracks.count
    }

    func loadImportedFiles(_ urls: [URL]) async {
        await loadImportedFiles(urls, additionalFailures: [], blindShuffle: { $0.shuffled() })
    }

    func loadImportedFiles(
        _ urls: [URL],
        blindShuffle: ([SessionTrack]) -> [SessionTrack]
    ) async {
        await loadImportedFiles(urls, additionalFailures: [], blindShuffle: blindShuffle)
    }

    private func loadImportedFiles(
        _ urls: [URL],
        additionalFailures: [ImportFailure],
        blindShuffle: ([SessionTrack]) -> [SessionTrack]
    ) async {
        guard !urls.isEmpty || !additionalFailures.isEmpty else { return }

        let wasPlaying = session.isPlaying
        var preparedLoads: [PreparedTrackLoad] = []
        var failures = additionalFailures
        var skippedFileNames: [String] = []
        var importedTrackURLs = Set(session.tracks.map { Self.timelineIdentityURL(for: $0.loadedTrack.url) })

        for url in urls {
            let identityURL = Self.timelineIdentityURL(for: url)
            guard importedTrackURLs.insert(identityURL).inserted else {
                continue
            }

            guard session.tracks.count + preparedLoads.count < Self.maximumTrackCount else {
                skippedFileNames.append(url.lastPathComponent.ifEmpty(url.path))
                continue
            }

            do {
                preparedLoads.append(try await prepareTrackLoad(from: url))
            } catch let error as PlaybackError {
                failures.append(ImportFailure(url: url, message: error.importFailureMessage))
            } catch {
                failures.append(ImportFailure(url: url, message: PlaybackError.failedToOpenFile(url).importFailureMessage))
            }
        }

        var resumePosition: TimeInterval?
        var shouldAutoAlignAfterOpening = false
        if wasPlaying, !preparedLoads.isEmpty {
            resumePosition = currentTransportPosition()
        }

        if !preparedLoads.isEmpty {
            let appendedTrackIDs = preparedLoads.map(appendPreparedTrackLoad)
            finishTrackLoading(preferZero: !wasPlaying && transportStoppedAtTimelineStart)
            shuffleForBlindListeningIfNeeded(using: blindShuffle)
            shouldAutoAlignAfterOpening = settings?.alignTracksOnOpen == true
            if let resumePosition, !startAppendedTracksDuringPlayback(appendedTrackIDs, at: resumePosition) {
                return
            }
        }

        switch (failures.isEmpty, skippedFileNames.isEmpty) {
        case (false, false):
            playbackError = .importSummary(
                failures: failures,
                skippedFileNames: skippedFileNames,
                limit: Self.maximumTrackCount
            )
        case (false, true):
            playbackError = .importFailures(failures)
        case (true, false):
            playbackError = .trackLimitExceeded(limit: Self.maximumTrackCount, skippedFileNames: skippedFileNames)
        case (true, true):
            break
        }

        if shouldAutoAlignAfterOpening {
            autoAlignTracks()
        }
    }

    private static func timelineIdentityURL(for url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    @discardableResult
    private func startAppendedTracksDuringPlayback(_ trackIDs: [SessionTrack.ID], at resumePosition: TimeInterval) -> Bool {
        let restoredPosition = TransportMapping.clampedTransport(
            resumePosition,
            timelineStart: session.timelineStart,
            timelineEnd: session.timelineEnd
        )
        session.transportPosition = restoredPosition

        do {
            try ensureEngineRunning()
            try scheduleTracks(trackIDs, startingAt: restoredPosition, stoppingExistingSchedule: false)
            startScheduledPlayers(for: trackIDs)
        } catch let error as PlaybackError {
            failImportPlaybackResume(with: error, at: restoredPosition)
            return false
        } catch {
            failImportPlaybackResume(with: .schedulingFailed, at: restoredPosition)
            return false
        }

        session.isPlaying = true
        playbackStartedFromTransport = session.transportPosition
        playbackStartedAt = CACurrentMediaTime()
        startTimer()
        applyAudibility()
        return true
    }

    private func failImportPlaybackResume(with error: PlaybackError, at restoredPosition: TimeInterval) {
        session.isPlaying = false
        session.transportPosition = restoredPosition
        playbackStartedAt = nil
        playbackStartedFromTransport = restoredPosition
        timer?.invalidate()
        playbackError = error
        applyAudibility()
    }

    private func restorePlaybackAfterTrackMutation(at resumePosition: TimeInterval) {
        let restoredPosition = TransportMapping.clampedTransport(
            resumePosition,
            timelineStart: session.timelineStart,
            timelineEnd: session.timelineEnd
        )
        session.transportPosition = restoredPosition

        do {
            if engineConfigured {
                try reschedulePlayers(startingAt: restoredPosition)
                startScheduledPlayers()
            }
            session.isPlaying = true
            playbackStartedFromTransport = session.transportPosition
            playbackStartedAt = CACurrentMediaTime()
            startTimer()
            applyAudibility()
        } catch let error as PlaybackError {
            failImportPlaybackResume(with: error, at: restoredPosition)
        } catch {
            failImportPlaybackResume(with: .schedulingFailed, at: restoredPosition)
        }
    }

    func loadSelectedLibraryTracks() async {
        do {
            let selection = try libraryTrackSelector.selectedTracks()
            await loadImportedFiles(
                selection.urls,
                additionalFailures: selection.failures,
                blindShuffle: { $0.shuffled() }
            )
        } catch let error as PlaybackError {
            playbackError = error
        } catch {
            playbackError = .librarySelectionFailed("Could not load the selected track from Music.")
        }
    }

    @discardableResult
    func loadStreamingTrack(
        from rawURLString: String,
        statusHandler: @escaping @Sendable (StreamingURLPromptStatus) async -> Void = { _ in }
    ) async -> Bool {
        let trimmed = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sourceURL = URL(string: trimmed), sourceURL.scheme != nil else {
            await statusHandler(.failed("Enter a valid streaming URL."))
            return false
        }

        let loadID = UUID()
        var loadDirectory: URL?

        do {
            try Task.checkCancellation()
            await statusHandler(.preparingDownloader)
            let downloaderURL = try await ytdlpManager.executableURL()
            try Task.checkCancellation()

            let match = try await streamingTrackResolver.resolveYouTubeMatch(
                for: sourceURL,
                using: downloaderURL,
                statusHandler: statusHandler
            )
            let youtubeURL = match.url
            try Task.checkCancellation()

            try streamingDownloadCache.prepare()
            let currentLoadDirectory = try streamingDownloadCache.createLoadDirectory(id: loadID)
            loadDirectory = currentLoadDirectory

            await statusHandler(.downloading(progress: nil))
            let downloadedURL = try await downloadStreamingAudio(
                from: youtubeURL,
                into: currentLoadDirectory,
                filenameBase: match.downloadFilenameBase,
                using: downloaderURL
            )
            try Task.checkCancellation()

            await statusHandler(.openingAudio)
            let existingTrackIDs = Set(session.tracks.map(\.id))
            await loadImportedFiles([downloadedURL])
            guard let importedTrack = session.tracks.first(where: {
                !existingTrackIDs.contains($0.id)
                    && Self.timelineIdentityURL(for: $0.loadedTrack.url) == Self.timelineIdentityURL(for: downloadedURL)
            }) else {
                throw StreamingTrackImportError.openImportFailed
            }
            streamingCacheFilesByTrackID[importedTrack.id] = downloadedURL
            return true
        } catch is CancellationError {
            if let loadDirectory {
                try? streamingDownloadCache.deleteOwnedItem(at: loadDirectory)
            }
            return false
        } catch {
            if let loadDirectory {
                try? streamingDownloadCache.deleteOwnedItem(at: loadDirectory)
            }
            NSLog("Streaming track import failed: \(error)")
            await statusHandler(.failed(StreamingTrackImportError.promptMessage(for: error)))
            return false
        }
    }

    func setPlaybackError(_ error: PlaybackError) {
        playbackError = error
    }

    func clearPlaybackError() {
        playbackError = nil
    }

    private func prepareTrackLoad(from url: URL) async throws -> PreparedTrackLoad {
        let metadata = try await loader.loadTrackMetadata(from: url)
        let file = try loader.makeAudioFile(from: url)
        return PreparedTrackLoad(metadata: metadata, file: file)
    }

    private static func defaultStreamingDownloadCacheRoot(fileManager: FileManager = .default) -> URL {
        let cachesRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "com.nigelwarren.Takes"
        return cachesRoot
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("StreamingDownloads", isDirectory: true)
    }

    private func prepareStreamingDownloadCache() {
        do {
            try streamingDownloadCache.prepare()
        } catch {
            playbackError = .librarySelectionFailed("Could not prepare the streaming download cache.")
        }
    }

    private func downloadStreamingAudio(
        from youtubeURL: URL,
        into directory: URL,
        filenameBase: String?,
        using downloaderURL: URL
    ) async throws -> URL {
        let downloader = YTDLPDownloader(binaryURL: downloaderURL)
        return try await downloader.download(youtubeURL, into: directory, filenameBase: filenameBase)
    }

    @discardableResult
    private func appendPreparedTrackLoad(_ preparedLoad: PreparedTrackLoad) -> SessionTrack.ID {
        let sessionTrack = SessionTrack(loadedTrack: preparedLoad.metadata)
        session.tracks.append(sessionTrack)
        configureEngine()
        attachRuntimeTrack(for: sessionTrack.id, file: preparedLoad.file)
        if session.activeTrackID == nil {
            session.activeTrackID = sessionTrack.id
        }
        return sessionTrack.id
    }

    private func finishTrackLoading(preferZero: Bool = true) {
        playbackError = nil
        recalculateSessionDuration(preferZero: preferZero)
        applyAudibility()
    }

    func play() {
        guard session.isPlayable else { return }
        playbackError = nil
        // Parked at the end (Repeat Off stops there): start over from the top of
        // the track/selection rather than replaying nothing.
        if session.transportPosition >= session.playbackEnd {
            session.transportPosition = session.playbackStart
        }
        do {
            try ensureEngineRunning()
            try reschedulePlayers(startingAt: session.transportPosition)
            startScheduledPlayers()
            session.isPlaying = true
            transportStoppedAtTimelineStart = false
            playbackStartedFromTransport = session.transportPosition
            playbackStartedAt = CACurrentMediaTime()
            startTimer()
            applyAudibility()
            animateScrollToPlayheadIfNeeded()
        } catch let error as PlaybackError {
            playbackError = error
        } catch {
            playbackError = .engineStartFailed
        }
    }

    func pause() {
        guard session.isPlaying else { return }
        session.transportPosition = currentTransportPosition()
        for runtime in runtimeTracksInSessionOrder() {
            runtime.player.pause()
        }
        session.isPlaying = false
        transportStoppedAtTimelineStart = false
        playbackStartedAt = nil
        playbackStartedFromTransport = session.transportPosition
        timer?.invalidate()
        pauseEngine()
    }

    func stop() {
        stopScrollAnimation()
        for runtime in runtimeTracksInSessionOrder() {
            runtime.player.stop()
        }
        session.isPlaying = false
        session.transportPosition = session.timelineStart
        transportStoppedAtTimelineStart = true
        playbackStartedAt = nil
        playbackStartedFromTransport = session.transportPosition
        timer?.invalidate()
        applyAudibility()
        pauseEngine()
    }

    /// Stop the engine's render thread while no transport is running so an
    /// idle Takes costs ~0% CPU. Every resume path goes through `play()`,
    /// which calls `ensureEngineRunning()` and reschedules players from
    /// scratch, so nothing depends on the engine staying hot while paused.
    private func pauseEngine() {
        guard engine.isRunning else { return }
        engine.pause()
    }

    func seek(to seconds: TimeInterval) {
        guard session.isPlayable else { return }
        stopScrollAnimation()
        // While a loop is active, keep the playhead inside it.
        let clamped = TransportMapping.clampedTransport(
            seconds,
            timelineStart: session.playbackStart,
            timelineEnd: session.playbackEnd
        )
        session.transportPosition = clamped
        transportStoppedAtTimelineStart = false

        guard session.isPlaying else { return }
        do {
            try reschedulePlayers(startingAt: clamped)
            startScheduledPlayers()
            playbackStartedFromTransport = clamped
            playbackStartedAt = CACurrentMediaTime()
            applyAudibility()
        } catch let error as PlaybackError {
            playbackError = error
        } catch {
            playbackError = .schedulingFailed
        }
    }

    func selectNextTrack() {
        guard session.canSwitchPlayback else { return }
        let currentIndex = session.activeTrackIndex ?? -1
        let nextIndex = currentIndex + 1 < session.tracks.count ? currentIndex + 1 : 0
        session.activeTrackID = session.tracks[nextIndex].id
        applyAudibility()
    }

    func selectPreviousTrack() {
        guard session.canSwitchPlayback else { return }
        let currentIndex = session.activeTrackIndex ?? 0
        let previousIndex = currentIndex > 0 ? currentIndex - 1 : session.tracks.count - 1
        session.activeTrackID = session.tracks[previousIndex].id
        applyAudibility()
    }

    func selectActiveTrack(_ trackID: SessionTrack.ID) {
        guard session.tracks.contains(where: { $0.id == trackID }) else { return }
        session.activeTrackID = trackID
        applyAudibility()
    }

    func canSelectTrackForHotkey(_ hotkey: Int) -> Bool {
        guard let trackIndex = trackIndex(forHotkey: hotkey) else { return false }
        return session.tracks.indices.contains(trackIndex)
    }

    func selectTrackForHotkey(_ hotkey: Int) {
        guard let trackIndex = trackIndex(forHotkey: hotkey) else { return }
        guard session.tracks.indices.contains(trackIndex) else { return }

        session.activeTrackID = session.tracks[trackIndex].id
        applyAudibility()
    }

    func reorderTrack(_ trackID: SessionTrack.ID, before destinationTrackID: SessionTrack.ID?) {
        guard let sourceIndex = session.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        guard destinationTrackID != trackID else { return }

        let movedTrack = session.tracks.remove(at: sourceIndex)
        let destinationIndex: Int
        if let destinationTrackID {
            guard let targetIndex = session.tracks.firstIndex(where: { $0.id == destinationTrackID }) else {
                session.tracks.insert(movedTrack, at: sourceIndex)
                return
            }
            destinationIndex = targetIndex
        } else {
            destinationIndex = session.tracks.endIndex
        }

        session.tracks.insert(movedTrack, at: destinationIndex)
        applyAudibility()
    }

    func replaceTrack(_ trackID: SessionTrack.ID, with url: URL) async {
        guard let index = session.tracks.firstIndex(where: { $0.id == trackID }) else { return }

        do {
            let preparedLoad = try await prepareTrackLoad(from: url)
            let wasPlaying = session.isPlaying
            let resumePosition = wasPlaying ? currentTransportPosition() : nil

            session.tracks[index].loadedTrack = preparedLoad.metadata
            configureEngine()
            attachRuntimeTrack(for: trackID, file: preparedLoad.file)
            finishTrackLoading(preferZero: !wasPlaying && transportStoppedAtTimelineStart)

            guard wasPlaying, let resumePosition else { return }
            restorePlaybackAfterTrackMutation(at: resumePosition)
        } catch let error as PlaybackError {
            playbackError = error
        } catch {
            playbackError = .failedToOpenFile(url)
        }
    }

    func removeTrack(_ trackID: SessionTrack.ID) {
        guard let removedIndex = session.tracks.firstIndex(where: { $0.id == trackID }) else { return }

        let wasPlaying = session.isPlaying
        let wasActive = session.activeTrackID == trackID
        let resumePosition = wasPlaying ? currentTransportPosition() : nil

        session.tracks.remove(at: removedIndex)
        detachRuntimeTrack(for: trackID)
        deleteStreamingCacheFile(for: trackID)

        if wasActive {
            if session.tracks.indices.contains(removedIndex) {
                session.activeTrackID = session.tracks[removedIndex].id
            } else {
                session.activeTrackID = session.tracks.last?.id
            }
        }

        recalculateSessionDuration()

        if wasPlaying, let resumePosition {
            let restoredPosition = TransportMapping.clampedTransport(
                resumePosition,
                timelineStart: session.timelineStart,
                timelineEnd: session.timelineEnd
            )
            guard session.isPlayable, restoredPosition < session.playbackEnd else {
                stopAtEnd()
                return
            }
            session.isPlaying = true
            session.transportPosition = restoredPosition
            playbackStartedFromTransport = restoredPosition
            playbackStartedAt = CACurrentMediaTime()
            startTimer()
            applyAudibility()
        } else {
            applyAudibility()
        }
    }

    func clearTracks() {
        guard !session.tracks.isEmpty else { return }

        stopScrollAnimation()
        for runtime in runtimeTracksInSessionOrder() {
            runtime.player.stop()
        }
        deleteAllStreamingCacheFiles()
        runtimeTracksByID.removeAll()
        session.tracks.removeAll()
        session.activeTrackID = nil
        session.isBlindListeningModeEnabled = false
        clearLoop()
        session.isPlaying = false
        transportStoppedAtTimelineStart = true
        playbackStartedAt = nil
        playbackStartedFromTransport = 0
        timer?.invalidate()
        recalculateSessionDuration()
        applyAudibility()
    }

    func cleanupStreamingDownloads() {
        deleteAllStreamingCacheFiles()
        try? streamingDownloadCache.deleteLaunchDirectory()
    }

    private func deleteStreamingCacheFile(for trackID: SessionTrack.ID) {
        guard let cacheFileURL = streamingCacheFilesByTrackID.removeValue(forKey: trackID) else { return }
        try? streamingDownloadCache.deleteOwnedItem(at: cacheFileURL)
        let parentDirectory = cacheFileURL.deletingLastPathComponent()
        try? streamingDownloadCache.deleteOwnedItem(at: parentDirectory)
    }

    private func deleteAllStreamingCacheFiles() {
        let trackIDs = Array(streamingCacheFilesByTrackID.keys)
        for trackID in trackIDs {
            deleteStreamingCacheFile(for: trackID)
        }
    }

    func setGain(_ trackID: SessionTrack.ID, db: Float) {
        guard let index = session.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        session.tracks[index].loadedTrack.gainDB = db
        applyAudibility()
    }

    func setOffset(_ trackID: SessionTrack.ID, seconds: TimeInterval) {
        setOffsets([trackID: seconds])
    }

    /// Set several track offsets as a single edit: the timeline is
    /// recalculated and — when playing — the players rescheduled once, not
    /// once per track. Unchanged or unknown track IDs are ignored.
    func setOffsets(_ offsetsByTrackID: [SessionTrack.ID: TimeInterval]) {
        let resumePosition = session.isPlaying ? currentTransportPosition() : session.transportPosition

        var changed = false
        for (trackID, seconds) in offsetsByTrackID {
            guard let index = session.tracks.firstIndex(where: { $0.id == trackID }),
                  session.tracks[index].loadedTrack.offsetSeconds != seconds else { continue }
            session.tracks[index].loadedTrack.offsetSeconds = seconds
            changed = true
        }
        guard changed else { return }

        recalculateSessionDuration()

        guard session.isPlaying else { return }
        do {
            try reschedulePlayers(startingAt: resumePosition)
            startScheduledPlayers()
            playbackStartedFromTransport = session.transportPosition
            playbackStartedAt = CACurrentMediaTime()
            applyAudibility()
        } catch let error as PlaybackError {
            playbackError = error
        } catch {
            playbackError = .schedulingFailed
        }
    }

    // MARK: - Auto-align

    /// Compute and apply offsets that align every other track's audio with the
    /// active track (which stays put), correlating around the current playhead.
    /// Runs in the background; `isAligning` is true until results land (an
    /// indeterminate spinner). Tracks with no confident match keep their offsets
    /// and surface the tempo-analysis offer.
    func autoAlignTracks() {
        guard !isAligning, session.canSwitchPlayback, let anchor = session.activeTrack else { return }

        let anchorTrack = anchor.loadedTrack
        let playheadFileTime = min(
            max(currentTransportPosition() - anchorTrack.offsetSeconds, 0),
            anchorTrack.duration
        )
        let request = TrackAligner.Request(
            anchor: TrackAligner.Source(
                id: anchor.id,
                url: anchorTrack.url,
                displayName: anchorTrack.displayName,
                currentOffsetSeconds: anchorTrack.offsetSeconds
            ),
            anchorPlayheadFileTime: playheadFileTime,
            others: session.tracks.filter { $0.id != anchor.id }.map { track in
                TrackAligner.Source(
                    id: track.id,
                    url: track.loadedTrack.url,
                    displayName: track.loadedTrack.displayName,
                    currentOffsetSeconds: track.loadedTrack.offsetSeconds
                )
            }
        )

        isAligning = true
        // A fresh run supersedes any lingering flash from the last one.
        alignmentOutcome = nil
        alignmentOutcomeClearTask?.cancel()
        // `align` is nonisolated async, so it hops off the main actor on its
        // own; the task only returns here to publish the results.
        Task { [weak self] in
            let results = await TrackAligner.align(request)
            self?.finishAlignment(results)
        }
    }

    private func finishAlignment(_ results: [TrackAligner.Result]) {
        isAligning = false

        let resultsByTrackID = Dictionary(
            results.map { ($0.trackID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var updates: [SessionTrack.ID: TimeInterval] = [:]
        var unalignedTrackIDs: [SessionTrack.ID] = []
        var unalignedTrackNames: [String] = []
        // Walk the session's current tracks so removed ones are skipped and
        // the alert lists names in track order.
        for track in session.tracks {
            guard let result = resultsByTrackID[track.id] else { continue }
            if let newOffset = result.newOffsetSeconds {
                updates[track.id] = newOffset
            } else {
                unalignedTrackIDs.append(track.id)
                unalignedTrackNames.append(result.displayName)
            }
        }

        setOffsets(updates)
        if !unalignedTrackIDs.isEmpty {
            // Rather than alerting outright, offer the slower tempo analysis via
            // a warning control: the tracks may be the same material at a
            // different speed. Flash red for consistent failure feedback.
            tempoAnalysisOffer = TempoAnalysisOffer(
                trackIDs: unalignedTrackIDs,
                trackNames: unalignedTrackNames
            )
            flashOutcome(.failure)
        } else {
            flashOutcome(.success)
        }
    }

    /// Dismiss the tempo-analysis offer (e.g. when the popover is closed without
    /// acting on it).
    func dismissAlignmentAttention() {
        tempoAnalysisOffer = nil
    }

    /// Briefly flash the Auto-Align button green (success) or red (failure),
    /// clearing the flash after a couple seconds.
    private func flashOutcome(_ outcome: AlignmentOutcome) {
        alignmentOutcome = outcome
        alignmentOutcomeClearTask?.cancel()
        alignmentOutcomeClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.alignmentOutcome = nil
        }
    }

    /// Run the slow tempo-search pass on the tracks the quick pass couldn't
    /// align (user-confirmed from the offer alert). Progress is published via
    /// `alignmentProgress` for the toolbar button's progress circle.
    func startTempoAnalysis() {
        guard let offer = tempoAnalysisOffer else { return }
        tempoAnalysisOffer = nil

        guard !isAligning, let anchor = session.activeTrack else { return }
        let targets = session.tracks.filter { offer.trackIDs.contains($0.id) && $0.id != anchor.id }
        guard !targets.isEmpty else { return }

        let anchorTrack = anchor.loadedTrack
        let playheadFileTime = min(
            max(currentTransportPosition() - anchorTrack.offsetSeconds, 0),
            anchorTrack.duration
        )
        let request = TrackAligner.Request(
            anchor: TrackAligner.Source(
                id: anchor.id,
                url: anchorTrack.url,
                displayName: anchorTrack.displayName,
                currentOffsetSeconds: anchorTrack.offsetSeconds
            ),
            anchorPlayheadFileTime: playheadFileTime,
            others: targets.map { track in
                TrackAligner.Source(
                    id: track.id,
                    url: track.loadedTrack.url,
                    displayName: track.loadedTrack.displayName,
                    currentOffsetSeconds: track.loadedTrack.offsetSeconds
                )
            }
        )

        isAligning = true
        alignmentProgress = 0
        alignmentOutcome = nil
        alignmentOutcomeClearTask?.cancel()
        let publishProgress = makeProgressPublisher()
        Task { [weak self] in
            let results = await TrackAligner.alignTempo(request, onProgress: publishProgress)
            self?.finishTempoAnalysis(results)
        }
    }

    /// A background-thread-safe sink that drives `alignmentProgress`, kept
    /// monotonic since align callbacks can hop over independently.
    private func makeProgressPublisher() -> @Sendable (Double) -> Void {
        { [weak self] progress in
            guard let self else { return }
            Task { @MainActor in
                self.alignmentProgress = max(self.alignmentProgress ?? 0, progress)
            }
        }
    }

    private func finishTempoAnalysis(_ results: [TrackAligner.TempoResult]) {
        isAligning = false
        alignmentProgress = nil

        let resultsByTrackID = Dictionary(
            results.map { ($0.trackID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var updates: [SessionTrack.ID: TimeInterval] = [:]
        var hasFailure = false
        for track in session.tracks {
            guard let result = resultsByTrackID[track.id] else { continue }
            guard let newOffset = result.newOffsetSeconds else {
                hasFailure = true
                continue
            }
            updates[track.id] = newOffset
        }

        setOffsets(updates)
        // Success or failure, the button pulse is the only feedback the user
        // needs — no lingering popover or badge.
        flashOutcome(hasFailure ? .failure : .success)
    }

    func skip(by delta: TimeInterval) {
        seek(to: currentTransportPosition() + delta)
    }

    // MARK: - Blind listening

    func setBlindListeningMode(_ isEnabled: Bool) {
        setBlindListeningMode(isEnabled) { tracks in
            tracks.shuffled()
        }
    }

    func toggleBlindListeningMode() {
        setBlindListeningMode(!session.isBlindListeningModeEnabled)
    }

    func setBlindListeningMode(
        _ isEnabled: Bool,
        shuffle: ([SessionTrack]) -> [SessionTrack]
    ) {
        guard session.isBlindListeningModeEnabled != isEnabled else { return }

        session.isBlindListeningModeEnabled = isEnabled
        if isEnabled {
            session.tracks = Self.blindListeningOrder(
                currentTracks: session.tracks,
                shuffledTracks: shuffle(session.tracks)
            )
            session.activeTrackID = session.tracks.first?.id
        }
        applyAudibility()
    }

    private func shuffleForBlindListeningIfNeeded(using shuffle: ([SessionTrack]) -> [SessionTrack]) {
        guard session.isBlindListeningModeEnabled else { return }
        session.tracks = Self.blindListeningOrder(
            currentTracks: session.tracks,
            shuffledTracks: shuffle(session.tracks)
        )
        session.activeTrackID = session.tracks.first?.id
    }

    nonisolated static func blindListeningOrder(
        currentTracks: [SessionTrack],
        shuffledTracks: [SessionTrack]
    ) -> [SessionTrack] {
        guard currentTracks.count > 1 else { return currentTracks }

        let currentIDs = currentTracks.map(\.id)
        let shuffledIDs = shuffledTracks.map(\.id)
        guard Set(currentIDs) == Set(shuffledIDs), shuffledIDs.count == currentIDs.count else {
            return currentTracks
        }

        if shuffledIDs != currentIDs {
            return shuffledTracks
        }

        var rotated = currentTracks
        let first = rotated.removeFirst()
        rotated.append(first)
        return rotated
    }

    // MARK: - Repeat & loop

    func setRepeatMode(_ mode: RepeatMode) {
        session.repeatMode = mode
    }

    func cycleRepeatMode() {
        setRepeatMode(session.repeatMode.next)
    }

    /// Activate a loop: force Switch & Repeat so the loop is heard across tracks.
    /// A loop starts from its beginning unless the current playhead already sits
    /// inside it. Replacing an active loop while playing preserves playback when
    /// the new loop still contains the live transport.
    func beginLoop(_ region: LoopRegion) {
        let previousLoop = session.loopRegion
        let transport = session.isPlaying ? currentTransportPosition() : session.transportPosition
        session.loopRegion = region
        session.repeatMode = .switchAndRepeat

        guard transport >= region.start, transport < region.end else {
            seek(to: region.start)
            return
        }

        guard session.isPlaying else {
            session.transportPosition = transport
            return
        }

        guard let previousLoop else {
            seek(to: transport)
            return
        }

        if Self.canResizeLoopWithoutRescheduling(from: previousLoop, to: region, transport: transport) {
            session.transportPosition = transport
            if region.end > previousLoop.end {
                appendLoopExtension(from: previousLoop, currentPosition: transport)
            }
            return
        }

        // The new loop still contains the playhead, but queued audio needs to be
        // rebound to the new loop boundary.
        seek(to: transport)
    }

    /// Update one edge of the active loop while dragging a resize handle.
    func resizeLoop(start: TimeInterval? = nil, end: TimeInterval? = nil) {
        guard let current = session.loopRegion else { return }
        guard let region = LoopRegion.normalized(
            start: start ?? current.start,
            end: end ?? current.end,
            timelineStart: session.timelineStart,
            timelineEnd: session.timelineEnd
        ) else { return }

        guard region != current else { return }

        let transport = session.isPlaying ? currentTransportPosition() : session.transportPosition
        session.loopRegion = region
        guard session.isPlaying else {
            seek(to: transport)
            return
        }

        if Self.canResizeLoopWithoutRescheduling(from: current, to: region, transport: transport) {
            session.transportPosition = transport
            if region.end > current.end {
                appendLoopExtension(from: current, currentPosition: transport)
            }
            return
        }

        // Destructive edits, such as shrinking the end under already-scheduled
        // audio or moving the start past the playhead, still need a precise rebind.
        seek(to: transport)
    }

    /// Clear the loop and turn repeat off.
    func deselectLoop() {
        guard let previousLoop = session.loopRegion else { return }
        let wasPlaying = session.isPlaying
        let resumePosition = wasPlaying ? currentTransportPosition() : nil
        clearLoop()
        guard wasPlaying, let resumePosition else { return }

        session.transportPosition = resumePosition
        if resumePosition < previousLoop.end {
            appendPlaybackAfterDeselectingLoop(previousLoop, currentPosition: resumePosition)
        }
    }

    /// Drop the loop and turn repeat off, without touching the transport. Used by
    /// `deselectLoop` and when the timeline no longer holds the loop.
    private func clearLoop() {
        guard session.loopRegion != nil else { return }
        session.loopRegion = nil
        session.repeatMode = .off
    }

    // MARK: - Timeline zoom

    /// Whether the content is long enough to zoom into at all.
    var canZoomTimeline: Bool {
        session.duration > TimelineViewport.minimumVisibleSpan
    }

    /// Set the visible span directly (slider), anchored to the playhead (D3).
    func zoomVisibleSpan(to span: TimeInterval) {
        applyRezoom(span: span, cursorFraction: nil)
    }

    /// Step the zoom by one −/+ increment, anchored to the playhead (D4).
    func stepZoom(zoomingIn: Bool) {
        let span = TimelineViewport.steppedVisibleSpan(
            visibleSpan: max(visibleSpan, TimelineViewport.minimumVisibleSpan),
            zoomingIn: zoomingIn
        )
        applyRezoom(span: span, cursorFraction: nil)
    }

    /// Zoom all the way out so the complete timeline is visible.
    func zoomToFit() {
        let span = session.timelineEnd - session.timelineStart
        guard span > 0 else { return }
        setVisibleWindow(start: session.timelineStart, span: span)
    }

    /// Zoom the timeline to the current waveform loop selection.
    func zoomToSelection() {
        guard let loop = session.loopRegion else { return }
        let selectionSpan = loop.end - loop.start
        let selectionVisibleSpan = max(selectionSpan, TimelineViewport.minimumVisibleSpan)
        let selectionCenter = loop.start + selectionSpan / 2
        let viewport = TimelineViewport.clampedWindow(
            visibleStart: selectionCenter - selectionVisibleSpan / 2,
            visibleSpan: selectionVisibleSpan,
            contentStart: session.timelineStart,
            contentEnd: session.timelineEnd
        )
        setVisibleWindow(start: viewport.start, span: viewport.span)
    }

    /// Pinch-to-zoom, anchored to the cursor (D5). `magnification` is the
    /// trackpad delta; `fraction` is the cursor's `0...1` position across the
    /// timeline.
    func magnifyTimeline(by magnification: Double, atFraction fraction: Double) {
        guard visibleSpan > 0 else { return }
        let span = TimelineViewport.magnifiedVisibleSpan(
            visibleSpan: visibleSpan,
            magnification: magnification
        )
        applyRezoom(span: span, cursorFraction: fraction)
    }

    /// Native horizontal scroll view offset → visible timeline start. The
    /// scroll view owns gesture physics, including elastic bounce at the edges.
    func scrollTimeline(toVisibleStart newVisibleStart: TimeInterval) {
        guard visibleSpan > 0 else { return }
        setVisibleWindow(start: newVisibleStart)
    }

    private func applyRezoom(span: TimeInterval, cursorFraction: Double?) {
        guard session.timelineEnd > session.timelineStart else { return }
        let clampedVisibleSpan = max(visibleSpan, 0.001)

        let anchorTime: TimeInterval
        let anchorFraction: Double
        if let cursorFraction {
            anchorFraction = min(max(cursorFraction, 0), 1)
            anchorTime = visibleStart + anchorFraction * clampedVisibleSpan
        } else {
            let anchor = TimelineViewport.anchor(
                transport: currentTransportPosition(),
                visibleStart: visibleStart,
                visibleSpan: clampedVisibleSpan
            )
            anchorTime = anchor.time
            anchorFraction = anchor.fraction
        }

        let result = TimelineViewport.rezoom(
            newSpan: span,
            anchorTime: anchorTime,
            anchorFraction: anchorFraction,
            contentStart: session.timelineStart,
            contentEnd: session.timelineEnd
        )
        setVisibleWindow(start: result.start, span: result.span)
    }

    /// While playing and zoomed in, page the window forward when the playhead
    /// runs off the edge (D6). Between pages `visibleStart` is left untouched so
    /// the timeline holds still. Suppressed while a scroll is animating (the
    /// tween is already moving the window).
    private func followPlayheadIfZoomed(transport: TimeInterval) {
        guard scrollAnimation == nil else { return }

        let contentSpan = session.timelineEnd - session.timelineStart
        guard contentSpan > 0,
              !TimelineViewport.isFit(visibleSpan: visibleSpan, contentSpan: contentSpan)
        else { return }

        guard let newStart = TimelineViewport.pagedStart(
            transport: transport,
            visibleStart: visibleStart,
            visibleSpan: visibleSpan,
            contentStart: session.timelineStart,
            contentEnd: session.timelineEnd
        ) else { return }

        // Animate the page turn rather than snapping the window forward.
        startScrollAnimation(to: newStart, duration: Self.pageAnimationDuration)
    }

    /// On play, if the playhead sits outside the visible window, animate the
    /// scroll that brings it into view rather than jumping — the motion shows
    /// where the view shifted.
    private func animateScrollToPlayheadIfNeeded() {
        let contentSpan = session.timelineEnd - session.timelineStart
        guard contentSpan > 0,
              !TimelineViewport.isFit(visibleSpan: visibleSpan, contentSpan: contentSpan),
              let newStart = TimelineViewport.pagedStart(
                  transport: currentTransportPosition(),
                  visibleStart: visibleStart,
                  visibleSpan: visibleSpan,
                  contentStart: session.timelineStart,
                  contentEnd: session.timelineEnd
              )
        else { return }

        startScrollAnimation(to: newStart, duration: Self.scrollCatchUpDuration)
    }

    /// Start a tween of `visibleStart` to `newStart`. Returns `false` (and does
    /// nothing) if the window is already there.
    @discardableResult
    private func startScrollAnimation(to newStart: TimeInterval, duration: CFTimeInterval) -> Bool {
        let from = visibleStart
        guard abs(newStart - from) > 0.0001 else { return false }

        scrollAnimation = ScrollAnimation(
            from: from,
            to: newStart,
            startedAt: CACurrentMediaTime(),
            duration: duration
        )
        scrollAnimationTimer?.invalidate()
        scrollAnimationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.advanceScrollAnimation()
            }
        }
        return true
    }

    private func advanceScrollAnimation() {
        guard let animation = scrollAnimation else {
            stopScrollAnimation()
            return
        }

        let progress = min(1, (CACurrentMediaTime() - animation.startedAt) / animation.duration)
        // easeOutCubic — decelerates into place.
        let eased = 1 - pow(1 - progress, 3)
        setVisibleWindow(start: animation.from + (animation.to - animation.from) * eased)

        if progress >= 1 {
            setVisibleWindow(start: animation.to)
            stopScrollAnimation()
        }
    }

    private func stopScrollAnimation() {
        scrollAnimationTimer?.invalidate()
        scrollAnimationTimer = nil
        scrollAnimation = nil
    }

    nonisolated static func transportPositionAfterTimelineRecalculation(
        currentPosition: TimeInterval,
        timelineStart: TimeInterval,
        timelineEnd: TimeInterval,
        preferZero: Bool
    ) -> TimeInterval {
        if preferZero, timelineStart <= 0, timelineEnd >= 0 {
            return 0
        }

        return TransportMapping.clampedTransport(
            currentPosition,
            timelineStart: timelineStart,
            timelineEnd: timelineEnd
        )
    }

    nonisolated static func silenceChunkDurations(
        duration: TimeInterval,
        maximumChunkDuration: TimeInterval = maximumSilenceBufferDuration
    ) -> [TimeInterval] {
        guard duration > 0, maximumChunkDuration > 0 else { return [] }

        var chunks: [TimeInterval] = []
        var remaining = duration
        while remaining > 0 {
            let chunk = min(remaining, maximumChunkDuration)
            chunks.append(chunk)
            remaining -= chunk
        }
        return chunks
    }

    /// What playback should do when it reaches the end of the playable range.
    enum EndAction: Equatable {
        case stop
        case restart
        case switchThenRestart
    }

    /// Decide the end-of-range behaviour from the repeat mode. With a single track
    /// there is no next track, so Switch & Repeat degrades to a plain restart.
    nonisolated static func advanceAtEnd(mode: RepeatMode, canSwitch: Bool) -> EndAction {
        switch mode {
        case .off:
            return .stop
        case .one:
            return .restart
        case .switchAndRepeat:
            return canSwitch ? .switchThenRestart : .restart
        }
    }

    private func configureEngine() {
        guard !engineConfigured else { return }

        engineConfigured = true
        applyAudibility()
    }

    private func attachRuntimeTrack(for trackID: SessionTrack.ID, file: AVAudioFile) {
        detachRuntimeTrack(for: trackID)

        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()

        engine.attach(player)
        engine.attach(mixer)
        engine.connect(player, to: mixer, format: nil)
        engine.connect(mixer, to: engine.mainMixerNode, format: nil)

        runtimeTracksByID[trackID] = RuntimeTrack(file: file, player: player, mixer: mixer)
        applyAudibility()
    }

    private func detachRuntimeTrack(for trackID: SessionTrack.ID) {
        guard let runtime = runtimeTracksByID.removeValue(forKey: trackID) else { return }
        runtime.player.stop()
        engine.detach(runtime.player)
        engine.detach(runtime.mixer)
    }

    private func ensureEngineRunning() throws {
        configureEngine()
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                throw PlaybackError.engineStartFailed
            }
        }
    }

    func handleAudioEngineConfigurationChange() {
        guard session.isPlaying else { return }

        let resumePosition = currentTransportPosition()
        session.transportPosition = resumePosition

        do {
            try ensureEngineRunning()
            try reschedulePlayers(startingAt: resumePosition)
            startScheduledPlayers()
            playbackStartedFromTransport = session.transportPosition
            playbackStartedAt = CACurrentMediaTime()
            applyAudibility()
        } catch let error as PlaybackError {
            failImportPlaybackResume(with: error, at: resumePosition)
        } catch {
            failImportPlaybackResume(with: .schedulingFailed, at: resumePosition)
        }
    }

    private func reschedulePlayers(startingAt globalTime: TimeInterval) throws {
        let transport = TransportMapping.clampedTransport(
            globalTime,
            timelineStart: session.timelineStart,
            timelineEnd: session.timelineEnd
        )

        try scheduleTracks(
            session.tracks.map(\.id),
            startingAt: transport,
            stoppingExistingSchedule: true
        )

        session.transportPosition = transport
    }

    private func startScheduledPlayers() {
        guard session.isPlayable else { return }
        startScheduledPlayers(for: session.tracks.map(\.id))
    }

    private func startScheduledPlayers(for trackIDs: [SessionTrack.ID]) {
        guard session.isPlayable else { return }
        for trackID in trackIDs {
            guard let runtime = runtimeTracksByID[trackID] else { continue }
            runtime.player.play()
        }
    }

    private func scheduleTracks(
        _ trackIDs: [SessionTrack.ID],
        startingAt globalTime: TimeInterval,
        stoppingExistingSchedule: Bool
    ) throws {
        guard session.isPlayable else {
            throw PlaybackError.schedulingFailed
        }

        for trackID in trackIDs {
            guard let sessionTrack = session.tracks.first(where: { $0.id == trackID }),
                  let runtime = runtimeTracksByID[trackID] else {
                continue
            }
            if stoppingExistingSchedule {
                runtime.player.stop()
            }
            scheduleTrack(
                sessionTrack.loadedTrack,
                file: runtime.file,
                on: runtime.player,
                atGlobalTime: globalTime
            )
        }
    }

    private func appendPlaybackAfterDeselectingLoop(_ previousLoop: LoopRegion, currentPosition: TimeInterval) {
        guard session.isPlayable else { return }
        do {
            for sessionTrack in session.tracks {
                let continuationStart = trackHadPlaybackScheduledThroughLoopEnd(
                    sessionTrack.loadedTrack,
                    loop: previousLoop,
                    currentPosition: currentPosition
                ) ? previousLoop.end : currentPosition
                try scheduleTracks(
                    [sessionTrack.id],
                    startingAt: continuationStart,
                    stoppingExistingSchedule: false
                )
            }
        } catch let error as PlaybackError {
            playbackError = error
            stopAtEnd()
        } catch {
            playbackError = .schedulingFailed
            stopAtEnd()
        }
    }

    private func appendLoopExtension(from previousLoop: LoopRegion, currentPosition: TimeInterval) {
        guard session.isPlayable else { return }
        let extensionStart = max(previousLoop.end, currentPosition)
        guard extensionStart < session.playbackEnd else { return }

        do {
            try scheduleTracks(
                session.tracks.map(\.id),
                startingAt: extensionStart,
                stoppingExistingSchedule: false
            )
        } catch let error as PlaybackError {
            playbackError = error
            stopAtEnd()
        } catch {
            playbackError = .schedulingFailed
            stopAtEnd()
        }
    }

    nonisolated static func canResizeLoopWithoutRescheduling(
        from previousLoop: LoopRegion,
        to resizedLoop: LoopRegion,
        transport: TimeInterval
    ) -> Bool {
        resizedLoop.end >= previousLoop.end
            && transport >= resizedLoop.start
            && transport < resizedLoop.end
    }

    private func trackHadPlaybackScheduledThroughLoopEnd(
        _ track: LoadedTrack,
        loop: LoopRegion,
        currentPosition: TimeInterval
    ) -> Bool {
        let trackStart = track.offsetSeconds
        let trackEnd = track.offsetSeconds + track.duration
        return trackStart < loop.end && trackEnd > currentPosition
    }

    private func recalculateSessionDuration(preferZero: Bool = false) {
        let previousContentSpan = session.timelineEnd - session.timelineStart

        guard let range = TransportMapping.timelineRange(tracks: session.tracks.map(\.loadedTrack)) else {
            session.timelineStart = 0
            session.timelineEnd = 0
            session.transportPosition = 0
            setVisibleWindow(start: 0, span: 0)
            clearLoop()
            return
        }

        session.timelineStart = range.lowerBound
        session.timelineEnd = range.upperBound

        // Keep the loop within the (possibly changed) timeline; drop it if it no
        // longer fits, restoring the prior repeat mode.
        if let loop = session.loopRegion {
            if let clamped = LoopRegion.normalized(
                start: loop.start,
                end: loop.end,
                timelineStart: session.timelineStart,
                timelineEnd: session.timelineEnd
            ) {
                session.loopRegion = clamped
            } else {
                clearLoop()
            }
        }
        let recalculationPosition = currentTransportPosition()
        session.transportPosition = Self.transportPositionAfterTimelineRecalculation(
            currentPosition: recalculationPosition,
            timelineStart: session.timelineStart,
            timelineEnd: session.timelineEnd,
            preferZero: preferZero || recalculationPosition == 0
        )

        let viewport = TimelineViewport.adjustedForContentChange(
            visibleStart: visibleStart,
            visibleSpan: visibleSpan,
            previousContentSpan: previousContentSpan,
            contentStart: session.timelineStart,
            contentEnd: session.timelineEnd
        )
        setVisibleWindow(start: viewport.start, span: viewport.span)

        playbackError = nil
    }

    private func scheduleTrack(
        _ track: LoadedTrack,
        file: AVAudioFile,
        on player: AVAudioPlayerNode,
        atGlobalTime globalTime: TimeInterval
    ) {
        let filePosition = TransportMapping.filePosition(
            forGlobalTime: globalTime,
            offset: track.offsetSeconds
        )

        if filePosition >= track.duration {
            return
        }

        // When a loop is active, cap everything at the loop end so no audio past
        // the loop is ever heard. The transport clock still wraps precisely; the
        // worst case is a sub-tick silent tail at the loop seam.
        let loopEnd = session.loopRegion?.end

        if filePosition < 0 {
            let delaySeconds = -filePosition
            if let loopEnd {
                // The file becomes audible at global time == offset; anything that
                // would sound after the loop end is dropped.
                let audibleSeconds = loopEnd - track.offsetSeconds
                guard audibleSeconds > 0 else { return }
                scheduleSilence(on: player, format: file.processingFormat, duration: min(delaySeconds, loopEnd - globalTime))
                let loopFrames = AVAudioFramePosition(audibleSeconds * track.sampleRate)
                let frameCount = min(file.length, loopFrames)
                guard frameCount > 0 else { return }
                player.scheduleSegment(file, startingFrame: 0, frameCount: AVAudioFrameCount(frameCount), at: nil)
                return
            }
            scheduleSilence(on: player, format: file.processingFormat, duration: delaySeconds)
            player.scheduleSegment(
                file,
                startingFrame: 0,
                frameCount: AVAudioFrameCount(file.length),
                at: nil
            )
            return
        }

        let frame = AVAudioFramePosition(filePosition * track.sampleRate)
        var framesRemaining = max(0, file.length - frame)
        guard framesRemaining > 0 else { return }
        if let loopEnd {
            let loopFrames = AVAudioFramePosition(max(0, loopEnd - globalTime) * track.sampleRate)
            framesRemaining = min(framesRemaining, loopFrames)
            guard framesRemaining > 0 else { return }
        }
        player.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(framesRemaining), at: nil)
    }

    private func scheduleSilence(on player: AVAudioPlayerNode, format: AVAudioFormat, duration: TimeInterval) {
        for chunkDuration in Self.silenceChunkDurations(duration: duration) {
            let frameLength = AVAudioFrameCount(max(0, chunkDuration * format.sampleRate))
            guard frameLength > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
                continue
            }

            buffer.frameLength = frameLength
            let audioBufferList = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for audioBuffer in audioBufferList {
                if let data = audioBuffer.mData {
                    memset(data, 0, Int(audioBuffer.mDataByteSize))
                }
            }

            player.scheduleBuffer(buffer, at: nil, options: [])
        }
    }

    private func applyAudibility() {
        guard engineConfigured else { return }

        for sessionTrack in session.tracks {
            guard let runtime = runtimeTracksByID[sessionTrack.id] else { continue }
            let gain = TransportMapping.linearGain(fromDB: sessionTrack.loadedTrack.gainDB)
            runtime.mixer.outputVolume = session.activeTrackID == sessionTrack.id ? gain : 0
        }
    }

    private func runtimeTracksInSessionOrder() -> [RuntimeTrack] {
        session.tracks.compactMap { runtimeTracksByID[$0.id] }
    }

    private func trackIndex(forHotkey hotkey: Int) -> Int? {
        guard (0...9).contains(hotkey) else { return nil }

        if hotkey == 0 {
            guard !session.tracks.isEmpty else { return nil }
            return session.tracks.index(before: session.tracks.endIndex)
        }

        return hotkey - 1
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshTransportTick()
            }
        }
    }

    private func refreshTransportTick() {
        guard session.isPlaying else { return }
        let transport = currentTransportPosition()
        // Deliberately no `session.transportPosition` write here: `session` is
        // one observable property, so a per-tick write would invalidate every
        // view reading any part of it — the exact coarse invalidation this
        // architecture avoids. During playback the position is derived from
        // the schedule anchors (`displayTransportPosition()`); the stored
        // position is written only at anchor events (play/pause/seek/stop/
        // wrap), keeping it correct whenever playback is not running.
        followPlayheadIfZoomed(transport: transport)

        let readoutText = transport.formattedSignedTimestamp
        if readoutText != playingReadoutText {
            playingReadoutText = readoutText
        }

        guard transport >= session.playbackEnd else { return }

        switch Self.advanceAtEnd(mode: session.repeatMode, canSwitch: session.canSwitchPlayback) {
        case .stop:
            stopAtEnd()
        case .restart:
            restartPlayback(from: session.playbackStart)
        case .switchThenRestart:
            selectNextTrack()
            restartPlayback(from: session.playbackStart)
        }
    }

    /// Stop playback at the end of the playable range (Repeat Off).
    /// Repeat Off: stop at the end of the playable range, leaving the playhead
    /// parked there. The next `play()` rewinds to the start of the range.
    private func stopAtEnd() {
        for runtime in runtimeTracksInSessionOrder() {
            runtime.player.stop()
        }
        session.isPlaying = false
        session.transportPosition = session.playbackEnd
        transportStoppedAtTimelineStart = false
        playbackStartedAt = nil
        playbackStartedFromTransport = session.transportPosition
        timer?.invalidate()
        applyAudibility()
        pauseEngine()
    }

    /// Jump the playhead back to `start` and keep playing without tearing the
    /// timer/scroll down — the loop/repeat wrap.
    private func restartPlayback(from start: TimeInterval) {
        let clamped = TransportMapping.clampedTransport(
            start,
            timelineStart: session.timelineStart,
            timelineEnd: session.timelineEnd
        )
        session.transportPosition = clamped
        do {
            try reschedulePlayers(startingAt: clamped)
            startScheduledPlayers()
            playbackStartedFromTransport = clamped
            playbackStartedAt = CACurrentMediaTime()
            applyAudibility()
        } catch let error as PlaybackError {
            playbackError = error
            stopAtEnd()
        } catch {
            playbackError = .schedulingFailed
            stopAtEnd()
        }
    }

    private func currentTransportPosition() -> TimeInterval {
        guard session.isPlaying, let playbackStartedAt else {
            return TransportMapping.clampedTransport(
                session.transportPosition,
                timelineStart: session.timelineStart,
                timelineEnd: session.timelineEnd
            )
        }

        let elapsed = CACurrentMediaTime() - playbackStartedAt
        return TransportMapping.clampedTransport(
            playbackStartedFromTransport + elapsed,
            timelineStart: session.timelineStart,
            timelineEnd: session.timelineEnd
        )
    }

    /// The transport position to display right now.
    ///
    /// While playing this is derived from the schedule anchors and the clock —
    /// not the periodically written `transportPosition` — so a
    /// display-refresh-rate caller (the `TimelineView`-driven playhead) gets
    /// smooth motion, and reading it in a view body does not subscribe that
    /// view to per-tick state writes. While paused it falls back to
    /// `transportPosition`, whose writes are then only user seeks.
    func displayTransportPosition() -> TimeInterval {
        currentTransportPosition()
    }

    /// Transport state relevant to Now Playing info and remote command
    /// enablement. Built to be read inside `withObservationTracking`: every
    /// field it derives from is observable, and while playing the elapsed time
    /// comes from the schedule anchors, so the snapshot's dependencies change
    /// on play/pause/seek/track-switch/loop-wrap — never on a 20 Hz tick. The
    /// system extrapolates playback position from `elapsed` + `rate`, so no
    /// periodic Now-Playing writes are needed.
    struct RemotePlaybackSnapshot: Equatable {
        var isPlayable: Bool
        var isPlaying: Bool
        var canSwitchPlayback: Bool
        var title: String
        var duration: TimeInterval
        var elapsed: TimeInterval
        var trackNumber: Int?
        var trackCount: Int
    }

    func remotePlaybackSnapshot() -> RemotePlaybackSnapshot {
        let title: String
        if session.isBlindListeningModeEnabled, let activeTrackIndex = session.activeTrackIndex {
            title = "Track \(activeTrackIndex + 1)"
        } else {
            title = session.activeTrack?.loadedTrack.displayName ?? "Takes"
        }

        return RemotePlaybackSnapshot(
            isPlayable: session.isPlayable,
            isPlaying: session.isPlaying,
            canSwitchPlayback: session.canSwitchPlayback,
            title: title,
            duration: session.playbackEnd - session.playbackStart,
            elapsed: currentTransportPosition() - session.playbackStart,
            trackNumber: session.activeTrackIndex.map { $0 + 1 },
            trackCount: session.tracks.count
        )
    }
}
