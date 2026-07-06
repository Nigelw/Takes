import SwiftUI
import UniformTypeIdentifiers

/// Experimental single-file analysis window (Debug → Analysis, ⌘⌥Z).
///
/// Renders an `AudioAnalysisReport` as a scrollable dossier: a metadata header,
/// the engine's plain-language verdicts, a strip of headline numbers, the
/// rendered spectrogram, and a log-frequency average-spectrum plot. All four
/// controller states (idle / analyzing / finished / failed) route through the
/// same window, and a file drop is accepted in every one of them so a new file
/// can always replace whatever is on screen.
struct AnalysisWindowView: View {
    @StateObject private var controller = AnalysisController()

    /// Highlight state for the window-wide drop target, so a drag anywhere over
    /// the window lights up regardless of which state view is showing.
    @State private var isDropTargeted = false

    var body: some View {
        stateContent
            .frame(minWidth: 680, minHeight: 520)
            .background(WindowBackground().ignoresSafeArea())
            .overlay {
                if isDropTargeted {
                    dropHighlightOverlay
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch controller.state {
        case .idle:
            IdleView(onOpen: presentOpenPanel)
        case .configuring(let url):
            ConfigurationView(
                fileURL: url,
                selection: Binding(
                    get: { controller.selection },
                    set: { controller.selection = $0 }
                ),
                onAnalyze: { controller.runConfiguredAnalysis() },
                onChooseAnotherFile: presentOpenPanel
            )
        case .analyzing(let fileName):
            AnalyzingView(fileName: fileName)
        case .finished(let report):
            ResultsView(
                report: report,
                onReset: { controller.reset() },
                onAdjust: { controller.reconfigure() },
                onOpen: presentOpenPanel
            )
        case .failed(let fileName, let message):
            FailureView(fileName: fileName, message: message, onReset: { controller.reset() })
        }
    }

    /// Indigo wash + inset border framing the whole window while a drag hovers,
    /// mirroring the main window's import highlight so the drop affordance reads
    /// the same everywhere.
    private var dropHighlightOverlay: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Theme.primary, lineWidth: 2)
            .background(Theme.primary.opacity(0.06))
            .padding(6)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            // Land on the configuration step, not straight into analysis, so
            // the slow modules can be switched off before the run.
            controller.prepare(fileAt: url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, AnalysisController.isSupportedAudioFile(url) else { return }
            Task { @MainActor in
                controller.prepare(fileAt: url)
            }
        }
        return true
    }
}

// MARK: - Idle

/// The empty state: an inviting dashed drop well plus an Open… button. Centered
/// in the window so it reads as a call to action rather than a toolbar.
private struct IdleView: View {
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        Theme.primary.opacity(0.4),
                        style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Theme.primary.opacity(0.05))
                    )
                    .frame(width: 320, height: 180)

                VStack(spacing: 12) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(Theme.primary)
                    Text("Drop an audio file to analyze")
                        .font(.headline)
                    Text("WAV, FLAC, MP3, AAC, and more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Open…", action: onOpen)
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: .command)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Configuration

/// The interim step between choosing a file and running: a checklist of the
/// analyses, each with a speed badge, the conclusion it feeds, and a sketch of
/// how it works. Analysis is CPU-heavy, so this is where the slow modules get
/// switched off before the (potentially long) run. All start enabled.
private struct ConfigurationView: View {
    let fileURL: URL
    @Binding var selection: AnalysisSelection
    let onAnalyze: () -> Void
    let onChooseAnotherFile: () -> Void

