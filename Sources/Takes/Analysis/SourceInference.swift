import Foundation

/// Combines every measurement into the headline conclusions — "this FLAC is
/// actually a re-encode", "this appears to be a vinyl rip" — with evidence
/// strings drawn from the numbers that triggered them. This is the
/// feature's real output; verdicts and raw metrics are supporting material.
///
/// At most one conclusion is emitted per domain (lossless authenticity,
/// analog source, lossy-encode quality) so the headline stays readable.
/// All thresholds are named constants for corpus-benchmark tuning.
enum SourceInference {
    // MARK: Thresholds

    /// Cutoff below this fraction of Nyquist (with a real shelf) on a
    /// lossless container implies lossy ancestry. Matches the verdicts.
    private static let transcodeCutoffFractionOfNyquist = 0.91

    /// Analog noise-floor window: audible-but-plausible hiss levels.
    private static let hissFloorRangeDBFS = -80.0 ... -28.0
    /// Clean digital music measures ≈ 0.17 on the corpus; hiss beds under
    /// gapless real music measure 0.31+ (correlated) / 0.42 (decorrelated).
    private static let hissFlatnessMinimum = 0.28
    /// Below this inter-channel coherence, floor noise reads as
    /// decorrelated — an analog-chain signature.
    private static let decorrelatedNoiseCoherenceMaximum = 0.5

    /// Clean real music still yields ~20 sharp-spike detections/minute
    /// (residual percussive edges); genuine surface noise measures in the
    /// hundreds. Sit well above the false-positive floor.
    private static let vinylClickRateMinimum = 60.0
    private static let clickSalienceMinimumDB = 8.0
    /// Side-channel rumble above this (relative dB) supports vinyl. Real
    /// music with ordinary stereo bass measures ≈ −32 on the corpus, so
    /// only rumble that punches well above musical LF side content counts.
    private static let rumbleSideLevelMinimumDB = -25.0
    private static let wowCentsMinimum = 12.0

    /// Pre-echo: mean rise before attacks (dB) that marks a bad encode, and
    /// the attack count needed to trust the score at all.
    /// With the audibility floor in the DSP, corpus measurements: clean
    /// transients 0.0, LAME 320 → 1.4, LAME 128 → 6.6. Split the gap.
    private static let preEchoScoreMinimumDB = 4.0
    private static let preEchoAttackCountMinimum = 5
    private static let flickerScoreMinimum = 4.0
    /// HF coherence above this on a stereo file suggests intensity stereo /
    /// fully mono-ified highs. Ordinary M/S joint stereo with a starved
    /// side channel measures ≈ 0.93 at 192 kbps on the corpus — legitimate
    /// coding, not an early-encoder tell — while true HF mono reads 1.00.
    private static let intensityStereoCoherenceMinimum = 0.97

    /// Expected minimum bandwidth a competent modern encoder delivers at a
    /// given bitrate (kbps → Hz), used for the "early encoder" mismatch
    /// tell. Values sit ~1.5 kHz below modern LAME/AAC behavior so only
    /// clear underperformance triggers.
    private static let expectedCutoffByBitrate: [(minKbps: Double, minCutoffHz: Double)] = [
        (256, 18_500),
        (192, 17_500),
        (160, 16_500),
        (128, 15_000),
    ]

    static func conclusions(
        fileInfo: AnalyzedFileInfo,
        loudness: LoudnessMetrics,
        noiseFloor: NoiseFloorMetrics,
        bandwidth: BandwidthMetrics,
        analogSource: AnalogSourceMetrics,
        lossyArtifacts: LossyArtifactMetrics,
        mp3Stream: MP3StreamInfo?
    ) -> [SourceConclusion] {
        var conclusions: [SourceConclusion] = []

        if let authenticity = authenticityConclusion(
            fileInfo: fileInfo, bandwidth: bandwidth, lossyArtifacts: lossyArtifacts
        ) {
            conclusions.append(authenticity)
        }
        if let analog = analogSourceConclusion(
            fileInfo: fileInfo, noiseFloor: noiseFloor, analogSource: analogSource
        ) {
            conclusions.append(analog)
        }
        if let encodeQuality = encodeQualityConclusion(
            fileInfo: fileInfo, bandwidth: bandwidth,
            lossyArtifacts: lossyArtifacts, mp3Stream: mp3Stream
        ) {
            conclusions.append(encodeQuality)
        }

        return conclusions
    }

    // MARK: Lossless authenticity

