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
    case downloadedFileMissing(URL)

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
        case .downloadedFileMissing(let url):
            return "The streaming audio download did not create \(url.lastPathComponent)."
        }
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

protocol StreamingAudioDownloading: Sendable {
    func download(_ sourceURL: URL, into directory: URL, filenameBase: String?) throws -> URL
}

struct YTDLPDownloader: StreamingAudioDownloading {
    static let audioFormatSelector = "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]"

    let binaryURL: URL

    func download(_ sourceURL: URL, into directory: URL, filenameBase: String?) throws -> URL {
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

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let message = Self.message(stdoutURL: outputLogURL, stderrURL: errorLogURL)
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