    private var modules: [AnalysisModule] { AnalysisModule.allCases }
    private var allSelected: Bool { selection.count == modules.count }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    ForEach(modules) { module in
                        ModuleRow(
                            module: module,
                            isOn: Binding(
                                get: { selection.contains(module) },
                                set: { isOn in
                                    if isOn { selection.insert(module) } else { selection.remove(module) }
                                }
                            )
                        )
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Choose Analyses")
                .font(.title2.bold())
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(Theme.primary)
                Text(fileURL.lastPathComponent)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("Each analysis runs independently. Switch off the slow ones you don't need to speed up the run.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            HStack(spacing: 12) {
                Button(allSelected ? "Deselect All" : "Select All") {
                    selection = allSelected ? [] : .all
                }
                .buttonStyle(.link)
                .font(.callout)
            }
            .padding(.top, 4)
        }
    }

    private var footer: some View {
        HStack {
            Button("Choose Different File…", action: onChooseAnotherFile)
            Spacer()
            Text(selectionSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Analyze", action: onAnalyze)
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private var selectionSummary: String {
        let slowCount = selection.filter { $0.cost == .slow }.count
        if selection.isEmpty { return "Select at least one analysis" }
        let base = "\(selection.count) of \(modules.count) selected"
        return slowCount > 0 ? "\(base) · \(slowCount) slow" : base
    }
}

/// One toggle row: the switch, the analysis name with a speed badge, and two
/// lines of explanation — what conclusion it determines and how it works.
private struct ModuleRow: View {
    let module: AnalysisModule
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(module.name)
                        .font(.headline)
                    CostBadge(cost: module.cost)
                }
                Text(module.determines)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                Text(module.howItWorks)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 4)
        }
        .toggleStyle(.switch)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.timelineWellShade)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isOn ? Theme.primary.opacity(0.35) : Theme.hairline, lineWidth: 1)
        )
        .opacity(isOn ? 1 : 0.6)
    }
}

/// Fast / Average / Slow pill, color-coded green → orange → red so the costly
/// analyses stand out at a glance.
private struct CostBadge: View {
    let cost: AnalysisModule.Cost

    private var tint: Color {
        switch cost {
        case .fast: return .green
        case .average: return .orange
        case .slow: return .red
        }
    }

    var body: some View {
        Text(cost.label.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.15)))
    }
}

// MARK: - Analyzing

/// In-flight state: a spinner and the filename being crunched.
private struct AnalyzingView: View {
    let fileName: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Analyzing")
                .font(.headline)
            Text(fileName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Failure

/// Terminal error state with a route back to idle.
private struct FailureView: View {
    let fileName: String
    let message: String
    let onReset: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text("Couldn't analyze \(fileName)")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Analyze Another File…", action: onReset)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Results

/// The full report, top to bottom: header + metadata, verdicts, headline number
/// strip, spectrogram, and average-spectrum plot.
private struct ResultsView: View {
    let report: AudioAnalysisReport
    let onReset: () -> Void
    let onAdjust: () -> Void
    let onOpen: () -> Void

    /// Whether any headline-number cell has real data to show.
    private var hasKeyNumbers: Bool {
        report.analyzedModules.contains(.loudness)
            || report.analyzedModules.contains(.noiseFloor)
            || report.analyzedModules.contains(.tonalBalance)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                // Headline conclusions sit directly under the metadata header —
                // above the per-category verdicts — because they are the whole
                // feature's payoff ("this FLAC is a re-encode"). Rendered only
                // when the engine reached one; no empty-state placeholder.
                if !report.conclusions.isEmpty {
                    ConclusionsList(conclusions: report.conclusions)
                }
                if !report.verdicts.isEmpty {
                    VerdictList(verdicts: report.verdicts)
                }
                if hasKeyNumbers {
                    KeyNumbersStrip(report: report)
                }

                if let spectrogram = report.spectrogram {
                    SectionCard(title: "Spectrogram") {
                        SpectrogramView(spectrogram: spectrogram)
                    }
                }

                if report.analyzedModules.contains(.tonalBalance) {
                    SectionCard(title: "Average Spectrum") {
                        AverageSpectrumPlot(
                            spectrum: report.averageSpectrum,
                            nyquistHz: report.bandwidth.nyquistHz,
                            cutoffHz: report.bandwidth.detectedCutoffHz
                        )
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(report.fileInfo.fileName)
                    .font(.title2.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 16)
                // Re-run the same file with different toggles without reopening.
                Button("Adjust Analyses", action: onAdjust)
                    .controlSize(.regular)
                Button("Analyze Another File…", action: onReset)
                    .controlSize(.regular)
            }
            Text(metadataLine)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// A compact "codec · 44.1 kHz · 16-bit · Stereo · 3:24 · 1411 kbps" line
    /// pulled from `fileInfo`. Bit depth is omitted for codecs that don't
    /// declare one (lossy formats).
    private var metadataLine: String {
        let info = report.fileInfo
        var parts: [String] = [info.codecDescription]
        parts.append(AnalysisFormat.sampleRate(info.sampleRateHz))
        if let bitDepth = info.bitDepth {
            parts.append("\(bitDepth)-bit")
        }
        parts.append(AnalysisFormat.channels(info.channelCount))
        parts.append(AnalysisFormat.duration(info.durationSeconds))
        parts.append("\(Int(info.dataRateKbps.rounded())) kbps")
        return parts.joined(separator: "  ·  ")
    }
}

// MARK: - Section card

/// A titled panel used to frame the spectrogram and spectrum plots. A subtle
/// filled card with a hairline border, matching the app's material idiom.
private struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.timelineWellShade)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Verdicts

/// One row per `AnalysisVerdict`, grouped by category so related findings sit
/// together. Each row leads with a colored tone dot, then the category tag,
/// bold title, and secondary detail.
private struct VerdictList: View {
    let verdicts: [AnalysisVerdict]

    /// Verdicts bucketed by category, in the canonical `Category.allCases`
    /// order, skipping any category with no findings.
    private var groupedByCategory: [(AnalysisVerdict.Category, [AnalysisVerdict])] {
        AnalysisVerdict.Category.allCases.compactMap { category in
            let matching = verdicts.filter { $0.category == category }
            return matching.isEmpty ? nil : (category, matching)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groupedByCategory.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Divider().padding(.leading, 22)
                }
                ForEach(group.1) { verdict in
                    VerdictRow(verdict: verdict)
                }
            }
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.timelineWellShade)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }
}

private struct VerdictRow: View {
    let verdict: AnalysisVerdict

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(AnalysisTone.color(for: verdict.tone))
                .frame(width: 9, height: 9)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(verdict.title)
                        .font(.callout.weight(.semibold))
                    Text(verdict.category.rawValue.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.primary.opacity(0.06))
                        )
                }
                Text(verdict.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - Conclusions

/// The stack of headline `SourceConclusion` cards. One prominent card per
/// finding, in the order the engine ranked them (most convincing first).
private struct ConclusionsList: View {
    let conclusions: [SourceConclusion]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(conclusions) { conclusion in
                ConclusionCard(conclusion: conclusion)
            }
        }
    }
}