    private static func authenticityConclusion(
        fileInfo: AnalyzedFileInfo,
        bandwidth: BandwidthMetrics,
        lossyArtifacts: LossyArtifactMetrics
    ) -> SourceConclusion? {
        guard fileInfo.isLosslessCodec else { return nil }

        let suspicious = bandwidth.detectedCutoffHz.map {
            $0 < bandwidth.nyquistHz * transcodeCutoffFractionOfNyquist && bandwidth.confidence != .low
        } ?? false

        guard suspicious, let cutoff = bandwidth.detectedCutoffHz else {
            return SourceConclusion(
                kind: .cleanLossless,
                statement: "This \(fileInfo.codecDescription) file shows no signs of lossy ancestry.",
                confidence: bandwidth.detectedCutoffHz == nil ? .high : .medium,
                evidence: [
                    String(
                        format: "Spectral content extends to %@ with no codec-style cutoff shelf.",
                        bandwidth.detectedCutoffHz.map { String(format: "%.1f kHz", $0 / 1_000) }
                            ?? String(format: "the full %.1f kHz bandwidth", bandwidth.nyquistHz / 1_000)
                    ),
                ]
            )
        }

        var evidence = [
            String(
                format: "Spectrum stops hard at %.1f kHz even though the container allows %.1f kHz.",
                cutoff / 1_000, bandwidth.nyquistHz / 1_000
            ),
        ]
        if let depth = bandwidth.shelfDepthDB {
            evidence.append(String(
                format: "The shelf above the cutoff is ~%.0f dB deep — a codec lowpass, not a gentle master rolloff.",
                depth
            ))
        }
        if lossyArtifacts.attackCount >= preEchoAttackCountMinimum,
           lossyArtifacts.preEchoScore >= preEchoScoreMinimumDB {
            evidence.append(String(
                format: "Pre-echo before transients (%.1f dB over %d attacks) — quantization noise smearing, a lossy-codec artifact.",
                lossyArtifacts.preEchoScore, lossyArtifacts.attackCount
            ))
        }

        return SourceConclusion(
            kind: .fakeLossless,
            statement: String(
                format: "This %@ file appears to be a re-encode of %@ — not a true lossless source.",
                fileInfo.codecDescription, lossySourceClass(forCutoff: cutoff)
            ),
            confidence: bandwidth.confidence == .high ? .high : .medium,
            evidence: evidence
        )
    }

    static func lossySourceClass(forCutoff cutoff: Double) -> String {
        switch cutoff {
        case ..<15_500: return "a low-bitrate lossy source"
        case ..<17_000: return "a ~128 kbps MP3-class source"
        case ..<19_500: return "a ~128–192 kbps lossy source"
        default: return "a ~320 kbps MP3 / high-bitrate lossy source"
        }
    }

    // MARK: Analog source

    private static func analogSourceConclusion(
        fileInfo: AnalyzedFileInfo,
        noiseFloor: NoiseFloorMetrics,
        analogSource: AnalogSourceMetrics
    ) -> SourceConclusion? {
        let floor = analogSource.stationaryNoiseFloorDBFS
        let stationaryHiss = hissFloorRangeDBFS.contains(floor)
            && analogSource.noiseFloorFlatness >= hissFlatnessMinimum
        // Quiet-gap analysis (v1) corroborates when the material has gaps.
        let gapHiss = noiseFloor.quietFrameSpectralFlatness > 0.2
            && hissFloorRangeDBFS.contains(noiseFloor.noiseFloorDBFS)
        let decorrelated = fileInfo.channelCount >= 2
            && analogSource.highBandNoiseCoherence < decorrelatedNoiseCoherenceMaximum

        let clicks = analogSource.clickRatePerMinute >= vinylClickRateMinimum
            && analogSource.meanClickSalienceDB >= clickSalienceMinimumDB
        let rumble = analogSource.rumbleSideLevelDB >= rumbleSideLevelMinimumDB
        let wow = (analogSource.wowPeakCents ?? 0) >= wowCentsMinimum

        var evidence: [String] = []
        if clicks {
            evidence.append(String(
                format: "%.0f click/pop events per minute (mean %.0f dB above the surrounding signal) — surface noise.",
                analogSource.clickRatePerMinute, analogSource.meanClickSalienceDB
            ))
        }
        if stationaryHiss {
            evidence.append(String(
                format: "A constant broadband noise floor at %.0f dBFS persists under the music (minimum-statistics estimate).",
                floor
            ))
        } else if gapHiss {
            evidence.append(String(
                format: "Broadband hiss at %.0f dBFS in the quiet passages.",
                noiseFloor.noiseFloorDBFS
            ))
        }
        if decorrelated, stationaryHiss || gapHiss {
            evidence.append(String(
                format: "The noise is uncorrelated between channels (coherence %.2f) — characteristic of an analog chain, not added digital noise.",
                analogSource.highBandNoiseCoherence
            ))
        }
        if rumble {
            evidence.append(String(
                format: "Sub-30 Hz rumble concentrated in the stereo difference channel (%.0f dB) — vertical stylus motion.",
                analogSource.rumbleSideLevelDB
            ))
        }
        if wow, let cents = analogSource.wowPeakCents {
            evidence.append(String(format: "Slow pitch wow of ±%.0f cents.", cents))
        }

        // Vinyl needs surface noise plus at least one corroborating signal;
        // tape/analog needs stationary hiss and no vinyl artifacts.
        if clicks, stationaryHiss || gapHiss || rumble {
            let strongSignals = [stationaryHiss || gapHiss, rumble, decorrelated, wow].filter { $0 }.count
            return SourceConclusion(
                kind: .vinylSourced,
                statement: "This \(fileInfo.codecDescription) file appears to be sourced from a vinyl rip.",
                confidence: strongSignals >= 2 ? .high : .medium,
                evidence: evidence
            )
        }

        if stationaryHiss || gapHiss {
            let confidence: SourceConclusion.Confidence = decorrelated
                ? (stationaryHiss ? .high : .medium)
                : .low
            return SourceConclusion(
                kind: .analogTapeSourced,
                statement: decorrelated
                    ? "This \(fileInfo.codecDescription) file appears to be sourced from tape or another analog chain."
                    : "This \(fileInfo.codecDescription) file carries constant background hiss (analog source or noisy processing).",
                confidence: confidence,
                evidence: evidence
            )
        }

        return nil
    }

