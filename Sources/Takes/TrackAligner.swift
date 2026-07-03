import Accelerate
import AVFoundation
import Foundation

/// Computes track offsets that line up similar audio content across the
/// session ("auto-align").
///
/// Each file is decoded once and reduced to a 1 kHz *onset-novelty envelope*:
/// the per-millisecond rise in log energy. A window of the anchor track's
/// envelope around the playhead is cross-correlated (FFT-based, normalized)
/// against every other track's full envelope, and the best-scoring lag becomes
/// that track's new offset. Correlating novelty rather than raw audio makes
/// the match robust to gain, EQ, and codec differences between takes of the
/// same material, and the fixed 1 ms hop keeps results comparable across
/// files with different sample rates.
enum TrackAligner {
    /// Envelope hop: one envelope sample per millisecond of audio. Also the
    /// resolution of the computed offsets, matching the offset field's units.
    static let hopSeconds: TimeInterval = 0.001

    /// Half-width of the reference window taken around the playhead (±15 s).
    static let referenceHalfWidthHops = 15_000

    /// Fraction of the anchor's total novelty a reference window must contain
    /// to be considered usable; quieter windows (silence, lead-in) are widened
    /// until they clear this bar or span the whole track.
    static let minimumWindowEnergyFraction: Float = 0.01

    /// Shortest envelope worth correlating (1 s). Guards against degenerate
    /// matches on tiny overlaps.
    static let minimumCorrelationHops = 1_000

    /// Half-width of the *coarse* moving average (±25 ms) used to find the
    /// candidate lag. Per-millisecond energy fluctuations of the same material
    /// differ between codecs and masterings (MP3 vs FLAC of one song
    /// correlates at only ~0.14 raw); the shared musical structure emerges at
    /// tens of milliseconds. The peak of the smoothed correlation still sits
    /// at the true lag.
    static let coarseSmoothingRadiusHops = 25

    /// Half-width of the *fine* moving average (±5 ms) used to validate and
    /// refine the coarse lag. All music shares coarse dynamic shape (intro
    /// swells, applause), so a coarse peak alone can pair unrelated tracks;
    /// at ±5 ms only genuinely shared event timing survives.
    static let fineSmoothingRadiusHops = 5

    /// How far (± hops) around the coarse peak the fine pass searches. Wide
    /// enough to absorb the peak shifting between smoothing scales and small
    /// speed differences across a long window.
    static let fineSearchRadiusHops = 75

    /// Half-width of the fine validation slice (±2.5 s). Real pairs of the
    /// same song often differ in speed by ~0.2% (analog transfers), which
    /// smears the true lag by ~60 ms across a 30 s window — enough to destroy
    /// fine-scale correlation over the whole window even for a genuine match.
    /// Across 5 s the smear is ~10 ms, within the fine smoothing's tolerance.
    static let fineValidationHalfWidthHops = 2_500

    /// Floor on the coarse correlation peak. Calibrated on real pairs: the
    /// same song across codecs/masterings peaks at 0.30–0.60; this floor only
    /// weeds out matches so weak that peak contrast alone can't be trusted.
    static let minimumConfidence: Float = 0.25

    /// Minimum ratio of the coarse peak to the best peak elsewhere (outside
    /// ±`secondaryPeakExclusionHops`). This is the real accept/reject signal:
    /// a genuine alignment has one distinct peak (same-song pairs measure
    /// 1.46–2.35), while unrelated audio's "best" lag is just the tallest of
    /// many similar flukes (unrelated songs and different live performances
    /// of one song measure 1.01–1.31).
    static let minimumPeakContrast: Float = 1.4

    /// Neighborhood around the primary peak ignored when hunting for the
    /// secondary peak (±1 s) — wide enough to clear the primary's own skirt.
    static let secondaryPeakExclusionHops = 1_000

    /// Largest offset the offset field accepts (± seconds); results are
    /// clamped to it.
    static let maximumOffsetSeconds: TimeInterval = 300

    // MARK: Tempo-search pass tuning

    /// Range of the speed-ratio search: ±6% covers analog transfer and
    /// mastering speed discrepancies (the well-known ones run 2–6%).
    static let tempoSearchMaximumDeviation = 0.06

