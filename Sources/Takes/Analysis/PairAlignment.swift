import Accelerate
import AVFoundation
import Foundation

/// Aligns two tracks to the sample, gain-matches them, subtracts, and reads
/// the relationship off the residual.
///
/// This is the gate for the whole comparative feature: nothing may be ranked
/// on fidelity until we know whether two files share a master. See
/// docs/comparative-quality-analysis.md.
///
/// Why sample accuracy matters: a half-sample misalignment leaves a residual
/// only ~3 dB below the signal at 10 kHz, which would drown every real
/// difference. The coarse 1 ms lag from `TrackAligner` is refined by GCC-PHAT
/// with parabolic peak interpolation, then the fractional part is applied
/// with a windowed-sinc delay before subtraction.
enum PairAligner {
    // MARK: Tuning

    /// Thresholds the classifier keys on. Gathered here because M8 tunes them
    /// against the corpus; see the plan's milestone table.
    enum Thresholds {
        /// Residual-to-signal below this counts as the same bits.
        static let identicalResidualDB = -80.0
        /// A same-master pair must match this closely across `midBandRangeHz`.
        /// Codecs are near-transparent there at any usable bitrate, so a
        /// difference in that range means a different master.
        static let sameMasterMidBandResidualDB = -12.0
        /// The range the same-master test aggregates over. It starts at 60 Hz
        /// deliberately: the sub band carries too little energy to judge, and
        /// reads alarmingly high on encodes that are otherwise transparent.
        static let midBandRangeHz = 60.0 ... 4_000.0
        /// Largest mid-band level difference a same-master pair may show. This
        /// is the real discriminator: a codec is a *level-preserving* operation
        /// below its cutoff, so the long-term band balance survives it almost
        /// exactly, while any remaster moves it. Measured across the corpus,
        /// same-master pairs top out at 1.6 dB and different masters start at
        /// 4.2 dB.
        static let sameMasterTiltDB = 2.5
        /// Minimum overlapping audio for any residual verdict.
        static let minimumOverlapSeconds = 3.0
        /// Correlation of the aligned, gain-matched signals below which we
        /// treat the alignment as not really having landed.
        static let minimumWaveformCoherence = 0.5
        /// Coherence below which a candidate offset is not worth pursuing at
        /// all — the two files are not the same performance.
        static let matchedCoherence = 0.7
        /// How much better a speed-corrected novelty match must score than the
        /// uncorrected one before we call it a genuine speed difference.
        static let speedMatchImprovement = 1.15
        /// Absolute floor the speed-corrected score must also clear.
        static let speedMatchMinimumScore: Float = 0.45
    }

    /// Probe window length in samples. A power of two so it feeds the
    /// correlation FFT directly; ~5.9 s at 44.1 kHz.
    static let probeWindowSamples = 1 << 18
    /// B is decoded over twice that, so the spectral shift has guard room at
    /// both ends to wrap into and the compared centre stays clean.
    static let probeSpanSamples = 1 << 19
    /// Guard samples either side of the compared window.
    static let probeGuardSamples = (probeSpanSamples - probeWindowSamples) / 2
    /// How many probe windows to spread across the overlap.
    static let probeWindowCount = 3

    // MARK: Result

    struct Measurement: Sendable {
        let alignment: PairAlignmentResult
        let residual: ResidualMetrics
        let relationship: PairRelationship
    }

    enum PairError: LocalizedError {
        case unreadable(URL)

        var errorDescription: String? {
            switch self {
            case .unreadable(let url): return "Could not read \(url.lastPathComponent)."
            }
        }
    }

    // MARK: Entry point

