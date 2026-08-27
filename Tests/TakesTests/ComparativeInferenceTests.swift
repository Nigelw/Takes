import XCTest
@testable import Takes

/// Covers the comparative layer's high-frequency comparison and the
/// fidelity/taste split it depends on.
///
/// The regression these guard against is a real one: comparing two
/// `detectedCutoffHz` scalars reported 17.7 kHz vs 17.6 kHz for a pair whose
/// spectra differ by 17 dB at 20 kHz, and the comparison missed it entirely.
final class ComparativeInferenceTests: XCTestCase {
    private let sampleRate = 44_100.0
    private var binWidth: Double { sampleRate / 8_192 }

    /// A spectrum flat at `midBandDB` up to `cutoffHz`, then falling to
    /// `aboveCutoffDB`. `slopePerKHz` bleeds content above the cutoff so a
    /// gentle rolloff can be distinguished from a hard shelf.
    private func spectrum(
        midBandDB: Float = -40,
        cutoffHz: Double,
        aboveCutoffDB: Float,
        slopePerKHz: Float = 0
    ) -> AverageSpectrum {
        let binCount = 4_096
        var magnitudes = [Float](repeating: midBandDB, count: binCount)
        for bin in 0 ..< binCount {
            let frequency = Double(bin) * binWidth
            guard frequency >= cutoffHz else { continue }
            let kHzAbove = Float((frequency - cutoffHz) / 1_000)
            magnitudes[bin] = aboveCutoffDB - slopePerKHz * kHzAbove
        }
        return AverageSpectrum(binWidthHz: binWidth, magnitudesDB: magnitudes)
    }

    // MARK: - relativeLevelDB

    func testRelativeLevelIsMeasuredAgainstTheFilesOwnMidBand() throws {
        // Flat everywhere: every band sits at 0 dB relative to the mid band,
        // whatever absolute level the file is mastered at.
        for level in [Float(-40), -10, -70] {
            let flat = spectrum(midBandDB: level, cutoffHz: 22_050, aboveCutoffDB: level)
            let relative = try XCTUnwrap(
                ComparativeInference.relativeLevelDB(flat, range: 16_000 ... 18_000)
            )
            XCTAssertEqual(relative, 0, accuracy: 0.5, "level \(level)")
        }
    }

    func testRelativeLevelTracksAShelf() throws {
        let shelved = spectrum(cutoffHz: 16_000, aboveCutoffDB: -70)
        let below = try XCTUnwrap(ComparativeInference.relativeLevelDB(shelved, range: 14_000 ... 16_000))
        let above = try XCTUnwrap(ComparativeInference.relativeLevelDB(shelved, range: 18_000 ... 20_000))
        XCTAssertEqual(below, 0, accuracy: 0.5)
        XCTAssertEqual(above, -30, accuracy: 0.5)
    }

    // MARK: - highBandDifferences

    func testHighBandDifferencesFindTheDivergence() throws {
        // Two files that agree below 18 kHz and diverge hard above it — the
        // shape two cutoff scalars cannot express.
        let wide = spectrum(cutoffHz: 22_050, aboveCutoffDB: -40)
        let narrow = spectrum(cutoffHz: 18_000, aboveCutoffDB: -80)

        let differences = ComparativeInference.highBandDifferences(
            a: report(spectrum: wide), b: report(spectrum: narrow)
        )

        for (range, difference) in differences where range.upperBound <= 18_000 {
            XCTAssertEqual(difference, 0, accuracy: 1, "\(range) should agree")
        }
        // The band straddling the cutoff reads a little under the full 40 dB:
        // integer bin rounding leaves one bin of below-cutoff content inside
        // it, and a mean *power* is dominated by its loudest bin. 20 dB is
        // still far past anything the finding treats as a tie.
        let top = differences.filter { $0.range.lowerBound >= 18_000 }
        XCTAssertFalse(top.isEmpty)
        for (range, difference) in top {
            XCTAssertGreaterThan(difference, 20, "\(range) should favour the wideband file")
        }
        let highest = try XCTUnwrap(top.last)
        XCTAssertEqual(highest.differenceDB, 40, accuracy: 1)
    }

    // MARK: - bandwidthFinding

    func testBandwidthFindingFiresWhenCutoffsAgreeButSpectraDoNot() {
        // The Mos Def case. Both files fade out around the same place by the
        // cutoff detector's absolute threshold, but one keeps real content two
        // octaves higher. Cutoffs are reported identical and low-confidence,
        // exactly as they were on the real pair.
        let gentle = spectrum(cutoffHz: 17_600, aboveCutoffDB: -55, slopePerKHz: 4)
        let cliff = spectrum(cutoffHz: 17_600, aboveCutoffDB: -55, slopePerKHz: 25)

        let finding = ComparativeInference.bandwidthFinding(
            a: report(spectrum: gentle, cutoffHz: 17_700, confidence: .low),
            b: report(spectrum: cliff, cutoffHz: 17_600, confidence: .low)
        )

        XCTAssertEqual(finding.direction, .favorsA)
        XCTAssertGreaterThan(finding.magnitude, ComparativeInference.Bars.highBandDB)
        // Cutoffs were not measured confidently, so they must not be quoted.
        XCTAssertFalse(finding.statement.contains("17.7"))
        XCTAssertTrue(finding.statement.contains("more content above"))
    }

