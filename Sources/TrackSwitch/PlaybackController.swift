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

    private var engineConfigured = false
    private var audioFileA: AVAudioFile?
    private var audioFileB: AVAudioFile?
    private var sessionStart: TimeInterval = 0
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
                session.trackA = metadata
                audioFileA = file
                if session.trackB == nil {
                    session.activeTrack = .a
                }
            case .b:
                var adjusted = metadata
                adjusted.offsetSeconds = session.trackB?.offsetSeconds ?? 0
                adjusted.gainDB = session.trackB?.gainDB ?? 0
                session.trackB = adjusted
                audioFileB = file
                if session.trackA == nil {
                    session.activeTrack = .b
                }
            }

            playbackError = nil
            recalculateSessionDuration()
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
            let assignments = try Self.libraryAssignments(for: urls, clickedSide: side)

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
        session.transportPosition = 0
        playbackStartedAt = nil
        playbackStartedFromTransport = 0
        timer?.invalidate()
        applyAudibility()
    }

    func seek(to seconds: TimeInterval) {
        guard session.isPlayable else { return }
        let clamped = TransportMapping.clampedTransport(seconds, duration: session.duration)
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

    nonisolated static func libraryAssignments(
        for urls: [URL],
        clickedSide: TrackSide
    ) throws -> [(TrackSide, URL)] {
        switch urls.count {
        case 1:
            [(clickedSide, urls[0])]
        case 2:
            [(.a, urls[0]), (.b, urls[1])]
        default:
            throw PlaybackError.librarySelectionFailed("Select one or two tracks in Music.")
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

    private func reschedulePlayers(startingAt relativeTransport: TimeInterval) throws {
        guard session.duration > 0 else {
            throw PlaybackError.schedulingFailed
        }

        let transport = TransportMapping.clampedTransport(relativeTransport, duration: session.duration)
        let absoluteTransport = TransportMapping.absoluteTransportPosition(
            relativeTransport: transport,
            sessionStart: sessionStart
        )
        playerA.stop()
        playerB.stop()

        if let trackA = session.trackA, let fileA = audioFileA {
            scheduleTrack(
                trackA,
                file: fileA,
                on: playerA,
                atRelativeTransport: transport,
                absoluteTransport: absoluteTransport
            )
        }

        if let trackB = session.trackB, let fileB = audioFileB {
            scheduleTrack(
                trackB,
                file: fileB,
                on: playerB,
                atRelativeTransport: transport,
                absoluteTransport: absoluteTransport
            )
        }

        session.transportPosition = transport
    }

    private func recalculateSessionDuration() {
        if let trackA = session.trackA, let trackB = session.trackB {
            guard let range = TransportMapping.sessionRange(trackA: trackA, trackB: trackB) else {
                session.duration = 0
                session.transportPosition = 0
                sessionStart = 0
                overlapWarning = nil
                return
            }

            sessionStart = range.lowerBound
            session.duration = range.upperBound - range.lowerBound
            session.transportPosition = TransportMapping.clampedTransport(session.transportPosition, duration: session.duration)
            let overlapDuration = TransportMapping.validOverlapDuration(trackA: trackA, trackB: trackB)
            if overlapDuration == 0 {
                overlapWarning = "Track A and Track B do not overlap at the current offsets."
            } else if overlapDuration < min(trackA.duration, trackB.duration) {
                overlapWarning = "Offsets reduce the shared compare range to \(overlapDuration.formattedTimestamp)."
            } else {
                overlapWarning = nil
            }
            playbackError = nil
            return
        }

        if let trackA = session.trackA {
            sessionStart = trackA.offsetSeconds
            session.duration = trackA.duration
            session.transportPosition = TransportMapping.clampedTransport(session.transportPosition, duration: session.duration)
            overlapWarning = nil
            return
        }

        if let trackB = session.trackB {
            sessionStart = trackB.offsetSeconds
            session.duration = trackB.duration
            session.transportPosition = TransportMapping.clampedTransport(session.transportPosition, duration: session.duration)
            overlapWarning = nil
            return
        }

        session.duration = 0
        sessionStart = 0
        overlapWarning = nil
    }

    private func scheduleTrack(
        _ track: LoadedTrack,
        file: AVAudioFile,
        on player: AVAudioPlayerNode,
        atRelativeTransport relativeTransport: TimeInterval,
        absoluteTransport: TimeInterval
    ) {
        let filePosition = absoluteTransport - track.offsetSeconds

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
        let frameLength = AVAudioFrameCount(max(0, duration * format.sampleRate))
        guard frameLength > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return
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
        if transport >= session.duration {
            stop()
        }
    }

    private func currentTransportPosition() -> TimeInterval {
        guard session.isPlaying, let playbackStartedAt else {
            return TransportMapping.clampedTransport(session.transportPosition, duration: session.duration)
        }

        let elapsed = CACurrentMediaTime() - playbackStartedAt
        return TransportMapping.clampedTransport(playbackStartedFromTransport + elapsed, duration: session.duration)
    }
}
