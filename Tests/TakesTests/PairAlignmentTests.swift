import XCTest
@testable import Takes

/// `PairAligner` and `CorrelationFFT` validation on synthetic signals.
///
/// Everything here is generated in code. No dependency on `Private/Analysis
/// Corpus` — those files are gitignored and absent from CI — and no file
/// I/O at all.
final class PairAlignmentTests: XCTestCase {
    private let sampleRate = 44_100.0

    // MARK: - Signal generation

    private func whiteNoise(amplitude: Float, count: Int, seed: UInt64) -> [Float] {
        var state = seed
        return (0 ..< count).map { _ in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return amplitude * (Float(state % 2_000_001) / 1_000_000 - 1)
        }
    }

    /// Wraps `i` into `0 ..< n`, for checking circular-shift semantics.
    private func wrapped(_ i: Int, _ n: Int) -> Int {
        let m = i % n
        return m < 0 ? m + n : m
    }

    /// `whiteNoise`, box-averaged to roll off right at Nyquist.
    ///
    /// `spectralShift` deliberately leaves the Nyquist bin unrotated for a
    /// real signal (see its doc comment: rotating it would make the signal
    /// complex, and real audio carries negligible energy there). Raw LCG
    /// noise is flat all the way to Nyquist, which is a signal no decoded
    /// audio file ever produces — exercising that bin would be testing an
    /// input the function was never meant to handle. A one-sample moving
    /// average cancels Nyquist exactly (adjacent samples there alternate in
    /// sign) while barely touching anything else, giving a broadband signal
    /// that behaves like real audio for this purpose.
    ///
    /// Needed only where a *fractional* shift is round-tripped. A real signal's
    /// Nyquist component is x·cos(πn), which no fractional delay can preserve
    /// — `spectralShift` scales it by cos(πs), the only real-valued answer,
    /// and that scaling does not undo itself when the shift is reversed.
    /// Integer shifts are exact and use raw white noise.
    private func bandLimitedNoise(amplitude: Float, count: Int, seed: UInt64) -> [Float] {
        let raw = whiteNoise(amplitude: amplitude, count: count, seed: seed)
        return (0 ..< count).map { index in
            (raw[index] + raw[wrapped(index - 1, count)]) / 2
        }
    }

    // MARK: - CorrelationFFT.spectralShift

    func testSpectralShiftRoundTripsAtZero() throws {
        let size = 4_096
        let fft = CorrelationFFT(size: size)
        let input = whiteNoise(amplitude: 0.5, count: size, seed: 1)

        let output = try XCTUnwrap(fft.spectralShift(input, by: 0))

        // Away from the wrap edges: a shift of exactly 0 should reproduce the
        // input to float round-trip precision.
        for index in 8 ..< (size - 8) {
            XCTAssertEqual(output[index], input[index], accuracy: 1e-5)
        }
    }

    func testSpectralShiftReproducesIndexShift() throws {
        let size = 4_096
        let fft = CorrelationFFT(size: size)
        let input = whiteNoise(amplitude: 0.5, count: size, seed: 2)

        // The load-bearing sign convention: output[i] == input[i + shift],
        // wrapped circularly. Getting this backwards silently flips every
        // alignment the classifier ever makes.
        //
        // Full-band noise on purpose, and odd shifts on purpose: an integer
        // shift must be exact right up to Nyquist. It was not, once — the
        // Nyquist bin sits outside the generic phase rotation and was left
        // unturned, which cost 6e-3 on every odd-sample shift.
        for shift in [3, -5, 100, -777, 2_000] {
            let output = try XCTUnwrap(fft.spectralShift(input, by: Double(shift)))
            for index in 0 ..< size {
                let expected = input[wrapped(index + shift, size)]
                XCTAssertEqual(output[index], expected, accuracy: 1e-4, "shift \(shift), index \(index)")
            }
        }
    }

    // MARK: - CorrelationFFT.phatShift

