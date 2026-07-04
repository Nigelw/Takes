import CryptoKit
import Foundation

enum StreamingTrackImportError: Error, Equatable, LocalizedError {
    static let downloaderFailureMessage = "An error occurred. Check your connection and try again."

    case unsupportedStreamingURL
    case invalidMetadataEndpoint
    case missingTrackMetadata
    case noYouTubeMatch(query: String)
    case itemOutsideCache(URL)
    case downloaderUnavailable
    case downloaderFailed(status: Int32, message: String)
    case noCompatibleAudioStream
    case downloadedFileMissing(URL)
    case openImportFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedStreamingURL:
            return "Open an Apple Music, Spotify, YouTube, or YouTube Music URL."
        case .invalidMetadataEndpoint:
            return "Could not build the streaming metadata request."
        case .missingTrackMetadata:
            return "Could not read the track title and artist from that URL."
        case .noYouTubeMatch:
            return "Could not find a matching YouTube result."
        case .itemOutsideCache:
            return "The requested file is outside the streaming download cache."
        case .downloaderUnavailable:
            return "Could not find yt-dlp. Install yt-dlp or choose a streaming downloader location before opening streaming tracks."
        case .downloaderFailed:
            return Self.downloaderFailureMessage
        case .noCompatibleAudioStream:
            return "Could not find a compatible M4A audio stream for that track."
        case .downloadedFileMissing:
            return "Could not find a compatible M4A audio stream for that track."
        case .openImportFailed:
            return "Could not open the downloaded audio in Takes."
        }
    }

    static func promptMessage(for error: Error) -> String {
        if let streamingError = error as? StreamingTrackImportError {
            return streamingError.localizedDescription
        }
        return downloaderFailureMessage
    }
}

enum StreamingURLPromptStatus: Equatable {
    case idle
    case readingMetadata(String)
    case searchingYouTube(String)
    case foundYouTube(String)
    case preparingDownloader
    case downloading(progress: Double?)
    case openingAudio
    case failed(String)

    var isWorking: Bool {
        switch self {
        case .readingMetadata, .searchingYouTube, .foundYouTube, .preparingDownloader, .downloading, .openingAudio:
            return true
        case .idle, .failed:
            return false
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .idle:
            return nil
        case .readingMetadata(let platform):
            return "Reading \(platform) track info..."
        case .searchingYouTube(let query):
            return "Searching YouTube for \(query)..."
        case .foundYouTube(let title):
            return "Found YouTube match: \(title)"
        case .preparingDownloader:
            return "Preparing downloader..."
        case .downloading(let progress):
            if let progress {
                return "Downloading audio... \(Int((progress * 100).rounded()))%"
            }
            return "Downloading audio..."
        case .openingAudio:
            return "Opening audio..."
        case .failed(let message):
            return message.ifEmpty("Streaming URL could not be opened.")
        }
    }

    var downloadProgress: Double? {
        if case .downloading(let progress) = self {
            return progress
        }
        return nil
    }
}

enum StreamingSourcePlatform: Equatable {
    case appleMusic
    case spotify
    case youtube

    var displayName: String {
        switch self {
        case .appleMusic:
            return "Apple Music"
        case .spotify:
            return "Spotify"
        case .youtube:
            return "YouTube"
        }
    }

    static func detect(from url: URL) -> StreamingSourcePlatform? {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        if host.contains("music.apple.com") || host.contains("itunes.apple.com") {
            return .appleMusic
        }
        if host.contains("open.spotify.com") {
            return .spotify
        }
        if host.contains("youtube.com") || host.contains("youtu.be") {
            return .youtube
        }
        return nil
    }
}

struct StreamingTrackMetadata: Equatable {
    let title: String
    let artistName: String
    let duration: TimeInterval?
    let sourcePlatform: StreamingSourcePlatform

    var searchQuery: String {
        "\(artistName) \(title)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct StreamingYouTubeMatch: Equatable {
    let url: URL
    let title: String
    let confidence: Double
    let downloadFilenameBase: String?

    init(
        url: URL,
        title: String,
        confidence: Double,
        downloadFilenameBase: String? = nil
    ) {
        self.url = url
        self.title = title
        self.confidence = confidence
        self.downloadFilenameBase = downloadFilenameBase
    }
}

protocol StreamingTrackResolving: Sendable {
    func resolveYouTubeMatch(
        for sourceURL: URL,
        using downloaderURL: URL,
        statusHandler: @escaping @Sendable (StreamingURLPromptStatus) async -> Void
    ) async throws -> StreamingYouTubeMatch
}

struct StreamingTrackResolver: StreamingTrackResolving {
    private let metadataResolver: StreamingSourceMetadataResolving
    private let youtubeMetadataResolver: YouTubeVideoMetadataResolving
    private let youtubeSearcher: YouTubeSearching

