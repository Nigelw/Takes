import Accelerate
import Foundation

/// Streaming DSP building blocks for the analysis engine.
///
/// Every accumulator here is fed sequential chunks by
/// `AudioAnalysisEngine` so files never need to be resident in memory,
/// then produces its metric in `finalize()`.

// MARK: - Real FFT helper

/// Thin wrapper over vDSP's packed real FFT that produces a normalized power
/// spectrum. Power is normalized by the window's coherent gain so a
/// full-scale sine reads ~0 dB regardless of FFT size.
final class RealFFT {
    let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var realp: [Float]
    private var imagp: [Float]
    private let window: [Float]
    private let powerScale: Float
    private var windowed: [Float]

    init(size: Int) {
        precondition(size > 0 && (size & (size - 1)) == 0, "FFT size must be a power of two")
        self.size = size
        log2n = vDSP_Length(log2(Double(size)).rounded())
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        realp = [Float](repeating: 0, count: size / 2)
        imagp = [Float](repeating: 0, count: size / 2)
        windowed = [Float](repeating: 0, count: size)
        var hann = [Float](repeating: 0, count: size)
        vDSP_hann_window(&hann, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
        window = hann
        let windowSum = vDSP.sum(hann)
        // fft_zrip returns 2× the mathematical DFT; a real sine's spectral
        // line is amplitude/2 · windowSum. Combined amplitude normalization
        // is 2 / (2 · windowSum) ⇒ power normalization is its square.
        let amplitudeScale = 1 / windowSum
        powerScale = amplitudeScale * amplitudeScale
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    var binCount: Int { size / 2 }

    /// Windows `input` (must contain exactly `size` samples) and accumulates
    /// its normalized power spectrum into `accumulator` (`size/2` bins).
    func accumulatePowerSpectrum(of input: UnsafeBufferPointer<Float>, into accumulator: inout [Float]) {
        precondition(input.count == size && accumulator.count == binCount)
        vDSP.multiply(input, window, result: &windowed)

        realp.withUnsafeMutableBufferPointer { realPtr in
            imagp.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { source in
                    source.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                // Packed format stores Nyquist in imagp[0]; drop it so bin 0
                // is pure DC and every bin is realp²+imagp².
                imagPtr[0] = 0

                accumulator.withUnsafeMutableBufferPointer { accPtr in
                    var scale = powerScale
                    // acc += (re² + im²) · scale
                    vDSP_zvmags(&split, 1, &windowed, 1, vDSP_Length(size / 2))
                    vDSP_vsma(windowed, 1, &scale, accPtr.baseAddress!, 1, accPtr.baseAddress!, 1, vDSP_Length(size / 2))
                }
            }
        }
    }
}

// MARK: - Loudness (ITU-R BS.1770-4)

/// Integrated loudness with K-weighting and two-stage gating, plus sample
/// peak, overall RMS, and clipped-run counting.
final class LoudnessMeter {
    private let sampleRate: Double
    private let channelCount: Int
    private var filters: [vDSP.Biquad<Float>]
    private var filtered: [Float] = []

    /// 100 ms sub-blocks; a 400 ms gating block is 4 consecutive sub-blocks,
    /// which yields the standard 75% overlap when stepped one sub-block.
    private let subBlockLength: Int
    private var currentSubBlockSumSquares: Double = 0
    private var currentSubBlockFill = 0
    private var subBlockMeanSquares: [Double] = []

    private var totalSumSquares: Double = 0
    private var totalSampleCount = 0
    private(set) var samplePeak: Float = 0
    private(set) var clippedRunCount = 0
    private var clipRunLengths: [Int]

    init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        subBlockLength = Int((0.1 * sampleRate).rounded())
        clipRunLengths = [Int](repeating: 0, count: channelCount)

        // BS.1770-4 K-weighting: high-shelf ("head") stage then high-pass
        // (RLB) stage, with coefficients derived for the actual sample rate.
        let shelf = Self.headShelfCoefficients(sampleRate: sampleRate)
        let highPass = Self.rlbHighPassCoefficients(sampleRate: sampleRate)
        let biquad = vDSP.Biquad<Float>(
            coefficients: shelf + highPass,
            channelCount: 1,
            sectionCount: 2,
            ofType: Float.self
        )!
        filters = [vDSP.Biquad<Float>](repeating: biquad, count: channelCount)
    }

    /// Feed one chunk of deinterleaved channel data. All channels must have
    /// equal length and arrive in a consistent order across calls.
    func process(channels: [UnsafeBufferPointer<Float>]) {
        precondition(channels.count == channelCount)
        guard let frameCount = channels.first?.count, frameCount > 0 else { return }

        // Peak, clipping, and overall RMS come from the unweighted signal.
        for (channelIndex, channel) in channels.enumerated() {
            samplePeak = max(samplePeak, vDSP.maximumMagnitude(channel))
            totalSumSquares += Double(vDSP.sumOfSquares(channel))
            countClipRuns(in: channel, channelIndex: channelIndex)
        }
        totalSampleCount += frameCount * channelCount

        // K-weighted energy, summed across channels (weight 1.0 for the
        // mono/stereo layouts Takes loads), accumulated into 100 ms blocks.
        var weightedSquareSum = [Float](repeating: 0, count: frameCount)
        for (channelIndex, channel) in channels.enumerated() {
            filtered = filters[channelIndex].apply(input: Array(channel))
            vDSP.multiply(filtered, filtered, result: &filtered)
            vDSP.add(weightedSquareSum, filtered, result: &weightedSquareSum)
        }

        var offset = 0
        while offset < frameCount {
            let take = min(subBlockLength - currentSubBlockFill, frameCount - offset)
            weightedSquareSum.withUnsafeBufferPointer { pointer in
                currentSubBlockSumSquares += Double(
                    vDSP.sum(UnsafeBufferPointer(rebasing: pointer[offset ..< offset + take]))
                )
            }
            currentSubBlockFill += take
            offset += take
            if currentSubBlockFill == subBlockLength {
                subBlockMeanSquares.append(currentSubBlockSumSquares / Double(subBlockLength))
                currentSubBlockSumSquares = 0
                currentSubBlockFill = 0
            }
        }
    }

    struct Result {
        let integratedLUFS: Double?
        let samplePeakDBFS: Double
        let overallRMSDBFS: Double
        let clippedRunCount: Int
    }

    func finalize() -> Result {
        let peakDB = samplePeak > 0 ? 20 * log10(Double(samplePeak)) : -Double.infinity
        let rms = totalSampleCount > 0 ? totalSumSquares / Double(totalSampleCount) : 0
        let rmsDB = rms > 0 ? 10 * log10(rms) : -Double.infinity

        return Result(
            integratedLUFS: integratedLoudness(),
            samplePeakDBFS: peakDB,
            overallRMSDBFS: rmsDB,
            clippedRunCount: clippedRunCount
        )
    }

    private func integratedLoudness() -> Double? {
        // 400 ms gating blocks stepped by 100 ms.
        guard subBlockMeanSquares.count >= 4 else { return nil }
        var blockMeanSquares: [Double] = []
        blockMeanSquares.reserveCapacity(subBlockMeanSquares.count - 3)
        for start in 0 ... (subBlockMeanSquares.count - 4) {
            blockMeanSquares.append(subBlockMeanSquares[start ..< start + 4].reduce(0, +) / 4)
        }

        func loudness(ofMeanSquare meanSquare: Double) -> Double {
            -0.691 + 10 * log10(max(meanSquare, .leastNormalMagnitude))
        }

        // Absolute gate at -70 LUFS.
        let absoluteGated = blockMeanSquares.filter { loudness(ofMeanSquare: $0) > -70 }
        guard !absoluteGated.isEmpty else { return nil }

        // Relative gate 10 LU below the absolute-gated mean.
        let relativeThreshold = loudness(
            ofMeanSquare: absoluteGated.reduce(0, +) / Double(absoluteGated.count)
        ) - 10
        let relativeGated = absoluteGated.filter { loudness(ofMeanSquare: $0) > relativeThreshold }
        guard !relativeGated.isEmpty else { return nil }

        return loudness(ofMeanSquare: relativeGated.reduce(0, +) / Double(relativeGated.count))
    }

    private func countClipRuns(in channel: UnsafeBufferPointer<Float>, channelIndex: Int) {
        // ≥3 consecutive samples at |x| ≥ 0.999 counts as one clipped run.
        let threshold: Float = 0.999
        var runLength = clipRunLengths[channelIndex]
        for sample in channel {
            if abs(sample) >= threshold {
                runLength += 1
                if runLength == 3 { clippedRunCount += 1 }
            } else {
                runLength = 0
            }
        }
        clipRunLengths[channelIndex] = runLength
    }

    // MARK: BS.1770 coefficient derivation (sample-rate independent form)

    private static func headShelfCoefficients(sampleRate: Double) -> [Double] {
        let db = 3.999843853973347
        let f0 = 1681.974450955533
        let q = 0.7071752369554196
        let k = tan(.pi * f0 / sampleRate)
        let vh = pow(10, db / 20)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        return [
            (vh + vb * k / q + k * k) / a0,
            2 * (k * k - vh) / a0,
            (vh - vb * k / q + k * k) / a0,
            2 * (k * k - 1) / a0,
            (1 - k / q + k * k) / a0,
        ]
    }

    private static func rlbHighPassCoefficients(sampleRate: Double) -> [Double] {
        let f0 = 38.13547087602444
        let q = 0.5003270373238773
        let k = tan(.pi * f0 / sampleRate)
        let a0 = 1 + k / q + k * k
        return [
            1,
            -2,
            1,
            2 * (k * k - 1) / a0,
            (1 - k / q + k * k) / a0,
        ]
    }
}

// MARK: - Welch average spectrum

/// Long-term average power spectrum (Welch's method: Hann window, 50%
/// overlap) over a mono mix of the file.
final class WelchSpectrumAccumulator {
    let fftSize: Int
    private let hop: Int
    private let fft: RealFFT
    private let sampleRate: Double
    private var pending: [Float] = []
    private var powerAccumulator: [Float]
    private var windowCount = 0

