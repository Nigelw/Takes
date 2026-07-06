import Accelerate
import Foundation

/// Measures lossy-codec artifacts that grade encode quality beyond the
/// bandwidth shelf: pre-echo before transients, high-band "birdie" flicker,
/// and intensity-stereo HF mono-ification. Fed sequential deinterleaved
/// chunks by the engine; produces `LossyArtifactMetrics` in `finalize()`.
///
/// Detectors (see docs/experimental-audio-analysis.md, v2 design notes):
/// - Pre-echo: noise-floor rise in the ~6 ms before strong isolated attacks
///   vs the 30–80 ms pre-attack baseline (encoders without short-block
///   switching smear quantization noise ahead of transients). Only attacks
///   rising out of near-silence are measured — pre-echo is invisible
///   against sustained material.
/// - HF flicker: on/off toggling of 10–16 kHz sub-band envelopes at codec-
///   frame cadence, self-referenced against the 1–3 kHz toggle rate so
///   naturally choppy material does not read as birdies.
/// - HF stereo coherence: 10–16 kHz inter-channel coherence on the louder
///   high-band frames; ≈1 on stereo content suggests intensity stereo
///   (early-encoder tell).
final class LossyArtifactAnalyzer {
    private let sampleRate: Double
    private let channelCount: Int

    // MARK: Pre-echo configuration (frame counts derived from times)

    /// ~2.9 ms energy frames — short enough to separate the pre-echo zone
    /// from the attack itself.
    private let energyFrameLength: Int
    /// ~80 ms of history whose median is the attack-detection reference.
    private let medianWindowFrames: Int
    /// ~6 ms pre-echo zone directly before the attack…
    private let preZoneFrames: Int
    /// …skipping the frame adjacent to the attack (onset leakage).
    private let preZoneSkipFrames = 1
    /// Baseline region 30–80 ms before the attack, in frames.
    private let baselineStartFrames: Int
    private let baselineEndFrames: Int
    /// The attack frame must be the peak of the next ~17 ms so a rising
    /// noise edge just before a bigger transient is not itself an attack.
    private let lookaheadFrames: Int
    /// Minimum 100 ms between measured attacks.
    private let minAttackSeparationFrames: Int

    // MARK: Pre-echo state

    private var pendingMono: [Float] = []
    /// Sliding window of per-frame mean-square energies (linear power).
    private var frameEnergies: [Float] = []
    private var totalEnergyFrames = 0
    private var lastMeasuredAttackFrame = Int.min / 2
    private var preEchoSum = 0.0
    private var qualifyingAttackCount = 0

    // MARK: STFT configuration (flicker + coherence)

    private let fftSize = 1024
    private let hopSize = 512
    private let fft: ComplexSpectrumFFT
    /// Local median window for the toggle hysteresis, ~0.5 s of frames.
    private let toggleMedianFrames: Int
    private let highBandBinRanges: [Range<Int>]
    private let lowBandBinRanges: [Range<Int>]
    private let coherenceBins: Range<Int>

    // MARK: STFT state

    private var pendingLeft: [Float] = []
    private var pendingRight: [Float] = []
    private var leftReal: [Float]
    private var leftImaginary: [Float]
    private var rightReal: [Float]
    private var rightImaginary: [Float]
    private var highTrackers: [ToggleTracker]
    private var lowTrackers: [ToggleTracker]
    private var stftFrameCount = 0
    /// Per-frame high-band cross/auto spectral sums for coherence; frame
    /// selection (top 50% by level) happens in `finalize()`.
    private var coherenceFrames: [CoherenceFrame] = []

    init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount

        energyFrameLength = max(32, Int((sampleRate * 0.0029).rounded()))
        let frameDuration = Double(energyFrameLength) / sampleRate
        medianWindowFrames = max(8, Int((0.080 / frameDuration).rounded()))
        preZoneFrames = max(1, Int(0.006 / frameDuration))
        baselineStartFrames = max(preZoneFrames + preZoneSkipFrames + 2, Int((0.030 / frameDuration).rounded()))
        baselineEndFrames = max(baselineStartFrames + 4, max(medianWindowFrames, Int((0.080 / frameDuration).rounded())))
        lookaheadFrames = max(2, Int((0.017 / frameDuration).rounded()))
        minAttackSeparationFrames = max(1, Int((0.100 / frameDuration).rounded()))

