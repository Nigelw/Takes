import Foundation
import Testing
@testable import Takes

struct TrackMetadataMatcherTests {
    @Test
    func tagsGroupMasteringAndMixVariants() {
        let original = version(title: "Taxman", artist: "The Beatles", duration: 159)
        let remaster = version(title: "Taxman (Remastered 2009)", artist: "Beatles", duration: 161)
        let stereo = version(title: "Taxman (2022 Stereo Remix)", artist: "The Beatles", duration: 158)

        #expect(TrackMetadataMatcher.decision(between: original, and: remaster) == .match)
        #expect(TrackMetadataMatcher.decision(between: original, and: stereo) == .match)
    }

    @Test
    func revolverMonoAndStereoMixesFormOneGroup() {
        let mono = version(
            title: "Got to Get You Into My Life (1967 Mono Mix)",
            artist: "The Beatles",
            duration: 158.56
        )
        let remaster = version(
            title: "Got to Get You Into My Life (2009 Stereo Mix)",
            artist: "The Beatles",
            duration: 149.24
        )
        let stereoRemix = version(
            title: "Got to Get You Into My Life (2022 Stereo Mix)",
            artist: "The Beatles",
            duration: 149.29
        )

        #expect(TrackMetadataMatcher.decision(between: mono, and: remaster) == .match)
        #expect(TrackMetadataMatcher.decision(between: mono, and: stereoRemix) == .match)
        #expect(TrackMetadataMatcher.decision(between: remaster, and: stereoRemix) == .match)
    }

    @Test
    func smallTitleTyposCanMatchButDifferentArtistsCannot() {
        let original = version(title: "Here There and Everywhere", artist: "The Beatles", duration: 145)
        let typo = version(title: "Here, There and Everywher", artist: "Beatles", duration: 146)
        let cover = version(title: "Here There and Everywhere", artist: "Another Artist", duration: 145)

        #expect(TrackMetadataMatcher.decision(between: original, and: typo) == .match)
        #expect(TrackMetadataMatcher.decision(between: original, and: cover) == .mismatch)
    }

    @Test
    func featuredArtistCreditsDoNotSplitTheSameTrack() {
        let credited = version(title: "Example Song (feat. Guest)", artist: "Artist feat. Guest", duration: 200)
        let plain = version(title: "Example Song", artist: "Artist", duration: 201)

        #expect(TrackMetadataMatcher.decision(between: credited, and: plain) == .match)
    }

    @Test
    func filenameFallbackParsesTrackNumberArtistAndTitle() {
        let first = version(filename: "01 - Artist - Example Song (Remastered 2020).flac", duration: 240)
        let second = version(filename: "Artist - Example Song.mp3", duration: 242)

        #expect(TrackMetadataMatcher.decision(between: first, and: second) == .match)
    }

    @Test
    func performanceChangingQualifiersRemainPartOfTheTitle() {
        let studio = version(title: "Where to Begin", artist: "My Morning Jacket", duration: 230)
        let live = version(title: "Where to Begin (Live)", artist: "My Morning Jacket", duration: 231)

        #expect(TrackMetadataMatcher.decision(between: studio, and: live) == .mismatch)
    }

    @Test
    func ordinaryVersionsUseFiveSecondOrFivePercentDurationTolerance() {
        let first = version(title: "Example", artist: "Artist", duration: 200)
        let atLimit = version(title: "Example", artist: "Artist", duration: 210)
        let beyondLimit = version(title: "Example", artist: "Artist", duration: 211)

        #expect(TrackMetadataMatcher.decision(between: first, and: atLimit) == .match)
        #expect(TrackMetadataMatcher.decision(between: first, and: beyondLimit) == .mismatch)
    }

    @Test
    func explicitEditsUseTwoMinuteOrThirtyFivePercentDurationTolerance() {
        let original = version(title: "Example", artist: "Artist", duration: 200)
        let withinLimit = version(title: "Example (Extended Mix)", artist: "Artist", duration: 320)
        let beyondLimit = version(title: "Example (Extended Mix)", artist: "Artist", duration: 330)

        #expect(TrackMetadataMatcher.decision(between: original, and: withinLimit) == .match)
        #expect(TrackMetadataMatcher.decision(between: original, and: beyondLimit) == .mismatch)
    }

    @Test
    func unusableDurationAbstains() {
        let valid = version(title: "Example", artist: "Artist", duration: 200)
        let invalid = version(title: "Example", artist: "Artist", duration: 0)

        #expect(TrackMetadataMatcher.decision(between: valid, and: invalid) == .unknown)
        #expect(!TrackMetadataMatcher.canAttemptMatch(invalid))
    }

    private func version(
        title: String? = nil,
        artist: String? = nil,
        filename: String = "track.wav",
        duration: TimeInterval
    ) -> PlaylistVersion {
        PlaylistVersion(
            file: PlaylistFileReference(storedURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)/\(filename)")),
            metadata: PlaylistMetadata(
                title: title,
                artist: artist,
                duration: duration,
                sampleRate: 44_100,
                channelCount: 2,
                fileFormatDescription: "WAV",
                displayName: filename
            )
        )
    }
}
