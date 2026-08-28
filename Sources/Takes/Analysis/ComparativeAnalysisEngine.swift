import Foundation

/// Runs the comparative pass over a whole session: one single-file report per
/// track, then a pairwise relationship/ranking pass, then clustering into
/// groups that share a master.
///
/// Pure and UI-independent, like `AudioAnalysisEngine`, so a CLI harness can
/// drive it against the corpus.
enum ComparativeAnalysisEngine {
    enum ComparativeError: LocalizedError {
        case tooFewTracks

        var errorDescription: String? {
            switch self {
            case .tooFewTracks: return "Comparing quality needs at least two loaded tracks."
            }
        }
    }

    /// Analyse `urls` and compare every pair.
    ///
    /// `progress` is called with a 0…1 fraction and a short label; it runs on
    /// whatever thread the analysis is on.
    static func analyze(
        urls: [URL],
        modules: AnalysisSelection = .all,
        progress: ((Double, String) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) throws -> ComparativeAnalysisResult {
        guard urls.count >= 2 else { throw ComparativeError.tooFewTracks }

        // Single-file reports first: every comparative finding is derived from
        // them plus the residual, so they are the shared substrate.
        //
        // The spectrogram is display-only and by far the largest allocation
        // per track, so it is dropped here regardless of what was selected.
        let singleFileModules = modules.subtracting([.spectrogram])
        var reports: [AudioAnalysisReport] = []
        let pairCount = urls.count * (urls.count - 1) / 2
        let totalSteps = Double(urls.count + pairCount)

        for (index, url) in urls.enumerated() {
            if isCancelled() { throw CancellationError() }
            progress?(Double(index) / totalSteps, "Analysing \(url.lastPathComponent)")
            reports.append(try AudioAnalysisEngine.analyze(fileAt: url, modules: singleFileModules))
        }

        var pairs: [PairComparison] = []
        var completedPairs = 0
        for a in 0 ..< urls.count {
            for b in (a + 1) ..< urls.count {
                if isCancelled() { throw CancellationError() }
                progress?(
                    Double(urls.count + completedPairs) / totalSteps,
                    "Comparing \(urls[a].lastPathComponent) with \(urls[b].lastPathComponent)"
                )
                completedPairs += 1

                // A pair that cannot be measured is not a failure of the run:
                // record it as unrelated and carry on with the rest.
                let measurement = (try? PairAligner.measure(a: urls[a], b: urls[b]))
                    ?? PairAligner.Measurement(
                        alignment: .none, residual: .unavailable, relationship: .differentRecording
                    )

                // What is worth saying depends on the relationship:
                //
                // - share a master: everything, fidelity included.
                // - different master: mastering differences only. Describing
                //   how two masters differ is the whole point there.
                // - different recording: nothing. Two unrelated songs differ
                //   in EQ and loudness, and saying so is noise, not a finding.
                let findings: [QualityFinding]
                switch measurement.relationship {
                case .identical, .sameMaster:
                    findings = ComparativeInference.findings(
                        a: reports[a], b: reports[b], residual: measurement.residual
                    )
                case .differentMaster:
                    findings = ComparativeInference.findings(
                        a: reports[a], b: reports[b], residual: measurement.residual
                    ).filter { !$0.dimension.isFidelityBearing }
                case .differentRecording, .indeterminate:
                    findings = []
                }

                pairs.append(PairComparison(
                    a: a,
                    b: b,
                    relationship: measurement.relationship,
                    alignment: measurement.alignment,
                    residual: measurement.residual,
                    findings: findings,
                    ranking: ComparativeInference.rank(
                        relationship: measurement.relationship,
                        alignment: measurement.alignment,
                        findings: findings
                    )
                ))
            }
        }

        progress?(1, "Done")
        return ComparativeAnalysisResult(
            reports: reports,
            pairs: pairs,
            groups: groups(reports: reports, pairs: pairs)
        )
    }

    // MARK: - Grouping

    /// Cluster tracks that share a master, then order each cluster by the
    /// pairwise rankings inside it.
    static func groups(reports: [AudioAnalysisReport], pairs: [PairComparison]) -> [MasterGroup] {
        var parent = Array(0 ..< reports.count)
        func find(_ index: Int) -> Int {
            var root = index
            while parent[root] != root { root = parent[root] }
            var walk = index
            while parent[walk] != walk {
                let next = parent[walk]
                parent[walk] = root
                walk = next
            }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            let rootA = find(a), rootB = find(b)
            if rootA != rootB { parent[max(rootA, rootB)] = min(rootA, rootB) }
        }

        for pair in pairs where pair.relationship.supportsFidelityRanking {
            union(pair.a, pair.b)
        }

        var buckets: [Int: [Int]] = [:]
        for index in 0 ..< reports.count { buckets[find(index), default: []].append(index) }

        return buckets.keys.sorted().map { root in
            group(members: buckets[root]!, reports: reports, pairs: pairs)
        }
    }

    private static func group(
        members: [Int],
        reports: [AudioAnalysisReport],
        pairs: [PairComparison]
    ) -> MasterGroup {
        guard members.count > 1 else {
            let index = members[0]
            // A singleton that is nonetheless *related* to something — a
            // different master or transfer of the same performance — is a
            // different statement from one that matched nothing at all.
            let related = pairs.filter {
                ($0.a == index || $0.b == index) && $0.relationship == .differentMaster
            }
            let statement = related.isEmpty
                ? "\(reports[index].fileInfo.fileName) matches none of the other tracks."
                : "\(reports[index].fileInfo.fileName) is a different master from the tracks it "
                    + "otherwise matches, so it cannot be ranked against them on fidelity."
            return MasterGroup(
                orderedIndices: members,
                bestIndex: index,
                isTotallyOrdered: true,
                statement: statement,
                confidence: .high,
                evidence: related.map(\.ranking).compactMap {
                    if case .notComparable(let reason) = $0 { return reason }
                    return nil
                }
            )
        }

        // Score by pairwise wins. A group is only claimed as ordered when every
        // pair inside it produced a definite verdict.
        var wins = [Int: Int](uniqueKeysWithValues: members.map { ($0, 0) })
        var evidence: [String] = []
        var undecided = 0

        for pair in pairs where members.contains(pair.a) && members.contains(pair.b) {
            switch pair.ranking {
            case .aBetter:
                wins[pair.a, default: 0] += 1
                evidence.append(winStatement(pair, winner: pair.a, reports: reports))
            case .bBetter:
                wins[pair.b, default: 0] += 1
                evidence.append(winStatement(pair, winner: pair.b, reports: reports))
            case .equivalent:
                break
            case .undetermined(let reason), .notComparable(let reason):
                undecided += 1
                evidence.append(
                    "\(reports[pair.a].fileInfo.fileName) vs \(reports[pair.b].fileInfo.fileName): \(reason)"
                )
            }
        }

        let ordered = members.sorted { (wins[$0] ?? 0, -$0) > (wins[$1] ?? 0, -$1) }
        let topScore = wins[ordered[0]] ?? 0
        let contested = ordered.filter { (wins[$0] ?? 0) == topScore }.count > 1
        let isTotallyOrdered = undecided == 0 && !contested
        let best = (contested || topScore == 0) ? nil : ordered[0]

        let statement: String
        if let best {
            statement = "\(members.count) copies of the same master; "
                + "\(reports[best].fileInfo.fileName) is the closest to it."
        } else if undecided > 0 {
            statement = "\(members.count) copies of the same master, but the evidence does not "
                + "separate them cleanly."
        } else {
            statement = "\(members.count) copies of the same master, and nothing measurable "
                + "separates them."
        }

        return MasterGroup(
            orderedIndices: ordered,
            bestIndex: best,
            isTotallyOrdered: isTotallyOrdered,
            statement: statement,
            confidence: best == nil ? .low : groupConfidence(members: members, pairs: pairs),
            evidence: evidence
        )
    }

    private static func winStatement(
        _ pair: PairComparison,
        winner: Int,
        reports: [AudioAnalysisReport]
    ) -> String {
        let loser = winner == pair.a ? pair.b : pair.a
        let reason = pair.fidelityFindings.first { $0.direction != .tie }?.statement ?? "measured cleaner."
        return "\(reports[winner].fileInfo.fileName) over \(reports[loser].fileInfo.fileName): \(reason)"
    }

    private static func groupConfidence(members: [Int], pairs: [PairComparison]) -> SourceConclusion.Confidence {
        let inside = pairs.filter { members.contains($0.a) && members.contains($0.b) }
        let confidences: [SourceConclusion.Confidence] = inside.compactMap { pair in
            switch pair.ranking {
            case .aBetter(let confidence), .bBetter(let confidence): return confidence
            default: return nil
            }
        }
        // The group is only as strong as its weakest decisive comparison.
        return confidences.min() ?? .low
    }
}