    init(
        metadataResolver: StreamingSourceMetadataResolving = PlatformMetadataResolver(),
        youtubeMetadataResolver: YouTubeVideoMetadataResolving = YTDLPYouTubeMetadataResolver(),
        youtubeSearcher: YouTubeSearching = YTDLPYouTubeSearcher()
    ) {
        self.metadataResolver = metadataResolver
        self.youtubeMetadataResolver = youtubeMetadataResolver
        self.youtubeSearcher = youtubeSearcher
    }

    func resolveYouTubeMatch(
        for sourceURL: URL,
        using downloaderURL: URL,
        statusHandler: @escaping @Sendable (StreamingURLPromptStatus) async -> Void
    ) async throws -> StreamingYouTubeMatch {
        guard let platform = StreamingSourcePlatform.detect(from: sourceURL) else {
            throw StreamingTrackImportError.unsupportedStreamingURL
        }

        if platform == .youtube {
            await statusHandler(.readingMetadata(platform.displayName))
            let metadata = try? await youtubeMetadataResolver.metadata(for: sourceURL, using: downloaderURL)
            let title = metadata?.displayTitle ?? sourceURL.host(percentEncoded: false) ?? "YouTube"
            let match = StreamingYouTubeMatch(
                url: sourceURL,
                title: title,
                confidence: 1,
                downloadFilenameBase: metadata?.downloadFilenameBase
                    ?? StreamingDownloadFilename.makeBase(
                        artist: "YouTube",
                        title: Self.youtubeIdentifier(from: sourceURL) ?? title
                    )
            )
            await statusHandler(.foundYouTube(title))
            return match
        }

        await statusHandler(.readingMetadata(platform.displayName))
        let metadata = try await metadataResolver.metadata(for: sourceURL, platform: platform)
        let query = metadata.searchQuery
        guard !query.isEmpty else {
            throw StreamingTrackImportError.missingTrackMetadata
        }

        await statusHandler(.searchingYouTube(query))
        let candidates = try await youtubeSearcher.search(query: "\(query) audio", using: downloaderURL)
        guard let match = YouTubeMatchScorer.bestMatch(
            for: metadata,
            candidates: candidates
        ) else {
            throw StreamingTrackImportError.noYouTubeMatch(query: query)
        }

        let namedMatch = StreamingYouTubeMatch(
            url: match.url,
            title: match.title,
            confidence: match.confidence,
            downloadFilenameBase: StreamingDownloadFilename.makeBase(
                artist: metadata.artistName,
                title: metadata.title
            )
        )
        await statusHandler(.foundYouTube(namedMatch.title))
        return namedMatch
    }

    private static func youtubeIdentifier(from url: URL) -> String? {
        if let videoID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "v" })?
            .value,
            !videoID.isEmpty {
            return videoID
        }
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard let identifier = pathComponents.last, !identifier.isEmpty else { return nil }
        return identifier
    }
}

protocol YouTubeVideoMetadataResolving: Sendable {
    func metadata(for sourceURL: URL, using downloaderURL: URL) async throws -> YouTubeVideoMetadata
}

struct YouTubeVideoMetadata: Decodable, Equatable, Sendable {
    let title: String?
    let track: String?
    let artist: String?
    let creator: String?
    let uploader: String?
    let channel: String?
    let altTitle: String?

    private enum CodingKeys: String, CodingKey {
        case title
        case track
        case artist
        case creator
        case uploader
        case channel
        case altTitle = "alt_title"
    }

    var displayTitle: String? {
        resolvedArtistAndTitle.map { "\($0.artist) – \($0.title)" }
            ?? firstNonEmpty(track, altTitle, title)
    }

    var downloadFilenameBase: String? {
        guard let resolvedArtistAndTitle else { return nil }
        return StreamingDownloadFilename.makeBase(
            artist: resolvedArtistAndTitle.artist,
            title: resolvedArtistAndTitle.title
        )
    }

    var resolvedArtistAndTitle: (artist: String, title: String)? {
        if let artist = firstNonEmpty(artist, creator).map(Self.removingTopicSuffix),
           let title = firstNonEmpty(track, altTitle, title) {
            return (artist, title)
        }

        if let parsed = Self.parseArtistAndTitle(from: title) {
            return parsed
        }

        guard let fallbackArtist = firstNonEmpty(uploader, channel, creator).map(Self.removingTopicSuffix),
              let fallbackTitle = firstNonEmpty(track, altTitle, title)
        else { return nil }
        return (fallbackArtist, fallbackTitle)
    }

