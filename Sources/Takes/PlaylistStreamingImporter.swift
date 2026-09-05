import Foundation

/// Downloads into durable workspace storage. Navigation and quit never remove
/// successful downloads; reclamation waits for workspace and Undo ownership.
struct PlaylistStreamingImporter {
    var directoryURL: URL = PlaylistWorkspaceStore.defaultDownloadsDirectoryURL()
    var resolver: any StreamingTrackResolving = StreamingTrackResolver()
    var manager: any YTDLPManaging = YTDLPManager()

    func download(
        from rawURL: String,
        statusHandler: @escaping @Sendable (StreamingURLPromptStatus) async -> Void = { _ in }
    ) async throws -> URL {
        guard let source = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              source.scheme != nil else {
            throw StreamingTrackImportError.unsupportedStreamingURL
        }
        try Task.checkCancellation()
        await statusHandler(.preparingDownloader)
        let executable = try await manager.executableURL()
        let match = try await resolver.resolveYouTubeMatch(
            for: source, using: executable, statusHandler: statusHandler
        )
        try Task.checkCancellation()
        let destination = directoryURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            await statusHandler(.downloading(progress: nil))
            let result = try await YTDLPDownloader(binaryURL: executable).download(
                match.url, into: destination, filenameBase: match.downloadFilenameBase
            )
            try Task.checkCancellation()
            await statusHandler(.openingAudio)
            return result
        } catch {
            // Only this uncommitted operation's freshly created directory.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
