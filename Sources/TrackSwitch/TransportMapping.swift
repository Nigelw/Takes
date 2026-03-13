import Foundation

struct TransportMapping {
    static func transportBounds(duration: TimeInterval, offset: TimeInterval) -> ClosedRange<TimeInterval> {
        offset...(offset + duration)
    }

    static func overlapRange(trackA: LoadedTrack, trackB: LoadedTrack) -> ClosedRange<TimeInterval>? {
        let a = transportBounds(duration: trackA.duration, offset: trackA.offsetSeconds)
        let b = transportBounds(duration: trackB.duration, offset: trackB.offsetSeconds)
        let lower = max(a.lowerBound, b.lowerBound)
        let upper = min(a.upperBound, b.upperBound)
        guard upper > lower else { return nil }
        return lower...upper
    }

    static func validOverlapDuration(trackA: LoadedTrack, trackB: LoadedTrack) -> TimeInterval {
        guard let range = overlapRange(trackA: trackA, trackB: trackB) else { return 0 }
        return range.upperBound - range.lowerBound
    }

    static func absoluteTransportPosition(relativeTransport: TimeInterval, overlapStart: TimeInterval) -> TimeInterval {
        overlapStart + relativeTransport
    }

    static func filePosition(
        forRelativeTransport relativeTransport: TimeInterval,
        overlapStart: TimeInterval,
        offset: TimeInterval
    ) -> TimeInterval {
        absoluteTransportPosition(relativeTransport: relativeTransport, overlapStart: overlapStart) - offset
    }

    static func clampedTransport(_ transport: TimeInterval, duration: TimeInterval) -> TimeInterval {
        min(max(0, transport), duration)
    }

    static func linearGain(fromDB db: Float) -> Float {
        powf(10, db / 20)
    }
}