    static func parseArtistAndTitle(from value: String?) -> (artist: String, title: String)? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        let separators = [" - ", " – ", " — "]
        for separator in separators {
            let parts = value.components(separatedBy: separator)
            guard parts.count >= 2 else { continue }
            let artist = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let title = parts.dropFirst().joined(separator: separator)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artist.isEmpty, !title.isEmpty else { continue }
            return (artist, title)
        }
        return nil
    }

    private static func removingTopicSuffix(_ value: String) -> String {
        let suffix = " - Topic"
        guard value.hasSuffix(suffix) else { return value }
        return String(value.dropLast(suffix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

struct YTDLPYouTubeMetadataResolver: YouTubeVideoMetadataResolving {
    func metadata(for sourceURL: URL, using downloaderURL: URL) async throws -> YouTubeVideoMetadata {
        try await Task.detached(priority: .userInitiated) {
            try metadataSync(for: sourceURL, using: downloaderURL)
        }.value
    }

    func arguments(for sourceURL: URL) -> [String] {
        [
            "--dump-single-json",
            "--skip-download",
            "--no-warnings",
            "--no-playlist",
            sourceURL.absoluteString
        ]
    }

    private func metadataSync(for sourceURL: URL, using downloaderURL: URL) throws -> YouTubeVideoMetadata {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TakesYTDLPMetadata-\(UUID().uuidString)-stdout.json")
        let errorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TakesYTDLPMetadata-\(UUID().uuidString)-stderr.log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }

        let process = Process()
        process.executableURL = downloaderURL
        process.arguments = arguments(for: sourceURL)

        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        defer {
            try? output.close()
            try? error.close()
        }
        process.standardOutput = output
        process.standardError = error

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw StreamingTrackImportError.downloaderFailed(
                status: process.terminationStatus,
                message: YTDLPDownloader.message(stdoutURL: outputURL, stderrURL: errorURL)
            )
        }

        return try JSONDecoder().decode(YouTubeVideoMetadata.self, from: try Data(contentsOf: outputURL))
    }
}

protocol StreamingSourceMetadataResolving: Sendable {
    func metadata(for sourceURL: URL, platform: StreamingSourcePlatform) async throws -> StreamingTrackMetadata
}

struct PlatformMetadataResolver: StreamingSourceMetadataResolving {
    typealias DataLoader = @Sendable (URLRequest) async throws -> Data

    private let dataLoader: DataLoader
    private let decoder: JSONDecoder

    init(
        dataLoader: @escaping DataLoader = { request in
            let (data, _) = try await URLSession.shared.data(for: request)
            return data
        },
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.dataLoader = dataLoader
        self.decoder = decoder
    }

    func metadata(for sourceURL: URL, platform: StreamingSourcePlatform) async throws -> StreamingTrackMetadata {
        switch platform {
        case .appleMusic:
            return try await appleMusicMetadata(for: sourceURL)
        case .spotify:
            return try await spotifyMetadata(for: sourceURL)
        case .youtube:
            throw StreamingTrackImportError.unsupportedStreamingURL
        }
    }

    private func appleMusicMetadata(for sourceURL: URL) async throws -> StreamingTrackMetadata {
        guard let trackID = Self.appleMusicTrackID(from: sourceURL),
              var components = URLComponents(string: "https://itunes.apple.com/lookup")
        else {
            throw StreamingTrackImportError.missingTrackMetadata
        }
        components.queryItems = [
            URLQueryItem(name: "id", value: trackID),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "country", value: Self.appleMusicCountry(from: sourceURL) ?? "US")
        ]
        guard let url = components.url else {
            throw StreamingTrackImportError.invalidMetadataEndpoint
        }
        let response = try decoder.decode(
            AppleMusicLookupResponse.self,
            from: try await dataLoader(URLRequest(url: url))
        )
        guard let result = response.results.first(where: { $0.kind == "song" }) else {
            throw StreamingTrackImportError.missingTrackMetadata
        }
        return StreamingTrackMetadata(
            title: result.trackName,
            artistName: result.artistName,
            duration: result.trackTimeMillis.map { TimeInterval($0) / 1000 },
            sourcePlatform: .appleMusic
        )
    }

    private func spotifyMetadata(for sourceURL: URL) async throws -> StreamingTrackMetadata {
        guard let trackID = Self.spotifyTrackID(from: sourceURL),
              let url = URL(string: "https://open.spotify.com/embed/track/\(trackID)?utm_source=takes")
        else {
            throw StreamingTrackImportError.missingTrackMetadata
        }
        let data = try await dataLoader(URLRequest(url: url))
        guard let html = String(data: data, encoding: .utf8),
              let json = Self.spotifyNextDataJSON(from: html)
        else {
            throw StreamingTrackImportError.missingTrackMetadata
        }
        let response = try decoder.decode(SpotifyEmbedNextData.self, from: json)
        let entity = response.props.pageProps.state.data.entity
        guard let artistName = entity.artists.first?.name else {
            throw StreamingTrackImportError.missingTrackMetadata
        }
        return StreamingTrackMetadata(
            title: entity.title,
            artistName: artistName,
            duration: entity.duration.map { TimeInterval($0) / 1000 },
            sourcePlatform: .spotify
        )
    }

    static func appleMusicTrackID(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "i" || $0.name == "id" })?
            .value
    }

    static func appleMusicCountry(from url: URL) -> String? {
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard let country = pathComponents.first, country.count == 2 else { return nil }
        return country.uppercased()
    }

    static func spotifyTrackID(from url: URL) -> String? {
        let string = url.absoluteString
        if string.hasPrefix("spotify:track:") {
            return string.replacingOccurrences(of: "spotify:track:", with: "")
        }
        let components = url.pathComponents
        guard let index = components.firstIndex(of: "track"), index + 1 < components.count else {
            return nil
        }
        return components[index + 1]
    }

    static func spotifyNextDataJSON(from html: String) -> Data? {
        guard let idRange = html.range(of: #"id="__NEXT_DATA__""#),
              let start = html[idRange.upperBound...].range(of: ">")?.upperBound,
              let end = html[start...].range(of: "</script>")?.lowerBound
        else {
            return nil
        }
        return String(html[start..<end]).data(using: .utf8)
    }
}

