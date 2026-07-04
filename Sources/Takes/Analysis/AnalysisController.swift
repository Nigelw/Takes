import Foundation
import UniformTypeIdentifiers

/// Drives the experimental Analysis window: accepts a file, runs the engine
/// off the main actor, and publishes the state the view renders.
@MainActor
final class AnalysisController: ObservableObject {
    enum State {
        case idle
        case analyzing(fileName: String)
        case finished(AudioAnalysisReport)
        case failed(fileName: String, message: String)
    }

    @Published private(set) var state: State = .idle

    private var analysisTask: Task<Void, Never>?

    var isAnalyzing: Bool {
        if case .analyzing = state { return true }
        return false
    }

    func analyze(fileAt url: URL) {
        analysisTask?.cancel()
        state = .analyzing(fileName: url.lastPathComponent)

        analysisTask = Task {
            let didStartScopedAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartScopedAccess { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try AudioAnalysisEngine.analyze(fileAt: url)
                }.value
                guard !Task.isCancelled else { return }
                state = .finished(report)
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(fileName: url.lastPathComponent, message: error.localizedDescription)
            }
        }
    }

    func reset() {
        analysisTask?.cancel()
        analysisTask = nil
        state = .idle
    }

    static func isSupportedAudioFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio)
    }
}