    /// Measure how `b` relates to `a`. Blocking; call off the main actor.
    static func measure(a: URL, b: URL) throws -> Measurement {
        guard let aInfo = probeInfo(a) else { throw PairError.unreadable(a) }
        guard let bInfo = probeInfo(b) else { throw PairError.unreadable(b) }

        // Both files are compared at A's rate; B is resampled when it differs,
        // which puts a floor under how deep the null can go (documented
        // limitation — see the plan).
        let sampleRate = aInfo.sampleRate

        // Candidate starting offsets, in order of preference.
        //
        // Zero is always tried, and is usually right: two copies of one track
        // start at the same place. The novelty aligner is the fallback for real
        // offsets (different intros, trimmed leaders), but it is not allowed to
        // veto the comparison — its peak-contrast gate rejects repetitive
        // material outright, and on such a pair the residual itself is a far
        // better test of whether the files line up than novelty contrast ever
        // was.
        var candidates = [0]
        if let envelopeA = TrackAligner.noveltyEnvelope(url: a),
           let envelopeB = TrackAligner.noveltyEnvelope(url: b),
           let match = TrackAligner.bestAlignment(reference: envelopeA, target: envelopeB) {
            // `bestAlignment` reports `reference[0]` lining up with
            // `target[lag]`, in 1 ms hops: A[i] corresponds to B[i + lag].
            let offset = Int((Double(match.lag) * TrackAligner.hopSeconds * sampleRate).rounded())
            if offset != 0 { candidates.append(offset) }
        }

        var best: Measurement?
        for offset in candidates {
            guard let measurement = measure(
                a: a, b: b, aInfo: aInfo, bInfo: bInfo, coarseOffsetSamples: offset
            ) else { continue }
            if measurement.residual.waveformCoherence > (best?.residual.waveformCoherence ?? -1) {
                best = measurement
            }
            // A clean match needs no second opinion.
            if measurement.residual.waveformCoherence >= Thresholds.matchedCoherence { break }
        }

        let measurement = best ?? Measurement(
            alignment: .none,
            residual: .unavailable,
            relationship: .differentRecording
        )
        guard measurement.residual.waveformCoherence < Thresholds.matchedCoherence else {
            return measurement
        }

        // Nothing lined up at a fixed lag. Before calling these different
        // recordings, check whether they are the same performance running at
        // different speeds — remasters transferred from tape routinely are, and
        // half a percent is enough to destroy a sample-accurate comparison
        // while leaving the music obviously the same.
        guard let ratio = detectSpeedRatio(a: a, b: b) else { return measurement }
        return Measurement(
            alignment: PairAlignmentResult(
                offsetSeconds: measurement.alignment.offsetSeconds,
                offsetSamples: measurement.alignment.offsetSamples,
                sampleRate: sampleRate,
                correlation: measurement.alignment.correlation,
                gainMatchDB: measurement.alignment.gainMatchDB,
                overlapSeconds: measurement.alignment.overlapSeconds,
                isConfident: false,
                speedRatio: ratio
            ),
            residual: measurement.residual,
            // Same performance, different transfer speed: that is a different
            // master by definition, and not rankable on fidelity.
            relationship: .differentMaster
        )
    }

    /// The playback-speed ratio that best matches `b` to `a`, or `nil` when no
    /// stretched ratio explains the pair materially better than 1.0 does.
    static func detectSpeedRatio(a: URL, b: URL) -> Double? {
        guard
            let envelopeA = TrackAligner.noveltyEnvelope(url: a),
            let envelopeB = TrackAligner.noveltyEnvelope(url: b),
            let baseline = TrackAligner.bestAlignment(reference: envelopeA, target: envelopeB)
        else { return nil }

        var bestRatio = 1.0
        var bestScore = baseline.score
        // ±3% covers tape transfer error and the 4% PAL/NTSC-style shifts;
        // anything beyond that is a different performance, not a transfer.
        for step in -12 ... 12 where step != 0 {
            let ratio = 1 + Double(step) * 0.0025
            let stretched = TrackAligner.stretchedEnvelope(envelopeB, ratio: ratio)
            guard let match = TrackAligner.bestAlignment(reference: envelopeA, target: stretched) else { continue }
            if match.score > bestScore {
                bestScore = match.score
                bestRatio = ratio
            }
        }

        guard bestRatio != 1.0,
              bestScore >= Thresholds.speedMatchMinimumScore,
              bestScore >= baseline.score * Float(Thresholds.speedMatchImprovement)
        else { return nil }
        return bestRatio
    }