    /// Grid step of the ratio search (0.25%). Coarse-smoothed whole-track
    /// correlation tolerates roughly this much ratio error before the peak
    /// collapses, so the grid can't miss a real match between points.
    static let tempoSearchStepDeviation = 0.0025

    /// Successive refinement steps around the best grid ratio, sharpening the
    /// detected ratio (and with it the offset) beyond the grid resolution.
    static let tempoRefinementStepDeviations: [Double] = [0.001, 0.000_5]

    /// Contrast gate for the tempo pass, stricter than `minimumPeakContrast`:
    /// searching ~50 candidate ratios inflates the fluke background (unrelated
    /// songs reach contrast ~1.5 over the search; a genuine tempo match
    /// measures ~2.6).
    static let minimumTempoPeakContrast: Float = 1.7

    /// Frames decoded per pass, mirroring `WaveformSource`.
    private static let framesPerChunk: AVAudioFrameCount = 65_536

    /// Floor added to mean-square energy before the log, so silence maps to a
    /// finite value instead of -inf.
    private static let energyFloor: Float = 1e-10

    struct Source: Equatable, Sendable {
        let id: SessionTrack.ID
        let url: URL
        let displayName: String
        let currentOffsetSeconds: TimeInterval
    }

    struct Request: Sendable {
        /// The track that stays put; everything else is moved to match it.
        let anchor: Source
        /// Playhead position within the anchor's *file* (not the timeline),
        /// in seconds. The reference window is centered here.
        let anchorPlayheadFileTime: TimeInterval
        let others: [Source]
    }

    struct Result: Equatable, Sendable {
        let trackID: SessionTrack.ID
        let displayName: String
        /// The offset that aligns this track with the anchor, or `nil` when
        /// no confident match was found.
        let newOffsetSeconds: TimeInterval?
        /// Peak normalized-correlation score (-1...1), for diagnostics.
        let score: Float
    }

    /// A candidate alignment: `reference[0]` lines up with `target[lag]`.
    struct Match: Equatable {
        let lag: Int
        /// Coarse correlation peak height (-1...1).
        let score: Float
        /// Ratio of the coarse peak to the best peak elsewhere. See
        /// `minimumPeakContrast`.
        let contrast: Float
    }

    /// A correlation peak: `reference[0]` lines up with `target[lag]`.
    struct Peak: Equatable {
        let lag: Int
        let score: Float
    }

    /// Whether a match clears both confidence gates (peak height and peak
    /// contrast).
    static func isConfident(_ match: Match) -> Bool {
        match.score >= minimumConfidence && match.contrast >= minimumPeakContrast
    }

