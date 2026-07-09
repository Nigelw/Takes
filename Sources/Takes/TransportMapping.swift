import AVFoundation
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

    // MARK: - Gapless loop pre-queue

    /// How one track's audio maps onto a single bounded playback window
    /// `[windowStart, windowEnd]`, padded with silence so the described segment
    /// occupies the *entire* window (`leadingSilence + frameCount + trailingSilence`
    /// == `windowEnd − windowStart`). This is the single source of truth for
    /// transport→file mapping used by both the one-shot scheduler
    /// (`scheduleTrack`, which ignores the trailing pad) and the gapless loop
    /// pre-queue (`scheduleLoopIteration`, which schedules all three parts so
    /// every player advances by exactly one loop length per iteration and stays
    /// phase-locked across wraps).
    struct LoopIterationSegment: Equatable {
        /// Silence before the file first becomes audible in this window.
        var leadingSilence: TimeInterval
        /// First audible frame of the file (0 when the file starts at/after the
        /// window start).
        var startFrame: AVAudioFramePosition
        /// Number of file frames to play. Zero means the track is entirely out
        /// of range for this window (silence only).
        var frameCount: AVAudioFramePosition
        /// Silence after the file goes out of range, filling the window to its
        /// end. Ignored by callers that leave the player idle after the content.
        var trailingSilence: TimeInterval
    }

    /// Map a track (given its `offsetSeconds`, `fileLength` in frames and
    /// `sampleRate`) onto the window `[windowStart, windowEnd]`. Pass
    /// `windowEnd = .greatestFiniteMagnitude` for an uncapped window (play to
    /// the natural end of the file with no rounding loss).
    static func loopIterationSegment(
        offsetSeconds: TimeInterval,
        fileLength: AVAudioFramePosition,
        sampleRate: Double,
        windowStart: TimeInterval,
        windowEnd: TimeInterval
    ) -> LoopIterationSegment {
        let windowLength = max(0, windowEnd - windowStart)
        guard windowLength > 0, sampleRate > 0, fileLength > 0 else {
            return LoopIterationSegment(
                leadingSilence: windowLength,
                startFrame: 0,
                frameCount: 0,
                trailingSilence: 0
            )
        }

        // Silence until the file becomes audible (offset later than the window
        // start), capped to the window so a track starting past the window is
        // fully silent.
        let leadingSilence = min(max(offsetSeconds - windowStart, 0), windowLength)
        // Global time where audible content would begin (== max(windowStart, offset)).
        let contentGlobalStart = windowStart + leadingSilence
        let startFrameRaw = (contentGlobalStart - offsetSeconds) * sampleRate
        let startFrame = max(0, AVAudioFramePosition(startFrameRaw.rounded(.towardZero)))
        guard startFrame < fileLength else {
            // The file has already ended by the time this window starts sounding.
            return LoopIterationSegment(
                leadingSilence: windowLength,
                startFrame: 0,
                frameCount: 0,
                trailingSilence: 0
            )
        }

        let framesInFile = fileLength - startFrame
        let framesToWindowEndRaw = max(0, windowEnd - contentGlobalStart) * sampleRate
        let frameCount: AVAudioFramePosition
        if framesToWindowEndRaw >= Double(framesInFile) {
            // Window extends to or past the file end: play the rest exactly, with
            // no frame lost to rounding the (effectively unbounded) cap.
            frameCount = framesInFile
        } else {
            frameCount = max(0, min(framesInFile, AVAudioFramePosition(framesToWindowEndRaw.rounded())))
        }

        let contentDuration = Double(frameCount) / sampleRate
        let trailingSilence = max(0, windowLength - leadingSilence - contentDuration)
        return LoopIterationSegment(
            leadingSilence: leadingSilence,
            startFrame: startFrame,
            frameCount: frameCount,
            trailingSilence: trailingSilence
        )
    }

    /// The re-anchor produced by a gapless loop wrap.
    ///
    /// The wrap happens at an *exact* audio moment — one iteration length after
    /// the current iteration was anchored — not at the (up to a tick late)
    /// instant the transport timer notices it. Deriving the new anchor from the
    /// previous anchor plus the exact iteration length keeps the transport clock
    /// from drifting later on every wrap.
    ///
    /// - Parameters:
    ///   - previousStartHostTime: host time the current iteration was anchored at.
    ///   - previousStartTransport: transport position the current iteration started from.
    ///   - playbackStart: start of the playable range (where the next iteration begins).
    ///   - playbackEnd: end of the playable range (where the current iteration wraps).
    /// - Returns: the host time and transport position to anchor the next iteration at.
    static func wrapAnchors(
        previousStartHostTime: CFTimeInterval,
        previousStartTransport: TimeInterval,
        playbackStart: TimeInterval,
        playbackEnd: TimeInterval
    ) -> (startHostTime: CFTimeInterval, startTransport: TimeInterval) {
        let currentIterationLength = playbackEnd - previousStartTransport
        return (previousStartHostTime + currentIterationLength, playbackStart)
    }
}

