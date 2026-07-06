import Accelerate
import Foundation

/// Detects analog-source signatures (tape/vinyl) that survive gapless
/// music, where quiet-gap analysis (`QuietFrameCollector`) has nothing to
/// work with. Fed sequential deinterleaved chunks by the engine like every
/// other accumulator; produces `AnalogSourceMetrics` in `finalize()`.
///
/// Detectors (see docs/experimental-audio-analysis.md, v2 design notes):
/// - **Stationary noise floor** via minimum statistics: per-band power
///   percentile minima across the whole file. Between musical events every
///   band repeatedly falls back to the noise floor, even when the broadband
///   level never does — which is what makes this work without gaps.
/// - **Noise coherence**: within each high band, the frames near that
///   band's floor are (mostly) noise; magnitude-squared coherence between
///   channels over those frames separates decorrelated analog hiss (≈0)
///   from correlated digital residue (≈1).
/// - **Clicks/crackle**: impulsive outliers of the second-difference
///   envelope against a sliding local median — narrow, wideband, and much
///   faster than musical transients.
/// - **Rumble**: sub-30 Hz energy in the stereo difference channel
///   (vertical stylus motion); digital masters keep their deep bass mono.
/// - **Wow**: not implemented in v2 (needs a reliable partial tracker to
///   avoid confusing vibrato with transport speed error); always `nil`.
final class AnalogSourceAnalyzer {
    private let sampleRate: Double
    private let channelCount: Int

    // MARK: STFT configuration

    private let fftSize = 4096
    private let hop = 2048
    private let fft: ComplexSpectrumFFT
    /// Linear analysis bands for the floor estimate, ~500 Hz wide.
    private let bandBinRanges: [Range<Int>]
    private let bandCenters: [Double]
    /// 2 kHz-wide sub-bands over 8–16 kHz for noise coherence.
    private let coherenceBandBinRanges: [Range<Int>]
    /// Empirical correction for Hann-window noise-power bias in the summed
    /// floor estimate (validated against the corpus hiss ground truth).
    private let noiseCalibrationDB = 1.25

    // MARK: STFT state

    private var pendingLeft: [Float] = []
    private var pendingRight: [Float] = []
    private var leftReal: [Float]
    private var leftImaginary: [Float]
    private var rightReal: [Float]
    private var rightImaginary: [Float]
    /// Per-frame mean bin power for each analysis band, appended per frame.
    private var bandPowerHistory: [[Float]] = []
    /// Per-frame per-coherence-band accumulators: (crossRe, crossIm, autoL,
    /// autoR). Frame selection happens in `finalize()`.
    private var coherenceHistory: [[SIMD4<Float>]] = []
    /// Beyond this many stored frames, store every other frame — long files
    /// don't need more resolution for percentile statistics.
    private let storedFrameCap = 60_000
    private var frameToggle = false

    // MARK: Click-detection configuration/state

    /// ~0.5 ms envelope sub-frames over the second difference.
    private let clickFrameLength: Int
    /// Sliding envelope ring: ±30 ms around the evaluated frame.
    private let clickRingLength: Int
    private let clickThresholdDB: Float = 12
    /// Frames above 2× median within ±3 ms must stay under this count
    /// (clicks are narrow; drum hits are not).
    private let clickMaxWidthFrames: Int
    private let clickRefractoryFrames: Int
    private var diffCarry: (Float, Float) = (0, 0)
    private var pendingDiffMono: [Float] = []
    private var envelopeRing: [Float] = []
    private var framesSinceClick = Int.max / 2
    private var clickCount = 0
    private var clickSalienceSumDB = 0.0

    // MARK: Rumble state

    private var rumbleFilter: vDSP.Biquad<Float>
    private var rumbleSideSumSquares = 0.0
    private var totalSumSquares = 0.0
    private var totalSampleCount = 0

    init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount

        fft = ComplexSpectrumFFT(size: fftSize)
        let binWidth = sampleRate / Double(fftSize)
        let binCount = fftSize / 2

