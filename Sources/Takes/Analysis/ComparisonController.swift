import Foundation

/// Drives the experimental Compare Quality window: takes the URLs of the
/// tracks currently loaded in the session, runs the comparative engine off the
/// main actor, and publishes the state the view renders.
///
/// Deliberately session-driven rather than file-picker-driven — the input to
/// this feature is "the tracks I already have open".
@MainActor
final class ComparisonController: ObservableObject {
    enum State {
        case idle
        /// Tracks are loaded and awaiting the user's module selection.
        case configuring(urls: [URL])
        case analyzing(progress: Double, detail: String)
        case finished(ComparativeAnalysisResult)
        case failed(message: String)
    }

    @Published private(set) var state: State = .idle
    /// The modules to run. The spectrogram is display-only and the comparison
    /// window never shows one, so it is off by default here.
    @Published var selection: AnalysisSelection = .all.subtracting([.spectrogram])

    private var analysisTask: Task<Void, Never>?
    private var configuredURLs: [URL] = []

    var isAnalyzing: Bool {
        if case .analyzing = state { return true }
        return false
    }

    /// Load the session's tracks and show the configuration step. Called every
    /// time the window opens so it always reflects what is loaded right now.
    func prepare(urls: [URL]) {
        analysisTask?.cancel()
        configuredURLs = urls
        state = urls.count >= 2 ? .configuring(urls: urls) : .idle
    }

    func runConfiguredAnalysis() {
        guard case .configuring(let urls) = state, !selection.isEmpty else { return }
        analyze(urls: urls, modules: selection)
    }

    /// Return to the configuration step for the same tracks, so toggles can be
    /// adjusted and the run repeated without reopening the window.
    func reconfigure() {
        guard configuredURLs.count >= 2 else { return }
        analysisTask?.cancel()
        state = .configuring(urls: configuredURLs)
    }

    /// Progress and completion travel back from the detached worker as a
    /// stream, so the main actor never blocks and cancellation propagates by
    /// cancelling the worker directly.
    private enum Update: Sendable {
        case progress(Double, String)
        case finished(ComparativeAnalysisResult)
        case failed(String)
    }

    func analyze(urls: [URL], modules: AnalysisSelection) {
        analysisTask?.cancel()
        configuredURLs = urls
        state = .analyzing(progress: 0, detail: "Starting")

        analysisTask = Task { [weak self] in
            let (stream, continuation) = AsyncStream<Update>.makeStream()

            let work = Task.detached(priority: .userInitiated) {
                let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
                defer {
                    scoped.forEach { $0.stopAccessingSecurityScopedResource() }
                    continuation.finish()
                }
                do {
                    let result = try ComparativeAnalysisEngine.analyze(
                        urls: urls,
                        modules: modules,
                        progress: { continuation.yield(.progress($0, $1)) },
                        isCancelled: { Task.isCancelled }
                    )
                    continuation.yield(.finished(result))
                } catch is CancellationError {
                    // The user closed the window or started another run.
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                }
            }
            // Cancelling this task must stop the work, not just stop listening.
            defer { work.cancel() }

            for await update in stream {
                if Task.isCancelled { return }
                switch update {
                case .progress(let fraction, let detail):
                    self?.state = .analyzing(progress: fraction, detail: detail)
                case .finished(let result):
                    self?.state = .finished(result)
                case .failed(let message):
                    self?.state = .failed(message: message)
                }
            }
        }
    }

    func reset() {
        analysisTask?.cancel()
        analysisTask = nil
        state = .idle
    }
}
