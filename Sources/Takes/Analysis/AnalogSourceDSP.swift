import Accelerate
import Foundation

/// Detects analog-source signatures (tape/vinyl) that survive gapless
/// music, where quiet-gap analysis (`QuietFrameCollector`) has nothing to
/// work with. Fed sequential deinterleaved chunks by the engine like every
/// other accumulator; produces `AnalogSourceMetrics` in `finalize()`.
///
/// Detectors (see docs/experimental-audio-analysis.md, v2 design notes):
/// - Minimum-statistics stationary noise floor (Martin-style): per-band
///   energy minima over a sliding multi-second window.
/// - Inter-channel coherence of the estimated noise floor above 8 kHz
///   (analog noise is decorrelated; digital quiet is not).
/// - Click/crackle detection: impulsive wideband outliers, reported as a
///   rate per minute plus mean salience.
/// - Rumble: sub-30 Hz energy in the stereo difference channel.
/// - Wow (stretch): 0.3–6 Hz pitch modulation of sustained tonal content.
final class AnalogSourceAnalyzer {
    private let sampleRate: Double
    private let channelCount: Int

    init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    /// `channels` holds one array per channel (1 = mono, 2 = stereo; more
    /// are reduced to the first two by the engine), equal lengths, arriving
    /// in file order across calls.
    func process(channels: [[Float]]) {
        // TODO(M3a): implemented by the analog-source DSP milestone.
        _ = channels
    }

    func finalize() -> AnalogSourceMetrics {
        // TODO(M3a): placeholder neutral values until implemented.
        AnalogSourceMetrics(
            stationaryNoiseFloorDBFS: -.infinity,
            noiseFloorFlatness: 0,
            highBandNoiseCoherence: 1,
            clickRatePerMinute: 0,
            meanClickSalienceDB: 0,
            rumbleSideLevelDB: -.infinity,
            wowPeakCents: nil
        )
    }
}
