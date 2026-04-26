import AVFoundation
import Combine
import Foundation

@MainActor
final class PlaybackController: ObservableObject {
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
    private var audioFileA: AVAudioFile?
    private var audioFileB: AVAudioFile?
    private var playbackStartedAt: CFTimeInterval?
    private var playbackStartedFromTransport: TimeInterval = 0
    private var timer: Timer?

    init(
        loader: AudioFileLoading = AudioFileLoader(),
        libraryTrackSelector: LibraryTrackSelecting = LibraryTrackSelectionLoader()
    ) {
        self.loader = loader
        self.libraryTrackSelector = libraryTrackSelector
    }

    func loadTrack(_ side: TrackSide, from url: URL) async {
        do {
            stop()
            let metadata = try loader.loadTrackMetadata(from: url)
            let file = try loader.makeAudioFile(from: url)

            switch side {
            case .a:
                session.trackA = Self.replacingTrackMetadata(metadata, preservingSettingsFrom: session.trackA)
                audioFileA = file
                if session.trackB == nil {
                    session.activeTrack = .a
                }
            case .b:
                session.trackB = Self.replacingTrackMetadata(metadata, preservingSettingsFrom: session.trackB)
                audioFileB = file
                if session.trackA == nil {
                    session.activeTrack = .b
                }
            }

            playbackError = nil
            recalculateSessionDuration(preferZero: true)
            applyAudibility()
        } catch let error as PlaybackError {
            playbackError = error
        } catch {
            playbackError = .failedToOpenFile(url)
        }
    }

    func loadSelectedLibraryTrack(_ side: TrackSide) async {
        do {
            let urls = try libraryTrackSelector.selectedTrackURLs()
            let assignments = try Self.importAssignments(for: urls, in: session)

            for (assignedSide, url) in assignments {
                await loadTrack(assignedSide, from: url)
            }
        } catch let error as PlaybackError {
            playbackError = error
        } catch {
            playbackError = .librarySelectionFailed("Could not load the selected track from Music.")
        }
    }

    func play() {
        guard session.isPlayable else { return }
        playbackError = nil
        do {
            try ensureEngineRunning()
            try reschedulePlayers(startingAt: session.transportPosition)
            if audioFileA != nil {
                playerA.play()
            }
            if audioFileB != nil {
                playerB.play()
            }
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
            if audioFileA != nil {
                playerA.play()
            }
            if audioFileB != nil {
                playerB.play()
            }
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
        guard session.canToggleComparison else { return }
        session.activeTrack = session.activeTrack == .a ? .b : .a
        applyAudibility()
    }

    func setGain(_ side: TrackSide, db: Float) {
        switch side {
        case .a:
            session.trackA?.gainDB = db
        case .b:
            session.trackB?.gainDB = db
        }
        applyAudibility()
    }

    func setOffset(_ side: TrackSide, seconds: TimeInterval) {
        switch side {
        case .a:
            session.trackA?.offsetSeconds = seconds
        case .b:
            session.trackB?.offsetSeconds = seconds
        }

        recalculateSessionDuration()

        guard session.isPlaying else { return }
        do {
            try reschedulePlayers(startingAt: session.transportPosition)
            if audioFileA != nil {
                playerA.play()
            }
            if audioFileB != nil {
                playerB.play()
            }
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

    nonisolated static func importAssignments(
        for urls: [URL],
        in session: ComparisonSession
    ) throws -> [(TrackSide, URL)] {
        switch urls.count {
        case 1:
            if session.trackA == nil {
                return [(.a, urls[0])]
            }
            if session.trackB == nil {
                return [(.b, urls[0])]
            }
            return [(session.activeTrack, urls[0])]
        case 2:
            return [(.a, urls[0]), (.b, urls[1])]
        default:
            throw PlaybackError.tooManyImportFiles
        }
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

        if let trackA = session.trackA, let fileA = audioFileA {
            scheduleTrack(trackA, file: fileA, on: playerA, atGlobalTime: transport)
        }

        if let trackB = session.trackB, let fileB = audioFileB {
            scheduleTrack(trackB, file: fileB, on: playerB, atGlobalTime: transport)
        }

        session.transportPosition = transport
    }

    private func recalculateSessionDuration(preferZero: Bool = false) {
        guard let range = TransportMapping.timelineRange(trackA: session.trackA, trackB: session.trackB) else {
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
