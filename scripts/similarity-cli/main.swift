import Foundation

@main
struct SimilarityCLI {
    struct Manifest: Decodable {
        let status: String
        let pairs: [LabeledPair]
    }
    struct LabeledPair: Decodable {
        let first: String
        let second: String
        let sameRecording: Bool?
        let samePerformance: Bool?
        let provenance: String
    }
    struct Row: Encodable {
        let first: String
        let second: String
        let sameRecording: String
        let samePerformance: String
        let matchedSeconds: Double
        let firstCoverage: Double
        let secondCoverage: Double
        let speedRatio: Double
        let offsetSeconds: Double
        let diagnostic: String
        let seconds: Double
        let timedOut: Bool
    }

    static func emit<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let mode = args.first ?? "inventory"
        if mode == "decode", args.count == 2 {
            let features = try TrackSimilarityAnalyzer.extract(url: URL(fileURLWithPath: args[1]))
            try emit(["hops": features.novelty.count, "activeHops": features.activeRange.count])
            return
        }
        if mode == "inventory" {
            let root = URL(fileURLWithPath: args.dropFirst().first ?? "Private/Audio Samples/Auto-Grouping Tracks")
            var visited: Set<String> = []
            var paths: [String] = []
            func visit(_ url: URL) throws {
                var candidate = url
                let info = try candidate.resourceValues(forKeys: [.isAliasFileKey])
                if info.isAliasFile == true {
                    candidate = try URL(resolvingAliasFileAt: candidate, options: [.withoutUI, .withoutMounting])
                }
                candidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
                guard visited.insert(candidate.path).inserted else { return }
                let values = try candidate.resourceValues(forKeys: [.isDirectoryKey])
                if values.isDirectory == true {
                    for child in try FileManager.default.contentsOfDirectory(at: candidate, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                        try visit(child)
                    }
                } else if ["wav", "aif", "aiff", "flac", "mp3", "m4a", "opus", "ogg", "aac"].contains(candidate.pathExtension.lowercased()) {
                    paths.append(candidate.path)
                }
            }
            try visit(root)
            try emit(paths.sorted())
            return
        }

        let analyzer = TrackSimilarityAnalyzer()
        if mode == "batch", args.count >= 3 {
            let sources = args.dropFirst().enumerated().map { index, path in
                TrackSimilaritySource(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!, url: URL(fileURLWithPath: path))
            }
            var pairs: [TrackSimilarityPair] = []
            for i in sources.indices { for j in sources.indices where j > i {
                pairs.append(TrackSimilarityPair(firstID: sources[i].id, secondID: sources[j].id))
            } }
            let start = Date()
            let result = await analyzer.analyze(TrackSimilarityRequest(sources: sources, pairs: pairs, deadline: start.addingTimeInterval(5)))
            let elapsed = Date().timeIntervalSince(start)
            for pair in pairs {
                let value = result.evidence[pair] ?? TrackSimilarityEvidence()
                try emit(Row(first: sources.first { $0.id == pair.firstID }!.url.path,
                    second: sources.first { $0.id == pair.secondID }!.url.path,
                    sameRecording: value.sameRecording.rawValue, samePerformance: value.samePerformance.rawValue,
                    matchedSeconds: value.matchedSeconds, firstCoverage: value.firstCoverage,
                    secondCoverage: value.secondCoverage, speedRatio: value.speedRatio,
                    offsetSeconds: value.offsetSeconds, diagnostic: value.diagnostic,
                    seconds: elapsed, timedOut: result.timedOut))
            }
            return
        }
        var falsePositives = 0
        var positives = [0, 0]
        var matches = [0, 0]
        var unknown = 0
        var labeledNegatives = 0
        var groundTruthComplete = false
        var checks: [LabeledPair] = []
        if mode == "manifest" {
            guard args.count == 2 else { throw CocoaError(.fileReadInvalidFileName) }
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
            checks = manifest.pairs
            groundTruthComplete = manifest.status == "source-verified"
        } else if mode == "compare", args.count >= 3 {
            let files = Array(args.dropFirst())
            for i in files.indices {
                for j in files.indices where j > i {
                    checks.append(LabeledPair(first: files[i], second: files[j], sameRecording: nil, samePerformance: nil, provenance: "Unlabeled diagnostic."))
                }
            }
        } else {
            print("Usage: similarity-benchmark.sh inventory [DIRECTORY] | compare FILE FILE [...] | manifest MANIFEST.json")
            return
        }
        for check in checks {
            let sources = [TrackSimilaritySource(id: UUID(), url: URL(fileURLWithPath: check.first)),
                           TrackSimilaritySource(id: UUID(), url: URL(fileURLWithPath: check.second))]
            let pair = TrackSimilarityPair(firstID: sources[0].id, secondID: sources[1].id)
            let start = Date()
            let analysis = await analyzer.analyze(TrackSimilarityRequest(sources: sources, pairs: [pair], deadline: start.addingTimeInterval(30)))
            let evidence = analysis.evidence[pair] ?? TrackSimilarityEvidence()
            let canonicalFirst = sources.first { $0.id == pair.firstID }!.url.path
            let canonicalSecond = sources.first { $0.id == pair.secondID }!.url.path
            try emit(Row(first: canonicalFirst, second: canonicalSecond,
                         sameRecording: evidence.sameRecording.rawValue, samePerformance: evidence.samePerformance.rawValue,
                         matchedSeconds: evidence.matchedSeconds, firstCoverage: evidence.firstCoverage,
                         secondCoverage: evidence.secondCoverage, speedRatio: evidence.speedRatio,
                         offsetSeconds: evidence.offsetSeconds, diagnostic: evidence.diagnostic,
                         seconds: Date().timeIntervalSince(start), timedOut: analysis.timedOut))
            for (index, expected) in [check.sameRecording, check.samePerformance].enumerated() {
                guard let expected else { unknown += 1; continue }
                let verdict = index == 0 ? evidence.sameRecording : evidence.samePerformance
                if expected { positives[index] += 1; if verdict == .match { matches[index] += 1 } }
                else { labeledNegatives += 1 }
                if !expected && verdict == .match { falsePositives += 1 }
            }
        }
        let gatesPass = groundTruthComplete && unknown == 0 && labeledNegatives > 0 && falsePositives == 0
            && positives[0] > 0 && positives[1] > 0
            && Double(matches[0]) / Double(positives[0]) >= 0.95
            && Double(matches[1]) / Double(positives[1]) >= 0.90
        try emit(["falsePositives": falsePositives, "sameRecordingPositives": positives[0],
                  "sameRecordingMatches": matches[0], "samePerformancePositives": positives[1],
                  "samePerformanceMatches": matches[1], "unlabeledVerdicts": unknown,
                  "labeledNegativeVerdicts": labeledNegatives, "accuracyGatesPassed": gatesPass ? 1 : 0])
        if falsePositives > 0 { exit(1) }
    }
}