    /// Align every `others` track to the anchor. Blocking (decodes all files);
    /// call from a background task. Tracks are processed concurrently.
    static func align(_ request: Request) async -> [Result] {
        func failures(score: Float = 0) -> [Result] {
            request.others.map {
                Result(trackID: $0.id, displayName: $0.displayName, newOffsetSeconds: nil, score: score)
            }
        }

        guard let anchorNovelty = noveltyEnvelope(url: request.anchor.url) else {
            return failures()
        }

        let center = Int((request.anchorPlayheadFileTime / hopSeconds).rounded())
        let window = referenceWindow(novelty: anchorNovelty, centerIndex: center)
        guard !window.isEmpty else { return failures() }

        let anchorOffset = request.anchor.currentOffsetSeconds

        return await withTaskGroup(of: Result.self) { group in
            for other in request.others {
                group.addTask {
                    alignTrack(
                        other,
                        anchorNovelty: anchorNovelty,
                        window: window,
                        anchorOffsetSeconds: anchorOffset
                    )
                }
            }
            var results: [Result] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    private static func alignTrack(
        _ source: Source,
        anchorNovelty: [Float],
        window: Range<Int>,
        anchorOffsetSeconds: TimeInterval
    ) -> Result {
        guard let novelty = noveltyEnvelope(url: source.url) else {
            return Result(trackID: source.id, displayName: source.displayName, newOffsetSeconds: nil, score: 0)
        }

        var windowStartIndex = window.lowerBound
        var match = bestAlignment(reference: Array(anchorNovelty[window]), target: novelty)

        // The playhead window can genuinely fail on matching tracks — e.g. the
        // two files have different intros and the playhead is parked at the
        // start — so before reporting no match, try the whole track.
        let windowedIsConfident = match.map(isConfident) ?? false
        if !windowedIsConfident, window.count < anchorNovelty.count,
           let fullMatch = bestAlignment(reference: anchorNovelty, target: novelty),
           isConfident(fullMatch) {
            match = fullMatch
            windowStartIndex = 0
        }

        guard let match, isConfident(match) else {
            return Result(
                trackID: source.id,
                displayName: source.displayName,
                newOffsetSeconds: nil,
                score: match?.score ?? 0
            )
        }

        let offset = alignedOffsetSeconds(
            anchorOffsetSeconds: anchorOffsetSeconds,
            windowStartIndex: windowStartIndex,
            matchLag: match.lag
        )
        return Result(trackID: source.id, displayName: source.displayName, newOffsetSeconds: offset, score: match.score)
    }

    /// The offset that plays `target[matchLag]` at the same global time as the
    /// anchor's `windowStartIndex`, rounded to the offset field's 1 ms grid and
    /// clamped to its range.
    static func alignedOffsetSeconds(
        anchorOffsetSeconds: TimeInterval,
        windowStartIndex: Int,
        matchLag: Int
    ) -> TimeInterval {
        let raw = anchorOffsetSeconds + Double(windowStartIndex - matchLag) * hopSeconds
        let rounded = (raw * 1000).rounded() / 1000
        return min(max(rounded, -maximumOffsetSeconds), maximumOffsetSeconds)
    }

    // MARK: - Tempo-search pass

    struct TempoResult: Equatable, Sendable {
        let trackID: SessionTrack.ID
        let displayName: String
        /// The offset that aligns this track with the anchor *at the playhead*,
        /// or `nil` when no confident match was found at any candidate ratio.
        let newOffsetSeconds: TimeInterval?
        /// Detected speed ratio (this track's musical time per unit of anchor
        /// musical time): > 1 means this track plays slower than the anchor.
        /// `nil` when no confident match was found.
        let speedRatio: Double?
        /// Coarse correlation peak at the best ratio, for diagnostics.
        let score: Float
    }

    /// Second-pass alignment for tracks the plain pass rejected: search over
    /// candidate speed ratios, correlating the *whole* time-stretched anchor
    /// envelope against each track (a playhead window can't integrate enough
    /// evidence once the ratio is also unknown). Far slower than `align` —
    /// ~50 whole-track correlations per track — hence `onProgress` (0...1),
    /// called from a background thread.
    ///
    /// A detected ratio is reported, not corrected: playback stays at normal
    /// speed, so the returned offset aligns exactly at the playhead and
    /// drifts away from it at `|ratio − 1|` seconds per second.
    static func alignTempo(
        _ request: Request,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async -> [TempoResult] {
        func failure(_ source: Source) -> TempoResult {
            TempoResult(trackID: source.id, displayName: source.displayName, newOffsetSeconds: nil, speedRatio: nil, score: 0)
        }

        guard let anchorNovelty = noveltyEnvelope(url: request.anchor.url) else {
            onProgress(1)
            return request.others.map(failure)
        }

        let gridDeviations = Array(stride(
            from: -tempoSearchMaximumDeviation,
            through: tempoSearchMaximumDeviation,
            by: tempoSearchStepDeviation
        ))
        let stepsPerTrack = gridDeviations.count + tempoRefinementStepDeviations.count * 2
        let totalSteps = max(1, stepsPerTrack * request.others.count)
        var completedSteps = 0

        // Tracks run serially so progress is monotonic and memory stays flat;
        // the per-ratio FFTs inside already use the machine's vector units.
        var results: [TempoResult] = []
        for (trackIndex, other) in request.others.enumerated() {
            let result = tempoAlignTrack(
                other,
                anchorNovelty: anchorNovelty,
                anchorPlayheadFileTime: request.anchorPlayheadFileTime,
                anchorOffsetSeconds: request.anchor.currentOffsetSeconds,
                gridDeviations: gridDeviations
            ) {
                completedSteps += 1
                onProgress(Double(completedSteps) / Double(totalSteps))
            }
            results.append(result)
            // Realign progress at track boundaries so early-outs (unreadable
            // file, no refinement) don't leave the bar short.
            completedSteps = stepsPerTrack * (trackIndex + 1)
            onProgress(Double(completedSteps) / Double(totalSteps))
        }
        return results
    }

    private static func tempoAlignTrack(
        _ source: Source,
        anchorNovelty: [Float],
        anchorPlayheadFileTime: TimeInterval,
        anchorOffsetSeconds: TimeInterval,
        gridDeviations: [Double],
        step: () -> Void
    ) -> TempoResult {
        guard let novelty = noveltyEnvelope(url: source.url) else {
            return TempoResult(trackID: source.id, displayName: source.displayName, newOffsetSeconds: nil, speedRatio: nil, score: 0)
        }

        func evaluate(_ ratio: Double) -> Match? {
            defer { step() }
            return bestAlignment(reference: stretchedEnvelope(anchorNovelty, ratio: ratio), target: novelty)
        }

        var best: (ratio: Double, match: Match)?
        for deviation in gridDeviations {
            let ratio = 1 + deviation
            if let match = evaluate(ratio), best == nil || match.score > best!.match.score {
                best = (ratio, match)
            }
        }

        // Sharpen the winning ratio: at ±0.125% residual error the offset can
        // still be off by >100 ms far from the track center.
        if let coarse = best {
            var current = coarse
            for refinementStep in tempoRefinementStepDeviations {
                for direction in [-1.0, 1.0] {
                    if let match = evaluate(current.ratio + direction * refinementStep),
                       match.score > current.match.score {
                        current = (current.ratio + direction * refinementStep, match)
                    }
                }
            }
            best = current
        }

        guard let best, isTempoConfident(best.match) else {
            return TempoResult(
                trackID: source.id,
                displayName: source.displayName,
                newOffsetSeconds: nil,
                speedRatio: nil,
                score: best?.match.score ?? 0
            )
        }

        let offset = tempoAlignedOffsetSeconds(
            anchorOffsetSeconds: anchorOffsetSeconds,
            anchorPlayheadFileTime: anchorPlayheadFileTime,
            speedRatio: best.ratio,
            matchLag: best.match.lag
        )
        return TempoResult(
            trackID: source.id,
            displayName: source.displayName,
            newOffsetSeconds: offset,
            speedRatio: best.ratio,
            score: best.match.score
        )
    }

    /// Whether a tempo-search match clears the (stricter) confidence gates.
    static func isTempoConfident(_ match: Match) -> Bool {
        match.score >= minimumConfidence && match.contrast >= minimumTempoPeakContrast
    }

    /// The offset that aligns the track with the anchor at the playhead, given
    /// a whole-track match of the `speedRatio`-stretched anchor.
    ///
    /// Anchor file time `t` corresponds to track file time
    /// `matchLag·hop + t·ratio`; equating global times at `t = playhead`
    /// gives `offset = anchorOffset + playhead·(1 − ratio) − matchLag·hop`.
    static func tempoAlignedOffsetSeconds(
        anchorOffsetSeconds: TimeInterval,
        anchorPlayheadFileTime: TimeInterval,
        speedRatio: Double,
        matchLag: Int
    ) -> TimeInterval {
        let raw = anchorOffsetSeconds
            + anchorPlayheadFileTime * (1 - speedRatio)
            - Double(matchLag) * hopSeconds
        let rounded = (raw * 1000).rounded() / 1000
        return min(max(rounded, -maximumOffsetSeconds), maximumOffsetSeconds)
    }

    /// Linear-interpolation time stretch of an envelope: `ratio > 1`
    /// lengthens it. Element `i` of the result samples the input at `i/ratio`.
    static func stretchedEnvelope(_ values: [Float], ratio: Double) -> [Float] {
        guard ratio > 0, !values.isEmpty else { return values }

        let count = Int(Double(values.count) * ratio)
        var stretched = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let source = Double(index) / ratio
            let lower = Int(source)
            guard lower + 1 < values.count else { break }
            let fraction = Float(source - Double(lower))
            stretched[index] = values[lower] * (1 - fraction) + values[lower + 1] * fraction
        }
        return stretched
    }

    // MARK: - Reference window

    /// The slice of the anchor's novelty to correlate: ±`halfWidth` around the
    /// playhead, widened (×2 per step) while it holds too little of the
    /// track's novelty to be a reliable fingerprint, capped at the whole track.
    static func referenceWindow(
        novelty: [Float],
        centerIndex: Int,
        halfWidth: Int = referenceHalfWidthHops
    ) -> Range<Int> {
        let count = novelty.count
        guard count > 0 else { return 0..<0 }

        var total: Float = 0
        vDSP_sve(novelty, 1, &total, vDSP_Length(count))
        guard total > 0 else { return 0..<count }

        let center = min(max(centerIndex, 0), count - 1)
        var half = max(1, halfWidth)
        while true {
            let lower = max(0, center - half)
            let upper = min(count, center + half)
            if lower == 0 && upper == count { return 0..<count }

            var windowSum: Float = 0
            novelty.withUnsafeBufferPointer { buffer in
                vDSP_sve(buffer.baseAddress! + lower, 1, &windowSum, vDSP_Length(upper - lower))
            }
            if windowSum >= minimumWindowEnergyFraction * total {
                return lower..<upper
            }
            half *= 2
        }
    }

    // MARK: - Correlation

    /// The lag that best aligns raw novelty `reference` against `target`.
    ///
    /// Two-scale: the candidate lag and the confidence signals (peak score
    /// and peak contrast — gate with `isConfident`) come from normalized
    /// cross-correlation of the coarsely smoothed signals, robust to
    /// codec/mastering differences; the lag is then refined on a short,
    /// finely smoothed slice. `lag` may be negative (reference
    /// starts before the target does). Returns `nil` when either signal is too
    /// short or has no variation to correlate.
    static func bestAlignment(reference: [Float], target: [Float]) -> Match? {
        let coarseMinOverlap = max(minimumCorrelationHops, min(reference.count, target.count) / 2)
        guard reference.count >= coarseMinOverlap, target.count >= coarseMinOverlap else { return nil }

        guard let scan = correlationScan(
            reference: smoothed(reference, radius: coarseSmoothingRadiusHops),
            target: smoothed(target, radius: coarseSmoothingRadiusHops)
        ), let primary = scan.bestPeak(minOverlap: coarseMinOverlap) else { return nil }

        // Peak contrast: how much the primary stands out over the best
        // candidate elsewhere. A dominated landscape (contrast near 1) means
        // the "peak" is just the tallest of many flukes.
        let secondary = scan.bestPeak(
            minOverlap: coarseMinOverlap,
            excluding: (primary.lag - secondaryPeakExclusionHops)...(primary.lag + secondaryPeakExclusionHops)
        )
        let contrast: Float
        if let secondary, secondary.score > 0 {
            contrast = primary.score / secondary.score
        } else {
            contrast = .infinity
        }

        // Refine the lag on a short, finely smoothed slice (see
        // `fineValidationHalfWidthHops`): over the whole window a slight speed
        // difference between the files smears fine timing, so only a short
        // span can pin the lag precisely — and pinning it at the slice puts
        // the alignment at (or near) the playhead the user is listening at.
        // Confidence comes from the coarse peak and its contrast, not from
        // the fine score: fine-scale energy detail barely survives codec and
        // mastering differences even for genuine matches.
        let slice = fineValidationSlice(reference)
        let fineReference = Array(smoothed(reference, radius: fineSmoothingRadiusHops)[slice])
        let fineTarget = smoothed(target, radius: fineSmoothingRadiusHops)
        let expectedLag = primary.lag + slice.lowerBound
        let fineMinOverlap = max(
            minimumCorrelationHops,
            min(fineReference.count, fineTarget.count) / 2
        )
        let fine = bestNCCLag(
            reference: fineReference,
            target: fineTarget,
            minOverlap: fineMinOverlap,
            lagRange: (expectedLag - fineSearchRadiusHops)...(expectedLag + fineSearchRadiusHops)
        )

        let lag = fine.map { $0.lag - slice.lowerBound } ?? primary.lag
        return Match(lag: lag, score: primary.score, contrast: contrast)
    }

    /// The sub-range of the reference window the fine pass correlates: the
    /// central ±`fineValidationHalfWidthHops` when it carries a reasonable
    /// share of the window's novelty (the playhead sits at the window center),
    /// otherwise the highest-energy slice of the same length — a quiet
    /// passage can't pin a lag.
    static func fineValidationSlice(_ novelty: [Float]) -> Range<Int> {
        let length = min(novelty.count, 2 * fineValidationHalfWidthHops)
        guard length > 0, length < novelty.count else { return 0..<novelty.count }

        var prefix = [Double](repeating: 0, count: novelty.count + 1)
        for (index, value) in novelty.enumerated() {
            prefix[index + 1] = prefix[index] + Double(value)
        }
        func sliceSum(startingAt start: Int) -> Double {
            prefix[start + length] - prefix[start]
        }

        // Central slice, if it holds at least a quarter of the window's
        // average novelty density.
        let centralStart = (novelty.count - length) / 2
        let averageDensitySum = prefix[novelty.count] * Double(length) / Double(novelty.count)
        if sliceSum(startingAt: centralStart) >= averageDensitySum * 0.25 {
            return centralStart..<(centralStart + length)
        }

        var bestStart = 0
        var bestSum = -Double.infinity
        for start in 0...(novelty.count - length) {
            let sum = sliceSum(startingAt: start)
            if sum > bestSum {
                bestSum = sum
                bestStart = start
            }
        }
        return bestStart..<(bestStart + length)
    }

    /// Peak of the zero-mean normalized cross-correlation, optionally
    /// restricted to `lagRange`.
    static func bestNCCLag(
        reference: [Float],
        target: [Float],
        minOverlap: Int,
        lagRange: ClosedRange<Int>? = nil
    ) -> Peak? {
        correlationScan(reference: reference, target: target)?
            .bestPeak(minOverlap: minOverlap, lagRange: lagRange)
    }

    /// Cross-correlation of two mean-centered signals, precomputed (one FFT)
    /// so multiple peak scans — primary, then secondary with the primary's
    /// neighborhood excluded — reuse the same dot products.
    private struct CorrelationScan {
        let dots: [Float]
        let referenceSquares: [Double]
        let targetSquares: [Double]
        let referenceCount: Int
        let targetCount: Int

        /// Highest-scoring lag. Overlaps shorter than `minOverlap` are not
        /// considered, so a sliver of coincidental match at an extreme lag
        /// can't win; lags in `excluding` are skipped.
        func bestPeak(
            minOverlap: Int,
            lagRange: ClosedRange<Int>? = nil,
            excluding: ClosedRange<Int>? = nil
        ) -> Peak? {
            var lowerLag = minOverlap - referenceCount
            var upperLag = targetCount - minOverlap
            if let lagRange {
                lowerLag = max(lowerLag, lagRange.lowerBound)
                upperLag = min(upperLag, lagRange.upperBound)
            }
            guard lowerLag <= upperLag else { return nil }

            let wrap = dots.count
            var bestLag: Int?
            var bestScore: Float = 0
            for lag in lowerLag...upperLag {
                if let excluding, excluding.contains(lag) { continue }
                let refLower = max(0, -lag)
                let refUpper = min(referenceCount, targetCount - lag)

                let referenceEnergy = referenceSquares[refUpper] - referenceSquares[refLower]
                let targetEnergy = targetSquares[refUpper + lag] - targetSquares[refLower + lag]
                let denominator = (referenceEnergy * targetEnergy).squareRoot()
                guard denominator > 0 else { continue }

                let dot = dots[(lag + wrap) % wrap]
                let score = Float(Double(dot) / denominator)
                if bestLag == nil || score > bestScore {
                    bestLag = lag
                    bestScore = score
                }
            }

            guard let bestLag, bestScore.isFinite else { return nil }
            return Peak(lag: bestLag, score: bestScore)
        }
    }

    private static func correlationScan(reference: [Float], target: [Float]) -> CorrelationScan? {
        let centeredReference = meanCentered(reference)
        let centeredTarget = meanCentered(target)
        guard let dots = circularCorrelation(reference: centeredReference, target: centeredTarget) else {
            return nil
        }

        // Prefix sums of squares (in Double: these run to millions of terms)
        // give each candidate overlap's norms in O(1).
        return CorrelationScan(
            dots: dots,
            referenceSquares: prefixSumsOfSquares(centeredReference),
            targetSquares: prefixSumsOfSquares(centeredTarget),
            referenceCount: reference.count,
            targetCount: target.count
        )
    }

    private static func meanCentered(_ values: [Float]) -> [Float] {
        var mean: Float = 0
        vDSP_meanv(values, 1, &mean, vDSP_Length(values.count))
        var negated = -mean
        var centered = [Float](repeating: 0, count: values.count)
        vDSP_vsadd(values, 1, &negated, &centered, 1, vDSP_Length(values.count))
        return centered
    }

    private static func prefixSumsOfSquares(_ values: [Float]) -> [Double] {
        var sums = [Double](repeating: 0, count: values.count + 1)
        var running = 0.0
        for (index, value) in values.enumerated() {
            running += Double(value) * Double(value)
            sums[index + 1] = running
        }
        return sums
    }

    /// Raw correlation dot products for every circular lag, via FFT:
    /// `result[(lag + L) % L] == Σ reference[i]·target[i + lag]`. Both inputs
    /// are zero-padded to a power of two ≥ their combined length, so no lag in
    /// `-(m-1)...(n-1)` aliases.
    private static func circularCorrelation(reference: [Float], target: [Float]) -> [Float]? {
        let m = reference.count
        let n = target.count
        var length = 8
        while length < m + n { length <<= 1 }

        guard
            let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(length), .FORWARD),
            let inverse = vDSP_DFT_zop_CreateSetup(forward, vDSP_Length(length), .INVERSE)
        else { return nil }
        defer {
            vDSP_DFT_DestroySetup(forward)
            vDSP_DFT_DestroySetup(inverse)
        }

        // One flat allocation carved into the 8 real/imaginary planes the
        // transform pipeline needs (input, reference/target spectra, output).
        let planes = 8
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: length * planes)
        defer { storage.deallocate() }
        storage.initialize(repeating: 0, count: length * planes)

        let inputRe = storage
        let inputIm = storage + length
        let referenceRe = storage + length * 2
        let referenceIm = storage + length * 3
        let targetRe = storage + length * 4
        let targetIm = storage + length * 5
        let outputRe = storage + length * 6
        let outputIm = storage + length * 7

        reference.withUnsafeBufferPointer { inputRe.update(from: $0.baseAddress!, count: m) }
        vDSP_DFT_Execute(forward, inputRe, inputIm, referenceRe, referenceIm)

        inputRe.update(repeating: 0, count: length)
        target.withUnsafeBufferPointer { inputRe.update(from: $0.baseAddress!, count: n) }
        vDSP_DFT_Execute(forward, inputRe, inputIm, targetRe, targetIm)

        // Cross-spectrum conj(reference) × target, written over the input
        // planes (no longer needed), then back to time domain.
        var referenceSplit = DSPSplitComplex(realp: referenceRe, imagp: referenceIm)
        var targetSplit = DSPSplitComplex(realp: targetRe, imagp: targetIm)
        var crossSplit = DSPSplitComplex(realp: inputRe, imagp: inputIm)
        vDSP_zvmul(&referenceSplit, 1, &targetSplit, 1, &crossSplit, 1, vDSP_Length(length), -1)

        vDSP_DFT_Execute(inverse, inputRe, inputIm, outputRe, outputIm)

        // The unnormalized forward/inverse pair scales by `length`.
        var scale = 1 / Float(length)
        var result = [Float](repeating: 0, count: length)
        vDSP_vsmul(outputRe, 1, &scale, &result, 1, vDSP_Length(length))
        return result
    }

