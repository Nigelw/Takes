import Foundation

/// Turns raw metrics into the human-readable findings shown in the Analysis
/// window. All thresholds live here (as named constants) so benchmark runs
/// against the corpus can tune them without touching measurement code.
enum AnalysisVerdictBuilder {
    // MARK: Thresholds (tuned against `docs/analysis-corpus.md` ground truth)

    /// LUFS above this reads as a hot/slammed master, below the quiet bound
    /// as a notably quiet one (streaming platforms normalize near -14).
    private static let hotMasterLUFS = -8.0
    private static let quietMasterLUFS = -20.0

    /// Peak-to-RMS in dB: below the squashed bound suggests heavy limiting.
    private static let squashedCrestDB = 9.0
    private static let dynamicCrestDB = 14.0

    /// Bass-minus-treble band tilt in dB beyond which balance is notable.
    /// Real-world masters sit around +15…+25, so only extremes are called
    /// out; subtler tilts need the (future) comparative mode to judge.
    private static let bassHeavyTiltDB = 30.0
    private static let brightTiltDB = 0.0

    /// Clarity heuristics from the long-term spectrum. The Air band
    /// (10–22 kHz) relative level separates "mellow but fine" (≈ −30 dB on
    /// real music) from genuinely lowpassed/muffled (−45 dB and below);
    /// energy rolloff can't, because bass dominates total energy.
    private static let muffledAirRelativeDB = -38.0
    private static let muffledCutoffHz = 6_000.0
    private static let brightCentroidHz = 3_500.0

    /// Quiet-frame floor and flatness that indicate broadband hiss.
    private static let hissFlatnessMinimum = 0.2
    private static let hissFloorRangeDBFS = -78.0 ... -30.0
    private static let audibleFloorDBFS = -60.0
    private static let pristineFloorDBFS = -90.0

    /// A lossless file whose bandwidth stops below this fraction of Nyquist
    /// (with a sharp shelf) is suspected of lossy ancestry.
    private static let transcodeCutoffFractionOfNyquist = 0.91

    private static let lowBitrateMP3Kbps = 160.0
    private static let lowBitrateAACKbps = 128.0

    static func verdicts(
        modules: AnalysisSelection = .all,
        fileInfo: AnalyzedFileInfo,
        loudness: LoudnessMetrics,
        tonalBalance: TonalBalanceMetrics,
        noiseFloor: NoiseFloorMetrics,
        bandwidth: BandwidthMetrics
    ) -> [AnalysisVerdict] {
        // Each verdict group is gated on the module that measured it, so a
        // skipped analysis never asserts a (neutral-placeholder) negative.
        // The encoding/authenticity verdicts read bandwidth, which the
        // tonal-balance module produces.
        var verdicts: [AnalysisVerdict] = []
        if modules.contains(.loudness) {
            verdicts.append(contentsOf: loudnessVerdicts(loudness))
        }
        if modules.contains(.tonalBalance) {
            verdicts.append(contentsOf: tonalBalanceVerdicts(tonalBalance, bandwidth: bandwidth))
        }
        if modules.contains(.noiseFloor) {
            verdicts.append(contentsOf: noiseVerdicts(noiseFloor))
        }
        if modules.contains(.tonalBalance) {
            verdicts.append(contentsOf: encodingVerdicts(fileInfo: fileInfo, bandwidth: bandwidth))
            verdicts.append(contentsOf: authenticityVerdicts(fileInfo: fileInfo, bandwidth: bandwidth))
        }
        return verdicts
    }

    // MARK: Loudness

