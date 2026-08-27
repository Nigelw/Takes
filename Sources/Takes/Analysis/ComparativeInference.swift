import Foundation

/// Turns two single-file reports plus their residual into directional findings,
/// then into a ranking — or into an explicit refusal to rank.
///
/// The design rule this file exists to enforce: fidelity and taste never mix.
/// A finding on a taste dimension (loudness, dynamics, tonal balance) is
/// recorded and shown, and is not allowed to influence the ranking. See
/// docs/comparative-quality-analysis.md.
enum ComparativeInference {
    // MARK: Audibility bars

    /// How large a difference has to be before it counts as a finding rather
    /// than a tie. Below these, the two files are the same as far as we are
    /// willing to claim.
    enum Bars {
        /// Retained bandwidth, Hz. Below this, two cutoffs are the same cutoff.
        /// Only used to phrase a finding, never to decide one — see
        /// `bandwidthFinding`.
        static let bandwidthHz = 700.0
        /// High-band level difference, dB, before one file counts as keeping
        /// more bandwidth than the other.
        static let highBandDB = 6.0
        /// Above this the difference is large enough to call high confidence,
        /// provided the sub-bands agree on direction.
        static let decisiveHighBandDB = 12.0
        /// Pre-echo score difference, dB.
        static let preEchoDB = 2.0
        /// Minimum qualifying attacks before a pre-echo score means anything.
        static let preEchoAttacks = 5
        /// HF flicker score difference.
        static let flicker = 2.0
        /// Noise-floor difference, dB.
        static let noiseFloorDB = 4.0
        /// Click-rate difference, clicks per minute.
        static let clickRate = 40.0
        /// Rumble difference, dB.
        static let rumbleDB = 6.0
        /// How many times more clipped runs one file needs before the
        /// difference counts. Decoding a lossy file produces its own
        /// intersample overshoot, so two encodes of one master routinely differ
        /// by 15–30% in clipped-run count with no fidelity difference at all.
        /// Only a gross disparity means anything.
        static let clippedRunRatio = 4.0
        /// Absolute floor for the higher count, so a handful of runs on a quiet
        /// track cannot trip the ratio test.
        static let clippedRunFloor = 50
        /// Crest-factor difference, dB.
        static let crestDB = 1.5
        /// Band-level difference, dB.
        static let tonalDB = 1.0
        /// Integrated-loudness difference, LU.
        static let loudnessLU = 1.0
    }

    // MARK: - Findings

    /// Every measurable difference between the pair, fidelity-bearing first,
    /// largest first within each group.
    static func findings(
        a: AudioAnalysisReport,
        b: AudioAnalysisReport,
        residual: ResidualMetrics
    ) -> [QualityFinding] {
        var results: [QualityFinding] = []
        let modules = a.analyzedModules.intersection(b.analyzedModules)

        if modules.contains(.tonalBalance) {
            results.append(bandwidthFinding(a: a, b: b))
            results.append(contentsOf: tonalBalanceFinding(a: a, b: b))
        }
        results.append(contentsOf: provenanceFinding(a: a, b: b))
        if modules.contains(.lossyArtifacts) {
            results.append(contentsOf: codecArtifactFindings(a: a, b: b))
        }
        if modules.contains(.analogSource) {
            results.append(contentsOf: addedNoiseFindings(a: a, b: b))
        }
        if modules.contains(.loudness) {
            results.append(contentsOf: loudnessFindings(a: a, b: b))
        }

        return results.sorted { lhs, rhs in
            if lhs.dimension.isFidelityBearing != rhs.dimension.isFidelityBearing {
                return lhs.dimension.isFidelityBearing
            }
            if (lhs.direction == .tie) != (rhs.direction == .tie) {
                return rhs.direction == .tie
            }
            return lhs.magnitude > rhs.magnitude
        }
    }

    // MARK: Bandwidth

