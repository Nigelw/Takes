import Foundation

/// A user-toggleable unit of analysis in the experimental Analysis window.
///
/// Each case maps to one accumulator (or the bitstream pass) inside
/// `AudioAnalysisEngine`, and carries the copy the pre-run configuration
/// screen shows: what conclusion it feeds and roughly how it works. Analysis
/// is CPU-heavy, so the window lets you switch the expensive modules off
/// before running — the `cost` rating flags which ones those are.
enum AnalysisModule: String, CaseIterable, Identifiable, Sendable {
    case loudness
    case tonalBalance
    case noiseFloor
    case analogSource
    case lossyArtifacts
    case bitstream
    case spectrogram

    var id: String { rawValue }

    /// Relative runtime, shown as a badge. Ordered so the UI can color-code:
    /// `fast` ≈ trivial, `average` ≈ one STFT pass, `slow` ≈ heavy per-sample
    /// plus multi-band STFT work.
    enum Cost: Int, Comparable {
        case fast, average, slow

        static func < (lhs: Cost, rhs: Cost) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .fast: return "Fast"
            case .average: return "Average"
            case .slow: return "Slow"
            }
        }
    }

    var name: String {
        switch self {
        case .loudness: return "Loudness & Dynamics"
        case .tonalBalance: return "Tonal Balance & Bandwidth"
        case .noiseFloor: return "Noise Floor (Quiet Passages)"
        case .analogSource: return "Analog Source Detection"
        case .lossyArtifacts: return "Lossy Encode Artifacts"
        case .bitstream: return "MP3 Bitstream Inspection"
        case .spectrogram: return "Spectrogram"
        }
    }

    var cost: Cost {
        switch self {
        case .loudness, .noiseFloor, .bitstream: return .fast
        case .tonalBalance: return .fast
        case .spectrogram: return .average
        case .analogSource, .lossyArtifacts: return .slow
        }
    }

    /// The question this analysis is trying to answer — i.e. which conclusion
    /// or verdict it feeds.
    var determines: String {
        switch self {
        case .loudness:
            return "Whether the master is loud or quiet, and how heavily it's compressed or clipped."
        case .tonalBalance:
            return "Bass/treble balance, whether it sounds muffled, and whether a \u{201C}lossless\u{201D} file is secretly a lossy transcode."
        case .noiseFloor:
            return "Background hiss audible in a track's quiet moments."
        case .analogSource:
            return "Whether the audio was ripped from vinyl or tape \u{2014} even under continuous music with no quiet gaps."
        case .lossyArtifacts:
            return "Whether a lossy encode is low quality or from an early / badly configured encoder, and adds evidence that a lossless file is a transcode."
        case .bitstream:
            return "The original encoder and its settings, read straight from an MP3's frames."
        case .spectrogram:
            return "A visual time\u{2013}frequency picture that makes codec cutoffs and noise visible at a glance."
        }
    }

    /// A one- or two-sentence sketch of the method, for the curious.
    var howItWorks: String {
        switch self {
        case .loudness:
            return "Integrated loudness by ITU-R BS.1770 K-weighting with gating, plus sample peak, crest factor, and runs of full-scale (clipped) samples."
        case .tonalBalance:
            return "Builds a long-term average spectrum (Welch's method) and reads its per-band levels, spectral tilt, and any sharp high-frequency cutoff shelf."
        case .noiseFloor:
            return "Ranks short frames by level and inspects the quietest ones for broadband, spectrally flat noise. Needs actual quiet passages to work."
        case .analogSource:
            return "Estimates a stationary noise floor by minimum statistics, tests whether that noise is decorrelated between channels, and looks for surface clicks and sub-30 Hz turntable rumble."
        case .lossyArtifacts:
            return "Measures pre-echo before sharp transients, high-frequency \u{201C}birdie\u{201D} flicker at the codec frame rate, and whether the highs collapse to mono (intensity stereo)."
        case .bitstream:
            return "Parses MPEG frame headers and the Xing / LAME tag for encoder version, declared lowpass, bitrate mode, and intensity-stereo flags. MP3 files only; no decoding."
        case .spectrogram:
            return "A short-time Fourier transform rendered as a log-magnitude image with a linear frequency axis."
        }
    }
}

/// The set of modules to run. All on by default; the window persists the
/// last choice for the session.
typealias AnalysisSelection = Set<AnalysisModule>

extension Set where Element == AnalysisModule {
    /// Every module enabled — the default and the value the CLI/benchmark
    /// use (minus the spectrogram, which is display-only).
    static var all: AnalysisSelection { Set(AnalysisModule.allCases) }
}