private struct AppleMusicLookupResponse: Decodable {
    let results: [Result]

    struct Result: Decodable {
        let kind: String?
        let trackName: String
        let artistName: String
        let trackTimeMillis: Int?
    }
}

private struct SpotifyEmbedNextData: Decodable {
    let props: Props

    struct Props: Decodable {
        let pageProps: PageProps
    }

    struct PageProps: Decodable {
        let state: State
    }

    struct State: Decodable {
        let data: DataNode
    }

    struct DataNode: Decodable {
        let entity: Entity
    }

    struct Entity: Decodable {
        let title: String
        let artists: [Artist]
        let duration: Int?
    }

    struct Artist: Decodable {
        let name: String
    }
}

protocol YouTubeSearching: Sendable {
    func search(query: String, using downloaderURL: URL) async throws -> [YouTubeSearchCandidate]
}

struct YouTubeSearchCandidate: Decodable, Equatable {
    let id: String
    let title: String?
    let uploader: String?
    let channel: String?
    let duration: TimeInterval?

    var url: URL? {
        URL(string: "https://www.youtube.com/watch?v=\(id)")
    }

    var displayTitle: String {
        title?.ifEmpty(id) ?? id
    }
}

struct YTDLPYouTubeSearcher: YouTubeSearching {
    func search(query: String, using downloaderURL: URL) async throws -> [YouTubeSearchCandidate] {
        try await Task.detached(priority: .userInitiated) {
            try searchSync(query: query, using: downloaderURL)
        }.value
    }

    func arguments(for query: String) -> [String] {
        [
            "--dump-single-json",
            "--flat-playlist",
            "--skip-download",
            "--no-warnings",
            "ytsearch5:\(query)"
        ]
    }

    private func searchSync(query: String, using downloaderURL: URL) throws -> [YouTubeSearchCandidate] {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TakesYTDLPSearch-\(UUID().uuidString)-stdout.json")
        let errorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TakesYTDLPSearch-\(UUID().uuidString)-stderr.log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }

        let process = Process()
        process.executableURL = downloaderURL
        process.arguments = arguments(for: query)

        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        defer {
            try? output.close()
            try? error.close()
        }
        process.standardOutput = output
        process.standardError = error

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw StreamingTrackImportError.downloaderFailed(
                status: process.terminationStatus,
                message: YTDLPDownloader.message(stdoutURL: outputURL, stderrURL: errorURL)
            )
        }

        let data = try Data(contentsOf: outputURL)
        return try JSONDecoder().decode(YouTubeSearchResponse.self, from: data)
            .entries
            .compactMap { $0 }
    }
}

private struct YouTubeSearchResponse: Decodable {
    let entries: [YouTubeSearchCandidate?]
}

enum YouTubeMatchScorer {
    static func bestMatch(
        for metadata: StreamingTrackMetadata,
        candidates: [YouTubeSearchCandidate],
        minimumScore: Double = 0.45
    ) -> StreamingYouTubeMatch? {
        candidates
            .compactMap { candidate -> StreamingYouTubeMatch? in
                guard let url = candidate.url else { return nil }
                let score = score(candidate, against: metadata)
                guard score >= minimumScore else { return nil }
                return StreamingYouTubeMatch(
                    url: url,
                    title: candidate.displayTitle,
                    confidence: score
                )
            }
            .max { $0.confidence < $1.confidence }
    }