    /// Sub-band edges for the high-frequency comparison, Hz. Deliberately
    /// finer than `SpectrumMetrics.bandDefinitions`, whose single Air band
    /// (10–22 kHz) is dominated by the 10–16 kHz region where two encodes of
    /// one master usually agree — burying the difference that matters.
    static let highBandEdges: [Double] = [12_000, 14_000, 16_000, 18_000, 20_000, 22_050]

    /// Mean power across `range` relative to the file's own 1–8 kHz median, in
    /// dB. Self-referenced, so two files mastered at different levels compare
    /// directly, and per-bin, so bands of different widths compare too.
    static func relativeLevelDB(_ spectrum: AverageSpectrum, range: ClosedRange<Double>) -> Double? {
        guard spectrum.binWidthHz > 0, !spectrum.magnitudesDB.isEmpty else { return nil }
        let bins = spectrum.magnitudesDB

        func meanPower(_ lower: Double, _ upper: Double) -> Double? {
            let low = max(Int(lower / spectrum.binWidthHz), 0)
            let high = min(Int(upper / spectrum.binWidthHz), bins.count)
            guard low < high else { return nil }
            let total = bins[low ..< high].reduce(0.0) { $0 + pow(10, Double($1) / 10) }
            return total / Double(high - low)
        }

        guard let band = meanPower(range.lowerBound, range.upperBound),
              let reference = meanPower(1_000, 8_000),
              band > 0, reference > 0
        else { return nil }
        return 10 * log10(band / reference)
    }

    /// Per-sub-band high-frequency difference, A minus B. Positive means A
    /// holds more content there.
    static func highBandDifferences(
        a: AudioAnalysisReport,
        b: AudioAnalysisReport
    ) -> [(range: ClosedRange<Double>, differenceDB: Double)] {
        let ceiling = min(a.bandwidth.nyquistHz, b.bandwidth.nyquistHz)
        var results: [(ClosedRange<Double>, Double)] = []
        for (lower, upper) in zip(highBandEdges, highBandEdges.dropFirst()) {
            let top = min(upper, ceiling)
            guard top - lower >= 500 else { continue }
            let range = lower ... top
            guard let levelA = relativeLevelDB(a.averageSpectrum, range: range),
                  let levelB = relativeLevelDB(b.averageSpectrum, range: range)
            else { continue }
            results.append((range, levelA - levelB))
        }
        return results
    }

    /// Retained high-frequency bandwidth — the most reliable fidelity signal
    /// between two encodes of one master, because a codec's lowpass is a hard,
    /// measurable edge rather than a matter of degree.
    ///
    /// Decided by differencing the two average spectra sub-band by sub-band,
    /// not by subtracting two `detectedCutoffHz` values. Two cutoff scalars
    /// cannot express "one cliffs, one rolls off gently", and on dark masters
    /// the detector reports nearly the same number for both while the spectra
    /// differ by 17 dB at 20 kHz. The cutoffs are still used to *phrase* the
    /// finding, but only when both were measured confidently.
    static func bandwidthFinding(a: AudioAnalysisReport, b: AudioAnalysisReport) -> QualityFinding {
        let differences = highBandDifferences(a: a, b: b)
        // Below 14 kHz a level difference is tonal balance, not bandwidth.
        let decisive = differences.filter { $0.range.lowerBound >= 14_000 }
        let strongest = decisive.max { abs($0.differenceDB) < abs($1.differenceDB) }

        let cutoffA = a.bandwidth.detectedCutoffHz ?? a.bandwidth.nyquistHz
        let cutoffB = b.bandwidth.detectedCutoffHz ?? b.bandwidth.nyquistHz

        guard let strongest, abs(strongest.differenceDB) >= Bars.highBandDB else {
            return QualityFinding(
                dimension: .bandwidth,
                direction: .tie,
                magnitude: strongest.map { abs($0.differenceDB) } ?? 0,
                confidence: .medium,
                statement: "Both carry the same amount of high-frequency content."
            )
        }

        let favoursA = strongest.differenceDB > 0
        // Agreement across sub-bands is what separates a real bandwidth
        // difference from one band of noise.
        let consistent = decisive
            .filter { abs($0.differenceDB) >= 2 }
            .allSatisfy { ($0.differenceDB > 0) == favoursA }
        let confidence: SourceConclusion.Confidence =
            consistent && abs(strongest.differenceDB) >= Bars.decisiveHighBandDB ? .high
            : consistent ? .medium : .low

        // Quote cutoffs only when both were actually measured as shelves.
        let cutoffsTrusted = a.bandwidth.confidence != .low
            && b.bandwidth.confidence != .low
            && abs(cutoffA - cutoffB) >= Bars.bandwidthHz
        let statement: String
        if cutoffsTrusted {
            statement = "Keeps content to \(kHz(max(cutoffA, cutoffB))) where the other rolls off "
                + "at \(kHz(min(cutoffA, cutoffB)))."
        } else {
            statement = String(
                format: "Carries %.0f dB more content above %@.",
                abs(strongest.differenceDB), kHz(strongest.range.lowerBound)
            )
        }

        return QualityFinding(
            dimension: .bandwidth,
            direction: favoursA ? .favorsA : .favorsB,
            magnitude: abs(strongest.differenceDB),
            confidence: confidence,
            statement: statement
        )
    }

