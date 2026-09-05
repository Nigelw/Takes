import AVFoundation
import Foundation
import Testing
@testable import Takes

struct PlaylistRuntimeTests {
    @MainActor
    @Test
    func replacementRetainsIDsAdjustmentsConfigurationAndRuntimeCount() async throws {
        let firstURL = try makeTemporaryAudioFile(name: "runtime-first.wav")
        let secondURL = try makeTemporaryAudioFile(name: "runtime-second.wav")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }

        let firstID = UUID()
        let secondID = UUID()
        let firstTrack = SessionTrack(
            id: firstID,
            loadedTrack: makeTrack(url: firstURL, gainDB: -6, offsetSeconds: -0.25)
        )
        let secondTrack = SessionTrack(
            id: secondID,
            loadedTrack: makeTrack(url: secondURL, gainDB: 3, offsetSeconds: 0.5)
        )
        let loop = LoopRegion(start: 0.25, end: 0.75)
        let session = makeSession(
            tracks: [firstTrack, secondTrack],
            activeTrackID: secondID,
            isPlaying: false,
            transportPosition: 0.5,
            repeatMode: .switchAndRepeat,
            isBlindListeningModeEnabled: true,
            loopRegion: loop
        )
        let context = PlaylistRuntimeContext(itemID: UUID())
        let controller = PlaybackController()

        try await controller.replaceRuntimeSession(session, context: context)

        #expect(controller.runtimeContext == context)
        #expect(controller.runtimeTrackCount == 2)
        #expect(controller.session == session)

        let replacement = makeSession(
            tracks: [firstTrack],
            activeTrackID: firstID,
            isPlaying: false,
            transportPosition: 0.2,
            repeatMode: .one
        )
        let replacementContext = PlaylistRuntimeContext(itemID: context.itemID)
        try await controller.replaceRuntimeSession(replacement, context: replacementContext)

