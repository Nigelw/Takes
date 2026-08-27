import Foundation

// Comparative-analysis modes for the benchmark CLI. Kept beside `main.swift`
// so both share the engine sources compiled by
// `scripts/analysis-benchmark.sh`.
//
//   analysis-cli compare <fileA> <fileB> [more…]   ad-hoc comparison
//   analysis-cli compare-benchmark <corpus-dir>    ground-truth pair checks

/// One pair from the corpus whose relationship is known by construction, and
/// whose better side is known too when the pair shares a master.
///
/// Ground truth comes from `scripts/make-analysis-corpus.sh`, which builds the
/// degradation chains itself — see docs/analysis-corpus.md. Nothing here was
/// decided by listening.
struct PairExpectation {
    let a: String
    let b: String
    let relationship: PairRelationship
    /// `"a"`, `"b"`, `"equivalent"`, or `"abstain"` (any non-ranking outcome).
    let better: String
    let notes: String

    init(_ a: String, _ b: String, _ relationship: PairRelationship, _ better: String, _ notes: String = "") {
        self.a = a
        self.b = b
        self.relationship = relationship
        self.better = better
        self.notes = notes
    }
}

let pairExpectations: [PairExpectation] = [
    // Ordered degradation chains. The whole feature rests on reproducing these.
    .init("chain_master.wav", "chain_320.mp3", .sameMaster, "a", "master over 320"),
    .init("chain_320.mp3", "chain_192.mp3", .sameMaster, "a", "320 over 192"),
    .init("chain_192.mp3", "chain_128.mp3", .sameMaster, "a", "192 over 128"),
    .init("chain_master.wav", "chain_128.mp3", .sameMaster, "a", "ends of the chain"),
    .init("real_chain_master.wav", "real_chain_320.mp3", .sameMaster, "a", "real music"),
    .init("real_chain_320.mp3", "real_chain_192.mp3", .sameMaster, "a", "real music"),
    .init("real_chain_192.mp3", "real_chain_128.mp3", .sameMaster, "a", "real music"),

    // A lossless rewrap of a lossy file is the same audio, not an improvement.
    .init("chain_128.mp3", "chain_128_rewrap.flac", .identical, "equivalent", "FLAC rewrap of the same MP3"),
    .init(
        "real_chain_128.mp3", "real_chain_128_rewrap.flac", .identical, "equivalent",
        "FLAC rewrap of the same MP3"
    ),

    // Same master, different codecs: rankable, and AAC 256 should win.
    .init("cross_codec_aac256.m4a", "cross_codec_mp3128.mp3", .sameMaster, "a", "AAC 256 over MP3 128"),

    // Adversarial. Every one of these must NOT produce a fidelity ranking.
    .init("gain_only_a.wav", "gain_only_b.wav", .identical, "equivalent", "same encode, ±6 dB"),
    // Nulls at −134 dB once aligned: the same audio, just shifted.
    .init("offset_pair_a.wav", "offset_pair_b.wav", .identical, "equivalent", "same encode, 137.4 ms apart"),
    .init(
        "different_master_a.wav", "different_master_b.wav", .differentMaster, "abstain",
        "loud/limited vs dynamic, different EQ"
    ),
    .init(
        "different_recording_a.wav", "different_recording_b.wav", .differentRecording, "abstain",
        "unrelated material"
    ),
]

func describe(_ ranking: PairRanking) -> String {
    switch ranking {
    case .aBetter(let confidence): return "A better (\(confidence))"
    case .bBetter(let confidence): return "B better (\(confidence))"
    case .equivalent: return "equivalent"
    case .notComparable(let reason): return "not comparable — \(reason)"
    case .undetermined(let reason): return "undetermined — \(reason)"
    }
}

/// The outcome shorthand a ranking corresponds to, for comparison against
/// `PairExpectation.better`.
func outcome(_ ranking: PairRanking) -> String {
    switch ranking {
    case .aBetter: return "a"
    case .bBetter: return "b"
    case .equivalent: return "equivalent"
    case .notComparable, .undetermined: return "abstain"
    }
}