    // MARK: - Envelope

    /// Decode `url` and reduce it to a raw 1 kHz onset-novelty envelope:
    /// per-millisecond mean-square energy → log energy → half-wave-rectified
    /// rise. Smoothing is applied per correlation scale in `bestAlignment`.
    /// Returns `nil` when the file can't be read.
    static func noveltyEnvelope(url: URL) -> [Float]? {
        guard
            let file = try? AVAudioFile(forReading: url),
            file.length > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: framesPerChunk)
        else { return nil }

        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        // Frames per envelope hop, fractional so hop boundaries stay on the
        // exact 1 ms grid at any sample rate (44 100 Hz → 44.1 frames).
        let framesPerHop = sampleRate * hopSeconds
        let totalFrames = file.length
        let hopCount = Int((Double(totalFrames) / framesPerHop).rounded(.up))
        guard hopCount > 1 else { return nil }

        var energy = [Float](repeating: 0, count: hopCount)

        let capacity = Int(framesPerChunk)
        // squared[i] holds the frame's energy summed across channels; scratch
        // holds one channel's squares on the way in.
        let squared = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        defer {
            squared.deallocate()
            scratch.deallocate()
        }

        var framesRead: AVAudioFramePosition = 0
        while framesRead < totalFrames {
            do {
                try file.read(into: buffer, frameCount: framesPerChunk)
            } catch {
                break
            }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let channels = buffer.floatChannelData else { break }

            let count = vDSP_Length(frames)
            let channelCount = Int(buffer.format.channelCount)
            vDSP_vsq(channels[0], 1, squared, 1, count)
            for channel in 1..<channelCount {
                vDSP_vsq(channels[channel], 1, scratch, 1, count)
                vDSP_vadd(squared, 1, scratch, 1, squared, 1, count)
            }

            // Walk the hops overlapping this chunk, mirroring
            // `WaveformSource.accumulatePeaks`.
            var frame = 0
            while frame < frames {
                let globalFrame = framesRead + AVAudioFramePosition(frame)
                var hop = Int(Double(globalFrame) / framesPerHop)
                if hop >= hopCount { hop = hopCount - 1 }

                let hopEndGlobal = AVAudioFramePosition((Double(hop + 1) * framesPerHop).rounded(.up))
                var end = Int(hopEndGlobal - framesRead)
                if end > frames { end = frames }
                if end <= frame { end = frame + 1 }

                var sum: Float = 0
                vDSP_sve(squared + frame, 1, &sum, vDSP_Length(end - frame))
                energy[hop] += sum

                frame = end
            }

            framesRead += AVAudioFramePosition(frames)
        }