    static func score(_ candidate: YouTubeSearchCandidate, against metadata: StreamingTrackMetadata) -> Double {
        let candidateTitle = normalize(candidate.title ?? "")
        let sourceTitle = normalize(metadata.title)
        let sourceArtist = normalize(metadata.artistName)
        let channel = normalize(candidate.channel ?? candidate.uploader ?? "")

        var score = similarity(sourceTitle, candidateTitle) * 0.62
        if candidateTitle.contains(sourceArtist) {
            score += 0.18
        } else {
            score += similarity(sourceArtist, channel) * 0.14
        }

        if let sourceDuration = metadata.duration, let candidateDuration = candidate.duration {
            let distance = abs(sourceDuration - candidateDuration)
            score += max(0, 0.18 - min(distance / 60, 1) * 0.18)
        }

        let sourceHasVariant = containsVariantWord(sourceTitle)
        if !sourceHasVariant && containsVariantWord(candidateTitle) {
            score -= 0.16
        }
        if channel.contains("topic") {
            score += 0.08
        }

        return max(0, min(score, 1))
    }

    private static func containsVariantWord(_ value: String) -> Bool {
        ["live", "remix", "cover", "karaoke", "sped up", "slowed", "lyrics", "lyric"]
            .contains { value.contains($0) }
    }

    private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 1 }
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let longerCount = max(lhs.count, rhs.count)
        return Double(longerCount - levenshtein(lhs, rhs)) / Double(longerCount)
    }

    private static func levenshtein(_ source: String, _ target: String) -> Int {
        let source = Array(source)
        let target = Array(target)
        if source.isEmpty { return target.count }
        if target.isEmpty { return source.count }

        var previous = Array(0...target.count)
        var current = Array(repeating: 0, count: target.count + 1)

        for sourceIndex in 1...source.count {
            current[0] = sourceIndex
            for targetIndex in 1...target.count {
                let cost = source[sourceIndex - 1] == target[targetIndex - 1] ? 0 : 1
                current[targetIndex] = min(
                    previous[targetIndex] + 1,
                    current[targetIndex - 1] + 1,
                    previous[targetIndex - 1] + cost
                )
            }
            swap(&previous, &current)
        }
        return previous[target.count]
    }
}

struct StreamingDownloadCache {
    let rootURL: URL
    let launchDirectoryURL: URL

    private let fileManager: FileManager

    init(
        rootURL: URL,
        launchID: UUID = UUID(),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.launchDirectoryURL = rootURL
            .appendingPathComponent("launch-\(launchID.uuidString)", isDirectory: true)
            .standardizedFileURL
        self.fileManager = fileManager
    }

    func prepare() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try removeStaleLaunchDirectories()
        try fileManager.createDirectory(at: launchDirectoryURL, withIntermediateDirectories: true)
    }

    func createLoadDirectory(id: UUID = UUID()) throws -> URL {
        let directory = launchDirectoryURL
            .appendingPathComponent("load-\(id.uuidString)", isDirectory: true)
            .standardizedFileURL
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func deleteOwnedItem(at url: URL) throws {
        let ownedURL = url.standardizedFileURL
        guard isOwned(ownedURL) else {
            throw StreamingTrackImportError.itemOutsideCache(url)
        }
        guard fileManager.fileExists(atPath: ownedURL.path) else { return }
        try fileManager.removeItem(at: ownedURL)
    }

    func deleteLaunchDirectory() throws {
        try deleteOwnedItem(at: launchDirectoryURL)
    }

    func isOwned(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = rootURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private func removeStaleLaunchDirectories() throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }

        let children = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for child in children where child.lastPathComponent.hasPrefix("launch-") {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true, child.standardizedFileURL != launchDirectoryURL else { continue }
            try fileManager.removeItem(at: child)
        }
    }
}

enum YTDLPToolLocator {
    static func defaultExecutableURL(fileManager: FileManager = .default) -> URL? {
        let candidatePaths = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp"
        ]
        return candidatePaths
            .map(URL.init(fileURLWithPath:))
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}

protocol YTDLPManaging: Sendable {
    func executableURL() async throws -> URL
}

protocol YTDLPUpdating: Sendable {
    func managedToolStatus() -> YTDLPManagedToolStatus?
    func updateManagedExecutableNow() async throws -> URL
}

struct YTDLPDownloadedAsset: Sendable {
    let data: Data
    let finalURL: URL
}

struct YTDLPManagedToolStatus: Equatable {
    let version: String
    let channel: String
    let installedAt: Date
    let lastCheckedAt: Date
    let executableURL: URL
}

struct YTDLPManagedToolManifest: Codable, Equatable {
    let version: String
    let channel: String
    let installedAt: Date
    let lastCheckedAt: Date
    let checksum: String
    let executablePath: String

