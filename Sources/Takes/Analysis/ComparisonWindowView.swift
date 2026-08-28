import SwiftUI

/// Experimental multi-track comparison window (Debug → Compare Quality).
///
/// Answers "which of these is the better copy?" for the tracks currently
/// loaded in the session. The layout follows the feature's central rule: each
/// group of tracks that share a master gets a headline verdict backed by
/// evidence, and pairs that do *not* share a master are shown as descriptions
/// with the refusal to rank stated plainly rather than hidden.
struct ComparisonWindowView: View {
    @StateObject private var controller = ComparisonController()

    /// Supplied by the window controller each time the window is shown, so the
    /// contents always reflect the session as it is now.
    let trackURLs: [URL]

    var body: some View {
        content
            .frame(minWidth: 720, minHeight: 560)
            .background(WindowBackground().ignoresSafeArea())
            .onAppear { controller.prepare(urls: trackURLs) }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .idle:
            NotEnoughTracksView(count: trackURLs.count)
        case .configuring(let urls):
            ComparisonConfigurationView(
                urls: urls,
                selection: Binding(get: { controller.selection }, set: { controller.selection = $0 }),
                onCompare: { controller.runConfiguredAnalysis() }
            )
        case .analyzing(let progress, let detail):
            ComparingView(progress: progress, detail: detail, onCancel: { controller.reconfigure() })
        case .finished(let result):
            ComparisonResultsView(result: result, onAdjust: { controller.reconfigure() })
        case .failed(let message):
            ComparisonFailureView(message: message, onReset: { controller.reconfigure() })
        }
    }
}

// MARK: - States

private struct NotEnoughTracksView: View {
    let count: Int

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("Load at least two tracks to compare")
                .font(.title3.weight(.semibold))
            Text(count == 1
                 ? "One track is open. Comparison needs something to compare it against."
                 : "No tracks are open.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ComparisonConfigurationView: View {
    let urls: [URL]
    @Binding var selection: AnalysisSelection
    let onCompare: () -> Void

    /// Comparison runs every module over every track and then every pair, so
    /// the cost warning matters more here than in the single-file window.
    private var pairCount: Int { urls.count * (urls.count - 1) / 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Compare Quality")
                    .font(.title2.weight(.semibold))
                Text("\(urls.count) tracks · \(pairCount) pair\(pairCount == 1 ? "" : "s") to compare")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(urls, id: \.self) { url in
                            Label(url.lastPathComponent, systemImage: "waveform")
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Text("Analyses to run")
                        .font(.headline)

                    ForEach(AnalysisModule.allCases) { module in
                        Toggle(isOn: Binding(
                            get: { selection.contains(module) },
                            set: { isOn in
                                if isOn { selection.insert(module) } else { selection.remove(module) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(module.name).font(.callout.weight(.medium))
                                    Text(module.cost.label.uppercased())
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.secondary)
                                }
                                Text(module.determines)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(module == .spectrogram)
                        .opacity(module == .spectrogram ? 0.4 : 1)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Compare", action: onCompare)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.isEmpty)
            }
            .padding(20)
        }
    }
}

private struct ComparingView: View {
    let progress: Double
    let detail: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ProgressView(value: progress)
                .frame(maxWidth: 320)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Cancel", action: onCancel)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ComparisonFailureView: View {
    let message: String
    let onReset: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text("Comparison failed").font(.title3.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Back", action: onReset)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Results

private struct ComparisonResultsView: View {
    let result: ComparativeAnalysisResult
    let onAdjust: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(result.groups) { group in
                    GroupCard(group: group, result: result)
                }

                Text("Every comparison")
                    .font(.headline)
                    .padding(.top, 4)

                ForEach(result.pairs) { pair in
                    PairCard(pair: pair, result: result)
                }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Adjust and re-run", action: onAdjust)
            }
            .padding(16)
            .background(.bar)
        }
    }
}

/// The headline for one set of tracks that share a master.
private struct GroupCard: View {
    let group: MasterGroup
    let result: ComparativeAnalysisResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: group.bestIndex == nil ? "questionmark.circle.fill" : "trophy.fill")
                    .foregroundStyle(group.bestIndex == nil ? Color.secondary : .green)
                Text(group.statement)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                ComparisonConfidenceChip(confidence: group.confidence)
            }