    func testBandwidthFindingQuotesCutoffsWhenTheyAreTrustworthy() {
        let wide = spectrum(cutoffHz: 22_050, aboveCutoffDB: -40)
        let narrow = spectrum(cutoffHz: 16_000, aboveCutoffDB: -100)

        let finding = ComparativeInference.bandwidthFinding(
            a: report(spectrum: wide, cutoffHz: nil, confidence: .high),
            b: report(spectrum: narrow, cutoffHz: 16_000, confidence: .high)
        )

        XCTAssertEqual(finding.direction, .favorsA)
        XCTAssertEqual(finding.confidence, .high)
        XCTAssertTrue(finding.statement.contains("16.0 kHz"), finding.statement)
    }

    func testBandwidthFindingTiesOnMatchingSpectra() {
        let same = spectrum(cutoffHz: 19_000, aboveCutoffDB: -75)
        let finding = ComparativeInference.bandwidthFinding(
            a: report(spectrum: same), b: report(spectrum: same)
        )
        XCTAssertEqual(finding.direction, .tie)
    }

    // MARK: - Provenance

    func testProvenanceIgnoresEncodeQuality() {
        // Encode quality is measured directly by the bandwidth and
        // codec-artifact dimensions. Ranking on it here too would count the
        // same evidence twice and inflate confidence.
        let poor = report(spectrum: spectrum(cutoffHz: 16_000, aboveCutoffDB: -100),
                          isLossless: false, conclusionKind: .poorLossyEncode)
        let clean = report(spectrum: spectrum(cutoffHz: 20_000, aboveCutoffDB: -100),
                           isLossless: false, conclusionKind: .cleanLossyEncode)
        XCTAssertEqual(
            ComparativeInference.provenanceTier(poor).rank,
            ComparativeInference.provenanceTier(clean).rank
        )
    }

    func testProvenanceRanksContainerHonesty() {
        let lossless = report(spectrum: spectrum(cutoffHz: 22_050, aboveCutoffDB: -40),
                              isLossless: true, conclusionKind: .cleanLossless)
        let lossy = report(spectrum: spectrum(cutoffHz: 19_000, aboveCutoffDB: -90),
                           isLossless: false, conclusionKind: .cleanLossyEncode)
        let fake = report(spectrum: spectrum(cutoffHz: 16_000, aboveCutoffDB: -110),
                          isLossless: true, conclusionKind: .fakeLossless)

        let losslessRank = ComparativeInference.provenanceTier(lossless).rank
        let lossyRank = ComparativeInference.provenanceTier(lossy).rank
        let fakeRank = ComparativeInference.provenanceTier(fake).rank
        XCTAssertGreaterThan(losslessRank, lossyRank)
        XCTAssertGreaterThan(lossyRank, fakeRank)
    }

    // MARK: - Fixtures

    private func report(
        spectrum: AverageSpectrum,
        cutoffHz: Double? = nil,
        confidence: BandwidthMetrics.Confidence = .low,
        isLossless: Bool = false,
        conclusionKind: SourceConclusion.Kind? = nil
    ) -> AudioAnalysisReport {
        AudioAnalysisReport(
            fileInfo: AnalyzedFileInfo(
                url: URL(fileURLWithPath: "/dev/null"),
                fileName: "fixture",
                codecDescription: isLossless ? "FLAC" : "MP3",
                sampleRateHz: sampleRate,
                channelCount: 2,
                bitDepth: 16,
                durationSeconds: 180,
                dataRateKbps: isLossless ? 900 : 256,
                isLosslessCodec: isLossless
            ),
            analyzedModules: .all,
            loudness: .unavailable,
            tonalBalance: SpectrumMetrics.tonalBalance(from: spectrum),
            noiseFloor: .unavailable,
            bandwidth: BandwidthMetrics(
                nyquistHz: sampleRate / 2,
                detectedCutoffHz: cutoffHz,
                shelfDepthDB: nil,
                confidence: confidence
            ),
            analogSource: .unavailable,
            lossyArtifacts: .unavailable,
            mp3Stream: nil,
            averageSpectrum: spectrum,
            spectrogram: nil,
            conclusions: conclusionKind.map {
                [SourceConclusion(kind: $0, statement: "fixture", confidence: .medium, evidence: [])]
            } ?? [],
            verdicts: []
        )
    }
}