    func testPhatShiftRecoversIntegerShifts() throws {
        let size = 4_096
        let fft = CorrelationFFT(size: size)
        let reference = whiteNoise(amplitude: 0.5, count: size, seed: 3)

        for trueShift in [0, 5, -7, 37, -100] {
            let candidate = try XCTUnwrap(fft.spectralShift(reference, by: Double(trueShift)))
            let recovered = try XCTUnwrap(fft.phatShift(reference: reference, candidate: candidate))

            // The returned value is the shift to hand to `spectralShift`, not
            // the delay itself — the opposite sign, by design (see the doc
            // comment on `phatShift`).
            XCTAssertEqual(recovered, -trueShift, "trueShift \(trueShift)")

            // Confirm it actually works as "the shift to hand to spectralShift":
            // applying it should restore the reference.
            let realigned = try XCTUnwrap(fft.spectralShift(candidate, by: Double(recovered)))
            for index in 0 ..< size {
                XCTAssertEqual(realigned[index], reference[index], accuracy: 1e-3)
            }
        }
    }

    // MARK: - PairAligner.phaseSlopeShift

    func testPhaseSlopeShiftRecoversFractionalDelays() throws {
        let size = 16_384
        let fft = CorrelationFFT(size: size)
        let reference = whiteNoise(amplitude: 0.5, count: size, seed: 4)

        for fraction in [0.5, -0.25, 0.37] {
            let candidate = try XCTUnwrap(fft.spectralShift(reference, by: fraction))
            let recovered = PairAligner.phaseSlopeShift(
                reference: reference, candidate: candidate, sampleRate: sampleRate
            )
            // Same convention as `phatShift`: the value to hand to
            // `spectralShift` is the negative of the delay applied above.
            XCTAssertEqual(recovered, -fraction, accuracy: 0.01, "fraction \(fraction)")
        }
    }

    // MARK: - Combined: phatShift + phaseSlopeShift + spectralShift

    func testCombinedAlignmentNullsBelowMinus100DB() throws {
        let size = 32_768
        let fft = CorrelationFFT(size: size)
        // Band-limited: this round-trips a fractional shift, and a Nyquist
        // component cannot survive that (see `bandLimitedNoise`). Real audio
        // never carries full energy at Nyquist either.
        let reference = bandLimitedNoise(amplitude: 0.5, count: size, seed: 5)
        let trueDelay = 5.37

        let candidate = try XCTUnwrap(fft.spectralShift(reference, by: trueDelay))

        let integerShift = try XCTUnwrap(fft.phatShift(reference: reference, candidate: candidate))
        XCTAssertEqual(integerShift, -5)

        // Circularly re-slice the candidate at the integer-corrected position —
        // the same idea as `PairAligner.measure`'s `span[integerRange]`, just
        // over a fully circular synthetic buffer instead of a guard-padded
        // file span.
        let integerAligned = (0 ..< size).map { candidate[wrapped($0 + integerShift, size)] }

        let fraction = PairAligner.phaseSlopeShift(
            reference: reference, candidate: integerAligned, sampleRate: sampleRate
        )
        let fine = Double(integerShift) + fraction
        XCTAssertEqual(fine, -trueDelay, accuracy: 0.01)

        let aligned = try XCTUnwrap(fft.spectralShift(candidate, by: fine))
        let residual = PairAligner.windowResidual(
            reference: reference, aligned: aligned, gain: 1, sampleRate: sampleRate
        )
        XCTAssertLessThan(residual.residualToSignalDB, -100)
    }

    // MARK: - PairAligner.windowResidual / residualMetrics

    func testIdenticalSignalsNullToTheFloor() {
        let signal = whiteNoise(amplitude: 0.4, count: 16_384, seed: 6)
        let residual = PairAligner.windowResidual(reference: signal, aligned: signal, gain: 1, sampleRate: sampleRate)
        XCTAssertLessThan(residual.residualToSignalDB, -100)
        XCTAssertEqual(residual.waveformCoherence, 1.0, accuracy: 1e-6)
    }

    func testGainScaledCopyNullsWhenGainMatches() {
        let reference = whiteNoise(amplitude: 0.4, count: 16_384, seed: 7)
        let louder = reference.map { $0 * 3 }
        let residual = PairAligner.windowResidual(
            reference: reference, aligned: louder, gain: 1.0 / 3.0, sampleRate: sampleRate
        )
        XCTAssertLessThan(residual.residualToSignalDB, -80)
        XCTAssertEqual(residual.waveformCoherence, 1.0, accuracy: 1e-4)
    }