    /// One pass at a given coarse offset. `nil` when nothing could be measured
    /// there at all; a low-coherence `Measurement` when it simply did not match.
    private static func measure(
        a: URL,
        b: URL,
        aInfo: FileProbe,
        bInfo: FileProbe,
        coarseOffsetSamples: Int
    ) -> Measurement? {
        let sampleRate = aInfo.sampleRate
        let rateScale = sampleRate / bInfo.sampleRate
        let bTotalAtA = Int(Double(bInfo.totalFrames) * rateScale)
        let overlap = overlapRange(
            aFrames: Int(aInfo.totalFrames),
            bFrames: bTotalAtA,
            offset: coarseOffsetSamples
        )
        let overlapSeconds = Double(overlap.count) / sampleRate

        func inconclusive(_ relationship: PairRelationship) -> Measurement {
            Measurement(
                alignment: PairAlignmentResult(
                    offsetSeconds: Double(coarseOffsetSamples) / sampleRate,
                    offsetSamples: coarseOffsetSamples,
                    sampleRate: sampleRate,
                    correlation: 0,
                    gainMatchDB: 0,
                    overlapSeconds: overlapSeconds,
                    isConfident: false,
                    speedRatio: nil
                ),
                residual: .unavailable,
                relationship: relationship
            )
        }

        guard overlapSeconds >= Thresholds.minimumOverlapSeconds else {
            return inconclusive(.indeterminate)
        }

        var referenceSpans: [[Float]] = []
        var alignedSpans: [[Float]] = []
        var fineOffsets: [Double] = []
        // A window whose correlation peak lands nowhere near the expected lag
        // is positive evidence of no match, not a measurement failure. Tracked
        // separately so "every window disagreed" reads as `differentRecording`
        // rather than `indeterminate`.
        var attemptedWindows = 0
        var strayPeaks = 0

        let correlationFFT = CorrelationFFT(size: probeWindowSamples)
        let spanFFT = CorrelationFFT(size: probeSpanSamples)
        let compared = probeGuardSamples ..< probeGuardSamples + probeWindowSamples

        for start in probeWindowStarts(in: overlap) {
            guard
                let reference = decodeMono(
                    url: a, startFrame: AVAudioFramePosition(start), frameCount: probeWindowSamples
                ),
                reference.count == probeWindowSamples
            else { continue }

            // B's span, decoded with guard room either side so the shift has
            // somewhere to wrap and the compared centre stays clean.
            guard let span = decodeMonoResampled(
                url: b,
                startFrameAtTargetRate: start + coarseOffsetSamples - probeGuardSamples,
                frameCountAtTargetRate: probeSpanSamples,
                targetSampleRate: sampleRate,
                sourceSampleRate: bInfo.sampleRate
            ), span.count == probeSpanSamples else { continue }

            // Two stages. GCC-PHAT picks the right sample; the cross-spectrum
            // phase slope picks the fraction of one. Both are needed — the
            // integer alone leaves a null far too shallow to measure against.
            let centre = Array(span[compared])
            attemptedWindows += 1
            guard let integerShift = correlationFFT.phatShift(reference: reference, candidate: centre)
            else { continue }
            guard abs(integerShift) < probeGuardSamples / 2 else {
                strayPeaks += 1
                continue
            }

            let integerRange = (compared.lowerBound + integerShift) ..< (compared.upperBound + integerShift)
            let fraction = phaseSlopeShift(
                reference: reference,
                candidate: Array(span[integerRange]),
                sampleRate: sampleRate
            )
            let fine = Double(integerShift) + fraction
            guard let shiftedSpan = spanFFT.spectralShift(span, by: fine) else { continue }

            referenceSpans.append(reference)
            alignedSpans.append(Array(shiftedSpan[compared]))
            fineOffsets.append(fine)
        }

        guard !referenceSpans.isEmpty else {
            let noWindowMatched = attemptedWindows > 0 && strayPeaks == attemptedWindows
            return inconclusive(noWindowMatched ? .differentRecording : .indeterminate)
        }

        // A single broadband gain scalar, deliberately: a per-band match would
        // null out the EQ differences the classifier needs to see.
        let referenceEnergy = referenceSpans.reduce(0.0) { $0 + sumOfSquares($1) }
        let alignedEnergy = alignedSpans.reduce(0.0) { $0 + sumOfSquares($1) }
        let gain = alignedEnergy > 0 ? (referenceEnergy / alignedEnergy).squareRoot() : 1
        let gainMatchDB = gain > 0 ? 20 * log10(gain) : 0

        let residual = residualMetrics(
            reference: referenceSpans,
            aligned: alignedSpans,
            gain: Float(gain),
            sampleRate: sampleRate
        )

        let meanFine = fineOffsets.reduce(0, +) / Double(fineOffsets.count)
        let offsetSamplesTotal = Double(coarseOffsetSamples) + meanFine
        let alignment = PairAlignmentResult(
            offsetSeconds: offsetSamplesTotal / sampleRate,
            offsetSamples: Int(offsetSamplesTotal.rounded()),
            sampleRate: sampleRate,
            correlation: residual.waveformCoherence,
            gainMatchDB: gainMatchDB,
            overlapSeconds: overlapSeconds,
            isConfident: residual.waveformCoherence >= Thresholds.minimumWaveformCoherence,
            speedRatio: nil
        )

        return Measurement(
            alignment: alignment,
            residual: residual,
            relationship: classify(alignment: alignment, residual: residual)
        )
    }

    // MARK: - Classification

    /// Read the relationship off the residual's level *and shape*.
    ///
    /// Level alone cannot separate a 128 kbps re-encode from a different
    /// master — their overall residual-to-signal ratios overlap. The
    /// discriminator is where the residual sits: a codec leaves the low and
    /// mid bands almost untouched and dumps everything at the top, while a
    /// different master differs across the whole spectrum.
    static func classify(alignment: PairAlignmentResult, residual: ResidualMetrics) -> PairRelationship {
        guard alignment.overlapSeconds >= Thresholds.minimumOverlapSeconds else { return .indeterminate }
        guard alignment.isConfident else { return .differentRecording }
        if residual.residualToSignalDB <= Thresholds.identicalResidualDB { return .identical }

        // Two conditions, and both are needed. The tilt test catches a remaster
        // that happens to null well (a gentle EQ shift); the residual test
        // catches a difference too large to be codec noise even when the
        // long-term balance is untouched (a different take, an edit).
        if residual.midBandTiltDifferenceDB <= Thresholds.sameMasterTiltDB,
           residual.midBandResidualToSignalDB <= Thresholds.sameMasterMidBandResidualDB {
            return .sameMaster
        }
        return .differentMaster
    }

