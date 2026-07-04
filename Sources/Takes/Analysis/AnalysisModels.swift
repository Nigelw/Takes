import CoreGraphics
import Foundation

/// Everything the analysis engine learned about a single audio file.
///
/// Pure data so the same report drives the experimental Analysis window and
/// the `scripts/analysis-cli` benchmark harness. Numeric metrics stay separate
/// from `verdicts` (the human-readable interpretation) so thresholds can be
/// tuned without touching the measurement code.
struct AudioAnalysisReport {
    let fileInfo: AnalyzedFileInfo
    let loudness: LoudnessMetrics
    let tonalBalance: TonalBalanceMetrics
    let noiseFloor: NoiseFloorMetrics
    let bandwidth: BandwidthMetrics
    let averageSpectrum: AverageSpectrum
    let spectrogram: SpectrogramImage?
    let verdicts: [AnalysisVerdict]
}

/// Container/codec facts read from the file itself (not measured from audio).
struct AnalyzedFileInfo {
    let url: URL
    let fileName: String
    let codecDescription: String
    let sampleRateHz: Double
    let channelCount: Int
    /// Source bit depth where the container declares one (PCM/FLAC/ALAC).
    let bitDepth: Int?
    let durationSeconds: Double
    /// Overall data rate derived from file size / duration, in kbps.
    let dataRateKbps: Double
    /// Whether the codec itself is lossless (PCM, FLAC, ALAC). Drives the
    /// "lossless file that looks transcoded" verdict.
    let isLosslessCodec: Bool
}

/// ITU-R BS.1770-4 loudness plus peak/dynamics facts.
struct LoudnessMetrics {
    /// Integrated (gated) loudness in LUFS. `nil` when the whole file fell
    /// below the absolute gate (effectively silence).
    let integratedLUFS: Double?
    let samplePeakDBFS: Double
    /// Sample peak minus overall RMS, in dB. Squashed masters land ~8–10,
    /// dynamic ones 14+.
    let crestFactorDB: Double
    /// Runs of ≥3 consecutive near-full-scale samples; >0 suggests the
    /// master is clipped, many suggest it is slammed.
    let clippedSampleRunCount: Int
}

/// Long-term energy split into perceptually meaningful bands.
struct TonalBalanceMetrics {
    struct Band {
        let name: String
        let rangeHz: ClosedRange<Double>
        /// Band level in dB relative to the total energy of the file, so
        /// values are comparable across files mastered at different levels.
        let relativeDB: Double
    }

    let bands: [Band]
    let spectralCentroidHz: Double
    /// Frequency below which 95% of the energy lives.
    let rolloff95Hz: Double
}

/// Noise floor measured from the quietest stretches of the file.
struct NoiseFloorMetrics {
    /// Broadband level of the quietest frames, dBFS. Digital silence reads
    /// as -Double.infinity or extremely low; analog sources sit much higher.
    let noiseFloorDBFS: Double
    /// Spectral flatness (0…1) of the quiet frames. Broadband hiss is flat;
    /// tonal residue (hum, bleed) is not.
    let quietFrameSpectralFlatness: Double
}

/// High-frequency bandwidth measurement, the core of transcode detection.
struct BandwidthMetrics {
    enum Confidence {
        case low, medium, high
    }

    let nyquistHz: Double
    /// Highest frequency with real content. `nil` when energy extends to
    /// Nyquist with no shelf (full-bandwidth source).
    let detectedCutoffHz: Double?
    /// How far the spectrum falls above the cutoff relative to mid-band, dB.
    let shelfDepthDB: Double?
    let confidence: Confidence
}

/// Welch-averaged power spectrum for the UI line plot and cutoff marker.
struct AverageSpectrum {
    /// Center frequency of bin `i` is `Double(i) * binWidthHz`.
    let binWidthHz: Double
    let magnitudesDB: [Float]
}

/// Rendered spectrogram (linear frequency axis so codec shelves read as a
/// hard horizontal edge) plus the ranges needed to label its axes.
struct SpectrogramImage {
    let image: CGImage
    let durationSeconds: Double
    let maxFrequencyHz: Double
}

/// One human-readable finding derived from the metrics.
struct AnalysisVerdict: Identifiable {
    enum Category: String, CaseIterable {
        case loudness = "Loudness"
        case tonalBalance = "Tonal Balance"
        case clarity = "Clarity"
        case noise = "Noise"
        case encoding = "Encoding"
        case authenticity = "Authenticity"
    }

    /// How the finding should read at a glance in the UI.
    enum Tone {
        /// Neutral measurement, nothing notable.
        case info
        /// A property that speaks well of the file.
        case good
        /// Worth a second look (e.g. quiet master, dull balance).
        case caution
        /// Strong evidence of a problem (e.g. fake lossless, clipping).
        case warning
    }

    let id = UUID()
    let category: Category
    let title: String
    let detail: String
    let tone: Tone
}