    func testUncorrelatedNoiseReadsLowCoherence() {
        let reference = whiteNoise(amplitude: 0.4, count: 16_384, seed: 8)
        let unrelated = whiteNoise(amplitude: 0.4, count: 16_384, seed: 9)
        let residual = PairAligner.windowResidual(
            reference: reference, aligned: unrelated, gain: 1, sampleRate: sampleRate
        )
        XCTAssertLessThan(residual.waveformCoherence, 0.3)
    }

    // MARK: - PairAligner.median / medianVector

    func testMedianHandlesEvenOddAndEmpty() {
        XCTAssertEqual(PairAligner.median([]), 0)
        XCTAssertEqual(PairAligner.median([5]), 5)
        XCTAssertEqual(PairAligner.median([3, 1, 2]), 2)
        XCTAssertEqual(PairAligner.median([1, 2, 3, 4]), 2.5)
    }

    func testMedianVectorAppliesElementwise() {
        XCTAssertEqual(PairAligner.medianVector([]), [])
        XCTAssertEqual(PairAligner.medianVector([[1, 2], [5, 6], [3, 4]]), [3, 4])
        // Mismatched widths have no sensible per-column median.
        XCTAssertEqual(PairAligner.medianVector([[1, 2], [3]]), [])
    }

    // MARK: - PairAligner.overlapRange

    func testOverlapRangeAcrossOffsets() {
        XCTAssertEqual(PairAligner.overlapRange(aFrames: 1_000, bFrames: 1_000, offset: 0), 0 ..< 1_000)
        XCTAssertEqual(PairAligner.overlapRange(aFrames: 1_000, bFrames: 1_000, offset: 200), 0 ..< 800)
        XCTAssertEqual(PairAligner.overlapRange(aFrames: 1_000, bFrames: 1_000, offset: -200), 200 ..< 1_000)
        // No overlap at all.
        XCTAssertEqual(PairAligner.overlapRange(aFrames: 1_000, bFrames: 1_000, offset: 2_000), 0 ..< 0)
    }

    // MARK: - PairAligner.probeWindowStarts

    func testProbeWindowStartsEmptyWhenOverlapTooShort() {
        let overlap = 0 ..< (PairAligner.probeWindowSamples - 1)
        XCTAssertEqual(PairAligner.probeWindowStarts(in: overlap), [])
    }

    func testProbeWindowStartsInsetFromBothEdges() {
        let window = PairAligner.probeWindowSamples
        let overlap = 1_000 ..< (1_000 + window * 12)

        let starts = PairAligner.probeWindowStarts(in: overlap)

        XCTAssertFalse(starts.isEmpty)
        // Regression guard: a window at the exact edge of the overlap reads
        // encoder disagreement about near-silence (intro/outro fades and
        // padding), not the music. Every start must be inset from both edges.
        XCTAssertGreaterThan(starts.first!, overlap.lowerBound)
        XCTAssertLessThan(starts.last! + window, overlap.upperBound)
    }

    func testProbeWindowStartsNeverReadPastTheOverlap() {
        let window = PairAligner.probeWindowSamples
        for multiplier in [1, 2, 3, 5, 12] {
            let overlap = 4_096 ..< (4_096 + window * multiplier)
            for start in PairAligner.probeWindowStarts(in: overlap) {
                XCTAssertGreaterThanOrEqual(start, overlap.lowerBound)
                XCTAssertLessThanOrEqual(start + window, overlap.upperBound)
            }
        }
    }

    // MARK: - PairAligner.classify

    private func alignment(overlapSeconds: Double, isConfident: Bool) -> PairAlignmentResult {
        PairAlignmentResult(
            offsetSeconds: 0,
            offsetSamples: 0,
            sampleRate: sampleRate,
            correlation: isConfident ? 0.9 : 0.2,
            gainMatchDB: 0,
            overlapSeconds: overlapSeconds,
            isConfident: isConfident,
            speedRatio: nil
        )
    }