    init(sampleRate: Double, fftSize: Int = 8192) {
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        hop = fftSize / 2
        fft = RealFFT(size: fftSize)
        powerAccumulator = [Float](repeating: 0, count: fftSize / 2)
    }

    func process(monoSamples: [Float]) {
        pending.append(contentsOf: monoSamples)
        var start = 0
        while pending.count - start >= fftSize {
            pending.withUnsafeBufferPointer { pointer in
                fft.accumulatePowerSpectrum(
                    of: UnsafeBufferPointer(rebasing: pointer[start ..< start + fftSize]),
                    into: &powerAccumulator
                )
            }
            windowCount += 1
            start += hop
        }
        pending.removeFirst(start)
    }

    func finalize() -> AverageSpectrum {
        var magnitudesDB = [Float](repeating: -160, count: powerAccumulator.count)
        guard windowCount > 0 else {
            return AverageSpectrum(binWidthHz: sampleRate / Double(fftSize), magnitudesDB: magnitudesDB)
        }
        var meanPower = vDSP.divide(powerAccumulator, Float(windowCount))
        // Clamp before log so digital silence stays finite (-160 dB floor).
        vDSP.clip(meanPower, to: 1e-16 ... Float.greatestFiniteMagnitude, result: &meanPower)
        vDSP.convert(power: meanPower, toDecibels: &magnitudesDB, zeroReference: 1)
        return AverageSpectrum(binWidthHz: sampleRate / Double(fftSize), magnitudesDB: magnitudesDB)
    }
}

// MARK: - Noise floor / quiet-frame analysis

/// Keeps the quietest fixed-size blocks of the mono mix and measures their
/// level and spectral flatness — broadband flat noise in the quiet gaps is
/// the signature of an analog (tape/vinyl) source or noisy chain.
final class QuietFrameCollector {
    private let blockSize: Int
    private let keepCount: Int
    private let sampleRate: Double
    private var pending: [Float] = []
    /// (rms, samples) for the quietest blocks seen, unsorted.
    private var quietest: [(rms: Float, samples: [Float])] = []
    private var currentMaxRMS: Float = .greatestFiniteMagnitude
    private var totalBlockCount = 0

