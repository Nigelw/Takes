import Foundation

// Benchmark CLI for the analysis engine. Compiled by
// `scripts/analysis-benchmark.sh` together with the UI-independent engine
// sources from Sources/Takes/Analysis/, so it exercises exactly the code
// that ships in the app.
//
//   analysis-cli analyze <file...>       print metrics per file
//   analysis-cli benchmark <corpus-dir>  check the corpus against ground
//                                        truth from docs/analysis-corpus.md

// MARK: - Formatting helpers

func format(_ value: Double?, _ digits: Int = 1) -> String {
    guard let value, value.isFinite else { return "—" }
    return String(format: "%.\(digits)f", value)
}

/// Bass (sub+bass) minus treble (treble+air) band level, mirroring the
/// verdict builder's tilt input so thresholds can be tuned from CLI output.
func bassTiltDB(_ report: AudioAnalysisReport) -> Double {
    func level(_ names: [String]) -> Double {
        let power = report.tonalBalance.bands
            .filter { names.contains($0.name) }
            .map { pow(10, $0.relativeDB / 10) }
            .reduce(0, +)
        return 10 * log10(max(power, .leastNormalMagnitude))
    }
    return level(["Sub", "Bass"]) - level(["Treble", "Air"])
}

func describe(_ report: AudioAnalysisReport) -> String {
    let cutoff = report.bandwidth.detectedCutoffHz.map { String(format: "%.1fk", $0 / 1_000) } ?? "full"
    let confidence: String
    switch report.bandwidth.confidence {
    case .low: confidence = "low"
    case .medium: confidence = "med"
    case .high: confidence = "high"
    }
    var line = [
        report.fileInfo.fileName.padding(toLength: 34, withPad: " ", startingAt: 0),
        report.fileInfo.codecDescription.padding(toLength: 11, withPad: " ", startingAt: 0),
        "LUFS \(format(report.loudness.integratedLUFS))",
        "peak \(format(report.loudness.samplePeakDBFS))",
        "crest \(format(report.loudness.crestFactorDB))",
        "floor \(format(report.noiseFloor.noiseFloorDBFS, 0))",
        "flat \(format(report.noiseFloor.quietFrameSpectralFlatness, 2))",
        "cutoff \(cutoff) (\(confidence))",
        "tilt \(format(bassTiltDB(report)))",
        "centroid \(format(report.tonalBalance.spectralCentroidHz, 0))",
        "roll95 \(format(report.tonalBalance.rolloff95Hz, 0))",
    ].joined(separator: "  ")
    line += "\n    bands: " + report.tonalBalance.bands
        .map { "\($0.name) \(format($0.relativeDB))" }
        .joined(separator: "  ")
    line += "\n    analog: floor \(format(report.analogSource.stationaryNoiseFloorDBFS, 0))"
        + "  flat \(format(report.analogSource.noiseFloorFlatness, 2))"
        + "  cohere \(format(report.analogSource.highBandNoiseCoherence, 2))"
        + "  clicks/min \(format(report.analogSource.clickRatePerMinute, 1))"
        + "  rumble \(format(report.analogSource.rumbleSideLevelDB, 0))"
        + "  wow \(report.analogSource.wowPeakCents.map { format($0, 0) } ?? "—")"
    line += "\n    lossy: pre-echo \(format(report.lossyArtifacts.preEchoScore, 1)) dB"
        + " (\(report.lossyArtifacts.attackCount) attacks)"
        + "  flicker \(format(report.lossyArtifacts.highBandFlickerScore, 1))"
        + "  hf-cohere \(format(report.lossyArtifacts.hfStereoCoherence, 2))"
    if let stream = report.mp3Stream {
        line += "\n    mp3: \(stream.encoderInfo ?? "unknown encoder")"
            + "  \(stream.bitrateMode == .cbr ? "CBR" : "VBR") \(format(stream.meanBitrateKbps, 0)) kbps"
            + "  xing \(stream.hasXingOrInfoHeader)  lame \(stream.hasLameTag)"
            + "  lowpass \(stream.declaredLowpassHz.map { format($0, 0) } ?? "—")"
            + "  IS \(stream.usesIntensityStereo)  js \(format(stream.jointStereoFrameFraction, 2))"
    }
    line += "\n    verdicts: " + report.verdicts.map { "[\($0.category.rawValue)] \($0.title)" }.joined(separator: " | ")
    for conclusion in report.conclusions {
        line += "\n    ⇒ \(conclusion.statement) [\(conclusion.confidence)]"
        for item in conclusion.evidence {
            line += "\n       • \(item)"
        }
    }
    return line
}

