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
    func smallTitleTyposCanMatchAcrossArtists() {
        let original = version(title: "Here There and Everywhere", artist: "The Beatles", duration: 145)
        let typo = version(title: "Here, There and Everywher", artist: "Another Artist", duration: 146)

        #expect(TrackMetadataMatcher.decision(between: original, and: typo) == .match)
    }

    @Test
    func featuredArtistCreditsDoNotSplitTheSameTrack() {
        let credited = version(title: "Example Song (feat. Guest)", artist: "Artist feat. Guest", duration: 200)
        let plain = version(title: "Example Song", artist: "Artist", duration: 201)

        #expect(TrackMetadataMatcher.decision(between: credited, and: plain) == .match)
    }

    @Test(arguments: [
        "Another Artist - Example Song (Live 2019.11.12 Colosseum).mp3",
        "Example Song (Live 2019.11.12 - Colosseum).mp3"
    ])
    func filenameFallbackParsesTrackNumberArtistAndTitle(_ filename: String) {
        let first = version(filename: "01 - Artist - Example Song (Remastered 2020).flac", duration: 240)
        let second = version(filename: filename, duration: 242)

        #expect(TrackMetadataMatcher.decision(between: first, and: second) == .match)
    }

    @Test(arguments: ["Live", "Demo", "Acoustic", "Cover", "Alternate Take 2", "Alt Take 3"])
    func performanceMarkersAreStripped(_ marker: String) {
        let studio = version(title: "Where to Begin", duration: 230)
        let alternate = version(title: "Where to Begin - \(marker)", duration: 231)

        #expect(TrackMetadataMatcher.decision(between: studio, and: alternate) == .match)
    }

    @Test(arguments: [
        "(Live 2019.11.12 Colosseum)",
        "(2019.11.12 Live at the Colosseum)",
        "[Demo recorded in 2019]",
        "[2019 studio demo]",
        "(Acoustic session at KEXP) (Remastered 2024)",
        "(Alternate Take 2 from the vault) [Live at the Colosseum]"
    ])
    func trailingPerformanceDescriptionsAreStripped(_ annotation: String) {
        let studio = version(title: "Where to Begin", duration: 230)
        let alternate = version(title: "Where to Begin \(annotation)", duration: 231)

        #expect(TrackMetadataMatcher.decision(between: studio, and: alternate) == .match)
    }

    @Test(arguments: ["Part III", "Alive"])
    func parentheticalTitleTextIsPreserved(_ annotation: String) {
        let first = version(title: "Example (Part I)", duration: 200)
        let second = version(title: "Example (\(annotation)) (2019 Live at the Colosseum)", duration: 200)

        #expect(TrackMetadataMatcher.normalizedTitle(for: second) == "example \(annotation.lowercased())")
        #expect(TrackMetadataMatcher.decision(between: first, and: second) == .mismatch)
    }

    @Test
    func titleMatchIgnoresArtistAndDuration() {
        let original = version(title: "Example", artist: "Artist", duration: 200)
        let longCover = version(title: "Example (Extended Mix)", artist: "Another Artist", duration: 600)
        let unmeasured = version(title: "Example", duration: 0)

        #expect(TrackMetadataMatcher.decision(between: original, and: longCover) == .match)
        #expect(TrackMetadataMatcher.decision(between: original, and: unmeasured) == .match)
    }

    @Test
    func emptyNormalizedTitleAbstains() {
        let valid = version(title: "Example", duration: 200)
        let invalid = version(title: "(Live at the Colosseum)", duration: 200)

        #expect(TrackMetadataMatcher.decision(between: valid, and: invalid) == .unknown)
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