        #expect(replacementContext != context)
        #expect(controller.runtimeContext == replacementContext)
        #expect(controller.runtimeTrackCount == 1)
        #expect(controller.session == replacement)
        #expect(controller.session.tracks[0].id == firstID)
        #expect(controller.session.tracks[0].loadedTrack.gainDB == -6)
        #expect(controller.session.tracks[0].loadedTrack.offsetSeconds == -0.25)
    }

    @MainActor
    @Test
    func playingReplacementStartsOnlyTheSuppliedSession() async throws {
        let firstURL = try makeTemporaryAudioFile(name: "runtime-playing-first.wav")
        let secondURL = try makeTemporaryAudioFile(name: "runtime-playing-second.wav")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }

        let firstID = UUID()
        let secondID = UUID()
        let firstSession = makeSession(
            tracks: [SessionTrack(id: firstID, loadedTrack: makeTrack(url: firstURL))],
            activeTrackID: firstID,
            isPlaying: true,
            transportPosition: 0.1
        )
        let secondSession = makeSession(
            tracks: [SessionTrack(id: secondID, loadedTrack: makeTrack(url: secondURL))],
            activeTrackID: secondID,
            isPlaying: true,
            transportPosition: 0.15
        )
        let controller = PlaybackController()
        defer { controller.pause() }

        try await controller.replaceRuntimeSession(
            firstSession,
            context: PlaylistRuntimeContext(itemID: UUID())
        )
        #expect(controller.session.isPlaying)
        #expect(controller.runtimeTrackCount == 1)

        try await controller.replaceRuntimeSession(
            secondSession,
            context: PlaylistRuntimeContext(itemID: UUID())
        )

        #expect(controller.session.isPlaying)
        #expect(controller.session.activeTrackID == secondID)
        #expect(controller.runtimeTrackCount == 1)
    }

    @MainActor
    @Test
    func invalidatingContextRejectsAnOlderImportCompletion() async throws {
        let importedURL = try makeTemporaryAudioFile(name: "runtime-stale-import.wav")
        let replacementURL = try makeTemporaryAudioFile(name: "runtime-replacement.wav")
        defer {
            try? FileManager.default.removeItem(at: importedURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: replacementURL.deletingLastPathComponent())
        }

        let gate = RuntimeLoadGate()
        let controller = PlaybackController(
            loader: DelayedAudioFileLoader(delayedURL: importedURL, gate: gate)
        )
        let importTask = Task { @MainActor in
            await controller.loadImportedFiles([importedURL])
        }
        await gate.waitUntilStarted()

        let replacementID = UUID()
        let replacement = makeSession(
            tracks: [SessionTrack(id: replacementID, loadedTrack: makeTrack(url: replacementURL))],
            activeTrackID: replacementID
        )
        let context = PlaylistRuntimeContext(itemID: UUID())
        try await controller.replaceRuntimeSession(replacement, context: context)
        await gate.release()
        await importTask.value

        #expect(controller.runtimeContext == context)
        #expect(controller.session.tracks.map(\.id) == [replacementID])
        #expect(controller.runtimeTrackCount == 1)
    }

    @MainActor
    @Test
    func invalidationClearsIdentityWithoutDeletingRuntimeOwnedFiles() async throws {
        let url = try makeTemporaryAudioFile(name: "runtime-invalidate.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let id = UUID()
        let session = makeSession(
            tracks: [SessionTrack(id: id, loadedTrack: makeTrack(url: url))],
            activeTrackID: id
        )
        let controller = PlaybackController()
        let context = PlaylistRuntimeContext(itemID: UUID())
        try await controller.replaceRuntimeSession(session, context: context)

        controller.invalidateRuntimeContext()

        #expect(controller.runtimeContext == nil)
        #expect(controller.runtimeTrackCount == 0)
        #expect(controller.session.tracks.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    @Test
    func preparationFailureRetainsThePreviousRuntimeAndUserStopsDoNotEndPlayback() async throws {
        let validURL = try makeTemporaryAudioFile(name: "runtime-valid.wav")
        let missingURL = validURL.deletingLastPathComponent().appendingPathComponent("missing.wav")
        defer { try? FileManager.default.removeItem(at: validURL.deletingLastPathComponent()) }

        let id = UUID()
        let context = PlaylistRuntimeContext(itemID: UUID())
        let session = makeSession(
            tracks: [SessionTrack(id: id, loadedTrack: makeTrack(url: validURL))],
            activeTrackID: id
        )
        let controller = PlaybackController()
        try await controller.replaceRuntimeSession(session, context: context)

        var endedContexts: [PlaylistRuntimeContext?] = []
        controller.onPlaybackEnded = { endedContexts.append($0) }

        let badID = UUID()
        let badSession = makeSession(
            tracks: [SessionTrack(id: badID, loadedTrack: makeTrack(url: missingURL))],
            activeTrackID: badID
        )
        do {
            try await controller.replaceRuntimeSession(
                badSession,
                context: PlaylistRuntimeContext(itemID: UUID())
            )
            Issue.record("Expected replacement of a missing file to fail")
        } catch {
            // The previous runtime remains committed when candidate preparation fails.
        }

        #expect(controller.runtimeContext == context)
        #expect(controller.session == session)
        #expect(controller.runtimeTrackCount == 1)

        controller.pause()
        controller.stop()
        #expect(endedContexts.isEmpty)
    }

    @MainActor
    @Test
    func naturalRepeatOffCompletionCallsBackWithItsActivation() async throws {
        let url = try makeTemporaryAudioFile(name: "runtime-natural-end.wav", duration: 0.1)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let id = UUID()
        let context = PlaylistRuntimeContext(itemID: UUID())
        let session = makeSession(
            tracks: [SessionTrack(id: id, loadedTrack: makeTrack(url: url, duration: 0.1))],
            activeTrackID: id,
            isPlaying: true
        )
        let controller = PlaybackController()
        var endedContexts: [PlaylistRuntimeContext?] = []
        controller.onPlaybackEnded = { endedContexts.append($0) }
        defer { controller.pause() }

        try await controller.replaceRuntimeSession(session, context: context)
        for _ in 0..<100 {
            if !endedContexts.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(endedContexts == [context])
        #expect(controller.session.isPlaying == false)
    }

    private func makeSession(
        tracks: [SessionTrack],
        activeTrackID: SessionTrack.ID?,
        isPlaying: Bool = false,
        transportPosition: TimeInterval = 0,
        repeatMode: RepeatMode = .off,
        isBlindListeningModeEnabled: Bool = false,
        loopRegion: LoopRegion? = nil
    ) -> ComparisonSession {
        let range = TransportMapping.timelineRange(tracks: tracks.map(\.loadedTrack)) ?? 0...0
        return ComparisonSession(
            tracks: tracks,
            activeTrackID: activeTrackID,
            isPlaying: isPlaying,
            transportPosition: transportPosition,
            timelineStart: range.lowerBound,
            timelineEnd: range.upperBound,
            repeatMode: repeatMode,
            isBlindListeningModeEnabled: isBlindListeningModeEnabled,
            loopRegion: loopRegion
        )
    }

    private func makeTrack(
        url: URL,
        duration: TimeInterval = 1,
        gainDB: Float = 0,
        offsetSeconds: TimeInterval = 0
    ) -> LoadedTrack {
        LoadedTrack(
            url: url,
            displayName: url.lastPathComponent,
            fileFormatDescription: "WAV",
            duration: duration,
            sampleRate: 44_100,
            channelCount: 1,
            gainDB: gainDB,
            offsetSeconds: offsetSeconds
        )
    }

    private func makeTemporaryAudioFile(name: String, duration: TimeInterval = 1) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
            throw RuntimeTestError.couldNotCreateAudioFormat
        }
        let frameCount = AVAudioFrameCount(max(1, Int((duration * 44_100).rounded())))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw RuntimeTestError.couldNotCreateAudioFormat
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        buffer.frameLength = frameCount
        try file.write(from: buffer)
        return url
    }
}

private enum RuntimeTestError: Error {
    case couldNotCreateAudioFormat
}

private struct DelayedAudioFileLoader: AudioFileLoading {
    let delayedURL: URL
    let gate: RuntimeLoadGate

    func loadTrackMetadata(from url: URL) async throws -> LoadedTrack {
        if url == delayedURL {
            await gate.markStarted()
            await gate.waitUntilReleased()
        }
        let file = try AVAudioFile(forReading: url)
        return LoadedTrack(
            url: url,
            displayName: url.lastPathComponent,
            fileFormatDescription: "WAV",
            duration: Double(file.length) / file.processingFormat.sampleRate,
            sampleRate: file.processingFormat.sampleRate,
            channelCount: file.processingFormat.channelCount
        )
    }

    func makeAudioFile(from url: URL) throws -> AVAudioFile {
        try AVAudioFile(forReading: url)
    }
}

private actor RuntimeLoadGate {
    private var started = false
    private var released = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func markStarted() {
        started = true
        startedWaiter?.resume()
        startedWaiter = nil
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func waitUntilReleased() async {
        if released { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }
}
