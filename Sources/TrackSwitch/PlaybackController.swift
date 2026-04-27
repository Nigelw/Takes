import AVFoundation
import Combine
import Foundation

@MainActor
final class PlaybackController: ObservableObject {
    static let maximumTrackCount = 32

    @Published private(set) var session = ComparisonSession()
    @Published private(set) var playbackError: PlaybackError?
    @Published private(set) var overlapWarning: String?

    private let loader: AudioFileLoading
    private let libraryTrackSelector: LibraryTrackSelecting
    private let engine = AVAudioEngine()
    private let playerA = AVAudioPlayerNode()
    private let playerB = AVAudioPlayerNode()
    private let mixerA = AVAudioMixerNode()
    private let mixerB = AVAudioMixerNode()
    nonisolated private static let maximumSilenceBufferDuration: TimeInterval = 5

    private var engineConfigured = false
    private var audioFilesByTrackID: [SessionTrack.ID: AVAudioFile] = [:]
    private var playbackStartedAt: CFTimeInterval?
    private var playbackStartedFromTransport: TimeInterval = 0
    private var timer: Timer?

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

    func loadTrack(_ side: TrackSide, from url: URL) async {
        do {
            try loadTrackOrThrow(side, from: url)
        } catch let error as PlaybackError {
            playbackError = error
        } catch {
            playbackError = .failedToOpenFile(url)
        }
    }