    // MARK: Provenance

    /// Container and bitstream evidence: lossless beats lossy, and a lossless
    /// container that is really a re-encode beats nothing.
    static func provenanceFinding(a: AudioAnalysisReport, b: AudioAnalysisReport) -> [QualityFinding] {
        let tierA = provenanceTier(a)
        let tierB = provenanceTier(b)
        guard tierA.rank != tierB.rank else {
            // Same tier, but a bitrate gap within it is still evidence.
            guard a.fileInfo.isLosslessCodec == false, b.fileInfo.isLosslessCodec == false else { return [] }
            // Only within one codec. Bitrate does not compare across codecs —
            // AAC at 256 kbps beats MP3 at 320 — so a cross-codec bitrate gap
            // is not evidence of anything.
            guard a.fileInfo.codecDescription == b.fileInfo.codecDescription else { return [] }
            let rateDifference = a.fileInfo.dataRateKbps - b.fileInfo.dataRateKbps
            guard abs(rateDifference) >= 48 else { return [] }
            return [QualityFinding(
                dimension: .provenance,
                direction: rateDifference > 0 ? .favorsA : .favorsB,
                magnitude: abs(rateDifference),
                confidence: .low,
                statement: "Carries \(Int(max(a.fileInfo.dataRateKbps, b.fileInfo.dataRateKbps).rounded())) kbps "
                    + "against \(Int(min(a.fileInfo.dataRateKbps, b.fileInfo.dataRateKbps).rounded())) kbps."
            )]
        }

        let favoursA = tierA.rank > tierB.rank
        return [QualityFinding(
            dimension: .provenance,
            direction: favoursA ? .favorsA : .favorsB,
            magnitude: Double(abs(tierA.rank - tierB.rank)),
            confidence: favoursA ? tierA.confidence : tierB.confidence,
            statement: "\(favoursA ? tierA.label : tierB.label); the other is \(favoursA ? tierB.label : tierA.label)."
        )]
    }

    /// Where a file sits on the ladder from genuine lossless down to a lossy
    /// file wearing a lossless container.
    ///
    /// Deliberately about the *kind* of file, not the quality of its encode.
    /// `poorLossyEncode` vs `cleanLossyEncode` is a verdict the single-file
    /// engine reaches from pre-echo, flicker, intensity stereo and bandwidth —
    /// exactly the measurements the `bandwidth` and `codecArtifacts`
    /// dimensions already compare directly. Ranking on it too counts the same
    /// evidence twice, and the confidence rule then reads that as two
    /// independent dimensions agreeing.
    static func provenanceTier(
        _ report: AudioAnalysisReport
    ) -> (rank: Int, label: String, confidence: SourceConclusion.Confidence) {
        if let fake = report.conclusions.first(where: { $0.kind == .fakeLossless }) {
            return (1, "a lossy encode in a lossless container", fake.confidence)
        }
        if let lossless = report.conclusions.first(where: { $0.kind == .cleanLossless }) {
            return (3, "genuinely lossless", lossless.confidence)
        }
        if report.fileInfo.isLosslessCodec {
            return (3, "a lossless file", .low)
        }
        return (2, "a lossy encode", .low)
    }