    // MARK: - Residual measurement

    /// Residual metrics for a set of aligned probe windows, combined by median.
    ///
    /// Median rather than pooled energy: a single window that lands on a fade,
    /// an edit, or a quiet passage can differ wildly from the rest, and pooling
    /// lets it set the verdict for the whole pair.
    static func residualMetrics(
        reference: [[Float]],
        aligned: [[Float]],
        gain: Float,
        sampleRate: Double
    ) -> ResidualMetrics {
        let perWindow = zip(reference, aligned).map { a, b in
            windowResidual(reference: a, aligned: b, gain: gain, sampleRate: sampleRate)
        }
        guard !perWindow.isEmpty else { return .unavailable }

        return ResidualMetrics(
            residualToSignalDB: median(perWindow.map(\.residualToSignalDB)),
            bandResidualToSignalDB: medianVector(perWindow.map(\.bandResidualToSignalDB)),
            midBandResidualToSignalDB: median(perWindow.map(\.midBandResidualToSignalDB)),
            bandLevelDifferenceDB: medianVector(perWindow.map(\.bandLevelDifferenceDB)),
            midBandTiltDifferenceDB: median(perWindow.map(\.midBandTiltDifferenceDB)),
            highFrequencyEnergyFraction: median(perWindow.map(\.highFrequencyEnergyFraction)),
            residualCrestFactorDB: median(perWindow.map(\.residualCrestFactorDB)),
            waveformCoherence: median(perWindow.map(\.waveformCoherence))
        )
    }

    /// Residual metrics for a single aligned probe window.
    static func windowResidual(
        reference: [Float],
        aligned: [Float],
        gain: Float,
        sampleRate: Double
    ) -> ResidualMetrics {
        var scaled = [Float](repeating: 0, count: aligned.count)
        var scale = gain
        vDSP_vsmul(aligned, 1, &scale, &scaled, 1, vDSP_Length(aligned.count))

        var difference = [Float](repeating: 0, count: reference.count)
        vDSP_vsub(scaled, 1, reference, 1, &difference, 1, vDSP_Length(reference.count))

        var dot: Float = 0
        vDSP_dotpr(reference, 1, scaled, 1, &dot, vDSP_Length(reference.count))
        let referenceEnergy = sumOfSquares(reference)
        let scaledEnergy = sumOfSquares(scaled)
        let residualEnergy = sumOfSquares(difference)

        let coherenceDenominator = (referenceEnergy * scaledEnergy).squareRoot()
        let coherence = coherenceDenominator > 0
            ? max(0, min(1, Double(dot) / coherenceDenominator))
            : 0

        // Crest factor separates a stationary difference (codec quantization
        // noise, hiss) from an impulsive one (clicks, pre-echo).
        var peak: Float = 0
        vDSP_maxmgv(difference, 1, &peak, vDSP_Length(difference.count))
        let residualRMS = difference.isEmpty ? 0 : (residualEnergy / Double(difference.count)).squareRoot()
        let crestFactorDB = residualRMS > 0 ? 20 * log10(Double(peak) / residualRMS) : 0

        let referenceSpectrum = averagePowerSpectrum([reference], sampleRate: sampleRate)
        let residualSpectrum = averagePowerSpectrum([difference], sampleRate: sampleRate)
        let candidateSpectrum = averagePowerSpectrum([scaled], sampleRate: sampleRate)

        let bandDifferences = bandRatiosDB(
            residual: candidateSpectrum, reference: referenceSpectrum, sampleRate: sampleRate
        )
        let tilt = zip(SpectrumMetrics.bandDefinitions, bandDifferences)
            .filter { Thresholds.midBandRangeHz.contains($0.0.range.lowerBound) }
            .map { abs($0.1) }
            .max() ?? 0

        return ResidualMetrics(
            residualToSignalDB: ratioDB(residualEnergy, referenceEnergy),
            bandResidualToSignalDB: bandRatiosDB(
                residual: residualSpectrum, reference: referenceSpectrum, sampleRate: sampleRate
            ),
            midBandResidualToSignalDB: rangeRatioDB(
                residual: residualSpectrum,
                reference: referenceSpectrum,
                sampleRate: sampleRate,
                range: Thresholds.midBandRangeHz
            ),
            bandLevelDifferenceDB: bandDifferences,
            midBandTiltDifferenceDB: tilt,
            highFrequencyEnergyFraction: highFrequencyFraction(residualSpectrum, sampleRate: sampleRate),
            residualCrestFactorDB: crestFactorDB,
            waveformCoherence: coherence
        )
    }