    func loadImportedFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }

        let wasPlaying = session.isPlaying
        var preparedLoads: [PreparedTrackLoad] = []
        var failures: [ImportFailure] = []
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
            let urls = try libraryTrackSelector.selectedTrackURLs()
            await loadImportedFiles(urls)
        } catch let error as PlaybackError {
            playbackError = error
        } catch {
            playbackError = .librarySelectionFailed("Could not load the selected track from Music.")
        }
    }

    func setPlaybackError(_ error: PlaybackError) {
        playbackError = error
    }

    private func loadTrackOrThrow(_ side: TrackSide, from url: URL) throws {
        do {
            let preparedLoad = try prepareTrackLoad(from: url)
            stop()
            applyPreparedTrackLoad(preparedLoad, to: side)
            finishTrackLoading()
        } catch let error as PlaybackError {
            throw error
        } catch {
            throw PlaybackError.failedToOpenFile(url)
        }
    }

    private func prepareTrackLoad(from url: URL) throws -> PreparedTrackLoad {
        let metadata = try loader.loadTrackMetadata(from: url)
        let file = try loader.makeAudioFile(from: url)
        return PreparedTrackLoad(metadata: metadata, file: file)
    }

    private func applyPreparedTrackLoad(_ preparedLoad: PreparedTrackLoad, to side: TrackSide) {
        switch side {
        case .a:
            let previousID = session.trackAID
            session.trackA = Self.replacingTrackMetadata(
                preparedLoad.metadata,
                preservingSettingsFrom: session.trackA
            )
            if let previousID {
                audioFilesByTrackID[previousID] = nil
            }
            if let id = session.trackAID {
                audioFilesByTrackID[id] = preparedLoad.file
            }
            if session.trackB == nil {
                session.activeTrack = .a
            }
        case .b:
            let previousID = session.trackBID
            session.trackB = Self.replacingTrackMetadata(
                preparedLoad.metadata,
                preservingSettingsFrom: session.trackB
            )
            if let previousID {
                audioFilesByTrackID[previousID] = nil
            }
            if let id = session.trackBID {
                audioFilesByTrackID[id] = preparedLoad.file
            }
            if session.trackA == nil {
                session.activeTrack = .b
            }
        }
    }

    private func appendPreparedTrackLoad(_ preparedLoad: PreparedTrackLoad) {
        let sessionTrack = SessionTrack(loadedTrack: preparedLoad.metadata)
        session.tracks.append(sessionTrack)
        audioFilesByTrackID[sessionTrack.id] = preparedLoad.file
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
        playerA.pause()
        playerB.pause()
        session.isPlaying = false
        playbackStartedAt = nil
        playbackStartedFromTransport = session.transportPosition
        timer?.invalidate()
    }

    func stop() {
        playerA.stop()
        playerB.stop()
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

    func toggleActiveTrack() {
        guard session.canSwitchPlayback else { return }
        let currentIndex = session.activeTrackIndex ?? -1
        let nextIndex = currentIndex + 1 < session.tracks.count ? currentIndex + 1 : 0
        session.activeTrackID = session.tracks[nextIndex].id
        applyAudibility()
    }

    func selectActiveTrack(_ trackID: SessionTrack.ID) {
        guard session.tracks.contains(where: { $0.id == trackID }) else { return }
        session.activeTrackID = trackID
        applyAudibility()
    }

    func selectActiveTrack(_ side: TrackSide) {
        guard let trackID = trackID(for: side) else { return }
        selectActiveTrack(trackID)
    }

    func replaceTrack(_ trackID: SessionTrack.ID, with url: URL) async {
        guard let index = session.tracks.firstIndex(where: { $0.id == trackID }) else { return }

        do {
            let preparedLoad = try prepareTrackLoad(from: url)
            let wasPlaying = session.isPlaying
            let resumePosition = wasPlaying ? currentTransportPosition() : nil

            session.tracks[index].loadedTrack = preparedLoad.metadata
            audioFilesByTrackID[trackID] = preparedLoad.file
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
        audioFilesByTrackID[trackID] = nil

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

    func setGain(_ side: TrackSide, db: Float) {
        guard let trackID = trackID(for: side) else { return }
        setGain(trackID, db: db)
    }

    func setOffset(_ side: TrackSide, seconds: TimeInterval) {
        guard let trackID = trackID(for: side) else { return }
        setOffset(trackID, seconds: seconds)
    }

    func skip(by delta: TimeInterval) {
        seek(to: session.transportPosition + delta)
    }

    nonisolated static func replacingTrackMetadata(
        _ metadata: LoadedTrack,
        preservingSettingsFrom existingTrack: LoadedTrack?
    ) -> LoadedTrack {
        guard let existingTrack else { return metadata }
        var adjusted = metadata
        adjusted.offsetSeconds = existingTrack.offsetSeconds
        adjusted.gainDB = existingTrack.gainDB
        return adjusted
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

    private func configureEngine() {
        guard !engineConfigured else { return }

        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(mixerA)
        engine.attach(mixerB)

        engine.connect(playerA, to: mixerA, format: nil)
        engine.connect(playerB, to: mixerB, format: nil)
        engine.connect(mixerA, to: engine.mainMixerNode, format: nil)
        engine.connect(mixerB, to: engine.mainMixerNode, format: nil)

        engineConfigured = true
        applyAudibility()
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
        playerA.stop()
        playerB.stop()

        if let trackA = session.trackA,
           let trackAID = trackID(for: .a),
           let fileA = audioFilesByTrackID[trackAID] {
            scheduleTrack(trackA, file: fileA, on: playerA, atGlobalTime: transport)
        }

        if let trackB = session.trackB,
           let trackBID = trackID(for: .b),
           let fileB = audioFilesByTrackID[trackBID] {
            scheduleTrack(trackB, file: fileB, on: playerB, atGlobalTime: transport)
        }

        session.transportPosition = transport
    }

    private func startScheduledPlayers() {
        if let trackAID = trackID(for: .a),
           audioFilesByTrackID[trackAID] != nil {
            playerA.play()
        }
        if let trackBID = trackID(for: .b),
           audioFilesByTrackID[trackBID] != nil {
            playerB.play()
        }
    }

    private func recalculateSessionDuration(preferZero: Bool = false) {
        guard let range = TransportMapping.timelineRange(tracks: session.tracks.map(\.loadedTrack)) else {
            session.timelineStart = 0
            session.timelineEnd = 0
            session.transportPosition = 0
            overlapWarning = nil
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

        if let trackA = session.trackA, let trackB = session.trackB {
            let overlapDuration = TransportMapping.validOverlapDuration(trackA: trackA, trackB: trackB)
            if overlapDuration == 0 {
                overlapWarning = "Track A and Track B do not overlap at the current offsets."
            } else if overlapDuration < min(trackA.duration, trackB.duration) {
                overlapWarning = "Offsets reduce the shared compare range to \(overlapDuration.formattedTimestamp)."
            } else {
                overlapWarning = nil
            }
        } else {
            overlapWarning = nil
        }

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

        let gainA = TransportMapping.linearGain(fromDB: session.trackA?.gainDB ?? 0)
        let gainB = TransportMapping.linearGain(fromDB: session.trackB?.gainDB ?? 0)
        let canPlayA = session.trackA != nil
        let canPlayB = session.trackB != nil

        mixerA.outputVolume = canPlayA && (session.activeTrack == .a || !canPlayB) ? gainA : 0
        mixerB.outputVolume = canPlayB && (session.activeTrack == .b || !canPlayA) ? gainB : 0
    }

    private func trackID(for side: TrackSide) -> SessionTrack.ID? {
        switch side {
        case .a:
            session.trackAID
        case .b:
            session.trackBID
        }
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
            stop()
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