    // MARK: Codec artifacts

    static func codecArtifactFindings(a: AudioAnalysisReport, b: AudioAnalysisReport) -> [QualityFinding] {
        var results: [QualityFinding] = []

        // Pre-echo only means something when enough attacks were measured; on
        // material without transients the score is noise.
        let attacks = min(a.lossyArtifacts.attackCount, b.lossyArtifacts.attackCount)
        if attacks >= Bars.preEchoAttacks {
            let difference = a.lossyArtifacts.preEchoScore - b.lossyArtifacts.preEchoScore
            if abs(difference) >= Bars.preEchoDB {
                results.append(QualityFinding(
                    dimension: .codecArtifacts,
                    direction: difference < 0 ? .favorsA : .favorsB,
                    magnitude: abs(difference),
                    confidence: attacks >= 2 * Bars.preEchoAttacks ? .high : .medium,
                    statement: String(
                        format: "Smears %.1f dB less noise ahead of transients (pre-echo).", abs(difference)
                    )
                ))
            }
        }

        // Flicker is measured against the codec frame cadence (~26 ms, an MP3
        // granule pair), so the score is not comparable between codecs: an AAC
        // file's 1024-sample frames beat against that window differently. Only
        // compare it within one codec.
        let sameCodec = a.fileInfo.codecDescription == b.fileInfo.codecDescription
        let flicker = a.lossyArtifacts.highBandFlickerScore - b.lossyArtifacts.highBandFlickerScore
        if sameCodec, abs(flicker) >= Bars.flicker {
            results.append(QualityFinding(
                dimension: .codecArtifacts,
                direction: flicker < 0 ? .favorsA : .favorsB,
                magnitude: abs(flicker),
                confidence: .medium,
                statement: "Holds its top end steadier; the other flickers at the codec frame rate."
            ))
        }

        // Intensity stereo mono-ifies the top octaves. Only meaningful when the
        // other file is genuinely stereo up there.
        let coherenceA = a.lossyArtifacts.hfStereoCoherence
        let coherenceB = b.lossyArtifacts.hfStereoCoherence
        if abs(coherenceA - coherenceB) >= 0.03, max(coherenceA, coherenceB) >= 0.97 {
            results.append(QualityFinding(
                dimension: .codecArtifacts,
                direction: coherenceA < coherenceB ? .favorsA : .favorsB,
                magnitude: abs(coherenceA - coherenceB),
                confidence: .medium,
                statement: "Keeps its highs in stereo; the other collapses them toward mono."
            ))
        }

        return results
    }

    // MARK: Added noise

