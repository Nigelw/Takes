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
    private var timer: Timer?

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

        for url in urls {
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
            finishTrackLoading(preferZero: !wasPlaying)
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
            playbackStartedFromTransport = session.transportPosition
            playbackStartedAt = CACurrentMediaTime()
            startTimer()
            applyAudibility()
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
        playbackStartedAt = nil
        playbackStartedFromTransport = session.transportPosition
        timer?.invalidate()
    }

    func stop() {
        for runtime in runtimeTracksInSessionOrder() {
            runtime.player.stop()
        }
        session.isPlaying = false
        session.transportPosition = session.timelineStart
        playbackStartedAt = nil
        playbackStartedFromTransport = session.transportPosition
        timer?.invalidate()
        applyAudibility()
    }

    func seek(to seconds: TimeInterval) {
        guard session.isPlayable else { return }
        let clamped = TransportMapping.clampedTransport(
            seconds,
            timelineStart: session.timelineStart,
            timelineEnd: session.timelineEnd
        )
        session.transportPosition = clamped

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
            finishTrackLoading(preferZero: !wasPlaying)

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

        for runtime in runtimeTracksInSessionOrder() {
            runtime.player.stop()
        }
        runtimeTracksByID.removeAll()
        session.tracks.removeAll()
        session.activeTrackID = nil
        session.isPlaying = false
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
        guard let range = TransportMapping.timelineRange(tracks: session.tracks.map(\.loadedTrack)) else {
            session.timelineStart = 0
            session.timelineEnd = 0
            session.transportPosition = 0
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
        if transport >= session.timelineEnd {
            for runtime in runtimeTracksInSessionOrder() {
                runtime.player.stop()
            }
            session.isPlaying = false
            session.transportPosition = Self.transportPositionAtNaturalEnd(timelineEnd: session.timelineEnd)
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