        fft = ComplexSpectrumFFT(size: fftSize)
        toggleMedianFrames = max(9, Int((0.5 * sampleRate / Double(hopSize)).rounded()))
        let binWidth = sampleRate / Double(fftSize)
        let nyquist = sampleRate / 2
        let binCount = fftSize / 2
        highBandBinRanges = Self.subBandBinRanges(
            fromHz: 10_000, toHz: min(16_000, nyquist * 0.98), count: 8, binWidth: binWidth, binCount: binCount
        )
        lowBandBinRanges = Self.subBandBinRanges(
            fromHz: 1_000, toHz: 3_000, count: 8, binWidth: binWidth, binCount: binCount
        )
        let coherenceLow = min(Int(10_000 / binWidth), binCount)
        let coherenceHigh = min(Int(16_000 / binWidth), binCount)
        coherenceBins = coherenceLow ..< max(coherenceLow, coherenceHigh)

        leftReal = [Float](repeating: 0, count: binCount)
        leftImaginary = [Float](repeating: 0, count: binCount)
        rightReal = [Float](repeating: 0, count: binCount)
        rightImaginary = [Float](repeating: 0, count: binCount)
        highTrackers = [ToggleTracker](repeating: ToggleTracker(), count: highBandBinRanges.count)
        lowTrackers = [ToggleTracker](repeating: ToggleTracker(), count: lowBandBinRanges.count)
    }

    /// `channels` holds one array per channel (1 = mono, 2 = stereo), equal
    /// lengths, arriving in file order across calls.
    func process(channels: [[Float]]) {
        guard let first = channels.first, !first.isEmpty else { return }

        let mono: [Float]
        if channels.count > 1 {
            mono = vDSP.multiply(0.5, vDSP.add(first, channels[1]))
        } else {
            mono = first
        }
        processPreEcho(monoSamples: mono)

        pendingLeft.append(contentsOf: first)
        if channelCount > 1, channels.count > 1 {
            pendingRight.append(contentsOf: channels[1])
        }
        processSpectralFrames()
    }

    func finalize() -> LossyArtifactMetrics {
        LossyArtifactMetrics(
            preEchoScore: qualifyingAttackCount > 0 ? preEchoSum / Double(qualifyingAttackCount) : 0,
            attackCount: qualifyingAttackCount,
            highBandFlickerScore: flickerScore(),
            hfStereoCoherence: highBandCoherence()
        )
    }

    // MARK: - Pre-echo

    private func processPreEcho(monoSamples: [Float]) {
        pendingMono.append(contentsOf: monoSamples)
        var start = 0
        while pendingMono.count - start >= energyFrameLength {
            let energy = pendingMono.withUnsafeBufferPointer { pointer in
                vDSP.sumOfSquares(UnsafeBufferPointer(rebasing: pointer[start ..< start + energyFrameLength]))
            } / Float(energyFrameLength)
            appendFrameEnergy(energy)
            start += energyFrameLength
        }
        pendingMono.removeFirst(start)
    }

    private func appendFrameEnergy(_ energy: Float) {
        frameEnergies.append(energy)
        totalEnergyFrames += 1
        // Window: full baseline history before the candidate + lookahead
        // after it. The candidate under evaluation sits `lookaheadFrames`
        // behind the newest frame.
        let capacity = baselineEndFrames + lookaheadFrames + 1
        if frameEnergies.count > capacity {
            frameEnergies.removeFirst(frameEnergies.count - capacity)
        }
        guard frameEnergies.count == capacity else { return }
        evaluateAttackCandidate()
    }

    private func evaluateAttackCandidate() {
        let energies = frameEnergies
        let candidate = energies.count - 1 - lookaheadFrames // == baselineEndFrames
        let candidateAbsoluteIndex = totalEnergyFrames - 1 - lookaheadFrames

        let level = decibels(energies[candidate])
        guard level > -40 else { return }

        // Local peak: rising into the frame and not exceeded in the next
        // ~17 ms (otherwise the true transient is still ahead).
        guard energies[candidate] >= energies[candidate - 1] else { return }
        for index in (candidate + 1) ... (candidate + lookaheadFrames) where energies[index] > energies[candidate] {
            return
        }

        // Strong attack: ≥ 20 dB above the median of the preceding ~80 ms.
        let medianEnergy = Self.median(Array(energies[(candidate - medianWindowFrames) ..< candidate]))
        guard level >= decibels(medianEnergy) + 20 else { return }

        guard candidateAbsoluteIndex - lastMeasuredAttackFrame >= minAttackSeparationFrames else { return }

        // Pre-echo is only measurable against near-silence.
        let baselineDB = decibels(mean(energies[(candidate - baselineEndFrames) ... (candidate - baselineStartFrames)]))
        guard baselineDB < -45 else { return }

        let zoneEnd = candidate - 1 - preZoneSkipFrames
        let zoneStart = zoneEnd - preZoneFrames + 1
        let zoneDB = decibels(mean(energies[zoneStart ... zoneEnd]))

        preEchoSum += max(0, zoneDB - baselineDB)
        qualifyingAttackCount += 1
        lastMeasuredAttackFrame = candidateAbsoluteIndex
    }

    // MARK: - STFT pass (flicker + coherence)

    private func processSpectralFrames() {
        let stereo = channelCount > 1
        var start = 0
        while pendingLeft.count - start >= fftSize {
            pendingLeft.withUnsafeBufferPointer { pointer in
                fft.transform(
                    UnsafeBufferPointer(rebasing: pointer[start ..< start + fftSize]),
                    intoReal: &leftReal,
                    imaginary: &leftImaginary
                )
            }
            if stereo {
                pendingRight.withUnsafeBufferPointer { pointer in
                    fft.transform(
                        UnsafeBufferPointer(rebasing: pointer[start ..< start + fftSize]),
                        intoReal: &rightReal,
                        imaginary: &rightImaginary
                    )
                }
            }
            analyzeSpectralFrame(stereo: stereo)
            start += hopSize
        }
        pendingLeft.removeFirst(start)
        if stereo { pendingRight.removeFirst(min(start, pendingRight.count)) }
    }

    private func analyzeSpectralFrame(stereo: Bool) {
        stftFrameCount += 1

        // Band envelopes come from the mono mix; the FFT is linear, so the
        // mono spectrum is just the mean of the channel spectra.
        func monoBandPower(_ bins: Range<Int>) -> Float {
            var power: Float = 0
            if stereo {
                for bin in bins {
                    let re = (leftReal[bin] + rightReal[bin]) * 0.5
                    let im = (leftImaginary[bin] + rightImaginary[bin]) * 0.5
                    power += re * re + im * im
                }
            } else {
                for bin in bins {
                    power += leftReal[bin] * leftReal[bin] + leftImaginary[bin] * leftImaginary[bin]
                }
            }
            return power
        }

        for (index, bins) in highBandBinRanges.enumerated() {
            highTrackers[index].push(Float(decibels(monoBandPower(bins))), windowLength: toggleMedianFrames)
        }
        for (index, bins) in lowBandBinRanges.enumerated() {
            lowTrackers[index].push(Float(decibels(monoBandPower(bins))), windowLength: toggleMedianFrames)
        }

        if stereo, !coherenceBins.isEmpty {
            var crossRe: Float = 0
            var crossIm: Float = 0
            var leftPower: Float = 0
            var rightPower: Float = 0
            for bin in coherenceBins {
                let xr = leftReal[bin], xi = leftImaginary[bin]
                let yr = rightReal[bin], yi = rightImaginary[bin]
                crossRe += xr * yr + xi * yi
                crossIm += xi * yr - xr * yi
                leftPower += xr * xr + xi * xi
                rightPower += yr * yr + yi * yi
            }
            coherenceFrames.append(
                CoherenceFrame(
                    levelDB: Float(decibels((leftPower + rightPower) * 0.5)),
                    crossRe: crossRe,
                    crossIm: crossIm,
                    leftPower: leftPower,
                    rightPower: rightPower
                )
            )
        }
    }

    // MARK: - Finalization

    private func flickerScore() -> Double {
        guard stftFrameCount > 0, !highTrackers.isEmpty else { return 0 }
        let duration = Double(stftFrameCount) * Double(hopSize) / sampleRate
        guard duration > 0 else { return 0 }

        // A band that sits at the noise floor for > 90% of frames carries
        // no evidence — exclude it rather than diluting/adding noise.
        let activityFloor = stftFrameCount / 10
        let activeHigh = highTrackers.filter { $0.activeFrames > activityFloor }
        guard !activeHigh.isEmpty else { return 0 }
        let highRate = activeHigh.reduce(0.0) { $0 + Double($1.toggleCount) } / Double(activeHigh.count) / duration

        let activeLow = lowTrackers.filter { $0.activeFrames > activityFloor }
        let lowRate = activeLow.isEmpty
            ? 0
            : activeLow.reduce(0.0) { $0 + Double($1.toggleCount) } / Double(activeLow.count) / duration

        return max(0, highRate - lowRate)
    }

    private func highBandCoherence() -> Double {
        // Mono carries no evidence either way; report the neutral 1.0.
        guard channelCount > 1, !coherenceFrames.isEmpty else { return 1 }

        // Only frames with meaningful high-band energy: top 50% by level,
        // and above the digital noise floor.
        let sorted = coherenceFrames.sorted { $0.levelDB > $1.levelDB }
        let selected = sorted.prefix(max(1, sorted.count / 2)).filter { $0.levelDB > -90 }
        guard !selected.isEmpty else { return 1 }

        var crossRe = 0.0, crossIm = 0.0, leftPower = 0.0, rightPower = 0.0
        for frame in selected {
            crossRe += Double(frame.crossRe)
            crossIm += Double(frame.crossIm)
            leftPower += Double(frame.leftPower)
            rightPower += Double(frame.rightPower)
        }
        guard leftPower > 0, rightPower > 0 else { return 1 }
        let coherence = (crossRe * crossRe + crossIm * crossIm) / (leftPower * rightPower)
        return min(max(coherence, 0), 1)
    }

    // MARK: - Small helpers

    private func decibels(_ power: Float) -> Double {
        10 * log10(Double(max(power, 1e-12)))
    }

    private func mean(_ slice: ArraySlice<Float>) -> Float {
        slice.isEmpty ? 0 : slice.reduce(0, +) / Float(slice.count)
    }

    private static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func subBandBinRanges(
        fromHz: Double, toHz: Double, count: Int, binWidth: Double, binCount: Int
    ) -> [Range<Int>] {
        guard toHz > fromHz, count > 0 else { return [] }
        var ranges: [Range<Int>] = []
        let step = (toHz - fromHz) / Double(count)
        for index in 0 ..< count {
            let low = min(max(Int((fromHz + step * Double(index)) / binWidth), 1), binCount)
            let high = min(max(Int((fromHz + step * Double(index + 1)) / binWidth), low), binCount)
            if high > low { ranges.append(low ..< high) }
        }
        return ranges
    }
}