    /// Noise one file carries and the other does not. For a shared master this
    /// is decisive: the master had no surface noise, so whichever file has it
    /// picked it up on the way.
    static func addedNoiseFindings(a: AudioAnalysisReport, b: AudioAnalysisReport) -> [QualityFinding] {
        var results: [QualityFinding] = []

        let clicks = a.analogSource.clickRatePerMinute - b.analogSource.clickRatePerMinute
        if abs(clicks) >= Bars.clickRate {
            results.append(QualityFinding(
                dimension: .addedNoise,
                direction: clicks < 0 ? .favorsA : .favorsB,
                magnitude: abs(clicks),
                confidence: .high,
                statement: String(
                    format: "The other carries %.0f surface clicks a minute; this one has %.0f.",
                    max(a.analogSource.clickRatePerMinute, b.analogSource.clickRatePerMinute),
                    min(a.analogSource.clickRatePerMinute, b.analogSource.clickRatePerMinute)
                )
            ))
        }

        let floorA = a.analogSource.stationaryNoiseFloorDBFS
        let floorB = b.analogSource.stationaryNoiseFloorDBFS
        if floorA.isFinite || floorB.isFinite {
            let levelA = floorA.isFinite ? floorA : -120
            let levelB = floorB.isFinite ? floorB : -120
            if abs(levelA - levelB) >= Bars.noiseFloorDB {
                results.append(QualityFinding(
                    dimension: .addedNoise,
                    direction: levelA < levelB ? .favorsA : .favorsB,
                    magnitude: abs(levelA - levelB),
                    confidence: .medium,
                    statement: String(
                        format: "Sits %.0f dB quieter under the music (noise floor).", abs(levelA - levelB)
                    )
                ))
            }
        }

        let rumbleA = a.analogSource.rumbleSideLevelDB
        let rumbleB = b.analogSource.rumbleSideLevelDB
        if rumbleA.isFinite, rumbleB.isFinite, abs(rumbleA - rumbleB) >= Bars.rumbleDB {
            results.append(QualityFinding(
                dimension: .addedNoise,
                direction: rumbleA < rumbleB ? .favorsA : .favorsB,
                magnitude: abs(rumbleA - rumbleB),
                confidence: .medium,
                statement: "Free of the sub-30 Hz turntable rumble the other carries."
            ))
        }

        return results
    }

    // MARK: Loudness, dynamics, tonal balance (descriptive only)

    static func loudnessFindings(a: AudioAnalysisReport, b: AudioAnalysisReport) -> [QualityFinding] {
        var results: [QualityFinding] = []

        // Clipping is the one loudness-adjacent measure that IS fidelity: a
        // clipped sample is information destroyed, not a mastering preference.
        let clipA = a.loudness.clippedSampleRunCount
        let clipB = b.loudness.clippedSampleRunCount
        let higher = max(clipA, clipB)
        let lower = min(clipA, clipB)
        if higher >= Bars.clippedRunFloor, Double(higher) >= Double(max(lower, 1)) * Bars.clippedRunRatio {
            results.append(QualityFinding(
                dimension: .clipping,
                direction: clipA < clipB ? .favorsA : .favorsB,
                magnitude: Double(higher - lower),
                confidence: .high,
                statement: "Has \(lower) clipped runs against \(higher)."
            ))
        }

        if let lufsA = a.loudness.integratedLUFS, let lufsB = b.loudness.integratedLUFS,
           abs(lufsA - lufsB) >= Bars.loudnessLU {
            results.append(QualityFinding(
                dimension: .loudness,
                direction: lufsA > lufsB ? .favorsA : .favorsB,
                magnitude: abs(lufsA - lufsB),
                confidence: .high,
                statement: String(format: "Mastered %.1f LU louder.", abs(lufsA - lufsB))
            ))
        }

        let crest = a.loudness.crestFactorDB - b.loudness.crestFactorDB
        if abs(crest) >= Bars.crestDB {
            results.append(QualityFinding(
                dimension: .dynamics,
                direction: crest > 0 ? .favorsA : .favorsB,
                magnitude: abs(crest),
                confidence: .high,
                statement: String(format: "Holds %.1f dB more crest factor — less limited.", abs(crest))
            ))
        }

        return results
    }