/// Pure viewport math for timeline zoom.
///
/// The canonical zoom state is the visible window in absolute seconds
/// (`visibleStart` / `visibleSpan` on `PlaybackController`); the displayed zoom
/// factor is *derived* (`contentSpan / visibleSpan`). "Fit" is not a flag — it
/// is simply the state `visibleSpan ≈ contentSpan` (zoom ≈ 1). Storing the
/// window in absolute seconds keeps a zoomed view stable as content grows and
/// makes "zoom all the way out = fit" fall out for free.
enum TimelineViewport {
    /// Smallest visible window (D7). Bounds the maximum zoom-in.
    static let minimumVisibleSpan: TimeInterval = 0.5

    /// Multiplicative zoom factor applied by the −/+ buttons (D4).
    static let zoomButtonStep: Double = 1.5

    /// Tolerance for treating the visible span as equal to the content span.
    private static let fitTolerance: TimeInterval = 0.001

    /// Whether the visible window is effectively the whole content (zoomed out).
    static func isFit(visibleSpan: TimeInterval, contentSpan: TimeInterval) -> Bool {
        visibleSpan >= contentSpan - fitTolerance
    }

    /// Derived zoom factor (≥ 1).
    static func zoom(visibleSpan: TimeInterval, contentSpan: TimeInterval) -> Double {
        guard visibleSpan > 0, contentSpan > 0 else { return 1 }
        return max(1, contentSpan / visibleSpan)
    }

    /// The largest zoom factor allowed for a given content span.
    static func maximumZoom(contentSpan: TimeInterval) -> Double {
        guard contentSpan > minimumVisibleSpan else { return 1 }
        return contentSpan / minimumVisibleSpan
    }

    /// Clamp a candidate window to the content bounds and span limits. The span
    /// is held (only shrunk if it would exceed the content); the start is moved
    /// so the window stays inside `[contentStart, contentEnd]`.
    static func clampedWindow(
        visibleStart: TimeInterval,
        visibleSpan: TimeInterval,
        contentStart: TimeInterval,
        contentEnd: TimeInterval
    ) -> (start: TimeInterval, span: TimeInterval) {
        let contentSpan = max(contentEnd - contentStart, 0)
        guard contentSpan > 0 else { return (contentStart, 0) }
        let lowerSpan = min(minimumVisibleSpan, contentSpan)
        let span = min(max(visibleSpan, lowerSpan), contentSpan)
        let start = min(max(visibleStart, contentStart), contentEnd - span)
        return (start, span)
    }

    /// The anchor to hold fixed while rezooming: the playhead if it is currently
    /// on-screen, otherwise the view centre (D3).
    static func anchor(
        transport: TimeInterval,
        visibleStart: TimeInterval,
        visibleSpan: TimeInterval
    ) -> (time: TimeInterval, fraction: Double) {
        guard visibleSpan > 0 else { return (transport, 0.5) }
        let fraction = (transport - visibleStart) / visibleSpan
        if fraction >= 0, fraction <= 1 {
            return (transport, fraction)
        }
        return (visibleStart + visibleSpan / 2, 0.5)
    }

    /// Rezoom to `newSpan`, keeping `anchorTime` pinned at `anchorFraction` of
    /// the view width, clamped to the content range.
    static func rezoom(
        newSpan: TimeInterval,
        anchorTime: TimeInterval,
        anchorFraction: Double,
        contentStart: TimeInterval,
        contentEnd: TimeInterval
    ) -> (start: TimeInterval, span: TimeInterval) {
        let contentSpan = max(contentEnd - contentStart, 0)
        guard contentSpan > 0 else { return (contentStart, 0) }
        let lowerSpan = min(minimumVisibleSpan, contentSpan)
        let span = min(max(newSpan, lowerSpan), contentSpan)
        return clampedWindow(
            visibleStart: anchorTime - anchorFraction * span,
            visibleSpan: span,
            contentStart: contentStart,
            contentEnd: contentEnd
        )
    }

    /// Page the visible window when the playhead leaves it during playback (D6).
    ///
    /// Returns the new `visibleStart` — the playhead landing at the left edge,
    /// clamped to the content — or `nil` while the playhead is still inside the
    /// current page. Keeping the window put between pages means it only jumps in
    /// discrete steps, so the waveform is static (and the playhead simply runs
    /// across it) until it reaches an edge.
    static func pagedStart(
        transport: TimeInterval,
        visibleStart: TimeInterval,
        visibleSpan: TimeInterval,
        contentStart: TimeInterval,
        contentEnd: TimeInterval
    ) -> TimeInterval? {
        guard visibleSpan > 0 else { return nil }
        let visibleEnd = visibleStart + visibleSpan
        guard transport < visibleStart || transport >= visibleEnd else { return nil }

        let newStart = min(max(transport, contentStart), contentEnd - visibleSpan)
        return newStart == visibleStart ? nil : newStart
    }