    // MARK: - Spectral helpers

    /// Welch-style average power spectrum over every span, using the same FFT
    /// size and window as the single-file engine so levels are comparable.
    static func averagePowerSpectrum(_ spans: [[Float]], sampleRate: Double, fftSize: Int = 8_192) -> [Float] {
        let fft = RealFFT(size: fftSize)
        var accumulator = [Float](repeating: 0, count: fft.binCount)
        var frames = 0
        let hop = fftSize / 2

        for span in spans {
            guard span.count >= fftSize else { continue }
            var start = 0
            while start + fftSize <= span.count {
                span.withUnsafeBufferPointer { pointer in
                    let slice = UnsafeBufferPointer(rebasing: pointer[start ..< start + fftSize])
                    fft.accumulatePowerSpectrum(of: slice, into: &accumulator)
                }
                frames += 1
                start += hop
            }
        }

        guard frames > 0 else { return accumulator }
        var scale = Float(1) / Float(frames)
        vDSP_vsmul(accumulator, 1, &scale, &accumulator, 1, vDSP_Length(accumulator.count))
        return accumulator
    }

    /// Residual power over reference power, per band, in dB. 0 dB means the
    /// difference is as loud as the signal in that band.
    static func bandRatiosDB(residual: [Float], reference: [Float], sampleRate: Double) -> [Double] {
        guard !residual.isEmpty, residual.count == reference.count else { return [] }
        let binWidth = sampleRate / Double(residual.count * 2)

        return SpectrumMetrics.bandDefinitions.map { definition in
            let low = max(Int(definition.range.lowerBound / binWidth), 0)
            let high = min(Int(definition.range.upperBound / binWidth), residual.count)
            guard low < high else { return 0 }
            let residualPower = residual[low ..< high].reduce(Double(0)) { $0 + Double($1) }
            let referencePower = reference[low ..< high].reduce(Double(0)) { $0 + Double($1) }
            return ratioDB(residualPower, referencePower)
        }
    }

    /// Residual power over reference power across one frequency range, in dB.
    /// Energy-weighted, so loud parts of the range dominate — unlike a
    /// per-band maximum, which lets a near-empty band veto the verdict.
    static func rangeRatioDB(
        residual: [Float],
        reference: [Float],
        sampleRate: Double,
        range: ClosedRange<Double>
    ) -> Double {
        guard !residual.isEmpty, residual.count == reference.count else { return 0 }
        let binWidth = sampleRate / Double(residual.count * 2)
        let low = max(Int(range.lowerBound / binWidth), 0)
        let high = min(Int(range.upperBound / binWidth), residual.count)
        guard low < high else { return 0 }
        let residualPower = residual[low ..< high].reduce(Double(0)) { $0 + Double($1) }
        let referencePower = reference[low ..< high].reduce(Double(0)) { $0 + Double($1) }
        return ratioDB(residualPower, referencePower)
    }

    /// Share of residual energy above 10 kHz. Near 1 is the codec-bandwidth
    /// signature: the files agree everywhere except the top octaves.
    static func highFrequencyFraction(_ spectrum: [Float], sampleRate: Double, aboveHz: Double = 10_000) -> Double {
        guard !spectrum.isEmpty else { return 0 }
        let binWidth = sampleRate / Double(spectrum.count * 2)
        let split = min(max(Int(aboveHz / binWidth), 0), spectrum.count)
        let total = spectrum.reduce(Double(0)) { $0 + Double($1) }
        guard total > 0 else { return 0 }
        let high = spectrum[split...].reduce(Double(0)) { $0 + Double($1) }
        return high / total
    }

    // MARK: - Fine alignment

