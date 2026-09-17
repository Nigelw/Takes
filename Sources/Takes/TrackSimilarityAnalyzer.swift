import Accelerate
import AVFoundation
import Foundation

enum TrackSimilarityVerdict: String, Codable, Sendable {
    case match, mismatch, insufficientEvidence, analysisFailure
}

struct TrackSimilaritySource: Sendable {
    let id: UUID
    let url: URL
}

/// Canonical key. Directional measurements always refer to these sorted IDs.
struct TrackSimilarityPair: Hashable, Sendable {
    let firstID: UUID
    let secondID: UUID

    init(firstID: UUID, secondID: UUID) {
        if firstID.uuidString < secondID.uuidString {
            self.firstID = firstID
            self.secondID = secondID
        } else {
            self.firstID = secondID
            self.secondID = firstID
        }
    }
}

struct TrackSimilarityEvidence: Equatable, Sendable {
    var sameRecording: TrackSimilarityVerdict = .insufficientEvidence
    var samePerformance: TrackSimilarityVerdict = .insufficientEvidence
    /// Verified region duration, not an extrapolation across unmeasured audio.
    var matchedSeconds: Double = 0
    var firstCoverage: Double = 0
    var secondCoverage: Double = 0
    /// second file time = first file time * speedRatio + offsetSeconds.
    var offsetSeconds: Double = 0
    var speedRatio: Double = 1
    var diagnostic: String = ""
}

struct TrackSimilarityRequest: Sendable {
    let sources: [TrackSimilaritySource]
    let pairs: [TrackSimilarityPair]
    let deadline: Date
}

struct TrackSimilarityAnalysis: Sendable {
    var evidence: [TrackSimilarityPair: TrackSimilarityEvidence] = [:]
    var timedOut = false
}

protocol TrackSimilarityAnalyzing: Sendable {
    func analyze(_ request: TrackSimilarityRequest) async -> TrackSimilarityAnalysis
}

protocol TrackSimilarityClock: Sendable {
    func now() -> Date
}

struct SystemTrackSimilarityClock: TrackSimilarityClock {
    func now() -> Date { Date() }
}

