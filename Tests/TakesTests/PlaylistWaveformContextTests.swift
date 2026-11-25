import Foundation
import Testing
@testable import Takes

struct PlaylistWaveformContextTests {
    @Test @MainActor
    func removedThenReinsertedVersionRejectsOldCompletion() async {
        let generator = ControlledWaveformGenerator()
        let store = WaveformStore(generator: generator, cache: WaveformCache())
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
        let store = WaveformStore(generator: generator, cache: WaveformCache())
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

    /// Removing, reordering or regrouping a compared item's versions rebuilds
    /// its runtime under a new activation of the same item. Finished waveforms
    /// survive that. Another item's activation takes the same file's waveform
    /// from the cache rather than decoding it again.
    @Test @MainActor
    func reactivatingTheSameItemKeepsFinishedWaveforms() async {
        let generator = ControlledWaveformGenerator()
        let store = WaveformStore(generator: generator, cache: WaveformCache())
        let track = makeTrack()
        let itemID = UUID()
        store.sync(tracks: [track], context: PlaylistRuntimeContext(itemID: itemID))
        await generator.waitForStarts(1)
        await generator.emit(0, peak: 0.8)
        #expect(store.waveform(for: track.id)?.isComplete == true)

        store.sync(tracks: [track], context: PlaylistRuntimeContext(itemID: itemID))
        #expect(store.waveform(for: track.id)?.peaks == [0.8])
        #expect(await generator.startCount == 1)

        store.sync(tracks: [track], context: PlaylistRuntimeContext(itemID: UUID()))
        #expect(store.waveform(for: track.id)?.peaks == [0.8])
        #expect(await generator.startCount == 1)
    }

    /// Leaving compare tears down its view and store; the next store for the
    /// same files draws from the shared cache without decoding.
    @Test @MainActor
    func returningToComparedItemUsesCachedWaveforms() async {
        let cache = WaveformCache()
        let generator = ControlledWaveformGenerator()
        let track = makeTrack()
        let itemID = UUID()
        do {
            let store = WaveformStore(generator: generator, cache: cache)
            store.sync(tracks: [track], context: PlaylistRuntimeContext(itemID: itemID))
            await generator.waitForStarts(1)
            await generator.emit(0, peak: 0.6)
            store.sync(tracks: [], context: nil)
        }
        #expect(cache.count == 1)

        let store = WaveformStore(generator: generator, cache: cache)
        // A new runtime gives the track a new session ID.
        let rebuilt = SessionTrack(loadedTrack: track.loadedTrack)
        store.sync(tracks: [rebuilt], context: PlaylistRuntimeContext(itemID: itemID))
        #expect(store.waveform(for: rebuilt.id)?.peaks == [0.6])
        #expect(store.waveform(for: rebuilt.id)?.isComplete == true)
        #expect(await generator.startCount == 1)
    }

    /// A generation cut off before it finishes leaves nothing in the cache.
    @Test @MainActor
    func unfinishedGenerationIsNotCached() async {
        let cache = WaveformCache()
        let generator = ControlledWaveformGenerator()
        let store = WaveformStore(generator: generator, cache: cache)
        let track = makeTrack()
        store.sync(tracks: [track])
        await generator.waitForStarts(1)
        store.sync(tracks: [])
        await generator.emit(0, peak: 0.5)
        #expect(cache.count == 0)

        store.sync(tracks: [track])
        await generator.waitForStarts(2)
        #expect(store.waveform(for: track.id) == .empty)
    }

    @Test @MainActor
    func cacheSkipsIncompleteAndEmptyWaveforms() {
        let cache = WaveformCache()
        let identity = WaveformSource.Identity(url: URL(fileURLWithPath: "/private/tmp/takes-cache-a.wav"))
        cache.insert(Waveform(peaks: [0.1], bucketCount: 2, isComplete: false), for: identity)
        cache.insert(Waveform(peaks: [], bucketCount: 0, isComplete: true), for: identity)
        #expect(cache.count == 0)
        #expect(cache.waveform(for: identity) == nil)
    }

    @Test @MainActor
    func cacheEvictsLeastRecentlyUsedPastItsByteBudget() {
        let waveform = Waveform(peaks: [Float](repeating: 0.5, count: 100), bucketCount: 100, isComplete: true)
        let size = WaveformCache.bytes(of: waveform)
        let cache = WaveformCache(byteBudget: size * 2)
        let ids = ["a", "b", "c"].map {
            WaveformSource.Identity(url: URL(fileURLWithPath: "/private/tmp/takes-cache-\($0).wav"))
        }
        cache.insert(waveform, for: ids[0])
        cache.insert(waveform, for: ids[1])
        _ = cache.waveform(for: ids[0]) // a is now more recent than b
        cache.insert(waveform, for: ids[2])

        #expect(cache.count == 2)
        #expect(cache.totalBytes == size * 2)
        #expect(cache.waveform(for: ids[0]) != nil)
        #expect(cache.waveform(for: ids[1]) == nil)
        #expect(cache.waveform(for: ids[2]) != nil)

        // Re-inserting the same file replaces its entry, not adds to it.
        cache.insert(waveform, for: ids[2])
        #expect(cache.totalBytes == size * 2)
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

    var startCount: Int { callbacks.count }

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