    /// Sub-sample refinement from the slope of the cross-spectrum's phase.
    ///
    /// A pure delay is a linear phase ramp, so fitting that ramp recovers the
    /// delay exactly, where interpolating a correlation peak only approximates
    /// it. Accuracy matters more than it looks: 0.02 samples of residual error
    /// already puts a floor around −35 dB on the null at 10 kHz, which is the
    /// same order as the codec differences we are trying to measure.
    ///
    /// `candidate` must already be integer-aligned. Returns the extra shift to
    /// add, in samples.
    static func phaseSlopeShift(
        reference: [Float],
        candidate: [Float],
        sampleRate: Double,
        fftSize: Int = 8_192
    ) -> Double {
        guard reference.count == candidate.count, reference.count >= fftSize else { return 0 }
        let fft = ComplexSpectrumFFT(size: fftSize)
        let bins = fftSize / 2
        let binWidth = sampleRate / Double(fftSize)

        // Below 100 Hz the phase is dominated by rumble and DC offsets; above
        // a quarter of the rate the ramp could wrap past ±π for a delay of nearly one
        // sample, which would poison the fit.
        let lowBin = max(1, Int(100 / binWidth))
        let highBin = min(bins, Int((sampleRate / 4) / binWidth))
        guard lowBin < highBin else { return 0 }

        var referenceReal = [Float](repeating: 0, count: bins)
        var referenceImag = [Float](repeating: 0, count: bins)
        var candidateReal = [Float](repeating: 0, count: bins)
        var candidateImag = [Float](repeating: 0, count: bins)

        var numerator = 0.0
        var denominator = 0.0
        var start = 0
        while start + fftSize <= reference.count {
            reference.withUnsafeBufferPointer { pointer in
                let slice = UnsafeBufferPointer(rebasing: pointer[start ..< start + fftSize])
                fft.transform(slice, intoReal: &referenceReal, imaginary: &referenceImag)
            }
            candidate.withUnsafeBufferPointer { pointer in
                let slice = UnsafeBufferPointer(rebasing: pointer[start ..< start + fftSize])
                fft.transform(slice, intoReal: &candidateReal, imaginary: &candidateImag)
            }

            for bin in lowBin ..< highBin {
                // reference · conj(candidate)
                let real = Double(referenceReal[bin] * candidateReal[bin] + referenceImag[bin] * candidateImag[bin])
                let imaginary = Double(referenceImag[bin] * candidateReal[bin] - referenceReal[bin] * candidateImag[bin])
                let magnitude = (real * real + imaginary * imaginary).squareRoot()
                guard magnitude > 1e-12 else { continue }
                let phase = atan2(imaginary, real)
                // Weight by cross-spectrum magnitude so loud, well-correlated
                // bins decide the fit and quiet noisy ones barely count.
                let omega = 2 * Double.pi * Double(bin) * binWidth / sampleRate
                numerator += magnitude * phase * omega
                denominator += magnitude * omega * omega
            }
            start += fftSize / 2
        }

        guard denominator > 0 else { return 0 }
        return numerator / denominator
    }

    // MARK: - Decoding

    struct FileProbe {
        let sampleRate: Double
        let totalFrames: AVAudioFramePosition
    }