/// A single actor bounds all decoding and correlation to one background worker.
/// Cancellation/deadlines are checked at each decode chunk and verification region.
/// No audio engine, waveform-store data, or disk cache is involved.
actor TrackSimilarityAnalyzer: TrackSimilarityAnalyzing {
    struct Features: Sendable {
        let novelty: [Float]
        let mono: [Float]
        let activeRange: Range<Int>
        var byteCount: Int { (novelty.count + mono.count) * MemoryLayout<Float>.stride }
    }

    struct FileIdentity: Hashable, Sendable {
        let path: String
        let resourceID: String
        let size: Int
        let modified: Date

        init(url: URL) throws {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            let values = try canonical.resourceValues(forKeys: [
                .fileResourceIdentifierKey, .fileSizeKey, .contentModificationDateKey
            ])
            path = canonical.path
            resourceID = values.fileResourceIdentifier.map { String(describing: $0) } ?? path
            size = values.fileSize ?? 0
            modified = values.contentModificationDate ?? .distantPast
        }
    }

    private struct CacheEntry {
        let features: Features
        var access: UInt64
    }

    private let clock: any TrackSimilarityClock
    private let cacheByteLimit: Int
    private var cache: [FileIdentity: CacheEntry] = [:]
    private var access: UInt64 = 0
    private var cachedBytes = 0

    init(clock: any TrackSimilarityClock = SystemTrackSimilarityClock(), cacheByteLimit: Int = 64 * 1_024 * 1_024) {
        self.clock = clock
        self.cacheByteLimit = max(0, cacheByteLimit)
    }

    func analyze(_ request: TrackSimilarityRequest) async -> TrackSimilarityAnalysis {
        var result = TrackSimilarityAnalysis()
        let urls = Dictionary(request.sources.map { ($0.id, $0.url) }, uniquingKeysWith: { first, _ in first })
        var failures: Set<UUID> = []
        let stopped = { Task.isCancelled || self.clock.now() >= request.deadline }

        for pair in request.pairs {
            if stopped() { break }
            // Keep only this pair alive outside the bounded shared cache.
            var loaded: [UUID: Features] = [:]
            for id in [pair.firstID, pair.secondID] where loaded[id] == nil && !failures.contains(id) {
                guard let url = urls[id] else { failures.insert(id); continue }
                do {
                    let identity = try FileIdentity(url: url)
                    if var entry = cache[identity] {
                        access &+= 1
                        entry.access = access
                        cache[identity] = entry
                        loaded[id] = entry.features
                    } else {
                        let features = try Self.extract(url: url, stopped: stopped)
                        // Do not retain data from an identity that changed while decoding.
                        guard try FileIdentity(url: url) == identity else {
                            failures.insert(id)
                            continue
                        }
                        loaded[id] = features
                        retain(features, identity: identity)
                    }
                } catch is CancellationError {
                    break
                } catch {
                    failures.insert(id)
                }
            }
            if stopped() { break }
            if failures.contains(pair.firstID) || failures.contains(pair.secondID) {
                result.evidence[pair] = TrackSimilarityEvidence(
                    sameRecording: .analysisFailure, samePerformance: .analysisFailure,
                    diagnostic: "Audio could not be decoded or changed during analysis."
                )
            } else if let first = loaded[pair.firstID], let second = loaded[pair.secondID] {
                result.evidence[pair] = Self.compare(first, second, stopped: stopped)
            }
        }
        result.timedOut = clock.now() >= request.deadline
        for pair in request.pairs where result.evidence[pair] == nil {
            result.evidence[pair] = TrackSimilarityEvidence(diagnostic: Task.isCancelled ? "Cancelled." : "Analysis deadline reached.")
        }
        return result
    }

    private func retain(_ features: Features, identity: FileIdentity) {
        // Remove superseded identities for this path rather than retaining old versions.
        for key in cache.keys.filter({ $0.path == identity.path }) {
            if let old = cache.removeValue(forKey: key) { cachedBytes -= old.features.byteCount }
        }
        guard features.byteCount <= cacheByteLimit else { return }
        while cachedBytes + features.byteCount > cacheByteLimit,
              let oldest = cache.min(by: { $0.value.access < $1.value.access })?.key {
            if let old = cache.removeValue(forKey: oldest) { cachedBytes -= old.features.byteCount }
        }
        access &+= 1
        cache[identity] = CacheEntry(features: features, access: access)
        cachedBytes += features.byteCount
    }

    /// One pass yields a 1 kHz energy envelope and a box-filtered mono signal.
    /// The latter is only corroboration; it cannot establish a match on its own.
    static func extract(url: URL, stopped: () -> Bool = { false }) throws -> Features {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let framesPerHop = format.sampleRate * TrackAligner.hopSeconds
        // Bound allocation for malformed files and multi-hour imports. Long files abstain.
        guard framesPerHop > 0, file.length > 0,
              Double(file.length) / format.sampleRate <= 3_600,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let count = Int(ceil(Double(file.length) / framesPerHop))
        var energy = [Float](repeating: 0, count: count)
        var mono = [Float](repeating: 0, count: count)
        var squared = [Float](repeating: 0, count: 65_536)
        var scratch = squared
        var summed = squared
        var framesRead: Int64 = 0
        while framesRead < file.length {
            if stopped() { throw CancellationError() }
            try file.read(into: buffer, frameCount: 65_536)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
            let channelCount = Int(format.channelCount)
            guard channelCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
            let length = vDSP_Length(frames)
            vDSP_vsq(channels[0], 1, &squared, 1, length)
            summed.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: channels[0], count: frames) }
            for channel in 1..<channelCount {
                vDSP_vsq(channels[channel], 1, &scratch, 1, length)
                vDSP_vadd(squared, 1, scratch, 1, &squared, 1, length)
                vDSP_vadd(summed, 1, channels[channel], 1, &summed, 1, length)
            }
            var frame = 0
            while frame < frames {
                let hop = min(count - 1, Int(Double(framesRead + Int64(frame)) / framesPerHop))
                let end = min(frames, max(frame + 1, Int(ceil(Double(hop + 1) * framesPerHop)) - Int(framesRead)))
                var power: Float = 0
                var amplitude: Float = 0
                squared.withUnsafeBufferPointer { vDSP_sve($0.baseAddress! + frame, 1, &power, vDSP_Length(end - frame)) }
                summed.withUnsafeBufferPointer { vDSP_sve($0.baseAddress! + frame, 1, &amplitude, vDSP_Length(end - frame)) }
                energy[hop] += power / Float(channelCount)
                mono[hop] += amplitude / Float(framesPerHop * Double(channelCount))
                frame = end
            }
            framesRead += Int64(frames)
        }
        let peak = energy.max() ?? 0
        let threshold = max(1e-8, peak * 0.0001)
        let first = energy.firstIndex(where: { $0 > threshold }) ?? 0
        let last = energy.lastIndex(where: { $0 > threshold }).map { $0 + 1 } ?? 0
        return Features(novelty: TrackAligner.noveltyFromEnergy(energy, framesPerHop: framesPerHop), mono: mono, activeRange: first..<max(first, last))
    }

    private struct Region {
        let first: Double
        let second: Double
        let seconds: Double
        let coarse: Float
        let contrast: Float
        var waveform: Float
    }

    private static func waveformScore(first: Features, second: Features, firstCenter: Int, secondCenter: Int, ratio: Double) -> Float {
        let radius = 500
        guard firstCenter >= radius, firstCenter + radius <= first.mono.count else { return 0 }
        let a = Array(first.mono[(firstCenter - radius)..<(firstCenter + radius)])
        let lower = max(0, secondCenter - Int(Double(radius) * ratio) - 100)
        let upper = min(second.mono.count, secondCenter + Int(Double(radius) * ratio) + 100)
        guard upper - lower > Int(Double(a.count) * ratio) + 2 else { return 0 }
        var best: Float = 0
        // A one-hop integer lag can lose coherence when codec delay lands
        // between hops. Fractional probes also compensate the measured speed.
        for fraction in [0.0, 0.25, 0.5, 0.75] {
            let length = Int(Double(upper - lower - 2) / ratio)
            var b = [Float](repeating: 0, count: length)
            for index in b.indices {
                let position = Double(lower) + Double(index) * ratio + fraction
                let base = Int(position)
                let weight = Float(position - Double(base))
                b[index] = second.mono[base] * (1 - weight) + second.mono[base + 1] * weight
            }
            best = max(best, TrackAligner.bestNCCLag(reference: a, target: b, minOverlap: a.count)?.score ?? 0)
        }
        return best
    }

    static func compare(_ first: Features, _ second: Features, stopped: () -> Bool = { false }) -> TrackSimilarityEvidence {
        // Choose the shorter active source independently of caller/pair order.
        if first.activeRange.count > second.activeRange.count {
            var result = compare(second, first, stopped: stopped)
            swap(&result.firstCoverage, &result.secondCoverage)
            result.offsetSeconds = -result.offsetSeconds / result.speedRatio
            result.speedRatio = 1 / result.speedRatio
            return result
        }
        let firstDuration = Double(first.activeRange.count) / 1_000
        let secondDuration = Double(second.activeRange.count) / 1_000
        guard min(firstDuration, secondDuration) >= 24 else {
            return TrackSimilarityEvidence(diagnostic: "Less than 24 seconds of active audio.")
        }
        guard min(firstDuration, secondDuration) / max(firstDuration, secondDuration) >= 0.72 else {
            return TrackSimilarityEvidence(sameRecording: .mismatch, samePerformance: .mismatch,
                diagnostic: "Duration coverage excludes excerpts or partial reuse.")
        }
        // Six disjoint regions cover the source. Whole-region evidence measures
        // coverage directly rather than extrapolating from three short excerpts.
        var regions: [Region] = []
        var regionNotes: [String] = []
        var strongestCandidate: Float = 0
        var attempted = 0
        for index in 0..<6 {
            if stopped() { return TrackSimilarityEvidence(diagnostic: "Analysis deadline reached during verification.") }
            let lower = first.activeRange.lowerBound + first.activeRange.count * index / 6
            let upper = first.activeRange.lowerBound + first.activeRange.count * (index + 1) / 6
            let reference = Array(first.novelty[lower..<upper])
            guard reference.reduce(0, +) > Float(reference.count) * 0.0001 else { continue }
            attempted += 1
            let candidate = TrackAligner.bestAlignment(reference: reference, target: second.novelty)
            if let candidate {
                strongestCandidate = max(strongestCandidate, candidate.score)
                regionNotes.append(String(format: "%d:%.2f/%.2f@%.3f", index, candidate.score, candidate.contrast, Double(candidate.lag) / 1_000))
            }
            guard let match = candidate,
                  match.score >= 0.25, match.contrast >= 1.4,
                  match.lag >= 0,
                  match.lag + reference.count <= second.novelty.count else { continue }
            // Independent short waveform verification around the region center.
            let center = lower + reference.count / 2
            let targetCenter = match.lag + reference.count / 2
            regions.append(Region(first: Double(center) / 1_000, second: Double(targetCenter) / 1_000,
                                  seconds: Double(reference.count) / 1_000, coarse: match.score,
                                  contrast: match.contrast, waveform: 0))
        }
        guard attempted >= 5 else { return TrackSimilarityEvidence(diagnostic: "Too few informative regions.") }
        guard regions.count >= 5 else {
            // A failed mix/tempo verifier is unknown, not a contradiction that
            // can veto a valid grouping supported by another version.
            let verdict: TrackSimilarityVerdict = regions.isEmpty && strongestCandidate < 0.35 ? .mismatch : .insufficientEvidence
            return TrackSimilarityEvidence(sameRecording: verdict, samePerformance: verdict,
                diagnostic: "Only \(regions.count)/\(attempted) regions have distinctive event correspondence. " + regionNotes.joined(separator: "; "))
        }
        let meanFirst = regions.map(\.first).reduce(0, +) / Double(regions.count)
        let meanSecond = regions.map(\.second).reduce(0, +) / Double(regions.count)
        let variance = regions.reduce(0) { $0 + pow($1.first - meanFirst, 2) }
        let covariance = regions.reduce(0) { $0 + ($1.first - meanFirst) * ($1.second - meanSecond) }
        let ratio = variance > 0 ? covariance / variance : 1
        let offset = meanSecond - ratio * meanFirst
        let residual = regions.map { abs($0.second - ($0.first * ratio + offset)) }.max() ?? .infinity
        if (0.94...1.06).contains(ratio), residual <= 0.080 {
            for index in regions.indices {
                if stopped() { return TrackSimilarityEvidence(diagnostic: "Analysis deadline reached during verification.") }
                regions[index].waveform = waveformScore(first: first, second: second,
                    firstCenter: Int((regions[index].first * 1_000).rounded()),
                    secondCenter: Int((regions[index].second * 1_000).rounded()), ratio: ratio)
            }
        }
        let seconds = regions.map(\.seconds).reduce(0, +)
        let firstCoverage = min(1, seconds / firstDuration)
        let secondCoverage = min(1, seconds * ratio / secondDuration)
        let recordingRegions = regions.filter { $0.waveform >= 0.82 }.count
        let performanceRegions = regions.filter { $0.coarse >= 0.60 && $0.contrast >= 1.8 }.count
        let consistent = (0.94...1.06).contains(ratio) && residual <= 0.080
            && min(firstCoverage, secondCoverage) >= 0.80
        let recording = consistent && recordingRegions >= 5
        let performance = recording || (consistent && performanceRegions >= 5)
        return TrackSimilarityEvidence(
            sameRecording: recording ? .match : .insufficientEvidence,
            samePerformance: performance ? .match : .insufficientEvidence,
            matchedSeconds: seconds, firstCoverage: firstCoverage, secondCoverage: secondCoverage,
            offsetSeconds: offset, speedRatio: ratio,
            diagnostic: String(format: "%d/%d regions; waveform %d; performance %d; timing residual %.3fs; mean onset %.3f; mean waveform %.3f", regions.count, attempted, recordingRegions, performanceRegions, residual, regions.map(\.coarse).reduce(0, +) / Float(regions.count), regions.map(\.waveform).reduce(0, +) / Float(regions.count))
        )
    }
}