/// One headline finding, styled to carry the eye first: a large tinted icon,
/// the plain-language `statement` set big and bold, a confidence chip, and the
/// supporting evidence as an always-visible indented list. The tint is derived
/// from the conclusion's kind — the evidence IS the explanation, so nothing is
/// collapsed behind a disclosure.
private struct ConclusionCard: View {
    let conclusion: SourceConclusion

    private var style: ConclusionStyle { ConclusionStyle.style(for: conclusion.kind) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: style.symbol)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(style.tint)
                .frame(width: 30)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(conclusion.statement)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    ConfidenceChip(confidence: conclusion.confidence, tint: style.tint)
                        .padding(.top, 1)
                }

                if !conclusion.evidence.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(conclusion.evidence.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top, spacing: 7) {
                                // A neutral bullet, tinted just enough to tie
                                // the list to the card's accent without shouting.
                                Text("•")
                                    .foregroundStyle(style.tint.opacity(0.7))
                                Text(line)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            // A faint wash of the accent over the shared well shade, so the card
            // reads as tinted without introducing a new opaque surface color.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.timelineWellShade)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(style.tint.opacity(0.07))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style.tint.opacity(0.35), lineWidth: 1)
        )
    }
}

/// A small pill reading "Low/Medium/High confidence", tinted to match its card
/// so it reinforces the finding's flavor rather than reading as a separate tag.
private struct ConfidenceChip: View {
    let confidence: SourceConclusion.Confidence
    let tint: Color

    private var label: String {
        switch confidence {
        case .low: return "Low confidence"
        case .medium: return "Medium confidence"
        case .high: return "High confidence"
        }
    }

    var body: some View {
        Text(label.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.15)))
            .fixedSize()
    }
}

/// Icon + tint for each conclusion kind. Warning-flavored provenance (fake
/// lossless, poor encodes) uses traffic-light red/orange; positive findings use
/// green; neutral analog-source provenance borrows the Theme secondary accent so
/// it reads as informative rather than alarming. All three appearances resolve
/// through system semantic colors + Theme tokens, so light and dark both hold up.
private struct ConclusionStyle {
    let symbol: String
    let tint: Color

