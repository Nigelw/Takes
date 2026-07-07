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
    /// Which analyses actually ran. Skipped modules leave neutral placeholder
    /// metrics behind, so the UI consults this to hide sections it didn't
    /// measure rather than rendering empty/false readings.
    let analyzedModules: AnalysisSelection
    let loudness: LoudnessMetrics
    let tonalBalance: TonalBalanceMetrics
    let noiseFloor: NoiseFloorMetrics
    let bandwidth: BandwidthMetrics
    let analogSource: AnalogSourceMetrics
    let lossyArtifacts: LossyArtifactMetrics
    /// Present only for files that are MPEG audio streams.
    let mp3Stream: MP3StreamInfo?
    let averageSpectrum: AverageSpectrum
    let spectrogram: SpectrogramImage?
    /// Headline findings — "this FLAC is actually a reencode" — with the
    /// metrics that justify them. Rendered above the per-category verdicts.
    let conclusions: [SourceConclusion]
    let verdicts: [AnalysisVerdict]
}

/// Evidence of an analog (vinyl/tape) source, measurable even under gapless
/// music — unlike `NoiseFloorMetrics`, which needs quiet passages.
struct AnalogSourceMetrics {
    /// Minimum-statistics estimate of the stationary noise floor in dBFS
    /// (Martin-style per-band minima over a sliding window). Valid without
    /// any silent gaps; −∞ when the floor is indistinguishable from zero.
    let stationaryNoiseFloorDBFS: Double
    /// Spectral flatness (0…1) of the estimated stationary-noise PSD over
    /// 3–16 kHz. Broadband hiss is flat; digital silence/artifacts are not.
    let noiseFloorFlatness: Double
    /// Inter-channel coherence (0…1) of the noise floor above 8 kHz.
    /// Analog noise is decorrelated (≈0); mono/dual-mono digital ≈1.
    /// 1.0 for mono files (no evidence either way).
    let highBandNoiseCoherence: Double
    /// Impulsive wideband transient outliers per minute (vinyl clicks/pops).
    let clickRatePerMinute: Double
    /// Mean salience of detected clicks above the local signal, in dB.
    /// 0 when no clicks were detected.
    let meanClickSalienceDB: Double
    /// Energy below 30 Hz in the stereo difference (side) channel relative
    /// to total energy, dB. Turntable rumble is vertical ⇒ side-heavy.
    /// −∞ for mono files.
    let rumbleSideLevelDB: Double
    /// Peak pitch deviation in cents at wow rates (0.3–6 Hz), when
    /// measurable from sustained tonal content. Stretch metric; nil when
    /// the material offers no stable pitch track.
    let wowPeakCents: Double?

    /// Placeholder for when the analog-source module is switched off — reads
    /// as pristine (no floor, correlated, no clicks/rumble) so no analog
    /// conclusion is drawn.
    static let unavailable = AnalogSourceMetrics(
        stationaryNoiseFloorDBFS: -.infinity, noiseFloorFlatness: 0, highBandNoiseCoherence: 1,
        clickRatePerMinute: 0, meanClickSalienceDB: 0, rumbleSideLevelDB: -.infinity, wowPeakCents: nil
    )
}

/// Artifact measurements that grade lossy-encode quality beyond bandwidth.
struct LossyArtifactMetrics {
    /// Mean rise (dB) of the noise floor in the ~20 ms before strong
    /// attacks, relative to the local pre-attack baseline. Encoders without
    /// proper short-block switching smear quantization noise ahead of
    /// transients. ~0 for clean sources; higher = worse.
    let preEchoScore: Double
    /// Number of qualifying attacks the pre-echo score was averaged over
    /// (its reliability weight; <5 means "don't trust the score").
    let attackCount: Int
    /// On/off toggling rate of 10–16 kHz band energies at codec-frame
    /// cadence (~26 ms), normalized against natural modulation. Elevated
    /// values indicate "birdies"/spectral holes from starved bit allocation.
    let highBandFlickerScore: Double
    /// Inter-channel coherence (0…1) of content from 10 kHz up to the
    /// detected cutoff. ≈1 on a stereo file suggests intensity stereo or
    /// other HF mono-ification (early-encoder tell). 1.0 for mono files.
    let hfStereoCoherence: Double

    /// Placeholder for when the lossy-artifact module is switched off.
    static let unavailable = LossyArtifactMetrics(
        preEchoScore: 0, attackCount: 0, highBandFlickerScore: 0, hfStereoCoherence: 1
    )
}