// MARK: - Toggle tracker

/// Hysteresis "present/absent" state machine for one sub-band envelope:
/// counts transitions where the envelope crosses ±8 dB around its local
/// (~0.5 s) median — codec bands switching on and off between frames.
private struct ToggleTracker {
    private var recentEnvelope: [Float] = []
    /// 0 = unknown, 1 = present, -1 = absent.
    private var state = 0
    private(set) var toggleCount = 0
    /// Frames where the band was above the digital noise floor at all.
    private(set) var activeFrames = 0

    mutating func push(_ envelopeDB: Float, windowLength: Int) {
        recentEnvelope.append(envelopeDB)
        if recentEnvelope.count > windowLength { recentEnvelope.removeFirst() }
        let median = recentEnvelope.sorted()[recentEnvelope.count / 2]

        var newState = state
        if envelopeDB > median + 8 {
            newState = 1
        } else if envelopeDB < median - 8 {
            newState = -1
        }
        if newState != state, state != 0 { toggleCount += 1 }
        state = newState

        if envelopeDB > -90 { activeFrames += 1 }
    }
}

// MARK: - Coherence frame record

/// High-band cross/auto spectral sums for one STFT frame; kept per frame so
/// `finalize()` can select the top-50%-by-level frames before averaging.
private struct CoherenceFrame {
    let levelDB: Float
    let crossRe: Float
    let crossIm: Float
    let leftPower: Float
    let rightPower: Float
}

// `ComplexSpectrumFFT` lives in AnalysisDSP.swift — shared with
// `AnalogSourceAnalyzer`, which needs the same complex half-spectra for its
// cross-channel coherence measurement.