    static func style(for kind: SourceConclusion.Kind) -> ConclusionStyle {
        switch kind {
        case .fakeLossless:
            return ConclusionStyle(symbol: "exclamationmark.triangle.fill", tint: .red)
        case .poorLossyEncode:
            return ConclusionStyle(symbol: "waveform.badge.exclamationmark", tint: .orange)
        case .vinylSourced:
            return ConclusionStyle(symbol: "recordingtape", tint: Theme.secondary)
        case .analogTapeSourced:
            return ConclusionStyle(symbol: "recordingtape", tint: Theme.secondary)
        case .cleanLossyEncode:
            return ConclusionStyle(symbol: "checkmark.seal.fill", tint: .green)
        case .cleanLossless:
            return ConclusionStyle(symbol: "checkmark.seal.fill", tint: .green)
        }
    }
}

// MARK: - Key numbers

/// A wrapping strip of small labeled stat cells for the headline measurements:
/// integrated loudness, peak, crest factor, noise floor, and bandwidth.
private struct KeyNumbersStrip: View {
    let report: AudioAnalysisReport

    /// Only the cells whose module actually ran, so a skipped analysis never
    /// shows a placeholder −∞ or "nil" reading.
    private var cells: [StatCell] {
        var cells: [StatCell] = []
        if report.analyzedModules.contains(.loudness) {
            cells.append(StatCell(
                label: "Integrated",
                value: AnalysisFormat.lufs(report.loudness.integratedLUFS),
                unit: "LUFS"
            ))
            cells.append(StatCell(
                label: "Sample Peak",
                value: AnalysisFormat.decibels(report.loudness.samplePeakDBFS),
                unit: "dBFS"
            ))
            cells.append(StatCell(
                label: "Crest Factor",
                value: AnalysisFormat.decibels(report.loudness.crestFactorDB),
                unit: "dB"
            ))
        }
        if report.analyzedModules.contains(.noiseFloor) {
            cells.append(StatCell(
                label: "Noise Floor",
                value: AnalysisFormat.decibels(report.noiseFloor.noiseFloorDBFS),
                unit: "dBFS"
            ))
        }
        if report.analyzedModules.contains(.tonalBalance) {
            if let cutoff = report.bandwidth.detectedCutoffHz {
                cells.append(StatCell(
                    label: "Bandwidth",
                    value: AnalysisFormat.kilohertz(cutoff),
                    unit: "kHz"
                ))
            } else {
                cells.append(StatCell(
                    label: "Bandwidth",
                    value: "Full",
                    unit: AnalysisFormat.kilohertz(report.bandwidth.nyquistHz) + " kHz"
                ))
            }
        }
        return cells
    }

    private let columns = [GridItem(.adaptive(minimum: 118), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(cells) { cell in
                StatCellView(cell: cell)
            }
        }
    }
}

private struct StatCell: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let unit: String
}

private struct StatCellView: View {
    let cell: StatCell

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(cell.label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(cell.value)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text(cell.unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.timelineWellShade)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Spectrogram

/// Renders the engine's spectrogram `CGImage` full-width with crisp (non-
/// interpolated) pixels, a linear frequency axis on the left, and a duration
/// axis along the bottom.
private struct SpectrogramView: View {
    let spectrogram: SpectrogramImage

    private let axisWidth: CGFloat = 44
    private let timeAxisHeight: CGFloat = 18
    private let imageHeight: CGFloat = 240

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                frequencyAxis
                Image(decorative: spectrogram.image, scale: 1, orientation: .up)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: imageHeight)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
            }
            timeAxis
                .padding(.leading, axisWidth + 6)
        }
    }

    /// Linear frequency labels (0 at the bottom, Nyquist/1000 at the top).
    private var frequencyAxis: some View {
        let maxKHz = spectrogram.maxFrequencyHz / 1000
        return VStack(alignment: .trailing, spacing: 0) {
            ForEach(Array(stride(from: 5, through: 0, by: -1)), id: \.self) { step in
                let kHz = maxKHz * Double(step) / 5
                Text(String(format: "%.0f", kHz))
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity, alignment: step == 5 ? .top : (step == 0 ? .bottom : .center))
            }
        }
        .overlay(alignment: .topLeading) {
            Text("kHz")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(-90))
                .fixedSize()
                .offset(x: -14, y: imageHeight / 2)
        }
        .frame(width: axisWidth, height: imageHeight)
    }

    private var timeAxis: some View {
        HStack {
            Text("0:00")
            Spacer()
            Text(AnalysisFormat.duration(spectrogram.durationSeconds))
        }
        .font(.system(size: 9))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(height: timeAxisHeight)
    }
}