    init(
        version: String,
        channel: String,
        installedAt: Date,
        lastCheckedAt: Date,
        checksum: String,
        executablePath: String
    ) {
        self.version = version
        self.channel = channel
        self.installedAt = installedAt
        self.lastCheckedAt = lastCheckedAt
        self.checksum = checksum
        self.executablePath = executablePath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        channel = try container.decode(String.self, forKey: .channel)
        installedAt = try container.decode(Date.self, forKey: .installedAt)
        lastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt) ?? installedAt
        checksum = try container.decode(String.self, forKey: .checksum)
        executablePath = try container.decode(String.self, forKey: .executablePath)
    }
}

struct YTDLPManager: YTDLPManaging, YTDLPUpdating {
    static let assetName = "yt-dlp_macos"
    static let stableChannel = "stable"
    static let updateCheckInterval: TimeInterval = 7 * 24 * 60 * 60

    let rootURL: URL

    private let binaryURL: URL
    private let checksumsURL: URL
    private let systemExecutableURL: @Sendable () -> URL?
    private let isExecutableFile: @Sendable (String) -> Bool
    private let downloadAsset: @Sendable (URL) async throws -> YTDLPDownloadedAsset
    private let dateProvider: @Sendable () -> Date
    private let verifyExecutableVersion: @Sendable (URL) async throws -> String

    init(
        rootURL: URL = Self.defaultRootURL(),
        binaryURL: URL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!,
        checksumsURL: URL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS")!,
        systemExecutableURL: @escaping @Sendable () -> URL? = { YTDLPToolLocator.defaultExecutableURL() },
        isExecutableFile: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        downloadAsset: @escaping @Sendable (URL) async throws -> YTDLPDownloadedAsset = Self.downloadAsset,
        dateProvider: @escaping @Sendable () -> Date = Date.init,
        verifyExecutableVersion: @escaping @Sendable (URL) async throws -> String = Self.verifyExecutableVersion
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.binaryURL = binaryURL
        self.checksumsURL = checksumsURL
        self.systemExecutableURL = systemExecutableURL
        self.isExecutableFile = isExecutableFile
        self.downloadAsset = downloadAsset
        self.dateProvider = dateProvider
        self.verifyExecutableVersion = verifyExecutableVersion
    }

    func executableURL() async throws -> URL {
        if let managedTool = managedTool() {
            guard managedTool.manifest.channel == Self.stableChannel,
                  shouldCheckForUpdates(manifest: managedTool.manifest)
            else {
                return managedTool.executableURL
            }

            do {
                return try await installLatestManagedExecutable(previousManifest: managedTool.manifest)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return managedTool.executableURL
            }
        }

        do {
            return try await installLatestManagedExecutable(previousManifest: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let systemExecutableURL = systemExecutableURL() {
                return systemExecutableURL
            }
            throw StreamingTrackImportError.downloaderUnavailable
        }
    }

    func managedToolStatus() -> YTDLPManagedToolStatus? {
        guard let managedTool = managedTool() else { return nil }
        return YTDLPManagedToolStatus(
            version: managedTool.manifest.version,
            channel: managedTool.manifest.channel,
            installedAt: managedTool.manifest.installedAt,
            lastCheckedAt: managedTool.manifest.lastCheckedAt,
            executableURL: managedTool.executableURL
        )
    }

    func updateManagedExecutableNow() async throws -> URL {
        try await installLatestManagedExecutable(previousManifest: managedTool()?.manifest)
    }

    static func defaultRootURL(fileManager: FileManager = .default, bundle: Bundle = .main) -> URL {
        let applicationSupportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let bundleID = bundle.bundleIdentifier ?? "com.nigelwarren.Takes"
        return applicationSupportRoot
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent("yt-dlp", isDirectory: true)
    }

    static func downloadAsset(from url: URL) async throws -> YTDLPDownloadedAsset {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw StreamingTrackImportError.downloaderUnavailable
        }
        return YTDLPDownloadedAsset(data: data, finalURL: response.url ?? url)
    }

