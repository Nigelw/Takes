import Foundation

// Contracts for the experimental comparative (multi-file) analysis. See
// docs/comparative-quality-analysis.md.
//
// The organising idea: "which is better" is only answerable once you know how
// two files RELATE. A pair that shares a master can be ranked on fidelity from
// evidence; a pair that doesn't share a master differs by taste, and ranking it
// would be a category error. Every type here keeps that split explicit.

// MARK: - Relationship

/// How two tracks relate. Gates everything downstream: fidelity ranking is
/// only meaningful within `.identical` / `.sameMaster`.
enum PairRelationship: String, Equatable, Sendable {
    /// Bit-identical, or residual below the quantization floor after alignment.
    case identical
    /// Aligns confidently; the residual is well below the signal and
    /// *structured* (concentrated at HF, or impulsive around transients) —
    /// i.e. one is a degraded descendant of the other, or both descend from a
    /// common master.
    case sameMaster
    /// Aligns confidently, but the residual is broadband and comparable to the
    /// signal: different EQ, compression, or mix. Same performance, different
    /// master — rankable on taste, not on fidelity.
    case differentMaster
    /// No confident alignment: different performance, different edit, or
    /// unrelated material.
    case differentRecording
    /// Alignment or residual measurement was attempted but inconclusive.
    case indeterminate

    /// Whether a fidelity ranking is defensible for this relationship.
    var supportsFidelityRanking: Bool {
        switch self {
        case .identical, .sameMaster: return true
        case .differentMaster, .differentRecording, .indeterminate: return false
        }
    }

    var label: String {
        switch self {
        case .identical: return "Identical"
        case .sameMaster: return "Same master"
        case .differentMaster: return "Different master"
        case .differentRecording: return "Different recording"
        case .indeterminate: return "Undetermined"
        }
    }
}

// MARK: - Alignment

/// Sample-accurate alignment and gain match between two tracks, refined from
/// `TrackAligner`'s 1 ms coarse lag.
struct PairAlignmentResult: Equatable, Sendable {
    /// How far B sits after A, in seconds. Negative means B starts earlier.
    let offsetSeconds: Double
    /// The same offset in samples at `sampleRate`, from the fine (GCC-PHAT) pass.
    let offsetSamples: Int
    /// Rate the fine pass ran at; both files are resampled to this if they differ.
    let sampleRate: Double
    /// Normalised cross-correlation at the chosen lag, 0…1. The accept/reject signal.
    let correlation: Double
    /// Gain applied to B to match A's level, in dB. Derived from integrated
    /// loudness where available, else from overlap RMS.
    let gainMatchDB: Double
    /// Seconds of overlapping audio the comparison actually measured.
    let overlapSeconds: Double
    /// Whether `correlation` and `overlapSeconds` clear the accept thresholds.
    let isConfident: Bool
    /// Playback-speed ratio between the two files, when they hold the same
    /// performance at different speeds — the signature of a remaster
    /// transferred from tape at a slightly different rate. `nil` when the pair
    /// runs at the same speed, which is the normal case.
    ///
    /// A speed difference makes a fixed-lag comparison meaningless, so it is
    /// reported rather than corrected: it is by itself proof of a different
    /// transfer, and therefore of a different master.
    let speedRatio: Double?

    static let none = PairAlignmentResult(
        offsetSeconds: 0,
        offsetSamples: 0,
        sampleRate: 0,
        correlation: 0,
        gainMatchDB: 0,
        overlapSeconds: 0,
        isConfident: false,
        speedRatio: nil
    )
}