        var bands: [Range<Int>] = []
        var centers: [Double] = []
        var lowHz = 0.0
        while lowHz < sampleRate / 2 {
            let highHz = lowHz + 500
            let low = Int(lowHz / binWidth)
            let high = min(Int(highHz / binWidth), binCount)
            if low < high {
                bands.append(low ..< high)
                centers.append(lowHz + 250)
            }
            lowHz = highHz
        }
        bandBinRanges = bands
        bandCenters = centers

        var coherenceBands: [Range<Int>] = []
        var coherenceLowHz = 8_000.0
        while coherenceLowHz < min(16_000, sampleRate / 2 * 0.95) {
            let low = Int(coherenceLowHz / binWidth)
            let high = min(Int((coherenceLowHz + 2_000) / binWidth), binCount)
            if low < high { coherenceBands.append(low ..< high) }
            coherenceLowHz += 2_000
        }
        coherenceBandBinRanges = coherenceBands

        leftReal = [Float](repeating: 0, count: binCount)
        leftImaginary = [Float](repeating: 0, count: binCount)
        rightReal = [Float](repeating: 0, count: binCount)
        rightImaginary = [Float](repeating: 0, count: binCount)

        clickFrameLength = max(16, Int((sampleRate * 0.0005).rounded()))
        let framesPerMS = 0.001 * sampleRate / Double(clickFrameLength)
        clickRingLength = 2 * Int((30 * framesPerMS).rounded()) + 1
        clickMaxWidthFrames = max(2, Int((3 * framesPerMS).rounded()))
        clickRefractoryFrames = Int((50 * framesPerMS).rounded())

