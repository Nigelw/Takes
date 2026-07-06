import Foundation
import UniformTypeIdentifiers

/// Drives the experimental Analysis window: accepts a file, lets the user
/// choose which (CPU-heavy) analyses to run, then runs the engine off the
/// main actor and publishes the state the view renders.
@MainActor
final class AnalysisController: ObservableObject {
    enum State {
        case idle
        /// A file is loaded and awaiting the user's module selection.
        case configuring(url: URL)
        case analyzing(fileName: String)
        case finished(AudioAnalysisReport)
        case failed(fileName: String, message: String)
    }

    @Published private(set) var state: State = .idle
    /// The modules to run, edited on the configuration screen. Persisted for
    /// the window's lifetime so a re-run keeps the last choice.
    @Published var selection: AnalysisSelection = .all

    private var analysisTask: Task<Void, Never>?

    var isAnalyzing: Bool {
        if case .analyzing = state { return true }
        return false
    }

    /// Load a file and show the configuration step (rather than analyzing
    /// immediately) so the user can switch off the slow analyses first.
    func prepare(fileAt url: URL) {
        analysisTask?.cancel()
        state = .configuring(url: url)
    }

    /// Run the currently-selected modules against the configured file.
    func runConfiguredAnalysis() {
        guard case .configuring(let url) = state else { return }
        guard !selection.isEmpty else { return }
        analyze(fileAt: url, modules: selection)
    }

    /// Return from a finished/failed report to the configuration step for the
    /// same file, so the user can adjust toggles and re-run without reopening.
    func reconfigure() {
        guard let url = lastConfiguredURL else { return }
        analysisTask?.cancel()
        state = .configuring(url: url)
    }

    private var lastConfiguredURL: URL?

    func analyze(fileAt url: URL, modules: AnalysisSelection) {
        analysisTask?.cancel()
        lastConfiguredURL = url
        state = .analyzing(fileName: url.lastPathComponent)

        analysisTask = Task {
            let didStartScopedAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartScopedAccess { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try AudioAnalysisEngine.analyze(fileAt: url, modules: modules)
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