/// What is left after aligning, gain-matching and subtracting. The shape of
/// this residual — not just its level — is what separates a re-encode from a
/// different master.
struct ResidualMetrics: Equatable, Sendable {
    /// Residual RMS relative to the reference signal RMS, in dB. More negative
    /// means the two files are more alike. Roughly: < −60 dB is a transparent
    /// match, −60…−20 dB is codec-scale difference, > −20 dB is a different master.
    let residualToSignalDB: Double
    /// Per-band residual-to-signal ratio, using the same seven bands as
    /// `TonalBalanceMetrics` (sub, bass, low-mid, mid, high-mid, treble, air).
    let bandResidualToSignalDB: [Double]
    /// Residual-to-signal aggregated over 60 Hz – 4 kHz, where codecs are
    /// near-transparent at any usable bitrate. This is the statistic the
    /// same-master test keys on: energy-weighted across the range rather than
    /// per-band, because the sub band holds too little energy to judge and
    /// reads alarmingly high on encodes that are otherwise clean.
    let midBandResidualToSignalDB: Double
    /// Per-band level of the gain-matched candidate minus the reference, in dB,
    /// over the same seven bands. Negative means the candidate has less energy
    /// there.
    ///
    /// This is the difference spectrum the comparative metrics are built on,
    /// and it is what separates codec noise from a different master: a codec
    /// leaves the difference flat at 0 dB below its cutoff and then falls off a
    /// cliff, while a different master tilts the whole curve.
    let bandLevelDifferenceDB: [Double]
    /// Largest absolute band-level difference within 60 Hz – 4 kHz. Near zero
    /// for any same-master pair; a different master moves it several dB.
    let midBandTiltDifferenceDB: Double
    /// Fraction of total residual energy above 10 kHz, 0…1. Near 1 means the
    /// files differ only in the top octaves — the codec-bandwidth signature.
    let highFrequencyEnergyFraction: Double
    /// Crest factor of the residual envelope, dB. High means the difference is
    /// impulsive (clicks, pre-echo) rather than stationary.
    let residualCrestFactorDB: Double
    /// Normalised correlation of the two aligned, gain-matched signals, 0…1.
    let waveformCoherence: Double

    static let unavailable = ResidualMetrics(
        residualToSignalDB: 0,
        bandResidualToSignalDB: [],
        midBandResidualToSignalDB: 0,
        bandLevelDifferenceDB: [],
        midBandTiltDifferenceDB: 0,
        highFrequencyEnergyFraction: 0,
        residualCrestFactorDB: 0,
        waveformCoherence: 0
    )
}

// MARK: - Findings

/// One measured difference between two files, stated as a directional claim
/// with the evidence that supports it.
///
/// Findings are the unit the ranking policy reasons over. Each carries a
/// `dimension` that decides whether it counts toward fidelity or is merely
/// descriptive — see `Dimension.isFidelityBearing`.
struct QualityFinding: Identifiable, Equatable, Sendable {
    /// What was compared. The fidelity/taste split lives here and nowhere else.
    enum Dimension: String, Equatable, Sendable, CaseIterable {
        /// Retained high-frequency bandwidth (codec lowpass shelf).
        case bandwidth
        /// Pre-echo, HF flicker, intensity-stereo collapse.
        case codecArtifacts
        /// Hiss, clicks, crackle, rumble — noise one file has and the other doesn't.
        case addedNoise
        /// Full-scale runs / clipped samples.
        case clipping
        /// Direct provenance from the container or bitstream (lossless vs lossy,
        /// LAME tag, declared lowpass).
        case provenance
        /// Crest factor, limiting, dynamic range. Mastering choice, not fidelity.
        case dynamics
        /// Spectral tilt / EQ difference. Mastering choice, not fidelity.
        case tonalBalance
        /// Overall level. Never a quality difference.
        case loudness

        /// Whether a difference on this dimension is evidence about closeness
        /// to the master. The rest describe mastering choices, which are taste.
        var isFidelityBearing: Bool {
            switch self {
            case .bandwidth, .codecArtifacts, .addedNoise, .clipping, .provenance:
                return true
            case .dynamics, .tonalBalance, .loudness:
                return false
            }
        }

        var label: String {
            switch self {
            case .bandwidth: return "Bandwidth"
            case .codecArtifacts: return "Codec artifacts"
            case .addedNoise: return "Added noise"
            case .clipping: return "Clipping"
            case .provenance: return "Provenance"
            case .dynamics: return "Dynamics"
            case .tonalBalance: return "Tonal balance"
            case .loudness: return "Loudness"
            }
        }
    }