    static func probeInfo(_ url: URL) -> FileProbe? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        return FileProbe(sampleRate: rate, totalFrames: file.length)
    }

    /// Decode a frame range to mono at the file's own rate. Out-of-range
    /// frames read as silence so probe windows never need clamping.
    static func decodeMono(url: URL, startFrame: AVAudioFramePosition, frameCount: Int) -> [Float]? {
        guard
            frameCount > 0,
            let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        else { return nil }

        var output = [Float](repeating: 0, count: frameCount)
        let readStart = max(startFrame, 0)
        let readEnd = min(startFrame + AVAudioFramePosition(frameCount), file.length)
        guard readEnd > readStart else { return output }

        let readCount = AVAudioFrameCount(readEnd - readStart)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: readCount) else {
            return nil
        }
        file.framePosition = readStart
        do { try file.read(into: buffer, frameCount: readCount) } catch { return nil }

        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return output }
        let channelCount = Int(buffer.format.channelCount)
        let destinationOffset = Int(readStart - startFrame)

        for frame in 0 ..< frames {
            var sum: Float = 0
            for channel in 0 ..< channelCount { sum += channels[channel][frame] }
            output[destinationOffset + frame] = sum / Float(channelCount)
        }
        return output
    }

    /// Decode a range expressed in the *target* rate's frames, resampling when
    /// the source runs at a different rate.
    ///
    /// Rate conversion puts a floor under how deep the null can go, so a
    /// cross-rate pair is inherently a weaker comparison than a same-rate one.
    /// `AVAudioConverter` is used rather than a hand-rolled kernel because its
    /// error stays well below the codec differences being measured; any
    /// constant latency it introduces is absorbed by the fine alignment that
    /// runs afterwards.
    static func decodeMonoResampled(
        url: URL,
        startFrameAtTargetRate: Int,
        frameCountAtTargetRate: Int,
        targetSampleRate: Double,
        sourceSampleRate: Double
    ) -> [Float]? {
        if abs(targetSampleRate - sourceSampleRate) < 0.01 {
            return decodeMono(
                url: url,
                startFrame: AVAudioFramePosition(startFrameAtTargetRate),
                frameCount: frameCountAtTargetRate
            )
        }

        let ratio = sourceSampleRate / targetSampleRate
        // Decode a little extra either side to cover converter priming.
        let padding = 4_096
        let sourceStart = Int((Double(startFrameAtTargetRate) * ratio).rounded(.down)) - padding
        let sourceCount = Int((Double(frameCountAtTargetRate) * ratio).rounded(.up)) + 2 * padding
        guard
            let source = decodeMono(
                url: url, startFrame: AVAudioFramePosition(sourceStart), frameCount: sourceCount
            ),
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sourceSampleRate, channels: 1, interleaved: false
            ),
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
            let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(source.count)
            )
        else { return nil }

        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        inputBuffer.frameLength = AVAudioFrameCount(source.count)
        source.withUnsafeBufferPointer { pointer in
            inputBuffer.floatChannelData?[0].update(from: pointer.baseAddress!, count: source.count)
        }

        let outputCapacity = AVAudioFrameCount(frameCountAtTargetRate + 4 * padding)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity)
        else { return nil }

        nonisolated(unsafe) var supplied = false
        var conversionError: NSError?
        // The input block runs synchronously inside `convert`, so handing it
        // the buffer is safe despite `AVAudioPCMBuffer` not being Sendable.
        nonisolated(unsafe) let pending = inputBuffer
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return pending
        }
        guard conversionError == nil, let channel = outputBuffer.floatChannelData else { return nil }

        // Skip the padding we asked for, then take exactly what was requested.
        let skip = Int((Double(padding) / ratio).rounded())
        let available = Int(outputBuffer.frameLength) - skip
        guard available > 0 else { return nil }

        var output = [Float](repeating: 0, count: frameCountAtTargetRate)
        let copyCount = min(available, frameCountAtTargetRate)
        output.withUnsafeMutableBufferPointer { destination in
            destination.baseAddress!.update(from: channel[0] + skip, count: copyCount)
        }
        return output
    }

    // MARK: - Geometry

    /// The span of A that both files cover, given B's offset.
    static func overlapRange(aFrames: Int, bFrames: Int, offset: Int) -> Range<Int> {
        let start = max(0, -offset)
        let end = min(aFrames, bFrames - offset)
        guard end > start else { return 0 ..< 0 }
        return start ..< end
    }

    /// Evenly spaced probe window starts inside the overlap, inset from both
    /// edges.
    ///
    /// The inset is not cosmetic. Track intros and outros are where fades,
    /// silence and codec padding live, and a probe window landing there
    /// measures the encoders' disagreement about near-silence rather than
    /// anything about the music — on one real pair the leading window read
    /// −1.9 dB while every other window read −20 dB or better.
    static func probeWindowStarts(in overlap: Range<Int>) -> [Int] {
        let span = overlap.count
        guard span >= probeWindowSamples else { return [] }

        // Keep the inset proportional so short overlaps still yield a window.
        let inset = min(span / 10, probeWindowSamples)
        let insetSpan = span - 2 * inset
        let lowerBound = insetSpan >= probeWindowSamples ? overlap.lowerBound + inset : overlap.lowerBound
        let usable = (insetSpan >= probeWindowSamples ? insetSpan : span) - probeWindowSamples

        let count = min(probeWindowCount, max(1, usable / probeWindowSamples + 1))
        guard count > 1 else { return [lowerBound + usable / 2] }
        return (0 ..< count).map { index in
            lowerBound + usable * index / (count - 1)
        }
    }

    /// Median of `values`, or 0 when empty. Used to combine per-window results:
    /// pooling their energy instead lets a single anomalous window (a quiet
    /// passage, an edit point) set the verdict for the whole pair.
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    /// Element-wise median across equal-length vectors.
    static func medianVector(_ vectors: [[Double]]) -> [Double] {
        guard let width = vectors.first?.count, vectors.allSatisfy({ $0.count == width }) else { return [] }
        return (0 ..< width).map { index in median(vectors.map { $0[index] }) }
    }

    // MARK: - Small math

    static func sumOfSquares(_ values: [Float]) -> Double {
        var result: Float = 0
        vDSP_svesq(values, 1, &result, vDSP_Length(values.count))
        return Double(result)
    }

    static func ratioDB(_ numerator: Double, _ denominator: Double) -> Double {
        guard denominator > 0 else { return 0 }
        guard numerator > 0 else { return -200 }
        return 10 * log10(numerator / denominator)
    }
}

// MARK: - Correlation FFT