    init(sampleRate: Double, blockSize: Int = 8192, keepCount: Int = 32) {
        self.sampleRate = sampleRate
        self.blockSize = blockSize
        self.keepCount = keepCount
    }

    func process(monoSamples: [Float]) {
        pending.append(contentsOf: monoSamples)
        var start = 0
        while pending.count - start >= blockSize {
            let block = Array(pending[start ..< start + blockSize])
            start += blockSize
            totalBlockCount += 1
            let rms = vDSP.rootMeanSquare(block)
            if quietest.count < keepCount {
                quietest.append((rms, block))
                currentMaxRMS = quietest.map(\.rms).max() ?? 0
            } else if rms < currentMaxRMS {
                if let worst = quietest.indices.max(by: { quietest[$0].rms < quietest[$1].rms }) {
                    quietest[worst] = (rms, block)
                    currentMaxRMS = quietest.map(\.rms).max() ?? 0
                }
            }
        }
        pending.removeFirst(start)
    }

    func finalize() -> NoiseFloorMetrics {
        guard !quietest.isEmpty else {
            return NoiseFloorMetrics(noiseFloorDBFS: -.infinity, quietFrameSpectralFlatness: 0)
        }

        // Use only the quietest tenth of the file (bounded by the reservoir)
        // so short files or sparse gaps aren't polluted by musical content.
        let sorted = quietest.sorted { $0.rms < $1.rms }
        let useCount = max(min(4, sorted.count), min(sorted.count, totalBlockCount / 10))
        let used = Array(sorted.prefix(useCount))

        let meanSquare = used.map { Double($0.rms) * Double($0.rms) }.reduce(0, +) / Double(used.count)
        let floorDB = meanSquare > 0 ? 10 * log10(meanSquare) : -Double.infinity

        // Flatness over the hiss-relevant range, from the averaged spectrum
        // of the non-silent quiet blocks.
        let fft = RealFFT(size: blockSize)
        var power = [Float](repeating: 0, count: blockSize / 2)
        var analyzed = 0
        for entry in used where entry.rms > 0 {
            entry.samples.withUnsafeBufferPointer { fft.accumulatePowerSpectrum(of: $0, into: &power) }
            analyzed += 1
        }
        guard analyzed > 0 else {
            return NoiseFloorMetrics(noiseFloorDBFS: floorDB, quietFrameSpectralFlatness: 0)
        }

        let binWidth = sampleRate / Double(blockSize)
        let low = max(Int(200 / binWidth), 1)
        let high = min(Int(16000 / binWidth), power.count - 1)
        var logSum = 0.0
        var linearSum = 0.0
        for bin in low ..< high {
            let value = Double(max(power[bin], 1e-20))
            logSum += log(value)
            linearSum += value
        }
        let count = Double(high - low)
        let flatness = exp(logSum / count) / (linearSum / count)

        return NoiseFloorMetrics(noiseFloorDBFS: floorDB, quietFrameSpectralFlatness: flatness)
    }
}

// MARK: - Spectrum-derived metrics

enum SpectrumMetrics {
    static let bandDefinitions: [(name: String, range: ClosedRange<Double>)] = [
        ("Sub", 20 ... 60),
        ("Bass", 60 ... 250),
        ("Low Mid", 250 ... 500),
        ("Mid", 500 ... 2_000),
        ("High Mid", 2_000 ... 4_000),
        ("Treble", 4_000 ... 10_000),
        ("Air", 10_000 ... 22_000),
    ]