// MARK: - Average spectrum plot

/// Draws the Welch-averaged spectrum as a filled + stroked path on a log
/// frequency axis (20 Hz → Nyquist), −100…0 dB vertical. Decade gridlines and
/// 20 dB horizontal lines give it scale, and a vertical marker calls out the
/// detected cutoff when the engine found one.
private struct AverageSpectrumPlot: View {
    let spectrum: AverageSpectrum
    let nyquistHz: Double
    let cutoffHz: Double?

    private let minFrequency: Double = 20
    private let minDB: Double = -100
    private let maxDB: Double = 0
    private let plotHeight: CGFloat = 220
    private let leftInset: CGFloat = 34
    private let bottomInset: CGFloat = 20

    /// Decade grid frequencies within the axis range, plus the labeled anchors.
    private let gridFrequencies: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]

    var body: some View {
        Canvas { context, size in
            let plotRect = CGRect(
                x: leftInset,
                y: 0,
                width: size.width - leftInset,
                height: size.height - bottomInset
            )
            guard plotRect.width > 0, plotRect.height > 0 else { return }

            let maxFrequency = max(nyquistHz, minFrequency * 2)
            let logMin = log10(minFrequency)
            let logMax = log10(maxFrequency)

            func x(forFrequency freq: Double) -> CGFloat {
                let clamped = min(max(freq, minFrequency), maxFrequency)
                let t = (log10(clamped) - logMin) / (logMax - logMin)
                return plotRect.minX + CGFloat(t) * plotRect.width
            }

            func y(forDB db: Double) -> CGFloat {
                let clamped = min(max(db, minDB), maxDB)
                let t = (maxDB - clamped) / (maxDB - minDB)
                return plotRect.minY + CGFloat(t) * plotRect.height
            }

            drawGrid(context: context, plotRect: plotRect, x: x, y: y)
            drawSpectrum(context: context, plotRect: plotRect, x: x, y: y, maxFrequency: maxFrequency)
            drawCutoffMarker(context: context, plotRect: plotRect, x: x)
        }
        .frame(height: plotHeight)
    }

    private func drawGrid(
        context: GraphicsContext,
        plotRect: CGRect,
        x: (Double) -> CGFloat,
        y: (Double) -> CGFloat
    ) {
        let gridColor = GraphicsContext.Shading.color(Color.primary.opacity(0.12))
        let labelColor = Color.secondary

        // Horizontal dB lines every 20 dB.
        for db in stride(from: maxDB, through: minDB, by: -20) {
            let yPos = y(db)
            var line = Path()
            line.move(to: CGPoint(x: plotRect.minX, y: yPos))
            line.addLine(to: CGPoint(x: plotRect.maxX, y: yPos))
            context.stroke(line, with: gridColor, lineWidth: 0.5)

            context.draw(
                Text("\(Int(db))").font(.system(size: 8)).foregroundColor(labelColor),
                at: CGPoint(x: plotRect.minX - 5, y: yPos),
                anchor: .trailing
            )
        }

        // Vertical decade lines with kHz/Hz labels.
        let maxFrequency = max(nyquistHz, minFrequency * 2)
        for freq in gridFrequencies where freq >= minFrequency && freq <= maxFrequency {
            let xPos = x(freq)
            var line = Path()
            line.move(to: CGPoint(x: xPos, y: plotRect.minY))
            line.addLine(to: CGPoint(x: xPos, y: plotRect.maxY))
            context.stroke(line, with: gridColor, lineWidth: 0.5)

            context.draw(
                Text(AnalysisFormat.axisFrequency(freq)).font(.system(size: 8)).foregroundColor(labelColor),
                at: CGPoint(x: xPos, y: plotRect.maxY + 4),
                anchor: .top
            )
        }
    }

    private func drawSpectrum(
        context: GraphicsContext,
        plotRect: CGRect,
        x: (Double) -> CGFloat,
        y: (Double) -> CGFloat,
        maxFrequency: Double
    ) {
        let magnitudes = spectrum.magnitudesDB
        guard magnitudes.count > 1, spectrum.binWidthHz > 0 else { return }

        // Bin 0 is DC; start at the first bin whose center is within the axis.
        var stroke = Path()
        var started = false
        var firstX: CGFloat = plotRect.minX
        var lastX: CGFloat = plotRect.minX

        for i in 1..<magnitudes.count {
            let freq = Double(i) * spectrum.binWidthHz
            if freq < minFrequency { continue }
            if freq > maxFrequency { break }
            let point = CGPoint(x: x(freq), y: y(Double(magnitudes[i])))
            if started {
                stroke.addLine(to: point)
            } else {
                stroke.move(to: point)
                firstX = point.x
                started = true
            }
            lastX = point.x
        }
        guard started else { return }

        // Fill: close the stroke down to the baseline and back.
        var fill = stroke
        fill.addLine(to: CGPoint(x: lastX, y: plotRect.maxY))
        fill.addLine(to: CGPoint(x: firstX, y: plotRect.maxY))
        fill.closeSubpath()

        context.fill(
            fill,
            with: .linearGradient(
                Gradient(colors: [Theme.primary.opacity(0.35), Theme.primary.opacity(0.04)]),
                startPoint: CGPoint(x: 0, y: plotRect.minY),
                endPoint: CGPoint(x: 0, y: plotRect.maxY)
            )
        )
        context.stroke(stroke, with: .color(Theme.primary), lineWidth: 1.5)
    }

    private func drawCutoffMarker(
        context: GraphicsContext,
        plotRect: CGRect,
        x: (Double) -> CGFloat
    ) {
        guard let cutoffHz else { return }
        let xPos = x(cutoffHz)

        var line = Path()
        line.move(to: CGPoint(x: xPos, y: plotRect.minY))
        line.addLine(to: CGPoint(x: xPos, y: plotRect.maxY))
        context.stroke(
            line,
            with: .color(Theme.secondary),
            style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
        )

        let label = "cutoff ≈ \(AnalysisFormat.kilohertz(cutoffHz)) kHz"
        // Keep the label inside the plot: flip it to the left of the line when
        // the cutoff sits near the right edge.
        let nearRightEdge = xPos > plotRect.maxX - 90
        context.draw(
            Text(label).font(.system(size: 9, weight: .medium)).foregroundColor(Theme.secondary),
            at: CGPoint(x: nearRightEdge ? xPos - 5 : xPos + 5, y: plotRect.minY + 4),
            anchor: nearRightEdge ? .topTrailing : .topLeading
        )
    }
}

