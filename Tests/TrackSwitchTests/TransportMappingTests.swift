import AVFoundation
import Testing
@testable import TrackSwitch

struct TransportMappingTests {
    @Test
    func filePositionAccountsForOffsetAndOverlapStart() {
        let position = TransportMapping.filePosition(
            forRelativeTransport: 2,
            overlapStart: 1.5,
            offset: 0.5
        )

        #expect(position == 3)
    }

    @Test
    func overlapDurationUsesIntersectionOfTrackWindows() {
        let trackA = makeTrack(duration: 10, offset: 0)
        let trackB = makeTrack(duration: 8, offset: 1.5)

        #expect(TransportMapping.validOverlapDuration(trackA: trackA, trackB: trackB) == 8)
    }

    @Test
    func overlapReturnsZeroWhenOffsetsRemoveIntersection() {
        let trackA = makeTrack(duration: 5, offset: 0)
        let trackB = makeTrack(duration: 5, offset: 6)

        #expect(TransportMapping.validOverlapDuration(trackA: trackA, trackB: trackB) == 0)
    }

    @Test
    func clampedTransportStaysWithinSessionDuration() {
        #expect(TransportMapping.clampedTransport(-1, duration: 10) == 0)
        #expect(TransportMapping.clampedTransport(12, duration: 10) == 10)
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