        // RBJ 2nd-order Butterworth lowpass at 30 Hz for the rumble band.
        let w0 = 2 * Double.pi * 30 / sampleRate
        let alpha = sin(w0) / (2 * 0.7071)
        let cosW0 = cos(w0)
        let a0 = 1 + alpha
        rumbleFilter = vDSP.Biquad(
            coefficients: [
                (1 - cosW0) / 2 / a0, (1 - cosW0) / a0, (1 - cosW0) / 2 / a0,
                -2 * cosW0 / a0, (1 - alpha) / a0,
            ],
            channelCount: 1,
            sectionCount: 1,
            ofType: Float.self
        )!
    }

    /// `channels` holds one array per channel (1 = mono, 2 = stereo), equal
    /// lengths, arriving in file order across calls.
    func process(channels: [[Float]]) {
        guard let left = channels.first, !left.isEmpty else { return }
        let right = channels.count > 1 ? channels[1] : nil

        pendingLeft.append(contentsOf: left)
        if let right { pendingRight.append(contentsOf: right) }
        processSpectralFrames(isStereo: right != nil)

        let mono: [Float]
        if let right {
            mono = vDSP.multiply(0.5, vDSP.add(left, right))
            processRumble(left: left, right: right)
        } else {
            mono = left
        }
        processClicks(monoSamples: mono)

        for channel in channels.prefix(2) {
            totalSumSquares += Double(vDSP.sumOfSquares(channel))
            totalSampleCount += channel.count
        }
    }

    func finalize() -> AnalogSourceMetrics {
        let (floorDB, flatness) = stationaryFloor()
        let minutes = Double(totalSampleCount / max(channelCount, 1)) / sampleRate / 60

        return AnalogSourceMetrics(
            stationaryNoiseFloorDBFS: floorDB,
            noiseFloorFlatness: flatness,
            highBandNoiseCoherence: noiseCoherence(),
            clickRatePerMinute: minutes > 0 ? Double(clickCount) / minutes : 0,
            meanClickSalienceDB: clickCount > 0 ? clickSalienceSumDB / Double(clickCount) : 0,
            rumbleSideLevelDB: rumbleLevel(),
            wowPeakCents: nil
        )
    }

    // MARK: - Spectral pass (floor + coherence)

    private func processSpectralFrames(isStereo: Bool) {
        while pendingLeft.count >= fftSize, !isStereo || pendingRight.count >= fftSize {
            pendingLeft.withUnsafeBufferPointer { pointer in
                fft.transform(
                    UnsafeBufferPointer(rebasing: pointer[0 ..< fftSize]),
                    intoReal: &leftReal, imaginary: &leftImaginary
                )
            }
            if isStereo {
                pendingRight.withUnsafeBufferPointer { pointer in
                    fft.transform(
                        UnsafeBufferPointer(rebasing: pointer[0 ..< fftSize]),
                        intoReal: &rightReal, imaginary: &rightImaginary
                    )
                }
            }

            frameToggle.toggle()
            if bandPowerHistory.count < storedFrameCap || frameToggle {
                storeFrame(isStereo: isStereo)
            }

            pendingLeft.removeFirst(hop)
            if isStereo { pendingRight.removeFirst(hop) }
        }
    }

    private func storeFrame(isStereo: Bool) {
        // Mono (or mid) power per analysis band, mean over the band's bins.
        var bandPowers = [Float](repeating: 0, count: bandBinRanges.count)
        for (bandIndex, range) in bandBinRanges.enumerated() {
            var power: Float = 0
            for bin in range {
                let re = isStereo ? (leftReal[bin] + rightReal[bin]) * 0.5 : leftReal[bin]
                let im = isStereo ? (leftImaginary[bin] + rightImaginary[bin]) * 0.5 : leftImaginary[bin]
                power += re * re + im * im
            }
            bandPowers[bandIndex] = power / Float(range.count)
        }
        bandPowerHistory.append(bandPowers)

        guard isStereo else { return }
        var coherence = [SIMD4<Float>](repeating: .zero, count: coherenceBandBinRanges.count)
        for (bandIndex, range) in coherenceBandBinRanges.enumerated() {
            var crossRe: Float = 0
            var crossIm: Float = 0
            var autoL: Float = 0
            var autoR: Float = 0
            for bin in range {
                let lr = leftReal[bin], li = leftImaginary[bin]
                let rr = rightReal[bin], ri = rightImaginary[bin]
                crossRe += lr * rr + li * ri
                crossIm += li * rr - lr * ri
                autoL += lr * lr + li * li
                autoR += rr * rr + ri * ri
            }
            coherence[bandIndex] = SIMD4(crossRe, crossIm, autoL, autoR)
        }
        coherenceHistory.append(coherence)
    }

    private func stationaryFloor() -> (floorDB: Double, flatness: Double) {
        guard bandPowerHistory.count >= 20 else { return (-.infinity, 0) }

        // 5th-percentile power per band = that band's stationary floor.
        var floorPerBand = [Double](repeating: 0, count: bandBinRanges.count)
        for bandIndex in bandBinRanges.indices {
            var series = bandPowerHistory.map { $0[bandIndex] }
            series.sort()
            floorPerBand[bandIndex] = Double(series[series.count / 20])
        }

        // Total floor power: per-bin floor × bin count, summed 200 Hz–18 kHz.
        // Bands that never fall to the noise floor (a sustained tone or
        // drone parks their minimum at the music level) are clipped to 10×
        // the median band floor so one occupied band can't fake a high floor.
        let occupiedBands = bandCenters.indices.filter { bandCenters[$0] > 200 && bandCenters[$0] < 18_000 }
        let medianFloor = occupiedBands.map { floorPerBand[$0] }.sorted()[occupiedBands.count / 2]
        var totalPower = 0.0
        for bandIndex in occupiedBands {
            totalPower += min(floorPerBand[bandIndex], medianFloor * 10) * Double(bandBinRanges[bandIndex].count)
        }
        let floorDB = totalPower > 0
            ? 10 * log10(totalPower) + noiseCalibrationDB
            : -Double.infinity

        // Flatness of the floor PSD over the hiss-relevant range.
        var logSum = 0.0
        var linearSum = 0.0
        var count = 0.0
        for (bandIndex, center) in bandCenters.enumerated() where center > 3_000 && center < 16_000 {
            let value = max(floorPerBand[bandIndex], 1e-20)
            logSum += log(value)
            linearSum += value
            count += 1
        }
        let flatness = count > 0 ? exp(logSum / count) / (linearSum / count) : 0

        return (floorDB, flatness)
    }

    private func noiseCoherence() -> Double {
        guard channelCount >= 2, !coherenceHistory.isEmpty else { return 1 }

        var weightedCoherence = 0.0
        var totalWeight = 0.0
        for bandIndex in coherenceBandBinRanges.indices {
            // The frames where this band sits near its floor are the ones
            // whose content is (mostly) the noise itself.
            var powers = coherenceHistory.map { $0[bandIndex].z + $0[bandIndex].w }
            powers.sort()
            let threshold = powers[powers.count / 20] * 2

            var crossRe = 0.0, crossIm = 0.0, autoL = 0.0, autoR = 0.0
            var selected = 0.0
            for frame in coherenceHistory {
                let entry = frame[bandIndex]
                guard entry.z + entry.w <= threshold, entry.z + entry.w > 0 else { continue }
                crossRe += Double(entry.x)
                crossIm += Double(entry.y)
                autoL += Double(entry.z)
                autoR += Double(entry.w)
                selected += 1
            }
            guard selected > 10, autoL > 0, autoR > 0 else { continue }
            let coherence = (crossRe * crossRe + crossIm * crossIm) / (autoL * autoR)
            weightedCoherence += coherence * selected
            totalWeight += selected
        }

        return totalWeight > 0 ? weightedCoherence / totalWeight : 1
    }

    // MARK: - Clicks

    private func processClicks(monoSamples: [Float]) {
        // Second difference emphasizes sub-millisecond discontinuities over
        // musical attacks, which rise across many samples.
        var previous = diffCarry
        pendingDiffMono.reserveCapacity(pendingDiffMono.count + monoSamples.count)
        for sample in monoSamples {
            pendingDiffMono.append(abs(sample - 2 * previous.1 + previous.0))
            previous = (previous.1, sample)
        }
        diffCarry = previous

        var start = 0
        while pendingDiffMono.count - start >= clickFrameLength {
            let frameMax = pendingDiffMono.withUnsafeBufferPointer { pointer in
                vDSP.maximum(UnsafeBufferPointer(rebasing: pointer[start ..< start + clickFrameLength]))
            }
            start += clickFrameLength
            pushEnvelope(frameMax)
        }
        pendingDiffMono.removeFirst(start)
    }

    private func pushEnvelope(_ value: Float) {
        envelopeRing.append(value)
        framesSinceClick += 1
        guard envelopeRing.count >= clickRingLength else { return }
        if envelopeRing.count > clickRingLength {
            envelopeRing.removeFirst()
        }

        let center = clickRingLength / 2
        let candidate = envelopeRing[center]
        guard framesSinceClick >= clickRefractoryFrames, candidate > 0 else { return }

        // Local max within ±2 ms, well above the ±30 ms median, and narrow.
        let localRange = max(0, center - clickMaxWidthFrames) ... min(envelopeRing.count - 1, center + clickMaxWidthFrames)
        guard candidate >= envelopeRing[localRange].max() ?? candidate else { return }

        let median = envelopeRing.sorted()[envelopeRing.count / 2]
        let floorLevel = max(median, 1e-9)
        let salience = Double(20 * log10(candidate / floorLevel))
        guard salience >= Double(clickThresholdDB) else { return }

        let wideCount = envelopeRing[localRange].filter { $0 > floorLevel * 2 }.count
        guard wideCount <= clickMaxWidthFrames else { return }

        clickCount += 1
        clickSalienceSumDB += min(salience, 60)
        framesSinceClick = 0
    }

    // MARK: - Rumble

    private func processRumble(left: [Float], right: [Float]) {
        var side = vDSP.subtract(left, right)
        vDSP.multiply(0.5, side, result: &side)
        let filtered = rumbleFilter.apply(input: side)
        rumbleSideSumSquares += Double(vDSP.sumOfSquares(filtered))
    }

    private func rumbleLevel() -> Double {
        guard channelCount >= 2, totalSampleCount > 0, rumbleSideSumSquares > 0 else { return -.infinity }
        let totalMeanSquare = totalSumSquares / Double(totalSampleCount)
        let sideMeanSquare = rumbleSideSumSquares / Double(totalSampleCount / channelCount)
        guard totalMeanSquare > 0 else { return -.infinity }
        return 10 * log10(sideMeanSquare / totalMeanSquare)
    }
}
