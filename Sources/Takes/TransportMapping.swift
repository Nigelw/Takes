import Foundation

struct TransportMapping {
    static func transportBounds(duration: TimeInterval, offset: TimeInterval) -> ClosedRange<TimeInterval> {
        offset...(offset + duration)
    }

    static func timelineRange(tracks: [LoadedTrack]) -> ClosedRange<TimeInterval>? {
        let ranges = tracks.map { track in
            transportBounds(duration: track.duration, offset: track.offsetSeconds)
        }

        guard !ranges.isEmpty else { return nil }

        let lower = min(0, ranges.map(\.lowerBound).min() ?? 0)
        let upper = max(0, ranges.map(\.upperBound).max() ?? 0)
        guard upper > lower else { return nil }
        return lower...upper
    }

    static func filePosition(forGlobalTime globalTime: TimeInterval, offset: TimeInterval) -> TimeInterval {
        globalTime - offset
    }

    static func isTrackAudible(_ track: LoadedTrack, atGlobalTime globalTime: TimeInterval) -> Bool {
        let position = filePosition(forGlobalTime: globalTime, offset: track.offsetSeconds)
        return position >= 0 && position <= track.duration
    }

    static func clampedTransport(
        _ transport: TimeInterval,
        timelineStart: TimeInterval,
        timelineEnd: TimeInterval
    ) -> TimeInterval {
        min(max(transport, timelineStart), timelineEnd)
    }

    static func normalizedPosition(
        globalTime: TimeInterval,
        timelineStart: TimeInterval,
        timelineEnd: TimeInterval
    ) -> Double {
        let span = timelineEnd - timelineStart
        guard span > 0 else { return 0 }
        return (globalTime - timelineStart) / span
    }

    static func linearGain(fromDB db: Float) -> Float {
        powf(10, db / 20)
    }
}