    private static func loudnessVerdicts(_ loudness: LoudnessMetrics) -> [AnalysisVerdict] {
        var verdicts: [AnalysisVerdict] = []

        if let lufs = loudness.integratedLUFS {
            let tone: AnalysisVerdict.Tone
            let title: String
            if lufs > hotMasterLUFS {
                tone = .caution
                title = "Very loud master"
            } else if lufs < quietMasterLUFS {
                tone = .caution
                title = "Quiet master"
            } else {
                tone = .info
                title = "Typical loudness"
            }
            verdicts.append(AnalysisVerdict(
                category: .loudness,
                title: title,
                detail: String(
                    format: "Integrated %.1f LUFS, sample peak %.1f dBFS. Streaming services normalize near −14 LUFS.",
                    lufs, loudness.samplePeakDBFS
                ),
                tone: tone
            ))
        } else {
            verdicts.append(AnalysisVerdict(
                category: .loudness,
                title: "Essentially silent",
                detail: "The whole file fell below the −70 LUFS gate.",
                tone: .caution
            ))
        }

        if loudness.crestFactorDB.isFinite {
            if loudness.crestFactorDB < squashedCrestDB {
                verdicts.append(AnalysisVerdict(
                    category: .loudness,
                    title: "Heavily limited dynamics",
                    detail: String(
                        format: "Crest factor %.1f dB (peak vs. average). Suggests strong compression/limiting.",
                        loudness.crestFactorDB
                    ),
                    tone: .caution
                ))
            } else if loudness.crestFactorDB > dynamicCrestDB {
                verdicts.append(AnalysisVerdict(
                    category: .loudness,
                    title: "Dynamic master",
                    detail: String(format: "Crest factor %.1f dB — plenty of headroom between peaks and average level.", loudness.crestFactorDB),
                    tone: .good
                ))
            }
        }

        if loudness.clippedSampleRunCount > 0 {
            verdicts.append(AnalysisVerdict(
                category: .loudness,
                title: loudness.clippedSampleRunCount > 10 ? "Clipping detected" : "Possible clipping",
                detail: "\(loudness.clippedSampleRunCount) run(s) of consecutive full-scale samples.",
                tone: loudness.clippedSampleRunCount > 10 ? .warning : .caution
            ))
        }

        return verdicts
    }

    // MARK: Tonal balance & clarity

    private static func tonalBalanceVerdicts(
        _ tonalBalance: TonalBalanceMetrics,
        bandwidth: BandwidthMetrics
    ) -> [AnalysisVerdict] {
        var verdicts: [AnalysisVerdict] = []

        let bass = bandLevel(tonalBalance, names: ["Sub", "Bass"])
        let treble = bandLevel(tonalBalance, names: ["Treble", "Air"])
        if let bass, let treble {
            let tilt = bass - treble
            if tilt > bassHeavyTiltDB {
                verdicts.append(AnalysisVerdict(
                    category: .tonalBalance,
                    title: "Bass-heavy balance",
                    detail: String(format: "Low end sits %.0f dB above the top end in the long-term spectrum.", tilt),
                    tone: .info
                ))
            } else if tilt < brightTiltDB {
                verdicts.append(AnalysisVerdict(
                    category: .tonalBalance,
                    title: "Bright balance",
                    detail: String(format: "Top end is unusually strong relative to the low end (tilt %.0f dB).", tilt),
                    tone: .info
                ))
            }
        }

        // Centroid and rolloff are poor muffledness tests — bass dominates
        // total energy, so mellow real-world music scores "low" on both.
        // A collapsed Air band (or an outright lowpass) is what actually
        // reads as muffled.
        let airLevel = bandLevel(tonalBalance, names: ["Air"])
        let severelyBandLimited = (bandwidth.detectedCutoffHz ?? .infinity) < muffledCutoffHz
        if severelyBandLimited || (airLevel ?? 0) < muffledAirRelativeDB {
            verdicts.append(AnalysisVerdict(
                category: .clarity,
                title: "Sounds dull / muffled",
                detail: String(
                    format: "Almost no energy above 10 kHz (%.0f dB below overall). Spectral centroid %.0f Hz.",
                    airLevel ?? 0, tonalBalance.spectralCentroidHz
                ),
                tone: .caution
            ))
        } else if tonalBalance.spectralCentroidHz > brightCentroidHz {
            verdicts.append(AnalysisVerdict(
                category: .clarity,
                title: "Very bright / crisp",
                detail: String(format: "Spectral centroid %.0f Hz is unusually high.", tonalBalance.spectralCentroidHz),
                tone: .info
            ))
        }

        return verdicts
    }

    private static func bandLevel(_ tonalBalance: TonalBalanceMetrics, names: [String]) -> Double? {
        let levels = tonalBalance.bands.filter { names.contains($0.name) }.map(\.relativeDB)
        guard !levels.isEmpty else { return nil }
        // Sum band powers in the linear domain before returning to dB.
        let power = levels.map { pow(10, $0 / 10) }.reduce(0, +)
        return 10 * log10(power)
    }

    // MARK: Noise

