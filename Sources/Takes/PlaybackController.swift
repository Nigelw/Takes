import AVFoundation
import Combine
import Foundation

@MainActor
final class PlaybackController: ObservableObject {
    static let maximumTrackCount = 32

    @Published private(set) var session = ComparisonSession()
    @Published private(set) var playbackError: PlaybackError?

    private let loader: AudioFileLoading
    private let libraryTrackSelector: LibraryTrackSelecting
    private let engine = AVAudioEngine()
    nonisolated private static let maximumSilenceBufferDuration: TimeInterval = 5

    private var engineConfigured = false
    private var runtimeTracksByID: [SessionTrack.ID: RuntimeTrack] = [:]
    private var playbackStartedAt: CFTimeInterval?
    private var playbackStartedFromTransport: TimeInterval = 0
    private var transportStoppedAtTimelineStart = true
    private var timer: Timer?
    private var scrollAnimationTimer: Timer?
    private var scrollAnimation: ScrollAnimation?

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

    init(
        loader: AudioFileLoading = AudioFileLoader(),
        libraryTrackSelector: LibraryTrackSelecting = LibraryTrackSelectionLoader()
    ) {
        self.loader = loader
        self.libraryTrackSelector = libraryTrackSelector
    }

    func loadImportedFiles(_ urls: [URL]) async {
        await loadImportedFiles(urls, additionalFailures: [])
    }

