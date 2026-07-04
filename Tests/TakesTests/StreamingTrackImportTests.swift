import Foundation
import Testing
@testable import Takes

struct StreamingTrackImportTests {
    @Test
    func detectsSupportedStreamingSourcePlatforms() throws {
        #expect(StreamingSourcePlatform.detect(from: URL(string: "https://music.apple.com/us/album/example/123?i=456")!) == .appleMusic)
        #expect(StreamingSourcePlatform.detect(from: URL(string: "https://open.spotify.com/track/abc")!) == .spotify)
        #expect(StreamingSourcePlatform.detect(from: URL(string: "https://music.youtube.com/watch?v=abc")!) == .youtube)
        #expect(StreamingSourcePlatform.detect(from: URL(string: "https://example.com/track")!) == nil)
    }

    @Test
    func loadsAppleMusicMetadataFromLookupAPI() async throws {
        let resolver = PlatformMetadataResolver(dataLoader: { request in
            #expect(request.url?.absoluteString == "https://itunes.apple.com/lookup?id=456&entity=song&country=US")
            return Data("""
            {
              "resultCount": 1,
              "results": [
                {
                  "kind": "song",
                  "trackName": "Cut To The Feeling",
                  "artistName": "Carly Rae Jepsen",
                  "trackTimeMillis": 207960
                }
              ]
            }
            """.utf8)
        })

        let metadata = try await resolver.metadata(
            for: URL(string: "https://music.apple.com/us/album/example/123?i=456")!,
            platform: .appleMusic
        )

        #expect(metadata.title == "Cut To The Feeling")
        #expect(metadata.artistName == "Carly Rae Jepsen")
        #expect(metadata.duration == 207.96)
    }

    @Test
    func loadsSpotifyMetadataFromEmbedPage() async throws {
        let resolver = PlatformMetadataResolver(dataLoader: { request in
            #expect(request.url?.absoluteString == "https://open.spotify.com/embed/track/abc?utm_source=takes")
            return Data(Self.spotifyEmbedHTML.utf8)
        })

        let metadata = try await resolver.metadata(
            for: URL(string: "https://open.spotify.com/track/abc?si=share")!,
            platform: .spotify
        )

        #expect(metadata.title == "Cut To The Feeling")
        #expect(metadata.artistName == "Carly Rae Jepsen")
        #expect(metadata.duration == 207.959)
    }

    @Test
    func matchScorerPrefersOfficialAudioResultOverLyricVideo() {
        let metadata = StreamingTrackMetadata(
            title: "Cut To The Feeling",
            artistName: "Carly Rae Jepsen",
            duration: 207.96,
            sourcePlatform: .spotify
        )
        let candidates = [
            YouTubeSearchCandidate(
                id: "lyrics",
                title: "Carly Rae Jepsen - Cut To The Feeling (Lyrics)",
                uploader: "Lyrics Channel",
                channel: "Lyrics Channel",
                duration: 213
            ),
            YouTubeSearchCandidate(
                id: "official",
                title: "Carly Rae Jepsen - Cut To The Feeling (Audio)",
                uploader: "Carly Rae Jepsen",
                channel: "Carly Rae Jepsen",
                duration: 206
            )
        ]

        let match = YouTubeMatchScorer.bestMatch(for: metadata, candidates: candidates)

        #expect(match?.url.absoluteString == "https://www.youtube.com/watch?v=official")
    }

    @Test
    func ytdlpSearchArgumentsUseFlatPlaylistShape() {
        let searcher = YTDLPYouTubeSearcher()
        let arguments = searcher.arguments(for: "Carly Rae Jepsen Cut To The Feeling audio")

        #expect(arguments.contains("--dump-single-json"))
        #expect(arguments.contains("--flat-playlist"))
        #expect(arguments.contains("--skip-download"))
        #expect(arguments.last == "ytsearch5:Carly Rae Jepsen Cut To The Feeling audio")
    }

    @Test
    func ytdlpYouTubeMetadataArgumentsDumpSingleJSONWithoutDownloading() {
        let resolver = YTDLPYouTubeMetadataResolver()
        let arguments = resolver.arguments(for: URL(string: "https://www.youtube.com/watch?v=abc")!)

        #expect(arguments.contains("--dump-single-json"))
        #expect(arguments.contains("--skip-download"))
        #expect(arguments.contains("--no-playlist"))
        #expect(arguments.last == "https://www.youtube.com/watch?v=abc")
    }

    @Test
    func youtubeVideoMetadataPrefersArtistAndTrackFieldsForFilename() {
        let metadata = YouTubeVideoMetadata(
            title: "ignored upload title",
            track: "Cut To The Feeling",
            artist: "Carly Rae Jepsen",
            creator: nil,
            uploader: nil,
            channel: nil,
            altTitle: nil
        )

        #expect(metadata.displayTitle == "Carly Rae Jepsen – Cut To The Feeling")
        #expect(metadata.downloadFilenameBase == "Carly Rae Jepsen – Cut To The Feeling")
    }

    @Test
    func youtubeVideoMetadataParsesArtistAndTitleFromUploadTitle() throws {
        let metadata = try JSONDecoder().decode(
            YouTubeVideoMetadata.self,
            from: Data("""
            {
              "title": "Carly Rae Jepsen - Cut To The Feeling (Audio)",
              "uploader": "Carly Rae Jepsen - Topic"
            }
            """.utf8)
        )

        #expect(metadata.downloadFilenameBase == "Carly Rae Jepsen – Cut To The Feeling (Audio)")
    }