    /// The visible window after the content range changes (D2): refit while the
    /// user is fully zoomed out, otherwise keep the span and only clamp the
    /// start to the new bounds (sticky zoom).
    static func adjustedForContentChange(
        visibleStart: TimeInterval,
        visibleSpan: TimeInterval,
        previousContentSpan: TimeInterval,
        contentStart: TimeInterval,
        contentEnd: TimeInterval
    ) -> (start: TimeInterval, span: TimeInterval) {
        let contentSpan = max(contentEnd - contentStart, 0)
        guard contentSpan > 0 else { return (contentStart, 0) }
        if isFit(visibleSpan: visibleSpan, contentSpan: previousContentSpan) {
            return (contentStart, contentSpan)
        }
        return clampedWindow(
            visibleStart: visibleStart,
            visibleSpan: visibleSpan,
            contentStart: contentStart,
            contentEnd: contentEnd
        )
    }

    /// Logarithmic slider position in `0...1` for a visible span (0 = fit /
    /// fully zoomed out, 1 = maximum zoom). The zoom range is large, so a log
    /// mapping keeps the slider usable across it (D4).
    static func sliderValue(visibleSpan: TimeInterval, contentSpan: TimeInterval) -> Double {
        let maxZoom = maximumZoom(contentSpan: contentSpan)
        guard maxZoom > 1 else { return 0 }
        let zoom = min(max(zoom(visibleSpan: visibleSpan, contentSpan: contentSpan), 1), maxZoom)
        return log(zoom) / log(maxZoom)
    }

    /// Inverse of `sliderValue`: the visible span for a `0...1` slider position.
    static func visibleSpan(sliderValue: Double, contentSpan: TimeInterval) -> TimeInterval {
        guard contentSpan > 0 else { return 0 }
        let maxZoom = maximumZoom(contentSpan: contentSpan)
        guard maxZoom > 1 else { return contentSpan }
        let value = min(max(sliderValue, 0), 1)
        return contentSpan / pow(maxZoom, value)
    }

    /// Visible span after one −/+ button step (D4): a fixed multiplicative
    /// (i.e. fixed log) increment.
    static func steppedVisibleSpan(
        visibleSpan: TimeInterval,
        zoomingIn: Bool
    ) -> TimeInterval {
        visibleSpan * (zoomingIn ? 1 / zoomButtonStep : zoomButtonStep)
    }

    /// Visible span after a trackpad pinch delta. Exponential scaling keeps
    /// zoom-in and zoom-out continuous without a zero/negative denominator.
    static func magnifiedVisibleSpan(
        visibleSpan: TimeInterval,
        magnification: Double
    ) -> TimeInterval {
        guard visibleSpan > 0, magnification.isFinite else { return visibleSpan }
        return visibleSpan * exp(-magnification)
    }
}

enum TimelineScrollGeometry {
    static func pointsPerSecond(
        viewportWidth: Double,
        visibleSpan: TimeInterval
    ) -> Double {
        guard viewportWidth > 0, visibleSpan > 0 else { return 0 }
        return viewportWidth / visibleSpan
    }

    static func documentWidth(
        contentSpan: TimeInterval,
        visibleSpan: TimeInterval,
        viewportWidth: Double
    ) -> Double {
        let scale = pointsPerSecond(viewportWidth: viewportWidth, visibleSpan: visibleSpan)
        guard contentSpan > 0, scale > 0 else { return max(viewportWidth, 0) }
        return max(viewportWidth, contentSpan * scale)
    }

    static func scrollOffset(
        visibleStart: TimeInterval,
        contentStart: TimeInterval,
        pointsPerSecond: Double
    ) -> Double {
        guard pointsPerSecond > 0 else { return 0 }
        return (visibleStart - contentStart) * pointsPerSecond
    }

    static func visibleStart(
        scrollOffset: Double,
        contentStart: TimeInterval,
        pointsPerSecond: Double
    ) -> TimeInterval {
        guard pointsPerSecond > 0 else { return contentStart }
        return contentStart + scrollOffset / pointsPerSecond
    }

    static func visibleStart(
        scrollOffset: Double,
        contentStart: TimeInterval,
        contentEnd: TimeInterval,
        visibleSpan: TimeInterval,
        pointsPerSecond: Double,
        snapTolerancePoints: Double = 0.5
    ) -> TimeInterval {
        guard pointsPerSecond > 0 else { return contentStart }

        let maximumOffset = max((contentEnd - contentStart - visibleSpan) * pointsPerSecond, 0)
        if abs(scrollOffset) <= snapTolerancePoints {
            return contentStart
        }
        if abs(scrollOffset - maximumOffset) <= snapTolerancePoints {
            return contentEnd - visibleSpan
        }
        return visibleStart(
            scrollOffset: scrollOffset,
            contentStart: contentStart,
            pointsPerSecond: pointsPerSecond
        )
    }

    static func viewportFraction(
        locationX: Double,
        visibleOriginX: Double,
        viewportWidth: Double
    ) -> Double {
        guard viewportWidth > 0 else { return 0 }
        return min(max((locationX - visibleOriginX) / viewportWidth, 0), 1)
    }
}