    private func residual(
        residualToSignalDB: Double,
        midBandResidualToSignalDB: Double = -20,
        midBandTiltDifferenceDB: Double = 0.5
    ) -> ResidualMetrics {
        ResidualMetrics(
            residualToSignalDB: residualToSignalDB,
            bandResidualToSignalDB: [],
            midBandResidualToSignalDB: midBandResidualToSignalDB,
            bandLevelDifferenceDB: [],
            midBandTiltDifferenceDB: midBandTiltDifferenceDB,
            highFrequencyEnergyFraction: 0,
            residualCrestFactorDB: 0,
            waveformCoherence: 0
        )
    }

    func testClassifyIdentical() {
        let result = PairAligner.classify(
            alignment: alignment(overlapSeconds: 5, isConfident: true),
            residual: residual(residualToSignalDB: PairAligner.Thresholds.identicalResidualDB - 10)
        )
        XCTAssertEqual(result, .identical)
    }

    func testClassifySameMaster() {
        let result = PairAligner.classify(
            alignment: alignment(overlapSeconds: 5, isConfident: true),
            residual: residual(
                residualToSignalDB: -40,
                midBandResidualToSignalDB: PairAligner.Thresholds.sameMasterMidBandResidualDB - 5,
                midBandTiltDifferenceDB: PairAligner.Thresholds.sameMasterTiltDB - 1
            )
        )
        XCTAssertEqual(result, .sameMaster)
    }

    func testClassifyDifferentMasterViaTilt() {
        // Mid-band residual alone would pass; the tilt does not.
        let result = PairAligner.classify(
            alignment: alignment(overlapSeconds: 5, isConfident: true),
            residual: residual(
                residualToSignalDB: -40,
                midBandResidualToSignalDB: PairAligner.Thresholds.sameMasterMidBandResidualDB - 5,
                midBandTiltDifferenceDB: PairAligner.Thresholds.sameMasterTiltDB + 2
            )
        )
        XCTAssertEqual(result, .differentMaster)
    }

    func testClassifyDifferentMasterViaMidBandResidual() {
        // Tilt alone would pass; the mid-band residual does not.
        let result = PairAligner.classify(
            alignment: alignment(overlapSeconds: 5, isConfident: true),
            residual: residual(
                residualToSignalDB: -40,
                midBandResidualToSignalDB: PairAligner.Thresholds.sameMasterMidBandResidualDB + 4,
                midBandTiltDifferenceDB: PairAligner.Thresholds.sameMasterTiltDB - 1
            )
        )
        XCTAssertEqual(result, .differentMaster)
    }

    func testClassifyDifferentRecordingWhenNotConfident() {
        let result = PairAligner.classify(
            alignment: alignment(overlapSeconds: 5, isConfident: false),
            residual: residual(residualToSignalDB: -40)
        )
        XCTAssertEqual(result, .differentRecording)
    }

    func testClassifyIndeterminateWhenOverlapTooShort() {
        let tooShort = PairAligner.Thresholds.minimumOverlapSeconds - 1
        let result = PairAligner.classify(
            alignment: alignment(overlapSeconds: tooShort, isConfident: true),
            residual: residual(residualToSignalDB: -90)
        )
        XCTAssertEqual(result, .indeterminate)
    }

    // MARK: - Fidelity / taste split

    func testPairRelationshipFidelityRankingSplit() {
        XCTAssertTrue(PairRelationship.identical.supportsFidelityRanking)
        XCTAssertTrue(PairRelationship.sameMaster.supportsFidelityRanking)
        XCTAssertFalse(PairRelationship.differentMaster.supportsFidelityRanking)
        XCTAssertFalse(PairRelationship.differentRecording.supportsFidelityRanking)
        XCTAssertFalse(PairRelationship.indeterminate.supportsFidelityRanking)
    }

    func testQualityFindingDimensionFidelityBearingSplit() {
        let fidelityBearing: Set<QualityFinding.Dimension> = [
            .bandwidth, .codecArtifacts, .addedNoise, .clipping, .provenance,
        ]
        for dimension in QualityFinding.Dimension.allCases {
            XCTAssertEqual(dimension.isFidelityBearing, fidelityBearing.contains(dimension), "\(dimension)")
        }
    }
}