// MARK: - Formatting & tone helpers

/// Tone → color mapping for verdict indicators. Neutral findings borrow the
/// secondary text color; the rest use standard traffic-light semantics that
/// read in both appearances.
private enum AnalysisTone {
    static func color(for tone: AnalysisVerdict.Tone) -> Color {
        switch tone {
        case .info: return .secondary
        case .good: return .green
        case .caution: return .orange
        case .warning: return .red
        }
    }
}

/// Number/string formatting shared across the report views, kept in one place so
/// units read consistently.
private enum AnalysisFormat {
    static func sampleRate(_ hz: Double) -> String {
        let kHz = hz / 1000
        // Whole values (48 kHz) drop the decimal; 44.1 keeps it.
        if kHz == kHz.rounded() {
            return "\(Int(kHz)) kHz"
        }
        return String(format: "%.1f kHz", kHz)
    }

    static func channels(_ count: Int) -> String {
        switch count {
        case 1: return "Mono"
        case 2: return "Stereo"
        default: return "\(count) ch"
        }
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
    }

    static func lufs(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f", value)
    }

    static func decibels(_ value: Double) -> String {
        guard value.isFinite else { return "−∞" }
        return String(format: "%.1f", value)
    }

    static func kilohertz(_ hz: Double) -> String {
        String(format: "%.1f", hz / 1000)
    }

    /// Compact axis tick label: sub-kHz values in Hz, the rest in "k".
    static func axisFrequency(_ hz: Double) -> String {
        if hz >= 1000 {
            let kHz = hz / 1000
            return kHz == kHz.rounded() ? "\(Int(kHz))k" : String(format: "%.1fk", kHz)
        }
        return "\(Int(hz))"
    }
}