    static func tonalBalance(from spectrum: AverageSpectrum) -> TonalBalanceMetrics {
        let binWidth = spectrum.binWidthHz
        let power = spectrum.magnitudesDB.map { Double(pow(10, $0 / 10)) }
        let totalPower = max(power.reduce(0, +), .leastNormalMagnitude)

        var bands: [TonalBalanceMetrics.Band] = []
        for definition in bandDefinitions {
            let low = max(Int(definition.range.lowerBound / binWidth), 0)
            let high = min(Int(definition.range.upperBound / binWidth), power.count)
            guard low < high else { continue }
            let bandPower = power[low ..< high].reduce(0, +)
            bands.append(
                TonalBalanceMetrics.Band(
                    name: definition.name,
                    rangeHz: definition.range,
                    relativeDB: 10 * log10(max(bandPower, .leastNormalMagnitude) / totalPower)
                )
            )
        }

        var weightedFrequency = 0.0
        for (bin, binPower) in power.enumerated() {
            weightedFrequency += Double(bin) * binWidth * binPower
        }
        let centroid = weightedFrequency / totalPower

        var cumulative = 0.0
        var rolloff = Double(power.count) * binWidth
        for (bin, binPower) in power.enumerated() {
            cumulative += binPower
            if cumulative >= totalPower * 0.95 {
                rolloff = Double(bin) * binWidth
                break
            }
        }

        return TonalBalanceMetrics(bands: bands, spectralCentroidHz: centroid, rolloff95Hz: rolloff)
    }