    @Test
    func directYoutubeResolverUsesMetadataForDownloadFilename() async throws {
        let resolver = StreamingTrackResolver(
            youtubeMetadataResolver: StubYouTubeVideoMetadataResolver(
                metadata: YouTubeVideoMetadata(
                    title: "ignored upload title",
                    track: "Cut To The Feeling",
                    artist: "Carly Rae Jepsen",
                    creator: nil,
                    uploader: nil,
                    channel: nil,
                    altTitle: nil
                )
            )
        )

        let match = try await resolver.resolveYouTubeMatch(
            for: URL(string: "https://music.youtube.com/watch?v=abc")!,
            using: URL(fileURLWithPath: "/usr/local/bin/yt-dlp"),
            statusHandler: { _ in }
        )

        #expect(match.title == "Carly Rae Jepsen – Cut To The Feeling")
        #expect(match.downloadFilenameBase == "Carly Rae Jepsen – Cut To The Feeling")
    }

    @Test
    func prepareCreatesLaunchDirectoryAndRemovesStaleLaunchDirectories() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let stale = root.appendingPathComponent("launch-stale", isDirectory: true)
        let keep = root.appendingPathComponent("not-a-launch", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)

        let cache = StreamingDownloadCache(
            rootURL: root,
            launchID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        try cache.prepare()

        #expect(FileManager.default.fileExists(atPath: cache.launchDirectoryURL.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }

    @Test
    func createsLoadDirectoriesAndDeletesOwnedItemsOnly() throws {
        let root = try Self.makeTemporaryDirectory()
        let outside = try Self.makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let cache = StreamingDownloadCache(
            rootURL: root,
            launchID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        try cache.prepare()

        let loadDirectory = try cache.createLoadDirectory(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        )
        let downloadedFile = loadDirectory.appendingPathComponent("Carly Rae Jepsen – Cut To The Feeling.m4a")
        FileManager.default.createFile(atPath: downloadedFile.path, contents: Data("audio".utf8))

        try cache.deleteOwnedItem(at: downloadedFile)

        #expect(!FileManager.default.fileExists(atPath: downloadedFile.path))

        #expect(throws: StreamingTrackImportError.itemOutsideCache(outside)) {
            try cache.deleteOwnedItem(at: outside)
        }
    }

    @Test
    func ytdlpArgumentsUseM4AAudioOnlyShapeAndPerLoadOutputTemplate() {
        let directory = URL(fileURLWithPath: "/tmp/Takes Streaming/load-1", isDirectory: true)
        let downloader = YTDLPDownloader(binaryURL: URL(fileURLWithPath: "/usr/local/bin/yt-dlp"))

        let arguments = downloader.arguments(
            for: URL(string: "https://music.youtube.com/watch?v=abc")!,
            outputDirectory: directory,
            filenameBase: "Carly Rae Jepsen – Cut To The Feeling"
        )

        #expect(arguments.contains("--no-playlist"))
        #expect(arguments.contains("--format"))
        #expect(arguments.contains(YTDLPDownloader.audioFormatSelector))
        #expect(arguments.contains("--output"))
        #expect(arguments.contains("/tmp/Takes Streaming/load-1/Carly Rae Jepsen – Cut To The Feeling.m4a"))
        #expect(arguments.last == "https://music.youtube.com/watch?v=abc")
    }

    @Test
    func streamingDownloadFilenamesUseArtistTitleAndRemovePathSeparators() {
        #expect(
            StreamingDownloadFilename.makeBase(artist: "AC/DC", title: "Back: In Black")
                == "AC DC – Back In Black"
        )
        #expect(StreamingDownloadFilename.sanitizeBase("  ") == "Streaming Audio")
    }

    @Test
    func parsesYTDLPDownloadProgress() {
        let progress = YTDLPDownloader.downloadProgressFraction(
            from: "[download]  42.7% of 3.12MiB at 1.2MiB/s"
        )

        #expect(abs((progress ?? 0) - 0.427) < 0.000_1)
        #expect(YTDLPDownloader.downloadProgressFraction(from: "[ExtractAudio] Destination: track.m4a") == nil)
    }

    @Test
    func downloaderFailuresUseFriendlyPromptMessage() {
        let error = StreamingTrackImportError.downloaderFailed(
            status: 1,
            message: "ERROR: unable to download webpage"
        )

        #expect(error.localizedDescription == "An error occurred. Check your connection and try again.")
    }

    private static let spotifyEmbedHTML = """
    <html><body>
    <script id="__NEXT_DATA__" type="application/json">
    {
      "props": {
        "pageProps": {
          "state": {
            "data": {
              "entity": {
                "title": "Cut To The Feeling",
                "artists": [{ "name": "Carly Rae Jepsen" }],
                "duration": 207959
              }
            }
          }
        }
      }
    }
    </script>
    </body></html>
    """

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TakesStreamingTrackImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct StubYouTubeVideoMetadataResolver: YouTubeVideoMetadataResolving {
    let metadata: YouTubeVideoMetadata

    func metadata(for sourceURL: URL, using downloaderURL: URL) async throws -> YouTubeVideoMetadata {
        metadata
    }
}