        return noveltyFromEnergy(energy, framesPerHop: framesPerHop)
    }

    /// Log-compress per-hop energies and keep only their rises. Exposed for
    /// tests; `framesPerHop` only sets the mean-square scale, which the
    /// normalized correlation cancels anyway.
    static func noveltyFromEnergy(_ energy: [Float], framesPerHop: Double) -> [Float] {
        guard energy.count > 1, framesPerHop > 0 else { return [] }

        let scale = Float(1 / framesPerHop)
        var previous = log10(energy[0] * scale + energyFloor)
        var novelty = [Float](repeating: 0, count: energy.count)
        for index in 1..<energy.count {
            let current = log10(energy[index] * scale + energyFloor)
            novelty[index] = max(0, current - previous)
            previous = current
        }

        return novelty
    }

    /// Centered moving average of ±`radius` samples, via prefix sums.
    static func smoothed(_ values: [Float], radius: Int) -> [Float] {
        guard radius > 0, !values.isEmpty else { return values }

        var prefix = [Double](repeating: 0, count: values.count + 1)
        for (index, value) in values.enumerated() {
            prefix[index + 1] = prefix[index] + Double(value)
        }

        var smoothed = [Float](repeating: 0, count: values.count)
        for index in values.indices {
            let lower = max(0, index - radius)
            let upper = min(values.count, index + radius + 1)
            smoothed[index] = Float((prefix[upper] - prefix[lower]) / Double(upper - lower))
        }
        return smoothed
    }
}
