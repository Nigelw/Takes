# Takes Timeline Zoom Design

## Context

The timeline currently has no zoom. It always fits the entire content to the
viewport width, and re-fits automatically as tracks of different lengths are
added or removed. This auto-fit behavior is a feature users like and must be
preserved.

The reason auto-fit "just works" today is that a single range variable does two
jobs. Every coordinate renders through two centralized functions —
`xPosition(for:width:)` and `globalTime(atX:width:)` in `ContentView.swift` —
which both normalize against `[timelineStart, timelineEnd]` (the full session
span) and multiply by the viewport width. The waveform lane width is literally
`duration / timelineSpan × width`. There is no pixels-per-second concept
anywhere. When `recalculateSessionDuration` (in `PlaybackController.swift`) grows
the span as tracks change, every coordinate re-normalizes and the whole timeline
re-fits for free.

To add zoom we split that one range into two concepts:

- **Content range** — `[timelineStart, timelineEnd]`, the union of all tracks.
  Already exists; auto-fit tracks this.
- **Visible range** — `[visibleStart, visibleEnd]`, the window currently drawn.
  New. Today it is implicitly forced equal to the content range.

Zoom is simply: let the visible range be a sub-window of the content range.

## Goals

- Add timeline zoom while preserving auto-fit-to-window as the default state.
- Keep auto-fit-on-track-change behavior while the user is fully zoomed out.
- Add a fixed bottom control bar hosting zoom controls on its right side.

## Non-Goals

- Persisting zoom/scroll across launches or session changes (reset to fit).
- Horizontal `ScrollView`-based layout (rejected — see Decisions).
- A separate "fit to window" button (zoom-out-all-the-way is fit).

## Decisions (with rationale)

These were worked through interactively on 2026-06-23. Recorded here so they can
be revisited after using the feature.

### D1 — Zoom representation: absolute visible window, zoom derived

**Decision:** Canonical state is the visible window in absolute seconds:
`visibleStart` and `visibleSpan`. The displayed `zoom` is *derived*:
`zoom = contentSpan / visibleSpan`. "Fit mode" is not a flag — it is simply the
state `visibleSpan ≈ contentSpan` (zoom ≈ 1).

**Why not a raw zoom factor (×2, ×4)?** A raw factor breaks the "sticky" rule
(D2). Fit is relative to content, so when content grows (e.g. add a 60s track) a
constant factor would silently change the time span under the user's eyes.
Storing the visible window in absolute seconds keeps a zoomed view stable across
content changes, and makes "zoom all the way out = fit" fall out naturally
(slider minimum sets `visibleSpan = contentSpan`).

**Why not absolute pixels-per-second (DAW-style)?** It loses cheap auto-fit:
you'd have to constantly detect "is the user currently at fit?" and re-derive it.
With zoom derived from content, fit is just `zoom ≈ 1` and is free.

### D2 — On track add while zoomed in: stay zoomed (sticky)

**Decision:** Auto-refit applies *only* while in fit mode (zoom ≈ 1). Once the
user has manually zoomed in, adding/removing tracks keeps their `visibleSpan` and
`visibleStart` (only clamp `visibleStart` to the new content bounds). The slider
thumb drifts as content changes, which is correct — you are now more/less zoomed
relative to a different whole.

**Alternatives rejected:** "Snap back to fit" (throws away the user's zoom every
time they add a take); "snap to fit only if at end" (more logic, sometimes
confusing).

### D3 — Zoom anchor: playhead

**Decision:** When the slider changes `visibleSpan`, recompute `visibleStart` to
keep the playhead at the same on-screen position. Fall back to view-center if the
playhead is currently off-screen.

**Rationale:** This is an audition app — you zoom in to scrutinize the spot you
are listening to, so it should stay under your eyes.

Note: pinch-to-zoom (D5) anchors to the **cursor** instead, which is the
expected behavior for a pointer-driven gesture.

### D4 — Zoom control: slider with −/+ icon buttons, no fit button

**Decision:** A zoom slider on the right of the bottom bar, flanked by zoom-out
(−) and zoom-in (+) icon buttons that act as stepped controls. No separate "fit"
button — dragging the slider to minimum is fit. Slider is logarithmic (the zoom
range is large); buttons step by a fixed log increment.

### D5 — Pan / additional zoom inputs

**Decision (multi-select):**

- **Two-finger horizontal scroll** → pan (shift `visibleStart`). Does not
  conflict with click-to-seek.
- **Pinch to zoom** (trackpad magnify) → extra zoom input, anchored to the
  cursor.

Note: a plain click-drag on the waveform already *seeks* the playhead, which is
why panning needs its own gesture rather than reusing drag.

### D6 — Playback follow: page at the edge

**Decision (revised after use):** While playing and zoomed in, hold the window
still and let the playhead run across it; when the playhead reaches the right
edge, page forward so it lands back at the left edge (`visibleStart = transport`,
clamped so the final page rests against the content end and the playhead reaches
the edge there). Active only during playback; free scrolling when paused.

**Why the change:** The original decision was continuous centering
(`visibleStart = transport − visibleSpan/2` every tick). In practice the
constant sub-pixel scrolling was visually busy and made the waveform shimmer as
it re-rendered each frame. Paging keeps `visibleStart` constant between jumps, so
the waveform is static and only the playhead moves — calmer, and it sidesteps the
per-frame re-render entirely.

**Alternatives rejected:** "Keep centered" (original — busy, shimmered);
"don't follow" (lose sight of playback when zoomed).

### D7 — Max zoom (tunable default)

**Decision:** Minimum visible span ≈ **0.5 s** (enough to scrutinize transients,
prevents absurd zoom). This is a tunable, picked as a default; revisit after use.

## Architecture / Implementation Plan

### State ownership

- Add `visibleStart` / `visibleSpan` fields on `PlaybackController` (next to
  `recalculateSessionDuration`), because both content-change clamping (D2) and
  playback-follow (D6) need to write them.
- Add a pure-math namespace `TimelineViewport` (mirroring `TransportMapping` and
  `TimelineHeaderMarker` — pure functions + unit tests) holding: fit detection,
  playhead-anchored rezoom, clamp-on-content-change, and center-follow math.

### Coordinate refactor (small, centralized)

Re-base on the visible window instead of the content range:

- `xPosition(for:width:)` / `globalTime(atX:width:)` → normalize against
  `visibleStart` / `visibleSpan`.
- Waveform lane width → `duration / visibleSpan`, then **clip lanes to the
  viewport**.
- Seek + offset drag gestures already route through `globalTime(atX:)`, so they
  need **no changes**.

Reject a horizontal `ScrollView`: the code is already "normalized × width", and
keeping a fixed-width viewport gives precise control over zoom-to-playhead and
follow-during-playback, both painful to drive through SwiftUI's ScrollView.

### Two things to get right

- **Gesture capture:** SwiftUI has no scroll-wheel gesture for arbitrary views.
  Use a thin transparent `NSViewRepresentable` overlay capturing `scrollWheel`
  (pan) and `magnify` (pinch-zoom).
- **Waveform perf at high zoom:** do *not* build a Canvas frame of width
  `duration/visibleSpan × viewport` (explodes at high zoom). Keep the Canvas at
  viewport width and pass the visible bucket sub-range into `waveformPath`. Keeps
  it O(viewport px) regardless of zoom — a small change to that one function.

### UI

- New fixed bottom control bar holding the zoom control (−/slider/+, D4),
  right-aligned. No scrollbar (D5 update).
