# Timeline Ruler Zoom Improvement — Plan

## Context

The timeline-zoom feature (see [2026-06-23-timeline-zoom-design.md](2026-06-23-timeline-zoom-design.md))
re-based the header ruler on the **visible window** instead of the content
range, so markers already follow the zoom. What it did *not* change is how the
tick spacing is chosen, and that math predates zoom — it assumes a whole-second
granularity. The result: when you zoom in, the ruler shows too few ticks (often
just one, or none), and adjacent ticks would carry identical labels because the
label format has no sub-second resolution.

This plan covers fixing both the **interval selection** and the **label format**
so the ruler reads well at every zoom level, from the 0.5 s max-zoom window up to
multi-minute spans.

## The problem, precisely

Two pure functions in [`Sources/Takes/Models.swift`](../../../Sources/Takes/Models.swift):

### 1. `TimelineHeaderMarker.readableInterval(for:)`

```swift
let baseIntervals: [TimeInterval] = [1, 2, 5, 10, 30]
var scale: TimeInterval = 1
while scale * 30 < rawInterval { scale *= 60 }   // jumps in ×60 steps
if scale > 1 { /* pick baseInterval * scale */ }
if rawInterval <= 12 { return 10 }                // <-- floor
return baseIntervals.first { $0 >= rawInterval } ?? 30
```

`rawInterval` is `visibleSpan / targetMarkerCount` (target is 7). Problems:

- **Sub-second is impossible.** Anything with `rawInterval <= 12` returns `10`.
  At max zoom the visible span is 0.5 s → `rawInterval ≈ 0.07` → interval `10` →
  `firstTick = ceil(visibleStart / 10) * 10` usually lands outside the 0.5 s
  window → **0 ticks** (the ruler falls back to the static `00:00` label).
- **Coarse across all sub-84 s spans.** For any span up to ~84 s the interval is
  pinned at 10 s, so e.g. a 20 s zoomed view shows ~2 ticks instead of ~7.
- The `scale *= 60` ladder only generalizes *upward* (minutes, hours), never
  below 1 s.

### 2. `TimeInterval.formattedSignedTimestamp`

Formats as `mm:ss` (or `h:mm:ss`), integer seconds only. Even if we generated
0.1 s ticks, their labels would read `00:03, 00:03, 00:03…` — indistinguishable.

## Goals

- Roughly **5–8 evenly spaced ticks** at every zoom level (keep the existing
  `targetMarkerCount = 7` intent).
- A **"nice number" ladder** that spans sub-second to hours: 0.1, 0.2, 0.5, 1, 2,
  5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, … (i.e. 1-2-5 within each
  decade below a minute, and the familiar 1-2-5-10-15-30 steps at the minute/hour
  scales).
- **Labels that match the interval's resolution**: show fractional seconds only
  when the interval is sub-second (e.g. `0:03.5`), integer `mm:ss` otherwise.
- No label overlap; labels stay monospaced and right-readable as today.
- Pure, unit-tested functions — no view changes beyond label width if needed.

## Non-goals

- Changing marker *positioning* (already correct via `xPosition`, visible-window
  based).
- Minor tick marks / sub-divisions between labels (could be a later polish).
- Beat/bar or SMPTE rulers.

## Approach

### A. Generalize `readableInterval` to a full nice-number ladder

Replace the `scale *= 60` + `<= 12 → 10` logic with selection from an explicit
ascending ladder of "nice" intervals in seconds:

```
0.1, 0.2, 0.5,
1, 2, 5, 10, 15, 30,
60, 120, 300, 600, 900, 1800,
3600, 7200, 10800, 21600, 43200, 86400
```

Pick the smallest ladder value `>= rawInterval` (clamp to the ends). This keeps
the chosen interval close to `rawInterval`, so the tick count stays near
`targetMarkerCount` across all zoom levels. Optionally extend the ladder
generatively (1-2-5 × 10^k below 1 s; ×2/×2.5/×… composites above) instead of a
literal list — but a literal list is simplest, fully covers the 0.5 s … hours
range this app needs, and is trivial to test.

Decision to confirm during implementation: where exactly the sub-second floor
sits. With `minimumVisibleSpan = 0.5 s` and target 7, the smallest `rawInterval`
is ~0.07 s, so `0.1` would give ~5 ticks at max zoom — a reasonable floor. If we
want denser, add `0.05`.

### B. Resolution-aware label formatting

Add a formatter that takes the **interval** (so it knows the needed precision)
and the time:

- interval `>= 1 s` → existing `mm:ss` / `h:mm:ss`.
- interval `< 1 s` → append tenths (or hundredths if we add 0.05): `m:ss.t`,
  signed, e.g. `-0:00.5`, `0:03.5`.

Keep it a pure extension/helper next to `formattedSignedTimestamp` so it's
unit-testable. `markers(...)` will need to pass the chosen interval into label
formatting (today it calls `time.formattedSignedTimestamp` directly).

### C. Wiring

- `TimelineHeaderMarker.markers(timelineStart:timelineEnd:targetMarkerCount:)`
  already receives the visible window (the view passes `visibleStart` /
  `visibleEnd`). Only its internal interval choice + label formatting change.
- Check `ContentView.timelineHeaderMarker` `labelWidth` (currently `52`) — a
  `0:03.5` label is a touch wider than `00:03`; bump if it clips, or rely on the
  existing `minimumScaleFactor(0.8)`.

## Files to touch

- `Sources/Takes/Models.swift` — `readableInterval`, `markers` (pass interval to
  labels), new resolution-aware label formatter.
- `Sources/Takes/ContentView.swift` — only if `labelWidth` needs widening.
- `Tests/TakesTests/` — new tests (there is no existing coverage for
  `readableInterval` / marker generation).

## Tests to add

Pure-function tests, in the style of `TimelineViewportTests`:

- **Interval selection** across representative spans, asserting the chosen
  interval and that the resulting tick count is within ~[4, 9]:
  `0.5 s → 0.1`, `2 s → 0.5` (or `0.2`), `20 s → 5` (or `2`), `120 s → 30`,
  `600 s → 120`, `3600 s → 600`. (Pin exact expected values once the ladder is
  final.)
- **Sub-second labels**: `0.5` interval at `t = 3.5` → `"0:03.5"`; negative time
  keeps the sign.
- **Integer labels unchanged**: interval `≥ 1` still yields `mm:ss` exactly as
  today (guard against regressions for the zoomed-out ruler).
- **First-tick alignment**: first marker is the smallest multiple of the interval
  `≥ visibleStart`; markers stay within `[visibleStart, visibleEnd]`.
- **Degenerate spans**: zero/negative span → no markers (unchanged).

## Acceptance criteria

At every zoom level — including the 0.5 s max-zoom window — the ruler shows
~5–8 evenly spaced, non-overlapping ticks whose labels carry enough resolution to
be distinct (sub-second labels when zoomed in), and the fully-zoomed-out ruler is
visually unchanged from today.

## Rough order of work

1. Build the nice-number ladder + new `readableInterval`; unit-test interval
   selection and tick counts.
2. Add the resolution-aware label formatter; thread the interval through
   `markers`; unit-test labels.
3. Run in-app at several zoom levels; adjust the sub-second floor and
   `labelWidth` to taste.