// MARK: - Benchmark expectations

struct Expectation {
    var lufs: ClosedRange<Double>?
    /// Substrings that must appear among verdict titles.
    var requiredVerdicts: [String] = []
    /// Substrings that must NOT appear among verdict titles.
    var forbiddenVerdicts: [String] = []
    /// Substrings that must appear among conclusion statements.
    var requiredConclusions: [String] = []
    /// Substrings that must NOT appear among conclusion statements.
    var forbiddenConclusions: [String] = []
    var cutoffRange: ClosedRange<Double>?
    /// When true, a nil cutoff (full bandwidth) also satisfies `cutoffRange`.
    var cutoffMayBeFull = false
    var notes: String = ""
}

// Ground truth from docs/analysis-corpus.md (ffmpeg-measured LUFS ±1.0).
let expectations: [String: Expectation] = [
    "reference.wav": Expectation(
        lufs: -14.6 ... -12.6,
        requiredVerdicts: ["Looks genuinely lossless"],
        forbiddenVerdicts: ["transcode", "hiss", "muffled"],
        cutoffRange: 20_000 ... 22_050, cutoffMayBeFull: true
    ),
    "true_lossless.flac": Expectation(
        lufs: -14.6 ... -12.6,
        requiredVerdicts: ["Looks genuinely lossless"],
        forbiddenVerdicts: ["transcode"],
        cutoffRange: 20_000 ... 22_050, cutoffMayBeFull: true
    ),
    "loud.wav": Expectation(
        lufs: -6.6 ... -4.6,
        requiredVerdicts: ["Very loud master"]
    ),
    "quiet.wav": Expectation(
        lufs: -22.6 ... -20.6,
        requiredVerdicts: ["Quiet master"]
    ),
    "tilt_bassy.wav": Expectation(
        // A +6 dB/120 Hz shelf on bright synthetic material still leaves the
        // absolute tilt far below real-music norms, so single-file analysis
        // cannot honestly call it bass-heavy; comparative mode will.
        forbiddenVerdicts: ["muffled", "transcode"],
        notes: "absolute bass-tilt detection deferred to comparative mode"
    ),
    "tilt_bright.wav": Expectation(
        forbiddenVerdicts: ["Bass-heavy balance", "muffled"]
    ),
    "muffled.wav": Expectation(
        requiredVerdicts: ["muffled"]
    ),
    "hiss.wav": Expectation(
        requiredVerdicts: ["Background hiss"]
    ),
    "mp3_128.mp3": Expectation(
        lufs: -15.4 ... -13.4,
        requiredVerdicts: ["Lossy encode"],
        cutoffRange: 15_000 ... 17_500
    ),
    "mp3_320.mp3": Expectation(
        requiredVerdicts: ["Lossy encode"],
        cutoffRange: 19_000 ... 22_050, cutoffMayBeFull: true
    ),
    "aac_96.m4a": Expectation(
        requiredVerdicts: ["Low-bitrate lossy encode"],
        cutoffRange: 13_000 ... 16_500
    ),
    "aac_256.m4a": Expectation(
        requiredVerdicts: ["Lossy encode"],
        cutoffRange: 19_000 ... 22_050, cutoffMayBeFull: true
    ),
    "fake_lossless_mp3128.flac": Expectation(
        requiredVerdicts: ["transcode"],
        cutoffRange: 15_000 ... 17_500,
        notes: "core trap case: MP3-128 wearing FLAC"
    ),
    "fake_lossless_aac128.flac": Expectation(
        requiredVerdicts: ["transcode"],
        cutoffRange: 13_000 ... 19_500,
        notes: "trap case: AAC-128 wearing FLAC"
    ),
    "real_reference.wav": Expectation(
        forbiddenVerdicts: ["muffled", "hiss"],
        notes: "AAC-283-sourced WAV; soft ~19-20k rolloff — either flag is defensible, so only sanity checks here"
    ),
    "real_loud.wav": Expectation(
        lufs: -8.2 ... -6.2,
        requiredVerdicts: ["Very loud master"]
    ),
    "real_muffled.wav": Expectation(
        requiredVerdicts: ["muffled"]
    ),
    "real_hiss.wav": Expectation(
        // The 30 s real-music window never drops below ≈ −20 dBFS, so a
        // −50 dBFS hiss bed stays 30 dB under the quietest music — no gap
        // exists to measure it in. Documented limitation.
        forbiddenVerdicts: ["muffled", "transcode"],
        notes: "hiss under gapless music is undetectable via quiet-frame analysis"
    ),
    "real_mp3_128.mp3": Expectation(
        requiredVerdicts: ["Lossy encode"],
        cutoffRange: 15_000 ... 17_500
    ),
    "real_fake_lossless_mp3128.flac": Expectation(
        requiredVerdicts: ["transcode"],
        cutoffRange: 15_000 ... 17_500,
        notes: "trap case on real music"
    ),
]