func describe(_ pair: PairComparison, _ result: ComparativeAnalysisResult) -> String {
    let nameA = result.reports[pair.a].fileInfo.fileName
    let nameB = result.reports[pair.b].fileInfo.fileName
    var lines = [
        "\(nameA)  ↔  \(nameB)",
        "    \(pair.relationship.label) · \(describe(pair.ranking))",
        String(
            format: "    offset %.2f ms · residual %.1f dB · mid-band %.1f dB · tilt %.2f dB · coherence %.4f",
            pair.alignment.offsetSeconds * 1_000,
            pair.residual.residualToSignalDB,
            pair.residual.midBandResidualToSignalDB,
            pair.residual.midBandTiltDifferenceDB,
            pair.residual.waveformCoherence
        ),
    ]
    if let ratio = pair.alignment.speedRatio {
        lines.append(String(format: "    speed-stretched match near %.4f×", ratio))
    }
    for finding in pair.fidelityFindings where finding.direction != .tie {
        let side = finding.direction == .favorsA ? nameA : nameB
        lines.append("    ✓ [\(finding.dimension.label)] \(side): \(finding.statement) (\(finding.confidence))")
    }
    for finding in pair.descriptiveFindings {
        let side = finding.direction == .favorsA ? nameA : nameB
        lines.append("    · [\(finding.dimension.label)] \(side): \(finding.statement)")
    }
    return lines.joined(separator: "\n")
}

func runComparison(urls: [URL]) {
    do {
        let result = try ComparativeAnalysisEngine.analyze(urls: urls)
        for group in result.groups {
            print("• \(group.statement)  [\(group.confidence)]")
            for line in group.evidence { print("    – \(line)") }
        }
        print("")
        for pair in result.pairs { print(describe(pair, result)) }
    } catch {
        print("FAILED — \(error.localizedDescription)")
    }
}

func runComparativeBenchmark(corpusDir: URL) -> Never {
    let directory = corpusDir.appendingPathComponent("comparative")
    var passCount = 0
    var failCount = 0
    var missing: [String] = []

    for expectation in pairExpectations {
        let a = directory.appendingPathComponent(expectation.a)
        let b = directory.appendingPathComponent(expectation.b)
        let label = "\(expectation.a) ↔ \(expectation.b)"
        guard FileManager.default.fileExists(atPath: a.path),
              FileManager.default.fileExists(atPath: b.path)
        else {
            missing.append(label)
            continue
        }

        do {
            let result = try ComparativeAnalysisEngine.analyze(urls: [a, b])
            guard let pair = result.pairs.first else {
                failCount += 1
                print("FAIL  \(label) — no comparison produced")
                continue
            }

            var failures: [String] = []
            if pair.relationship != expectation.relationship {
                failures.append(
                    "relationship \(pair.relationship.rawValue), expected \(expectation.relationship.rawValue)"
                )
            }
            // `identical` pairs are allowed to read as `sameMaster` and vice
            // versa only where the manifest says so; anything else is a miss.
            let got = outcome(pair.ranking)
            if got != expectation.better {
                failures.append("ranking “\(got)”, expected “\(expectation.better)” — \(describe(pair.ranking))")
            }

            if failures.isEmpty {
                passCount += 1
                print("PASS  \(label)\(expectation.notes.isEmpty ? "" : "  (\(expectation.notes))")")
            } else {
                failCount += 1
                print("FAIL  \(label)")
                failures.forEach { print("      - \($0)") }
                print("      " + describe(pair, result).replacingOccurrences(of: "\n", with: "\n      "))
            }
        } catch {
            failCount += 1
            print("FAIL  \(label) — threw: \(error.localizedDescription)")
        }
    }

    if !missing.isEmpty {
        print("\nmissing corpus pairs (run scripts/make-analysis-corpus.sh): \(missing.joined(separator: ", "))")
    }
    print("\n\(passCount) passed, \(failCount) failed, \(missing.count) missing")
    exit(failCount == 0 ? 0 : 1)
}