/// Unwindowed packed real FFT with an inverse pass, used only for GCC-PHAT.
/// The analysis engine's `RealFFT`/`ComplexSpectrumFFT` both apply a Hann
/// window and drop the inverse, which correlation cannot use.
final class CorrelationFFT {
    private let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    init(size: Int) {
        precondition(size > 0 && (size & (size - 1)) == 0, "FFT size must be a power of two")
        self.size = size
        log2n = vDSP_Length(log2(Double(size)).rounded())
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Phase-transform-weighted circular cross-correlation. Index `k` holds the
    /// score for `candidate` running `k` samples late relative to `reference`,
    /// with negative lags wrapped to the top of the array.
    func phatCorrelation(_ reference: [Float], _ candidate: [Float]) -> [Float]? {
        guard reference.count == size, candidate.count == size else { return nil }
        let half = size / 2

        var referenceReal = [Float](repeating: 0, count: half)
        var referenceImag = [Float](repeating: 0, count: half)
        var candidateReal = [Float](repeating: 0, count: half)
        var candidateImag = [Float](repeating: 0, count: half)

        forward(reference, real: &referenceReal, imaginary: &referenceImag)
        forward(candidate, real: &candidateReal, imaginary: &candidateImag)

        // Cross-power spectrum reference · conj(candidate), normalized to unit
        // magnitude so every bin votes equally on the delay.
        var productReal = [Float](repeating: 0, count: half)
        var productImag = [Float](repeating: 0, count: half)
        for bin in 0 ..< half {
            let realPart = referenceReal[bin] * candidateReal[bin] + referenceImag[bin] * candidateImag[bin]
            let imagPart = referenceImag[bin] * candidateReal[bin] - referenceReal[bin] * candidateImag[bin]
            let magnitude = (realPart * realPart + imagPart * imagPart).squareRoot()
            if magnitude > 1e-12 {
                productReal[bin] = realPart / magnitude
                productImag[bin] = imagPart / magnitude
            }
        }
        // Bin 0 carries DC (and, in packed form, Nyquist); neither says
        // anything about delay.
        productReal[0] = 0
        productImag[0] = 0

        var output = [Float](repeating: 0, count: size)
        inverse(real: &productReal, imaginary: &productImag, into: &output)
        return output
    }

    private func forward(_ input: [Float], real: inout [Float], imaginary: inout [Float]) {
        real.withUnsafeMutableBufferPointer { realPtr in
            imaginary.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                input.withUnsafeBufferPointer { source in
                    source.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
    }

    /// Integer-sample shift to hand to `spectralShift` so `candidate` lines up
    /// with `reference`. Phase-transform weighted, so broadband musical content
    /// contributes equally and the peak stays sharp.
    ///
    /// Only the integer part is trusted here: PHAT's peak is near-delta, which
    /// makes it excellent at finding the right sample and poor at interpolating
    /// between samples. `PairAligner.phaseSlopeShift` does the sub-sample half.
    func phatShift(reference: [Float], candidate: [Float]) -> Int? {
        guard reference.count == size, candidate.count == size else { return nil }
        guard let correlation = phatCorrelation(reference, candidate) else { return nil }

        var bestIndex = 0
        var bestValue = -Float.greatestFiniteMagnitude
        for index in 0 ..< size where correlation[index] > bestValue {
            bestValue = correlation[index]
            bestIndex = index
        }
        // A circular correlation puts negative lags at the top of the array.
        let wrapped = bestIndex > size / 2 ? bestIndex - size : bestIndex
        // The peak reports where the candidate sits relative to the reference;
        // the shift needed is the opposite — how far to advance it.
        return -wrapped
    }

    /// Circularly shift `input` by `shift` samples so that
    /// `output[i] == input[i + shift]`, fractions included.
    ///
    /// A delay is a linear phase ramp, so applying it in the frequency domain
    /// is exact — no interpolation kernel, no passband droop near Nyquist.
    /// That matters here because a windowed-sinc kernel's error piles up in
    /// the top octave, which is the one octave this feature cannot afford to
    /// get wrong: it is where codec cutoffs live.
    ///
    /// The shift wraps, so callers must discard a guard region at both ends.
    func spectralShift(_ input: [Float], by shift: Double) -> [Float]? {
        guard input.count == size else { return nil }
        let half = size / 2

        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        forward(input, real: &real, imaginary: &imaginary)

        // Packed format hides Nyquist in imagp[0], where the generic rotation
        // below cannot reach it. It still has to move: the Nyquist component
        // of a real signal is x·cos(πn), so delaying by s scales it by
        // cos(πs) — exactly ±1 for integer shifts, and an attenuation for
        // fractional ones, which is the only real-valued answer available.
        // Leaving it alone puts a visible error on every odd-sample shift.
        let nyquist = imaginary[0] * Float(cos(.pi * shift))
        imaginary[0] = 0

        for bin in 1 ..< half {
            let angle = 2 * Double.pi * Double(bin) * shift / Double(size)
            let cosine = Float(cos(angle))
            let sine = Float(sin(angle))
            let re = real[bin]
            let im = imaginary[bin]
            real[bin] = re * cosine - im * sine
            imaginary[bin] = re * sine + im * cosine
        }
        imaginary[0] = nyquist

        var output = [Float](repeating: 0, count: size)
        inverse(real: &real, imaginary: &imaginary, into: &output)
        // vDSP's real round trip returns 2N times the input.
        var scale = Float(1) / Float(2 * size)
        vDSP_vsmul(output, 1, &scale, &output, 1, vDSP_Length(size))
        return output
    }

    private func inverse(real: inout [Float], imaginary: inout [Float], into output: inout [Float]) {
        real.withUnsafeMutableBufferPointer { realPtr in
            imaginary.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                output.withUnsafeMutableBufferPointer { destination in
                    destination.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(size / 2))
                    }
                }
            }
        }
        // Unscaled; callers that need amplitude apply the 1/(2N) themselves.
    }
}