func check(_ report: AudioAnalysisReport, against expectation: Expectation) -> [String] {
    var failures: [String] = []
    let titles = report.verdicts.map(\.title)

    if let range = expectation.lufs {
        if let lufs = report.loudness.integratedLUFS {
            if !range.contains(lufs) {
                failures.append("LUFS \(format(lufs)) outside \(range)")
            }
        } else {
            failures.append("LUFS nil, expected \(range)")
        }
    }
    for required in expectation.requiredVerdicts
    where !titles.contains(where: { $0.localizedCaseInsensitiveContains(required) }) {
        failures.append("missing verdict containing “\(required)”")
    }
    for forbidden in expectation.forbiddenVerdicts
    where titles.contains(where: { $0.localizedCaseInsensitiveContains(forbidden) }) {
        failures.append("unexpected verdict containing “\(forbidden)”")
    }
    let statements = report.conclusions.map(\.statement)
    for required in expectation.requiredConclusions
    where !statements.contains(where: { $0.localizedCaseInsensitiveContains(required) }) {
        failures.append("missing conclusion containing “\(required)”")
    }
    for forbidden in expectation.forbiddenConclusions
    where statements.contains(where: { $0.localizedCaseInsensitiveContains(forbidden) }) {
        failures.append("unexpected conclusion containing “\(forbidden)”")
    }
    if let range = expectation.cutoffRange {
        if let cutoff = report.bandwidth.detectedCutoffHz {
            if !range.contains(cutoff) {
                failures.append("cutoff \(format(cutoff / 1_000)) kHz outside \(range.lowerBound / 1_000)–\(range.upperBound / 1_000) kHz")
            }
        } else if !expectation.cutoffMayBeFull {
            failures.append("no cutoff detected, expected \(range.lowerBound / 1_000)–\(range.upperBound / 1_000) kHz")
        }
    }
    return failures
}

// MARK: - Entry point

let arguments = CommandLine.arguments.dropFirst()
guard let mode = arguments.first else {
    print("usage: analysis-cli analyze <file...> | benchmark <corpus-dir>")
    exit(2)
}

switch mode {
case "analyze":
    for path in arguments.dropFirst() {
        let url = URL(fileURLWithPath: path)
        do {
            // Spectrogram included so ad-hoc runs exercise the full app path
            // (benchmark mode skips it purely for speed).
            let report = try AudioAnalysisEngine.analyze(fileAt: url, includeSpectrogram: true)
            print(describe(report))
        } catch {
            print("\(url.lastPathComponent): FAILED — \(error.localizedDescription)")
        }
    }

case "benchmark":
    guard arguments.count >= 2 else {
        print("usage: analysis-cli benchmark <corpus-dir>")
        exit(2)
    }
    let corpusDir = URL(fileURLWithPath: Array(arguments)[1])
    var passCount = 0
    var failCount = 0
    var missing: [String] = []

    for (fileName, expectation) in expectations.sorted(by: { $0.key < $1.key }) {
        let url = corpusDir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            missing.append(fileName)
            continue
        }
        do {
            let report = try AudioAnalysisEngine.analyze(fileAt: url, includeSpectrogram: false)
            let failures = check(report, against: expectation)
            if failures.isEmpty {
                passCount += 1
                print("PASS  \(fileName)\(expectation.notes.isEmpty ? "" : "  (\(expectation.notes))")")
            } else {
                failCount += 1
                print("FAIL  \(fileName)")
                failures.forEach { print("      - \($0)") }
                print("      " + describe(report).replacingOccurrences(of: "\n", with: "\n      "))
            }
        } catch {
            failCount += 1
            print("FAIL  \(fileName) — analysis threw: \(error.localizedDescription)")
        }
    }

    if !missing.isEmpty {
        print("\nmissing corpus files (run scripts/make-analysis-corpus.sh): \(missing.joined(separator: ", "))")
    }
    print("\n\(passCount) passed, \(failCount) failed, \(missing.count) missing")
    exit(failCount == 0 ? 0 : 1)

default:
    print("unknown mode “\(mode)”")
    exit(2)
}