    static func verifyExecutableVersion(for executableURL: URL) async throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--version"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw StreamingTrackImportError.downloaderUnavailable
        }

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let version = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !version.isEmpty else {
            throw StreamingTrackImportError.downloaderUnavailable
        }
        return version
    }

    static func sha256Checksum(for url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func sha256Checksum(for data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func checksum(for assetName: String, in checksumsData: Data) -> String? {
        guard let text = String(data: checksumsData, encoding: .utf8) else { return nil }
        return text
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count >= 2, parts[1] == assetName else { return nil }
                let checksum = String(parts[0]).lowercased()
                guard checksum.count == 64,
                      checksum.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) })
                else {
                    return nil
                }
                return checksum
            }
            .first
    }

    static func version(fromDownloadURL url: URL) -> String {
        let components = url.pathComponents
        if let downloadIndex = components.firstIndex(of: "download"),
           components.indices.contains(downloadIndex + 1) {
            return components[downloadIndex + 1]
        }
        return "latest"
    }

    private func managedTool() -> (manifest: YTDLPManagedToolManifest, executableURL: URL)? {
        let manifestURL = rootURL.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(YTDLPManagedToolManifest.self, from: data)
        else {
            return nil
        }

        let executableURL = URL(fileURLWithPath: manifest.executablePath).standardizedFileURL
        guard isManaged(executableURL),
              isExecutableFile(executableURL.path),
              (try? Self.sha256Checksum(for: executableURL)) == manifest.checksum
        else {
            return nil
        }
        return (manifest, executableURL)
    }

    private func shouldCheckForUpdates(manifest: YTDLPManagedToolManifest) -> Bool {
        dateProvider().timeIntervalSince(manifest.lastCheckedAt) >= Self.updateCheckInterval
    }

    private func installLatestManagedExecutable(previousManifest: YTDLPManagedToolManifest?) async throws -> URL {
        try removeStagingDirectories()

        async let binary = downloadAsset(binaryURL)
        async let checksums = downloadAsset(checksumsURL)
        let (binaryAsset, checksumsAsset) = try await (binary, checksums)

        guard let expectedChecksum = Self.checksum(for: Self.assetName, in: checksumsAsset.data),
              Self.sha256Checksum(for: binaryAsset.data) == expectedChecksum
        else {
            throw StreamingTrackImportError.downloaderUnavailable
        }

        let now = dateProvider()
        try Task.checkCancellation()
        let stagingDirectory = rootURL
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        let stagedExecutableURL = stagingDirectory.appendingPathComponent(Self.assetName)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        try binaryAsset.data.write(to: stagedExecutableURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedExecutableURL.path)

        guard isExecutableFile(stagedExecutableURL.path) else {
            throw StreamingTrackImportError.downloaderUnavailable
        }

        try Task.checkCancellation()
        let version = try await verifyExecutableVersion(stagedExecutableURL)
        try Task.checkCancellation()

        if let previousManifest,
           previousManifest.version == version,
           previousManifest.checksum == expectedChecksum,
           let previousTool = managedTool() {
            let refreshedManifest = YTDLPManagedToolManifest(
                version: previousManifest.version,
                channel: previousManifest.channel,
                installedAt: previousManifest.installedAt,
                lastCheckedAt: now,
                checksum: previousManifest.checksum,
                executablePath: previousManifest.executablePath
            )
            try writeManifest(refreshedManifest)
            return previousTool.executableURL
        }

        let installDirectory = rootURL
            .appendingPathComponent(sanitizedVersionDirectoryName(version), isDirectory: true)
            .standardizedFileURL
        let finalInstallDirectory = availableInstallDirectory(startingAt: installDirectory)
        let executableURL = finalInstallDirectory.appendingPathComponent(Self.assetName)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: stagingDirectory, to: finalInstallDirectory)

        guard isManaged(executableURL),
              isExecutableFile(executableURL.path),
              (try? Self.sha256Checksum(for: executableURL)) == expectedChecksum
        else {
            try? FileManager.default.removeItem(at: finalInstallDirectory)
            throw StreamingTrackImportError.downloaderUnavailable
        }

        let manifest = YTDLPManagedToolManifest(
            version: version,
            channel: Self.stableChannel,
            installedAt: previousManifest?.installedAt ?? now,
            lastCheckedAt: now,
            checksum: expectedChecksum,
            executablePath: executableURL.path
        )
        try writeManifest(manifest)
        return executableURL
    }

    private func writeManifest(_ manifest: YTDLPManagedToolManifest) throws {
        let executableURL = URL(fileURLWithPath: manifest.executablePath).standardizedFileURL
        guard isManaged(executableURL) else {
            throw StreamingTrackImportError.downloaderUnavailable
        }
        let manifestData = try JSONEncoder().encode(manifest)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try manifestData.write(to: rootURL.appendingPathComponent("manifest.json"), options: [.atomic])
    }

    private func sanitizedVersionDirectoryName(_ version: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let sanitized = version.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return sanitized.isEmpty ? "latest" : sanitized
    }

    private func availableInstallDirectory(startingAt installDirectory: URL) -> URL {
        guard FileManager.default.fileExists(atPath: installDirectory.path) else {
            return installDirectory
        }
        return rootURL
            .appendingPathComponent("\(installDirectory.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
    }

    private func removeStagingDirectories() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootURL.path) else { return }

        let children = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )

        for child in children where child.lastPathComponent.hasPrefix(".staging-") {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true, isManaged(child) else { continue }
            try fileManager.removeItem(at: child)
        }
    }

    private func isManaged(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = rootURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }
}

