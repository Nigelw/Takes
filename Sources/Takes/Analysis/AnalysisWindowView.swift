import SwiftUI
import UniformTypeIdentifiers

/// Experimental single-file analysis window (Debug → Analysis, ⌘⌥Z).
///
/// Placeholder layout while the analysis UI is built out: drop or open a
/// file, run the engine, and dump the verdicts as text.
struct AnalysisWindowView: View {
    @StateObject private var controller = AnalysisController()

    var body: some View {
        Group {
            switch controller.state {
            case .idle:
                dropPrompt
            case .analyzing(let fileName):
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Analyzing \(fileName)…")
                        .foregroundStyle(.secondary)
                }
            case .finished(let report):
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(report.fileInfo.fileName).font(.headline)
                        ForEach(report.verdicts) { verdict in
                            Text("\(verdict.category.rawValue): \(verdict.title) — \(verdict.detail)")
                                .font(.callout)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            case .failed(let fileName, let message):
                VStack(spacing: 8) {
                    Text("Couldn't analyze \(fileName)").font(.headline)
                    Text(message).foregroundStyle(.secondary)
                    Button("Try Another File") { controller.reset() }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    private var dropPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Drop an audio file to analyze")
                .foregroundStyle(.secondary)
            Button("Open…") { presentOpenPanel() }
        }
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            controller.analyze(fileAt: url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, AnalysisController.isSupportedAudioFile(url) else { return }
            Task { @MainActor in
                controller.analyze(fileAt: url)
            }
        }
        return true
    }
}
