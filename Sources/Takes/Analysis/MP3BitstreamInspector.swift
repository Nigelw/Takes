import Foundation

/// Reads provenance facts straight out of an MPEG audio bitstream without
/// decoding it: Xing/Info and LAME headers (encoder version, declared
/// lowpass), CBR/VBR, per-frame stereo modes. The most direct evidence
/// available while a file is still an MP3 — a missing LAME tag on a
/// high-bitrate file, or intensity-stereo frames, point at early encoders.
enum MP3BitstreamInspector {
    /// Returns `nil` when the file is not an MPEG audio stream (this is not
    /// an error — most inputs are other formats). Throws only on I/O
    /// failure. `.mp3` data inside other containers is out of scope.
    static func inspect(fileAt url: URL) throws -> MP3StreamInfo? {
        // TODO(M3b): implemented by the lossy-artifact DSP milestone.
        _ = url
        return nil
    }
}