    /// Finds a codec-style lowpass shelf: the highest frequency whose
    /// (median-smoothed) level stays near the mid-band reference, with the
    /// spectrum above it dropping hard and staying down.
    static func bandwidth(from spectrum: AverageSpectrum, sampleRate: Double) -> BandwidthMetrics {
        let nyquist = sampleRate / 2
        let binWidth = spectrum.binWidthHz
        let db = medianSmoothed(spectrum.magnitudesDB, radius: 4)
        let binCount = db.count

        func bin(at frequency: Double) -> Int {
            min(max(Int(frequency / binWidth), 0), binCount - 1)
        }

        // Mid-band reference: median level between 1 and 8 kHz.
        let referenceBins = Array(db[bin(at: 1_000) ... bin(at: min(8_000, nyquist * 0.8))])
        let reference = Double(median(of: referenceBins))
        let contentThreshold = Float(reference - 30)

        // Highest bin still within 30 dB of the mid-band level.
        guard let lastContentBin = (bin(at: 200) ..< binCount).reversed().first(where: { db[$0] >= contentThreshold }) else {
            return BandwidthMetrics(nyquistHz: nyquist, detectedCutoffHz: nil, shelfDepthDB: nil, confidence: .low)
        }
        let cutoffHz = Double(lastContentBin) * binWidth

        // Content reaching ~96% of Nyquist means no shelf worth reporting.
        if cutoffHz >= nyquist * 0.96 {
            return BandwidthMetrics(nyquistHz: nyquist, detectedCutoffHz: nil, shelfDepthDB: nil, confidence: .high)
        }

        // Depth: how far the spectrum sits below the reference in the region
        // above the cutoff (skipping the transition band).
        let shelfStart = min(lastContentBin + Int(500 / binWidth), binCount - 1)
        let shelfEnd = min(shelfStart + Int(3_000 / binWidth), binCount)
        var depth: Double?
        if shelfStart < shelfEnd {
            let shelfLevel = Double(db[shelfStart ..< shelfEnd].reduce(0, +)) / Double(shelfEnd - shelfStart)
            depth = reference - shelfLevel
        }

        // Sharpness: drop across 1 kHz above the cutoff. A codec brick-wall
        // falls tens of dB there; natural masters slope gently.
        let probe = min(lastContentBin + Int(1_000 / binWidth), binCount - 1)
        let dropPerKHz = Double(db[lastContentBin] - db[probe])

        let confidence: BandwidthMetrics.Confidence
        if dropPerKHz >= 25, (depth ?? 0) >= 30 {
            confidence = .high
        } else if dropPerKHz >= 12, (depth ?? 0) >= 18 {
            confidence = .medium
        } else {
            confidence = .low
        }

        return BandwidthMetrics(
            nyquistHz: nyquist,
            detectedCutoffHz: cutoffHz,
            shelfDepthDB: depth,
            confidence: confidence
        )
    }

    private static func medianSmoothed(_ values: [Float], radius: Int) -> [Float] {
        guard values.count > 2 * radius + 1 else { return values }
        var result = values
        for index in values.indices {
            let low = max(index - radius, 0)
            let high = min(index + radius, values.count - 1)
            result[index] = median(of: Array(values[low ... high]))
        }
        return result
    }

    private static func median(of values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
