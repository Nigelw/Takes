import AVFoundation
import Testing
@testable import TrackSwitch

struct TransportMappingTests {
    @Test
    func filePositionAccountsForOffsetAndSessionStart() {
        let position = TransportMapping.filePosition(
            forRelativeTransport: 2,
            sessionStart: 1.5,
            offset: 0.5
        )

        #expect(position == 3)
    }

    @Test
    func sessionRangeUsesUnionOfTrackWindows() throws {
        let trackA = makeTrack(duration: 10, offset: 0)
        let trackB = makeTrack(duration: 8, offset: 1.5)

        let range = try #require(TransportMapping.sessionRange(trackA: trackA, trackB: trackB))
        #expect(range.lowerBound == 0)
        #expect(range.upperBound == 10)
    }

    @Test
    func sessionRangeCoversTracksEvenWhenTheyDoNotOverlap() throws {
        let trackA = makeTrack(duration: 5, offset: 0)
        let trackB = makeTrack(duration: 5, offset: 6)

        let range = try #require(TransportMapping.sessionRange(trackA: trackA, trackB: trackB))
        #expect(range.lowerBound == 0)
        #expect(range.upperBound == 11)
    }

    @Test
    func trackValidityUsesOwnFileWindowWithinSession() {
        let track = makeTrack(duration: 5, offset: 2)

        #expect(!TransportMapping.isTrackAudible(track, atRelativeTransport: 1, sessionStart: 0))
        #expect(TransportMapping.isTrackAudible(track, atRelativeTransport: 2, sessionStart: 0))
        #expect(TransportMapping.isTrackAudible(track, atRelativeTransport: 7, sessionStart: 0))
        #expect(!TransportMapping.isTrackAudible(track, atRelativeTransport: 7.01, sessionStart: 0))
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