    /// The largest band-balance difference, reported as description. A tonal
    /// difference between two masters is a mastering choice, and no measurement
    /// makes one of them correct.
    ///
    /// Read from each file's own long-term band levels rather than from the
    /// residual, because those are valid whether or not the pair aligned — and
    /// the pairs where tonal balance is most worth describing are exactly the
    /// unaligned ones.
    static func tonalBalanceFinding(a: AudioAnalysisReport, b: AudioAnalysisReport) -> [QualityFinding] {
        let bandsA = a.tonalBalance.bands
        let bandsB = b.tonalBalance.bands
        guard !bandsA.isEmpty, bandsA.count == bandsB.count else { return [] }

        // The air band is bandwidth, not balance — it is reported separately.
        let differences = zip(bandsA, bandsB).dropLast().map { ($0.name, $0.relativeDB - $1.relativeDB) }
        guard let worst = differences.max(by: { abs($0.1) < abs($1.1) }), abs(worst.1) >= Bars.tonalDB
        else { return [] }

        return [QualityFinding(
            dimension: .tonalBalance,
            direction: worst.1 > 0 ? .favorsA : .favorsB,
            magnitude: abs(worst.1),
            confidence: .high,
            statement: String(
                format: "Carries %.1f dB more %@ than the other.", abs(worst.1), worst.0.lowercased()
            )
        )]
    }

    // MARK: - Ranking

    /// Rank a pair, or decline to. Abstention is the default: a ranking is only
    /// produced when fidelity-bearing evidence exists and agrees with itself.
    static func rank(
        relationship: PairRelationship,
        alignment: PairAlignmentResult,
        findings: [QualityFinding]
    ) -> PairRanking {
        guard relationship.supportsFidelityRanking else {
            switch relationship {
            case .differentMaster where alignment.speedRatio != nil:
                // The ratio itself is not reported: the scan resolves it too
                // coarsely to quote. What is solid is that no fixed alignment
                // works and a stretched one does.
                return .notComparable(
                    reason: "These do not line up at any fixed offset, but do once one is stretched "
                        + "slightly — a different transfer speed. Separate masters either way."
                )
            case .differentMaster:
                return .notComparable(
                    reason: "These are different masters of the same performance. Which one sounds "
                        + "better is a mastering preference, not a fidelity difference."
                )
            case .differentRecording:
                return .notComparable(reason: "These are different recordings; there is nothing to compare.")
            default:
                return .undetermined(reason: "The two files could not be aligned well enough to compare.")
            }
        }

        if relationship == .identical {
            return .equivalent
        }

        let decisive = findings.filter { $0.dimension.isFidelityBearing && $0.direction != .tie }
        guard !decisive.isEmpty else { return .equivalent }

        let favoursA = decisive.filter { $0.direction == .favorsA }
        let favoursB = decisive.filter { $0.direction == .favorsB }

        if favoursA.isEmpty || favoursB.isEmpty {
            let winning = favoursA.isEmpty ? favoursB : favoursA
            let confidence = confidence(for: winning)
            return favoursA.isEmpty ? .bBetter(confidence: confidence) : .aBetter(confidence: confidence)
        }

        // Evidence pointing both ways. Rather than average it away, say so —
        // this is the case a listener actually needs to hear for themselves.
        let aSummary = favoursA.map(\.dimension.label).joined(separator: ", ").lowercased()
        let bSummary = favoursB.map(\.dimension.label).joined(separator: ", ").lowercased()
        return .undetermined(
            reason: "The evidence points both ways: one wins on \(aSummary), the other on \(bSummary)."
        )
    }

    /// Confidence for a set of agreeing findings. Two independent mid-confidence
    /// findings are worth more than either alone; one low-confidence finding on
    /// its own is not worth much.
    static func confidence(for findings: [QualityFinding]) -> SourceConclusion.Confidence {
        let best = findings.map(\.confidence).max() ?? .low
        let distinctDimensions = Set(findings.map(\.dimension)).count
        guard distinctDimensions >= 2 else { return best }
        // Independent dimensions agreeing is evidence in its own right: two
        // weak signals pointing the same way beat either alone.
        return best >= .medium ? .high : .medium
    }

    // MARK: - Formatting

    /// `BandwidthMetrics` carries its own confidence enum; map it onto the one
    /// the conclusions and findings share.
    static func shared(_ confidence: BandwidthMetrics.Confidence) -> SourceConclusion.Confidence {
        switch confidence {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        }
    }

    static func kHz(_ hertz: Double) -> String {
        String(format: "%.1f kHz", hertz / 1_000)
    }
}
