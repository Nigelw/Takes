import AVFoundation
import Testing
@testable import TrackSwitch

struct TransportMappingTests {
    @Test
    func timelineRangeIncludesZeroAndLoadedTrackRangeForSingleTrack() throws {
        let track = makeTrack(duration: 10, offset: 6)

        let range = try #require(TransportMapping.timelineRange(tracks: [track]))

        #expect(range.lowerBound == 0)
        #expect(range.upperBound == 16)
    }

    @Test
    func timelineRangeExpandsBelowZeroForNegativeOffsetsAcrossManyTracks() throws {
        let first = makeTrack(duration: 10, offset: 0)
        let second = makeTrack(duration: 8, offset: -12)
        let third = makeTrack(duration: 4, offset: 20)

        let range = try #require(TransportMapping.timelineRange(tracks: [first, second, third]))

        #expect(range.lowerBound == -12)
        #expect(range.upperBound == 24)
    }

    @Test
    func timelineRangeReturnsNilWithoutTracks() {
        #expect(TransportMapping.timelineRange(tracks: []) == nil)
    }

    @Test
    func filePositionUsesSignedGlobalTimeAndTrackOffset() {
        #expect(TransportMapping.filePosition(forGlobalTime: -8, offset: -10) == 2)
        #expect(TransportMapping.filePosition(forGlobalTime: 3, offset: 5) == -2)
        #expect(TransportMapping.filePosition(forGlobalTime: 9, offset: 5) == 4)
    }

    @Test
    func trackAudibilityUsesSignedGlobalTime() {
        let track = makeTrack(duration: 5, offset: -2)

        #expect(!TransportMapping.isTrackAudible(track, atGlobalTime: -2.01))
        #expect(TransportMapping.isTrackAudible(track, atGlobalTime: -2))
        #expect(TransportMapping.isTrackAudible(track, atGlobalTime: 3))
        #expect(!TransportMapping.isTrackAudible(track, atGlobalTime: 3.01))
    }

    @Test
    func clampTransportAllowsNegativeTimelineBounds() {
        #expect(TransportMapping.clampedTransport(-20, timelineStart: -10, timelineEnd: 12) == -10)
        #expect(TransportMapping.clampedTransport(-5, timelineStart: -10, timelineEnd: 12) == -5)
        #expect(TransportMapping.clampedTransport(20, timelineStart: -10, timelineEnd: 12) == 12)
    }

    @Test
    func normalizedPositionMapsSignedTimeIntoDisplaySpan() {
        #expect(TransportMapping.normalizedPosition(globalTime: -10, timelineStart: -10, timelineEnd: 10) == 0)
        #expect(TransportMapping.normalizedPosition(globalTime: 0, timelineStart: -10, timelineEnd: 10) == 0.5)
        #expect(TransportMapping.normalizedPosition(globalTime: 10, timelineStart: -10, timelineEnd: 10) == 1)
    }

    @Test
    func dbConversionMatchesExpectedLinearGain() {
        #expect(abs(TransportMapping.linearGain(fromDB: 6) - 1.9952623) < 0.0001)
    }

    private func makeTrack(duration: TimeInterval, offset: TimeInterval) -> LoadedTrack {
        LoadedTrack(
            url: URL(fileURLWithPath: "/tmp/test.wav"),
            displayName: "test.wav",
            fileFormatDescription: "WAV",
            duration: duration,
            sampleRate: 44_100,
            channelCount: 2,
            gainDB: 0,
            offsetSeconds: offset
        )
    }
}
