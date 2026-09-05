import Foundation
import Testing
@testable import Takes

struct PlaylistWaveformContextTests {
    @Test @MainActor
    func removedThenReinsertedVersionRejectsOldCompletion() async {
        let generator = ControlledWaveformGenerator()
        let store = WaveformStore(generator: generator)
        let track = makeTrack()
        store.sync(tracks: [track])
        await generator.waitForStarts(1)
        store.sync(tracks: [])
        store.sync(tracks: [track])
        await generator.waitForStarts(2)

        await generator.emit(0, peak: 0.9)
        #expect(store.waveform(for: track.id) == .empty)
        await generator.emit(1, peak: 0.2)
        #expect(store.waveform(for: track.id)?.peaks == [0.2])
    }

    @Test @MainActor
    func newActivationRejectsSameFileAndVersionFromPreviousContext() async {
        let generator = ControlledWaveformGenerator()
        let store = WaveformStore(generator: generator)
        let track = makeTrack()
        let itemID = UUID()
        store.sync(tracks: [track], context: PlaylistRuntimeContext(itemID: itemID))
        await generator.waitForStarts(1)
        store.sync(tracks: [track], context: PlaylistRuntimeContext(itemID: itemID))
        await generator.waitForStarts(2)

        await generator.emit(0, peak: 0.8)
        #expect(store.waveform(for: track.id) == .empty)
        await generator.emit(1, peak: 0.3)
        #expect(store.waveform(for: track.id)?.peaks == [0.3])
    }

    private func makeTrack() -> SessionTrack {
        SessionTrack(loadedTrack: LoadedTrack(
            url: URL(fileURLWithPath: "/private/tmp/playlist-waveform-context.wav"),
            displayName: "Fixture", fileFormatDescription: "WAV",
            duration: 10, sampleRate: 44_100, channelCount: 1
        ))
    }
}

private actor ControlledWaveformGenerator: WaveformGenerating {
    private var callbacks: [@Sendable ([Float], Int, Bool) async -> Void] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func generate(url: URL, onProgress: @escaping @Sendable ([Float], Int, Bool) async -> Void) async {
        callbacks.append(onProgress)
        let ready = waiters.filter { $0.0 <= callbacks.count }
        waiters.removeAll { $0.0 <= callbacks.count }
        for (_, continuation) in ready { continuation.resume() }
    }

    func waitForStarts(_ count: Int) async {
        if callbacks.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func emit(_ index: Int, peak: Float) async {
        await callbacks[index]([peak], 1, true)
    }
}