protocol StreamingAudioDownloading: Sendable {
    func download(_ sourceURL: URL, into directory: URL, filenameBase: String?) throws -> URL
}

private final class YTDLPCancellableProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func setProcess(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = cancelled
        lock.unlock()

        if shouldTerminate {
            process.terminate()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = process
        lock.unlock()

        process?.terminate()
    }

    var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }
}

struct YTDLPDownloader: StreamingAudioDownloading {
    static let audioFormatSelector = "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]"

    let binaryURL: URL

    func download(_ sourceURL: URL, into directory: URL, filenameBase: String?) throws -> URL {
        try download(sourceURL, into: directory, filenameBase: filenameBase, cancellation: nil)
    }

    func download(_ sourceURL: URL, into directory: URL, filenameBase: String?) async throws -> URL {
        let cancellation = YTDLPCancellableProcess()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try download(sourceURL, into: directory, filenameBase: filenameBase, cancellation: cancellation)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func download(
        _ sourceURL: URL,
        into directory: URL,
        filenameBase: String?,
        cancellation: YTDLPCancellableProcess?
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputLogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TakesYTDLP-\(UUID().uuidString)-stdout.log")
        let errorLogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TakesYTDLP-\(UUID().uuidString)-stderr.log")
        FileManager.default.createFile(atPath: outputLogURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorLogURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outputLogURL)
            try? FileManager.default.removeItem(at: errorLogURL)
        }

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = arguments(
            for: sourceURL,
            outputDirectory: directory,
            filenameBase: filenameBase
        )

        let output = try FileHandle(forWritingTo: outputLogURL)
        let error = try FileHandle(forWritingTo: errorLogURL)
        defer {
            try? output.close()
            try? error.close()
        }
        process.standardOutput = output
        process.standardError = error

        try Task.checkCancellation()
        try process.run()
        cancellation?.setProcess(process)
        process.waitUntilExit()

        if cancellation?.isCancelled == true {
            throw CancellationError()
        }

        if process.terminationStatus != 0 {
            let message = Self.message(stdoutURL: outputLogURL, stderrURL: errorLogURL)
            if Self.messageIndicatesMissingCompatibleAudio(message) {
                throw StreamingTrackImportError.noCompatibleAudioStream
            }
            throw StreamingTrackImportError.downloaderFailed(
                status: process.terminationStatus,
                message: message
            )
        }

        let downloadedURL = downloadedFileURL(in: directory, filenameBase: filenameBase)
        guard FileManager.default.fileExists(atPath: downloadedURL.path) else {
            throw StreamingTrackImportError.downloadedFileMissing(downloadedURL)
        }
        return downloadedURL
    }

    static func messageIndicatesMissingCompatibleAudio(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("requested format is not available")
            || lowercased.contains("no video formats found")
            || lowercased.contains("no audio formats found")
    }

    func arguments(
        for sourceURL: URL,
        outputDirectory: URL,
        filenameBase: String? = nil
    ) -> [String] {
        [
            "--no-playlist",
            "--format", Self.audioFormatSelector,
            "--output", downloadedFileURL(in: outputDirectory, filenameBase: filenameBase).path,
            sourceURL.absoluteString
        ]
    }

    func downloadedFileURL(in directory: URL, filenameBase: String? = nil) -> URL {
        let filenameBase = StreamingDownloadFilename.sanitizeBase(filenameBase ?? "Streaming Audio")
        return directory.appendingPathComponent("\(filenameBase).m4a")
    }

    static func downloadProgressFraction(from line: String) -> Double? {
        guard line.hasPrefix("[download]") else { return nil }
        let pattern = #"\s([0-9]+(?:\.[0-9]+)?)%"#
        guard let range = line.range(of: pattern, options: .regularExpression) else { return nil }
        let match = line[range].trimmingCharacters(in: .whitespaces)
        guard let percent = Double(match.dropLast()) else { return nil }
        return min(max(percent / 100, 0), 1)
    }

    static func message(stdoutURL: URL, stderrURL: URL) -> String {
        let stderrText = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        if !stderrText.isEmpty { return stderrText }
        return (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
    }
}

enum StreamingDownloadFilename {
    static func makeBase(artist: String, title: String) -> String {
        sanitizeBase("\(artist) – \(title)")
    }

    static func sanitizeBase(_ value: String) -> String {
        let forbiddenCharacters = CharacterSet(charactersIn: "/:\0")
        let sanitized = value
            .components(separatedBy: forbiddenCharacters)
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sanitized.isEmpty else { return "Streaming Audio" }
        return String(sanitized.prefix(160))
    }
}