    private func loadImportedFiles(_ urls: [URL], additionalFailures: [ImportFailure]) async {
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
                preparedLoads.append(try prepareTrackLoad(from: url))
            } catch let error as PlaybackError {
                failures.append(ImportFailure(url: url, message: error.localizedDescription))
            } catch {
                failures.append(ImportFailure(url: url, message: PlaybackError.failedToOpenFile(url).localizedDescription))
            }
        }

        var resumePosition: TimeInterval?
        if wasPlaying, !preparedLoads.isEmpty {
            resumePosition = currentTransportPosition()
        }

        if !preparedLoads.isEmpty {
            preparedLoads.forEach(appendPreparedTrackLoad)
            finishTrackLoading(preferZero: !wasPlaying && transportStoppedAtTimelineStart)
            if let resumePosition, !restorePlaybackAfterImportAppend(at: resumePosition) {
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
    }

    private static func timelineIdentityURL(for url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    @discardableResult
    private func restorePlaybackAfterImportAppend(at resumePosition: TimeInterval) -> Bool {
        let restoredPosition = TransportMapping.clampedTransport(
            resumePosition,
            timelineStart: session.timelineStart,
            timelineEnd: session.timelineEnd
        )
        session.transportPosition = restoredPosition

        if engineConfigured {
            do {
                try reschedulePlayers(startingAt: restoredPosition)
                startScheduledPlayers()
            } catch let error as PlaybackError {
                failImportPlaybackResume(with: error, at: restoredPosition)
                return false
            } catch {
                failImportPlaybackResume(with: .schedulingFailed, at: restoredPosition)
                return false
            }
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
            await loadImportedFiles(selection.urls, additionalFailures: selection.failures)
        } catch let error as PlaybackError {
            playbackError = error
        } catch {
            playbackError = .librarySelectionFailed("Could not load the selected track from Music.")
        }
    }

    func setPlaybackError(_ error: PlaybackError) {
        playbackError = error
    }

    func clearPlaybackError() {
        playbackError = nil
    }

    private func prepareTrackLoad(from url: URL) throws -> PreparedTrackLoad {
        let metadata = try loader.loadTrackMetadata(from: url)
        let file = try loader.makeAudioFile(from: url)
        return PreparedTrackLoad(metadata: metadata, file: file)
    }

    private func appendPreparedTrackLoad(_ preparedLoad: PreparedTrackLoad) {
        let sessionTrack = SessionTrack(loadedTrack: preparedLoad.metadata)
        session.tracks.append(sessionTrack)
        configureEngine()
        attachRuntimeTrack(for: sessionTrack.id, file: preparedLoad.file)
        if session.activeTrackID == nil {
            session.activeTrackID = sessionTrack.id
        }
    }

    private func finishTrackLoading(preferZero: Bool = true) {
        playbackError = nil
        recalculateSessionDuration(preferZero: preferZero)
        applyAudibility()
    }

    func play() {
        guard session.isPlayable else { return }
        playbackError = nil
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
    }

    func seek(to seconds: TimeInterval) {
        guard session.isPlayable else { return }
        stopScrollAnimation()
        let clamped = TransportMapping.clampedTransport(
            seconds,
            timelineStart: session.timelineStart,
            timelineEnd: session.timelineEnd
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
            let preparedLoad = try prepareTrackLoad(from: url)
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

        if wasActive {
            pause()
        }

        session.tracks.remove(at: removedIndex)
        detachRuntimeTrack(for: trackID)

        if wasActive {
            if session.tracks.indices.contains(removedIndex) {
                session.activeTrackID = session.tracks[removedIndex].id
            } else {
                session.activeTrackID = session.tracks.last?.id
            }
        }

        recalculateSessionDuration()

        if wasPlaying, !wasActive, let resumePosition {
            restorePlaybackAfterTrackMutation(at: resumePosition)
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
        runtimeTracksByID.removeAll()
        session.tracks.removeAll()
        session.activeTrackID = nil
        session.isPlaying = false
        transportStoppedAtTimelineStart = true
        playbackStartedAt = nil
        playbackStartedFromTransport = 0
        timer?.invalidate()
        recalculateSessionDuration()
        applyAudibility()
    }

    func setGain(_ trackID: SessionTrack.ID, db: Float) {
        guard let index = session.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        session.tracks[index].loadedTrack.gainDB = db
        applyAudibility()
    }

    func setOffset(_ trackID: SessionTrack.ID, seconds: TimeInterval) {
        guard let index = session.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        session.tracks[index].loadedTrack.offsetSeconds = seconds

        recalculateSessionDuration()

        guard session.isPlaying else { return }
        do {
            try reschedulePlayers(startingAt: session.transportPosition)
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

    func skip(by delta: TimeInterval) {
        seek(to: session.transportPosition + delta)
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
            visibleSpan: max(session.visibleSpan, TimelineViewport.minimumVisibleSpan),
            zoomingIn: zoomingIn
        )
        applyRezoom(span: span, cursorFraction: nil)
    }

    /// Pinch-to-zoom, anchored to the cursor (D5). `magnification` is the
    /// trackpad delta; `fraction` is the cursor's `0...1` position across the
    /// timeline.
    func magnifyTimeline(by magnification: Double, atFraction fraction: Double) {
        guard session.visibleSpan > 0 else { return }
        let span = session.visibleSpan / (1 + magnification)
        applyRezoom(span: span, cursorFraction: fraction)
    }

    /// Native horizontal scroll view offset → visible timeline start. The
    /// scroll view owns gesture physics, including elastic bounce at the edges.
    func scrollTimeline(toVisibleStart visibleStart: TimeInterval) {
        guard session.visibleSpan > 0 else { return }
        session.visibleStart = visibleStart
    }

    private func applyRezoom(span: TimeInterval, cursorFraction: Double?) {
        guard session.timelineEnd > session.timelineStart else { return }
        let visibleSpan = max(session.visibleSpan, 0.001)

        let anchorTime: TimeInterval
        let anchorFraction: Double
        if let cursorFraction {
            anchorFraction = min(max(cursorFraction, 0), 1)
            anchorTime = session.visibleStart + anchorFraction * visibleSpan
        } else {
            let anchor = TimelineViewport.anchor(
                transport: session.transportPosition,
                visibleStart: session.visibleStart,
                visibleSpan: visibleSpan
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
        session.visibleStart = result.start
        session.visibleSpan = result.span
    }

    /// While playing and zoomed in, page the window forward when the playhead
    /// runs off the edge (D6). Between pages `visibleStart` is left untouched so
    /// the timeline holds still. Suppressed while a scroll is animating (the
    /// tween is already moving the window).
    private func followPlayheadIfZoomed() {
        guard scrollAnimation == nil else { return }

        let contentSpan = session.timelineEnd - session.timelineStart
        guard contentSpan > 0,
              !TimelineViewport.isFit(visibleSpan: session.visibleSpan, contentSpan: contentSpan)
        else { return }

        guard let newStart = TimelineViewport.pagedStart(
            transport: session.transportPosition,
            visibleStart: session.visibleStart,
            visibleSpan: session.visibleSpan,
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
              !TimelineViewport.isFit(visibleSpan: session.visibleSpan, contentSpan: contentSpan),
              let newStart = TimelineViewport.pagedStart(
                  transport: session.transportPosition,
                  visibleStart: session.visibleStart,
                  visibleSpan: session.visibleSpan,
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
        let from = session.visibleStart
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
        session.visibleStart = animation.from + (animation.to - animation.from) * eased

        if progress >= 1 {
            session.visibleStart = animation.to
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

    nonisolated static func transportPositionAtNaturalEnd(timelineEnd: TimeInterval) -> TimeInterval {
        timelineEnd
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

    private func reschedulePlayers(startingAt globalTime: TimeInterval) throws {
        guard session.isPlayable else {
            throw PlaybackError.schedulingFailed
        }

        let transport = TransportMapping.clampedTransport(
            globalTime,
            timelineStart: session.timelineStart,
            timelineEnd: session.timelineEnd
        )

        for sessionTrack in session.tracks {
            guard let runtime = runtimeTracksByID[sessionTrack.id] else { continue }
            runtime.player.stop()
            scheduleTrack(
                sessionTrack.loadedTrack,
                file: runtime.file,
                on: runtime.player,
                atGlobalTime: transport
            )
        }

        session.transportPosition = transport
    }

    private func startScheduledPlayers() {
        guard session.isPlayable else { return }
        for runtime in runtimeTracksInSessionOrder() {
            runtime.player.play()
        }
    }

    private func recalculateSessionDuration(preferZero: Bool = false) {
        let previousContentSpan = session.timelineEnd - session.timelineStart

        guard let range = TransportMapping.timelineRange(tracks: session.tracks.map(\.loadedTrack)) else {
            session.timelineStart = 0
            session.timelineEnd = 0
            session.transportPosition = 0
            session.visibleStart = 0
            session.visibleSpan = 0
            return
        }

        session.timelineStart = range.lowerBound
        session.timelineEnd = range.upperBound
        session.transportPosition = Self.transportPositionAfterTimelineRecalculation(
            currentPosition: session.transportPosition,
            timelineStart: session.timelineStart,
            timelineEnd: session.timelineEnd,
            preferZero: preferZero || session.transportPosition == 0
        )

        let viewport = TimelineViewport.adjustedForContentChange(
            visibleStart: session.visibleStart,
            visibleSpan: session.visibleSpan,
            previousContentSpan: previousContentSpan,
            contentStart: session.timelineStart,
            contentEnd: session.timelineEnd
        )
        session.visibleStart = viewport.start
        session.visibleSpan = viewport.span

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

        if filePosition < 0 {
            let delaySeconds = -filePosition
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
        let framesRemaining = max(0, file.length - frame)
        guard framesRemaining > 0 else { return }
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
        guard (1...9).contains(hotkey) else { return nil }

        if hotkey == 9 {
            guard session.tracks.count > 8 else { return nil }
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
        session.transportPosition = transport
        followPlayheadIfZoomed()
        if transport >= session.timelineEnd {
            for runtime in runtimeTracksInSessionOrder() {
                runtime.player.stop()
            }
            session.isPlaying = false
            session.transportPosition = Self.transportPositionAtNaturalEnd(timelineEnd: session.timelineEnd)
            transportStoppedAtTimelineStart = false
            playbackStartedAt = nil
            playbackStartedFromTransport = session.transportPosition
            timer?.invalidate()
            applyAudibility()
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
}
