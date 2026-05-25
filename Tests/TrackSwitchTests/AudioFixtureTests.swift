import AVFoundation
import Foundation
import Testing
@testable import TrackSwitch

struct AudioFixtureTests {
    @Test
    func audioFileLoaderReadsBundledM4AFixtures() throws {
        let loader = AudioFileLoader()

        for fixture in AudioFixture.allCases {
            let track = try loader.loadTrackMetadata(from: fixture.url)

            #expect(track.url == fixture.url)
            #expect(track.displayName == fixture.fileName)
            #expect(track.fileFormatDescription == "M4A")
            #expect(track.duration > fixture.minimumDuration)
            #expect(track.duration < fixture.maximumDuration)
            #expect(track.sampleRate == 44_100)
            #expect(track.channelCount == 2)
            #expect(track.metadataSummary.contains("M4A"))
            #expect(track.metadataSummary.contains("44100 Hz"))
            #expect(track.metadataSummary.contains("2 ch"))
        }
    }

    @MainActor
    @Test
    func importedAudioFixturesAppendInProvidedOrder() async throws {
        let controller = PlaybackController()
        let fixtures = AudioFixture.allCases

        await controller.loadImportedFiles(fixtures.map(\.url))

        #expect(controller.playbackError == nil)
        #expect(controller.session.tracks.map { $0.loadedTrack.displayName } == fixtures.map(\.fileName))
        #expect(controller.session.activeTrackID == controller.session.tracks.first?.id)
        #expect(controller.session.timelineStart == 0)
        #expect(controller.session.timelineEnd > 240)
        #expect(controller.session.timelineEnd < 241)
    }

    @Test
    func audioFileLoaderCreatesPlayableFilesFromBundledFixtures() throws {
        let loader = AudioFileLoader()

        for fixture in AudioFixture.allCases {
            let file = try loader.makeAudioFile(from: fixture.url)

            #expect(file.length > 0)
            #expect(file.processingFormat.sampleRate == 44_100)
            #expect(file.processingFormat.channelCount == 2)
        }
    }

    @Test
    func launchFileArgumentsReturnExistingAudioFiles() {
        let arguments = [
            "/path/to/TrackSwitch",
            "--not-a-file",
            AudioFixture.liveSingle.url.path,
            "/tmp/missing.m4a",
            AudioFixture.studio.url.path
        ]

        #expect(LaunchFileArguments.audioFileURLs(from: arguments) == [
            AudioFixture.liveSingle.url,
            AudioFixture.studio.url
        ])
    }

    @MainActor
    @Test
    func appDelegateConsumesLaunchFileArgumentsOnlyOnce() {
        let delegate = AppDelegate()
        let arguments = ["/path/to/TrackSwitch", AudioFixture.liveSingle.url.path]

        #expect(delegate.consumeLaunchFileArguments(from: arguments) == [AudioFixture.liveSingle.url])
        #expect(delegate.consumeLaunchFileArguments(from: arguments).isEmpty)
    }

}

private enum AudioFixture: String, CaseIterable {
    case liveSingle = "05 Where to Begin (Live).m4a"
    case studio = "11 Where to Begin.m4a"
    case liveAlbum = "4-04 Where to Begin (Live).m4a"

    var fileName: String {
        rawValue
    }

    var url: URL {
        directory.appending(path: rawValue)
    }

    var minimumDuration: TimeInterval {
        switch self {
        case .liveSingle:
            238
        case .studio:
            239
        case .liveAlbum:
            240
        }
    }

    var maximumDuration: TimeInterval {
        switch self {
        case .liveSingle:
            239
        case .studio:
            240
        case .liveAlbum:
            241
        }
    }

    private var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Audio")
    }
}