    // MARK: Lossy encode quality

    private static func encodeQualityConclusion(
        fileInfo: AnalyzedFileInfo,
        bandwidth: BandwidthMetrics,
        lossyArtifacts: LossyArtifactMetrics,
        mp3Stream: MP3StreamInfo?
    ) -> SourceConclusion? {
        guard !fileInfo.isLosslessCodec else { return nil }

        let bitrate = mp3Stream?.meanBitrateKbps ?? fileInfo.dataRateKbps
        var evidence: [String] = []
        var signals = 0

        // Bandwidth far below what this bitrate should deliver.
        if let cutoff = bandwidth.detectedCutoffHz,
           let expected = expectedCutoffByBitrate.first(where: { bitrate >= $0.minKbps }),
           cutoff < expected.minCutoffHz {
            signals += 1
            evidence.append(String(
                format: "Bandwidth stops at %.1f kHz, but any modern encoder at %.0f kbps keeps ≥ %.1f kHz — typical of early encoders.",
                cutoff / 1_000, bitrate, expected.minCutoffHz / 1_000
            ))
        }

        if lossyArtifacts.attackCount >= preEchoAttackCountMinimum,
           lossyArtifacts.preEchoScore >= preEchoScoreMinimumDB {
            signals += 1
            evidence.append(String(
                format: "Pre-echo: noise smears %.1f dB above the floor in the 20 ms before attacks (%d measured) — missing short-block switching.",
                lossyArtifacts.preEchoScore, lossyArtifacts.attackCount
            ))
        }

        if lossyArtifacts.highBandFlickerScore >= flickerScoreMinimum {
            signals += 1
            evidence.append(String(
                format: "High-frequency bands flicker on/off at the codec frame rate (score %.1f) — \"birdie\" artifacts from starved bit allocation.",
                lossyArtifacts.highBandFlickerScore
            ))
        }

        if fileInfo.channelCount >= 2,
           lossyArtifacts.hfStereoCoherence >= intensityStereoCoherenceMinimum {
            signals += 1
            var line = String(
                format: "Content above 10 kHz is effectively mono (coherence %.2f) — intensity-stereo coding.",
                lossyArtifacts.hfStereoCoherence
            )
            if mp3Stream?.usesIntensityStereo == true {
                line += " The bitstream confirms intensity-stereo frames."
            }
            evidence.append(line)
        }

        // Bitstream provenance is supporting evidence, not a signal itself.
        if let stream = mp3Stream {
            if let encoder = stream.encoderInfo {
                evidence.append("Encoder: \(encoder) (from the bitstream tag).")
            } else if !stream.hasXingOrInfoHeader, bitrate >= 160 {
                evidence.append("No Xing/LAME header in the bitstream — common for early encoders and stream rips.")
            }
        }

        if signals > 0 {
            return SourceConclusion(
                kind: .poorLossyEncode,
                statement: String(
                    format: "This %@ encode (~%.0f kbps) shows quality problems beyond its bitrate class%@.",
                    fileInfo.codecDescription, bitrate,
                    signals >= 2 ? " — likely an early or badly configured encoder" : ""
                ),
                confidence: signals >= 2 ? .high : .medium,
                evidence: evidence
            )
        }

        var cleanEvidence = [
            String(
                format: "Bandwidth %@ is appropriate for %@ at ~%.0f kbps.",
                bandwidth.detectedCutoffHz.map { String(format: "%.1f kHz", $0 / 1_000) } ?? "to Nyquist",
                fileInfo.codecDescription, bitrate
            ),
        ]
        if lossyArtifacts.attackCount >= preEchoAttackCountMinimum {
            cleanEvidence.append(String(
                format: "No significant pre-echo (%.1f dB over %d attacks).",
                lossyArtifacts.preEchoScore, lossyArtifacts.attackCount
            ))
        }
        if let encoder = mp3Stream?.encoderInfo {
            cleanEvidence.append("Encoder: \(encoder).")
        }

        return SourceConclusion(
            kind: .cleanLossyEncode,
            statement: "This \(fileInfo.codecDescription) encode looks clean for its bitrate class.",
            confidence: .medium,
            evidence: cleanEvidence
        )
    }
}
