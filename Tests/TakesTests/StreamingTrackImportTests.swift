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
    func ytdlpManagerUsesManifestExecutableBeforeSystemFallback() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executableURL = try Self.writeManagedYTDLPExecutable(
            root: root,
            contents: Data("managed yt-dlp".utf8)
        )
        try Self.writeYTDLPManifest(root: root, executableURL: executableURL)
        let systemURL = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        let manager = YTDLPManager(rootURL: root, systemExecutableURL: { systemURL })

        let resolvedURL = try await manager.executableURL()

        #expect(resolvedURL == executableURL.standardizedFileURL)
    }

    @Test
    func ytdlpManagerFallsBackWhenManifestChecksumDoesNotMatch() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executableURL = try Self.writeManagedYTDLPExecutable(
            root: root,
            contents: Data("managed yt-dlp".utf8)
        )
        try Self.writeYTDLPManifest(root: root, executableURL: executableURL, checksum: "not-the-checksum")
        let systemURL = URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp")
        let manager = YTDLPManager(
            rootURL: root,
            systemExecutableURL: { systemURL },
            downloadAsset: { _ in throw StreamingTrackImportError.downloaderUnavailable }
        )

        let resolvedURL = try await manager.executableURL()

        #expect(resolvedURL == systemURL)
    }

    @Test
    func ytdlpManagerInstallsLatestMacOSBinaryWhenManagedToolIsMissing() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binaryData = Data("downloaded yt-dlp".utf8)
        let checksum = YTDLPManager.sha256Checksum(for: binaryData)
        let binaryURL = URL(string: "https://example.com/yt-dlp_macos")!
        let checksumsURL = URL(string: "https://example.com/SHA2-256SUMS")!
        let manager = YTDLPManager(
            rootURL: root,
            binaryURL: binaryURL,
            checksumsURL: checksumsURL,
            systemExecutableURL: { nil },
            downloadAsset: { url in
                if url == binaryURL {
                    return YTDLPDownloadedAsset(
                        data: binaryData,
                        finalURL: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download/2026.06.09/yt-dlp_macos")!
                    )
                }
                if url == checksumsURL {
                    return YTDLPDownloadedAsset(
                        data: Data("\(checksum)  yt-dlp_macos\n".utf8),
                        finalURL: url
                    )
                }
                throw StreamingTrackImportError.downloaderUnavailable
            },
            dateProvider: { Date(timeIntervalSince1970: 1) }
        )

        let resolvedURL = try await manager.executableURL()
        let manifestData = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(YTDLPManagedToolManifest.self, from: manifestData)

        #expect(resolvedURL.path.hasSuffix("/2026.06.09/yt-dlp_macos"))
        #expect(FileManager.default.isExecutableFile(atPath: resolvedURL.path))
        #expect(try Data(contentsOf: resolvedURL) == binaryData)
        #expect(manifest.version == "2026.06.09")
        #expect(manifest.checksum == checksum)
        #expect(manifest.executablePath == resolvedURL.path)
    }

    @Test
    func ytdlpManagerFallsBackWhenDownloadedChecksumDoesNotMatch() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binaryURL = URL(string: "https://example.com/yt-dlp_macos")!
        let checksumsURL = URL(string: "https://example.com/SHA2-256SUMS")!
        let systemURL = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        let manager = YTDLPManager(
            rootURL: root,
            binaryURL: binaryURL,
            checksumsURL: checksumsURL,
            systemExecutableURL: { systemURL },
            downloadAsset: { url in
                if url == binaryURL {
                    return YTDLPDownloadedAsset(data: Data("bad binary".utf8), finalURL: url)
                }
                return YTDLPDownloadedAsset(
                    data: Data("\(String(repeating: "0", count: 64))  yt-dlp_macos\n".utf8),
                    finalURL: url
                )
            }
        )

        let resolvedURL = try await manager.executableURL()

        #expect(resolvedURL == systemURL)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path))
    }

    @Test
    func ytdlpManagerParsesMacOSChecksumAndVersion() {
        let checksums = Data("""
        e5d57466682cfa9d61e9cf7c8a4f09b00f4a62af37d3bbdc4bcffdf63615feac  yt-dlp
        b82c3626952e6c14eaf654cc565866775ffd0b9ffb7021628ac59b42c2f4f244  yt-dlp_macos
        62a3108d7c37090107f0bb9a2369b953b35e43f4bc76ab0ea87e4ab593c23ec7  yt-dlp_macos.zip
        """.utf8)
        let downloadURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download/2026.06.09/yt-dlp_macos")!

        #expect(
            YTDLPManager.checksum(for: "yt-dlp_macos", in: checksums)
                == "b82c3626952e6c14eaf654cc565866775ffd0b9ffb7021628ac59b42c2f4f244"
        )
        #expect(YTDLPManager.version(fromDownloadURL: downloadURL) == "2026.06.09")
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

    private static func writeManagedYTDLPExecutable(root: URL, contents: Data) throws -> URL {
        let versionDirectory = root.appendingPathComponent("2026.07.04", isDirectory: true)
        try FileManager.default.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
        let executableURL = versionDirectory.appendingPathComponent("yt-dlp_macos")
        FileManager.default.createFile(atPath: executableURL.path, contents: contents)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        return executableURL
    }

    private static func writeYTDLPManifest(
        root: URL,
        executableURL: URL,
        checksum: String? = nil
    ) throws {
        let resolvedChecksum: String
        if let checksum {
            resolvedChecksum = checksum
        } else {
            resolvedChecksum = try YTDLPManager.sha256Checksum(for: executableURL)
        }
        let manifest = YTDLPManagedToolManifest(
            version: "2026.07.04",
            channel: "stable",
            installedAt: Date(timeIntervalSince1970: 0),
            checksum: resolvedChecksum,
            executablePath: executableURL.path
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: root.appendingPathComponent("manifest.json"))
    }
}

private struct StubYouTubeVideoMetadataResolver: YouTubeVideoMetadataResolving {
    let metadata: YouTubeVideoMetadata

    func metadata(for sourceURL: URL, using downloaderURL: URL) async throws -> YouTubeVideoMetadata {
        metadata
    }
}