    private static func noiseVerdicts(_ noiseFloor: NoiseFloorMetrics) -> [AnalysisVerdict] {
        var verdicts: [AnalysisVerdict] = []

        let isHiss = noiseFloor.quietFrameSpectralFlatness > hissFlatnessMinimum
            && hissFloorRangeDBFS.contains(noiseFloor.noiseFloorDBFS)

        if isHiss {
            verdicts.append(AnalysisVerdict(
                category: .noise,
                title: "Background hiss",
                detail: String(
                    format: "Broadband noise at %.0f dBFS in the quiet passages — typical of a vinyl, tape, or other analog source.",
                    noiseFloor.noiseFloorDBFS
                ),
                tone: noiseFloor.noiseFloorDBFS > audibleFloorDBFS ? .warning : .caution
            ))
        } else if noiseFloor.noiseFloorDBFS < pristineFloorDBFS {
            verdicts.append(AnalysisVerdict(
                category: .noise,
                title: "Very low noise floor",
                detail: String(format: "Quietest passages sit at %.0f dBFS.", max(noiseFloor.noiseFloorDBFS, -160)),
                tone: .good
            ))
        }

        return verdicts
    }

    // MARK: Encoding quality

    private static func encodingVerdicts(
        fileInfo: AnalyzedFileInfo,
        bandwidth: BandwidthMetrics
    ) -> [AnalysisVerdict] {
        var verdicts: [AnalysisVerdict] = []

        if !fileInfo.isLosslessCodec {
            let isMP3 = fileInfo.codecDescription == "MP3"
            let lowRate = isMP3 ? lowBitrateMP3Kbps : lowBitrateAACKbps
            if fileInfo.dataRateKbps > 0, fileInfo.dataRateKbps < lowRate {
                verdicts.append(AnalysisVerdict(
                    category: .encoding,
                    title: "Low-bitrate lossy encode",
                    detail: String(
                        format: "%@ at ~%.0f kbps. Expect audible artifacts and a reduced bandwidth (measured %@).",
                        fileInfo.codecDescription, fileInfo.dataRateKbps, cutoffDescription(bandwidth)
                    ),
                    tone: .warning
                ))
            } else {
                verdicts.append(AnalysisVerdict(
                    category: .encoding,
                    title: "Lossy encode",
                    detail: String(
                        format: "%@ at ~%.0f kbps, bandwidth %@.",
                        fileInfo.codecDescription, fileInfo.dataRateKbps, cutoffDescription(bandwidth)
                    ),
                    tone: .info
                ))
            }
        }

        return verdicts
    }

    // MARK: Authenticity (fake lossless)

    private static func authenticityVerdicts(
        fileInfo: AnalyzedFileInfo,
        bandwidth: BandwidthMetrics
    ) -> [AnalysisVerdict] {
        guard fileInfo.isLosslessCodec else { return [] }

        guard let cutoff = bandwidth.detectedCutoffHz,
              cutoff < bandwidth.nyquistHz * transcodeCutoffFractionOfNyquist,
              bandwidth.confidence != .low
        else {
            return [AnalysisVerdict(
                category: .authenticity,
                title: "Looks genuinely lossless",
                detail: "Content extends to \(cutoffDescription(bandwidth)) with no codec-style cutoff shelf.",
                tone: .good
            )]
        }

        let sourceGuess: String
        switch cutoff {
        case ..<15_500: sourceGuess = "a low-bitrate lossy source"
        case ..<17_000: sourceGuess = "a ~128 kbps MP3-class source"
        case ..<19_500: sourceGuess = "a ~192 kbps lossy source"
        default: sourceGuess = "a ~320 kbps MP3 / high-bitrate lossy source"
        }

        return [AnalysisVerdict(
            category: .authenticity,
            title: bandwidth.confidence == .high ? "Likely lossy transcode" : "Possible lossy transcode",
            detail: String(
                format: "Lossless container, but the spectrum stops hard at %.1f kHz (shelf ~%.0f dB deep) — consistent with %@.",
                cutoff / 1_000, bandwidth.shelfDepthDB ?? 0, sourceGuess
            ),
            tone: bandwidth.confidence == .high ? .warning : .caution
        )]
    }

    private static func cutoffDescription(_ bandwidth: BandwidthMetrics) -> String {
        if let cutoff = bandwidth.detectedCutoffHz {
            return String(format: "%.1f kHz", cutoff / 1_000)
        }
        return String(format: "full bandwidth (%.1f kHz)", bandwidth.nyquistHz / 1_000)
    }
}