    /// Which side the evidence points to. `tie` records that the dimension was
    /// measured and found equivalent — worth keeping, because "we looked and
    /// they match" is different from "we didn't look".
    enum Direction: Equatable, Sendable {
        case favorsA
        case favorsB
        case tie
    }

    let id = UUID()
    let dimension: Dimension
    let direction: Direction
    /// Dimension-specific size of the difference, used to order evidence and to
    /// decide whether it clears the audibility bar. Always non-negative.
    let magnitude: Double
    let confidence: SourceConclusion.Confidence
    /// One measurement-backed line, e.g. "A keeps 20.4 kHz; B rolls off at 16.0 kHz".
    let statement: String

    static func == (lhs: QualityFinding, rhs: QualityFinding) -> Bool {
        lhs.dimension == rhs.dimension
            && lhs.direction == rhs.direction
            && lhs.magnitude == rhs.magnitude
            && lhs.confidence == rhs.confidence
            && lhs.statement == rhs.statement
    }
}

// MARK: - Ranking

/// The verdict for one pair. Abstention is a first-class outcome: a tool that
/// always names a winner cannot be trusted on the calls where it is right.
enum PairRanking: Equatable, Sendable {
    /// A is closer to the master.
    case aBetter(confidence: SourceConclusion.Confidence)
    /// B is closer to the master.
    case bBetter(confidence: SourceConclusion.Confidence)
    /// Same master, and nothing separates them on fidelity.
    case equivalent
    /// Fidelity ranking does not apply — different master or different recording.
    case notComparable(reason: String)
    /// Measured, but the evidence is too weak or too contradictory to call.
    case undetermined(reason: String)

    var namesAWinner: Bool {
        switch self {
        case .aBetter, .bBetter: return true
        case .equivalent, .notComparable, .undetermined: return false
        }
    }
}

/// Everything measured about one ordered pair of tracks. `a` and `b` index into
/// `ComparativeAnalysisResult.reports`.
struct PairComparison: Identifiable, Sendable {
    let id = UUID()
    let a: Int
    let b: Int
    let relationship: PairRelationship
    let alignment: PairAlignmentResult
    let residual: ResidualMetrics
    /// Fidelity-bearing findings first, largest magnitude first.
    let findings: [QualityFinding]
    let ranking: PairRanking

    /// Findings that describe mastering choices rather than fidelity. Shown as
    /// description, never folded into the ranking.
    var descriptiveFindings: [QualityFinding] {
        findings.filter { !$0.dimension.isFidelityBearing && $0.direction != .tie }
    }

    var fidelityFindings: [QualityFinding] {
        findings.filter { $0.dimension.isFidelityBearing }
    }
}

// MARK: - Session-level result

/// A set of tracks that share a master, with whatever ordering the evidence
/// supports. `orderedIndices` is a flattened partial order: ties keep their
/// input order, and it is only as trustworthy as `isTotallyOrdered` says.
struct MasterGroup: Identifiable, Sendable {
    let id = UUID()
    /// Indices into `ComparativeAnalysisResult.reports`, best first where known.
    let orderedIndices: [Int]
    /// The clear winner, or nil when the group could not be ordered.
    let bestIndex: Int?
    /// False when at least one pair inside the group came back `.undetermined`
    /// or `.equivalent`, so the order is partial.
    let isTotallyOrdered: Bool
    /// Plain-language summary, e.g. "3 copies of the same master; the ALAC is
    /// the closest to it."
    let statement: String
    let confidence: SourceConclusion.Confidence
    /// Supporting lines, most convincing first.
    let evidence: [String]
}

/// The whole comparative pass over a session.
struct ComparativeAnalysisResult: Sendable {
    /// One single-file report per input track, in the order they were supplied.
    let reports: [AudioAnalysisReport]
    /// Every pair examined. Pairs whose tracks never aligned are still present,
    /// classified `.differentRecording`.
    let pairs: [PairComparison]
    /// Tracks clustered by shared master. Tracks that match nothing appear as
    /// singleton groups.
    let groups: [MasterGroup]

    func pair(_ a: Int, _ b: Int) -> PairComparison? {
        pairs.first { ($0.a == a && $0.b == b) || ($0.a == b && $0.b == a) }
    }
}