/// Facts read directly from an MPEG audio bitstream (no decoding) — the
/// most direct provenance evidence available while a file is still an MP3.
struct MP3StreamInfo {
    enum BitrateMode {
        case cbr, vbr
    }

    /// Encoder string from the LAME tag (e.g. "LAME3.100"), when present.
    let encoderInfo: String?
    /// Xing (VBR) or Info (CBR) header presence — absent on many early
    /// encoders (Xing-the-encoder aside) and stream rips.
    let hasXingOrInfoHeader: Bool
    /// Full LAME extension tag presence (implies a LAME-family encoder).
    let hasLameTag: Bool
    let bitrateMode: BitrateMode
    let meanBitrateKbps: Double
    /// Lowpass frequency declared in the LAME tag, Hz, when present.
    let declaredLowpassHz: Double?
    /// True if any frame uses the intensity-stereo mode extension.
    let usesIntensityStereo: Bool
    /// Fraction of frames using joint stereo (M/S or intensity).
    let jointStereoFrameFraction: Double
    let frameCount: Int
}

/// A headline finding about where the audio came from / how it was treated,
/// with the measurements that justify it. These are the feature's real
/// output; verdicts and raw metrics are the supporting material.
struct SourceConclusion: Identifiable {
    enum Kind {
        /// Lossless container, lossy-encoded signal.
        case fakeLossless
        /// Clicks/rumble/decorrelated hiss ⇒ vinyl rip.
        case vinylSourced
        /// Stationary decorrelated hiss without vinyl artifacts ⇒ tape or
        /// other analog chain.
        case analogTapeSourced
        /// Lossy encode showing early/badly-configured-encoder artifacts
        /// (pre-echo, flicker, intensity stereo, cutoff far below what the
        /// bitrate should deliver).
        case poorLossyEncode
        /// Lossy, but transparent for its class — nothing alarming.
        case cleanLossyEncode
        /// Lossless with no signs of lossy ancestry or analog noise.
        case cleanLossless
    }

    enum Confidence: Comparable {
        case low, medium, high
    }

    let id = UUID()
    let kind: Kind
    /// One-sentence plain-language statement, e.g. "This FLAC appears to be
    /// a re-encode of a ~128 kbps MP3."
    let statement: String
    let confidence: Confidence
    /// Measurement-backed justification lines, most convincing first.
    let evidence: [String]
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

    /// Placeholder for when the loudness module is switched off.
    static let unavailable = LoudnessMetrics(
        integratedLUFS: nil, samplePeakDBFS: -.infinity, crestFactorDB: 0, clippedSampleRunCount: 0
    )
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

    /// Placeholder for when the tonal-balance module is switched off.
    static let unavailable = TonalBalanceMetrics(bands: [], spectralCentroidHz: 0, rolloff95Hz: 0)
}

/// Noise floor measured from the quietest stretches of the file.
struct NoiseFloorMetrics {
    /// Broadband level of the quietest frames, dBFS. Digital silence reads
    /// as -Double.infinity or extremely low; analog sources sit much higher.
    let noiseFloorDBFS: Double
    /// Spectral flatness (0…1) of the quiet frames. Broadband hiss is flat;
    /// tonal residue (hum, bleed) is not.
    let quietFrameSpectralFlatness: Double

    /// Placeholder for when the noise-floor module is switched off.
    static let unavailable = NoiseFloorMetrics(noiseFloorDBFS: -.infinity, quietFrameSpectralFlatness: 0)
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

    /// Placeholder for when the tonal-balance module (which measures
    /// bandwidth) is switched off. Carries the Nyquist so the UI can still
    /// label an axis, but reports no cutoff and low confidence.
    static func unavailable(sampleRate: Double) -> BandwidthMetrics {
        BandwidthMetrics(nyquistHz: sampleRate / 2, detectedCutoffHz: nil, shelfDepthDB: nil, confidence: .low)
    }
}

/// Welch-averaged power spectrum for the UI line plot and cutoff marker.
struct AverageSpectrum {
    /// Center frequency of bin `i` is `Double(i) * binWidthHz`.
    let binWidthHz: Double
    let magnitudesDB: [Float]

    /// Placeholder (empty) for when the tonal-balance module is switched off.
    static func unavailable(sampleRate: Double) -> AverageSpectrum {
        AverageSpectrum(binWidthHz: sampleRate / 8_192, magnitudesDB: [])
    }
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
