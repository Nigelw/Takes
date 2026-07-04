import Foundation

/// Combines every measurement into the headline conclusions — "this FLAC is
/// actually a re-encode", "this appears to be a vinyl rip" — with evidence
/// strings drawn from the numbers that triggered them. This is the
/// feature's real output; verdicts and raw metrics are supporting material.
enum SourceInference {
    static func conclusions(
        fileInfo: AnalyzedFileInfo,
        loudness: LoudnessMetrics,
        noiseFloor: NoiseFloorMetrics,
        bandwidth: BandwidthMetrics,
        analogSource: AnalogSourceMetrics,
        lossyArtifacts: LossyArtifactMetrics,
        mp3Stream: MP3StreamInfo?
    ) -> [SourceConclusion] {
        // TODO(M4): inference rules land with engine integration.
        []
    }
}