            if group.orderedIndices.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(group.orderedIndices.enumerated()), id: \.offset) { rank, index in
                        HStack(spacing: 8) {
                            Text("\(rank + 1)")
                                .font(.caption.monospacedDigit().weight(.bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 16, alignment: .trailing)
                            Text(result.reports[index].fileInfo.fileName)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(result.reports[index].fileInfo.codecDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                // An order the evidence does not fully support is labelled as
                // such rather than presented as a ranking.
                if !group.isTotallyOrdered {
                    Text("Partial order — some pairs could not be separated.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !group.evidence.isEmpty {
                DisclosureGroup("Evidence") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(group.evidence.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.timelineWellShade)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }
}

/// One pair: what it is, what we concluded, and every finding behind it.
private struct PairCard: View {
    let pair: PairComparison
    let result: ComparativeAnalysisResult

    private var nameA: String { result.reports[pair.a].fileInfo.fileName }
    private var nameB: String { result.reports[pair.b].fileInfo.fileName }

    private func side(_ direction: QualityFinding.Direction) -> String {
        switch direction {
        case .favorsA: return nameA
        case .favorsB: return nameB
        case .tie: return "Both"
        }
    }

    private var verdict: (text: String, symbol: String, tint: Color) {
        switch pair.ranking {
        case .aBetter: return ("\(nameA) is the better copy", "checkmark.seal.fill", .green)
        case .bBetter: return ("\(nameB) is the better copy", "checkmark.seal.fill", .green)
        case .equivalent: return ("Nothing separates these", "equal.circle.fill", Theme.secondary)
        case .notComparable(let reason): return (reason, "arrow.triangle.branch", Theme.secondary)
        case .undetermined(let reason): return (reason, "questionmark.circle.fill", .orange)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(nameA).lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                Text(nameB).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(pair.relationship.label.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .fixedSize()
            }
            .font(.callout.weight(.medium))

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: verdict.symbol).foregroundStyle(verdict.tint)
                Text(verdict.text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if case .aBetter(let confidence) = pair.ranking {
                    ComparisonConfidenceChip(confidence: confidence)
                } else if case .bBetter(let confidence) = pair.ranking {
                    ComparisonConfidenceChip(confidence: confidence)
                }
            }

            let decisive = pair.fidelityFindings.filter { $0.direction != .tie }
            if !decisive.isEmpty {
                FindingList(title: "Fidelity", findings: decisive, side: side, emphasised: true)
            }
            if !pair.descriptiveFindings.isEmpty {
                FindingList(
                    title: "Mastering differences — description, not a ranking",
                    findings: pair.descriptiveFindings,
                    side: side,
                    emphasised: false
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.timelineWellShade)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }
}

private struct FindingList: View {
    let title: String
    let findings: [QualityFinding]
    let side: (QualityFinding.Direction) -> String
    let emphasised: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            ForEach(findings) { finding in
                HStack(alignment: .top, spacing: 8) {
                    Text(finding.dimension.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(emphasised ? Theme.primary : Color.secondary)
                        .frame(width: 96, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(side(finding.direction))
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(finding.statement)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }
}

private struct ComparisonConfidenceChip: View {
    let confidence: SourceConclusion.Confidence

    private var label: String {
        switch confidence {
        case .low: return "Low confidence"
        case .medium: return "Medium confidence"
        case .high: return "High confidence"
        }
    }

    private var tint: Color {
        switch confidence {
        case .low: return .secondary
        case .medium: return Theme.secondary
        case .high: return .green
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
