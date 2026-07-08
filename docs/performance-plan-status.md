# Takes Performance Improvement Plan

## Context

Takes' CPU during playback scales roughly linearly with the number of loaded
tracks (39% at 1 track → 105% at 20), while comparable players (QuickTime,
Music.app, Fission) stay in the single digits even at 10–20 tracks. Because the
audio engine work is fixed per track and small, the ramp points at the **UI
layer**, not audio. On top of that, with 20 tracks open, vertical/horizontal
scrolling, drag-to-reorder, and drag-to-select-loop all drop frames, and the app
burns 3–4% CPU while idle in the background (should be ~0%).

Root cause (confirmed by reading the code): the entire UI observes a single
coarse `@Published var session = ComparisonSession()` on `PlaybackController`
([PlaybackController.swift:9](Sources/Takes/PlaybackController.swift:9)). A 20 Hz
`Timer` writes `session.transportPosition` on every tick
([PlaybackController.swift:1611-1637](Sources/Takes/PlaybackController.swift:1611)),
which fires `objectWillChange` and invalidates every view holding
`@ObservedObject var controller` — including all N waveform lanes. Each lane's
`Canvas` then rebuilds its peak `Path` from scratch
([ContentView.swift:2709-2726](Sources/Takes/ContentView.swift:2709),
[ContentView.swift:2783-2858](Sources/Takes/ContentView.swift:2783)), even though
the waveform geometry hasn't changed. So playback = N full waveform redraws × 20/s.

Deployment target is **macOS 14** ([project.pbxproj:368](Takes.xcodeproj/project.pbxproj)),
so the Observation framework (`@Observable`) is available — the cleanest fix for
coarse invalidation.

**Sequencing:** biggest wins first, then iterate. **Measurement:** Instruments
(Time Profiler + SwiftUI) plus re-running the CPU-vs-track-count table before/after
each iteration.

---

## STATUS 2026-07-06 — Iterations 1 + 2 DONE (branch `perf/iteration-1-observable`, commit f20853a)

Measured results (Release, Activity Monitor/top):

| Scenario | Before | After |
|---|---|---|
| 1 track playing | 39% | ~2% |
| 10 tracks playing | 90% | ~5% |
| 18–20 tracks playing | 105% | ~8.5% |
| Paused / idle | 3–4% | 0.0% |

Two of this plan's assumptions were **wrong**; corrections that shaped the fix:

1. **`@Observable` does NOT track fields of a nested struct.** `session` is one
   observable property; any write to `session.transportPosition` invalidates
   every view reading any part of `session`. The real fix was to stop writing
   `transportPosition` per tick entirely — it's derivable from the schedule
   anchors (`displayTransportPosition()`), and is written only at anchor
   events (play/pause/seek/stop/wrap). All logic reads that need live position
   go through `currentTransportPosition()`.
2. **On macOS, SwiftUI cannot animate anything for free.** Both
   `TimelineView(.animation)` (even with `minimumInterval`, which throttles
   content but keeps the window's display-link layout cycle running at full
   refresh) and `withAnimation` of an offset interpolate on the main thread
   every frame (~15–20% CPU fixed). The playhead is now CALayers moved by one
   `CABasicAnimation` per anchor event — render-server interpolation, zero
   app CPU. The transport readout is a controller string written ~1×/s.
   **Any future "smooth motion during playback" feature must use CA, not
   SwiftUI animation or TimelineView.**

Also done: engine pause on pause/stop/end (idle 0%), equatable
`WaveformLaneView`, Now-Playing set-and-forget via `withObservationTracking`,
waveform QoS bump, mouse-monitor + pulse-animation idle fixes.

Remaining: Iteration 3 (scroll/drag/loop framerate at 20 tracks — likely much
better now, re-test before doing anything), Iteration 5 (align/analysis
speed), and re-checking blind-listening + loop behaviors manually.

---

## STATUS 2026-07-07 — Manual re-test done; Iteration 3 root causes pinpointed

User re-tested with many tracks loaded. Confirmed still bad: **horizontal
scroll of waveforms** and **drag-to-reorder** both remain jerky. Both are
covered by Iteration 3; code reading pinpointed the shared root cause, so the
Iteration 3 items are now concretized as work packages 3a/3b below.

What the code already does (landed with Iteration 1, keep intact):

- Lanes draw a **2×-viewport window on a half-viewport grid** in absolute
  timeline time (`LaneViewport`, `makeLaneViewport`), and the parent slides
  the window with `.offset(x: -shiftX)`
  ([ContentView.swift:2490-2542](Sources/Takes/ContentView.swift:2490)). So the
  lane `Canvas` (equatable `WaveformLaneView`) only re-rasterizes when the
  viewport crosses a half-viewport grid boundary — not per scroll event.

Remaining root causes:

1. **Per-scroll-event row diffing (3a).** Every scroll event writes
   `session.visibleStart`; the container body re-runs and rebuilds/diffs the
   *entire* `trackRow` tree for all N tracks
   ([ContentView.swift:1632-1695](Sources/Takes/ContentView.swift:1632),
   [ContentView.swift:2010](Sources/Takes/ContentView.swift:2010)) — info
   column with badges/gradients/steppers/drag-source closures included — at
   60–120 Hz on the main thread. Only the lane leaf is equatable; the row is
   not. **Reorder is the same bug**: each gap move bumps
   `reorderTargetIndex`/`reorderGapGeneration` (parent `@State`) → same full
   N-row rebuild + diff per pointer move, plus the offset animation.
2. **Synchronized grid-boundary rasterization (3b).** When the window grid
   boundary is crossed, all N lane Canvases re-rasterize a 2×-viewport-wide
   filled path in the same frame on the main thread → periodic hitch every
   half-viewport of scrolling; worse with more tracks.

**Work package 3a — isolate row bodies (fixes both continuous scroll jank and
reorder jank):**

- Extract the track row into an `Equatable` struct view keyed on value inputs
  (index, `SessionTrack`, `Waveform` (storage-identity-cheap `==`), isActive,
  isHovered/showsTrash, isBlind, offset-field focus, infoWidth, and the lane
  *window* fields — NOT `shiftX`). Closures excluded from `==`.
- Keep per-event work out of rows: apply the scroll `shiftX` in a tiny leaf
  wrapper that alone reads `visibleStart` (per-event body = one `.offset`), or
  apply it once to a shared lanes container. Rows must not receive any value
  that changes per scroll event or per reorder gap move (gap `.offset(y:)` and
  lifted `.opacity` stay applied *outside* the equatable row, as today).
- Result: scroll event → N trivial `==` checks + leaf offset updates; gap move
  → same. No row body re-runs.

**Work package 3b — async lane-window rasterization (fixes boundary hitch):**

- Replace the lane Canvas path-fill with a pre-rendered image of the lane
  window, rendered **off the main thread** (reuse the existing
  `waveformPath` math into a CGContext). On window/zoom/waveform-revision
  change, kick a background render; **keep showing the previous window's image
  (offset by its own windowStart) until the new one is ready** — the 2×
  window has a half-viewport of slack, so stale content still covers the
  viewport during the swap.
- Render the image as a template/alpha mask so active-track tint switches
  don't force re-rasterization.
- This subsumes the plan's "translatable waveform bitmaps" fallback without
  an NSView/CALayer rewrite; if measurement later shows SwiftUI image
  compositing per lane is still hot, CALayer contents is the escalation path.

Sequencing: 3a first (biggest, fixes both symptoms), then 3b, re-test feel
between. Loop-drag re-test after 3a (same root cause; likely fixed by it).

Also fixed today (unrelated bug, main tree): the timeline cursor manager was
entirely dead — its guard compared `window.frameAutosaveName` ("main") against
the UserDefaults key string "NSWindow Frame main", which can never match. Now
compares against the captured `mainWindow` reference. Plus: re-assert cursors
on every move inside a hot zone (AppKit cursor rects fight the manager), and
the ruler scrub's mouse-up records its openHand in the manager state so it
can't stick. Verified at runtime with synthetic pointer events reading
`NSCursor.currentSystem`.

### 3a/3b landed (worktree branch `worktree-agent-adebd280fa1ca3dfb`) + measured

Commits `10568b8` (3a: equatable `TrackRowView`, `LaneShiftView` leaf slide)
and `abb54ee` (3b: `LaneWaveformImage`/`LaneWaveformRenderer` off-main template
rasterization). Full test suite passes; lanes verified pixel-correct at
runtime against baseline.

Measured (Debug builds, 20 tracks, ~2.5 s visible span, scripted 8 s
horizontal scroll + 8 s reorder drag, main-thread CPU sampled via `ps -M`):

| Interaction | Baseline MT avg/max | 3a+3b MT avg/max |
|---|---|---|
| Horizontal scroll | 89.3% / 100% | 78.6% / 98.7% |
| Reorder drag | 62.7% / 92.1% | 47.1% / 70.0% |

Reorder is fixed. Scroll improved (and the synchronized 20-lane
boundary-rasterization hitch is gone; rasterization now runs on background
cores — total process CPU during scroll rose 72%→109% *by design*), but the
main thread stays near-saturated from a **pre-existing shared bottleneck**
`sample` exposed in both builds: every scroll event writes `visibleStart`, the
scroll-ZStack container reads it (`makeLaneViewport`), and rebuilding the
ZStack children forces `_ZStackLayout.sizeThatFits` → `StackLayout` to
re-measure all 20 rows per event — a layout walk that equatable row bodies
don't prevent.

**Work package 3c (landed, same branch, commit `cd2a8b9`):** the fix had to go
one level deeper than leaf-ifying readers: `@Observable` tracks `session` as
ONE property, so the per-event `session.visibleStart` write invalidated every
`session` reader regardless. `visibleStart`/`visibleSpan`/`visibleEnd` moved
out of `ComparisonSession` onto `PlaybackController` (same medicine Iteration
1 applied to `transportPosition`), mutated only via an equality-guarded
`setVisibleWindow(start:span:)` which also maintains a stored, grid-quantized
`laneWindowStart`. The container reads only the quantized window; per-event
readers are self-observing leaves (`LaneShiftView`, `TimelineHeaderRulerView`,
`TimelineScrollOverlayLeaf`, `TimelinePlayheadOverlayView`,
`LoopOverlayContentView` — gesture logic stays in ContentView closures, which
are not observation-tracked).

### Final Iteration 3 measurements (20 tracks, ~2.5 s visible span, scripted
8 s flick-scroll / 8 s reorder drag, main-thread CPU via `ps -M`)

| Interaction | Config | Baseline MT avg/max | 3a+3b | 3a+3b+3c |
|---|---|---|---|---|
| Horizontal scroll | Debug | 89.3% / 100% | 78.6% / 98.7% | 69.5% / 93.7% |
| Horizontal scroll | Release | 98.0% / 100% | — | 77.2% / 97.3% |
| Reorder drag | Debug | 62.7% / 92.1% | 47.1% / 70.0% | 46.1% / 67.9% |
| Reorder drag | Release | 60.7% / 88.7% | — | 43.1% / 64.0% |

`sample` profiles across the stages: baseline/3a+3b spent the scroll in
AttributeGraph body+layout storms (`_ZStackLayout.sizeThatFits` re-measuring
all rows per event); after 3c that is gone and the remaining main-thread cost
is `DisplayList.ViewUpdater` geometry updates — SwiftUI's per-frame
bookkeeping for physically moving ~20 wide image layers (`CoreViewSetGeometry`
→ `setFrameOrigin`). The synchronized boundary-rasterization hitch is gone
(renders are async on background cores; total-process CPU during scroll rises
by design).

**Assessment / designed escalation (WP-3d, only if scroll still feels bad in
manual testing):** the remaining per-event work is inherent to letting SwiftUI
move the lanes. The escalation is the plan's original "translatable bitmaps on
CALayer" end-state: host all lane images in one layer-backed NSView and set
sublayer positions directly from the scroll overlay's callback — zero SwiftUI
involvement per scroll event. Hold until the user feel-tests the 3c build;
reorder and boundary hitches are already fixed, and 77% avg with the hitch
source gone may well feel smooth.

## STATUS 2026-07-07 (evening) — User feel-test: wins confirmed, regressions found

User verdict on the 3a–3c build (20+ tracks): scroll better, reorder "buttery
smooth" — but the async render pipeline shipped regressions, all triaged to
two root causes plus separates:

1. **Cancellation starvation** (`LaneWaveformImage` uses `.task(id:renderKey)`,
   which cancels the in-flight render on every key change): during file load,
   waveform-generation progress bumps the key ~20 Hz/lane, so renders die
   before finishing → lanes stay blank, then "flash in chunks". Same
   starvation during zoom (continuous key churn → waveform frozen while
   ruler/playhead move live) and fast scroll (blank lanes at high zoom,
   flicker at low zoom). Fix: never-cancel render loop per lane (finish,
   publish, then re-render at the latest key; drop only intermediate keys) +
   throttle generation-progress re-renders (~5 Hz/lane, never dropping the
   final render).
2. **Stale-image placement is scale-blind and unbounded**: the previous
   window's image is translated by its own `windowStart` but NOT rescaled when
   zoom changes points-per-second — the frozen-waveform look during zoom. The
   translation is also unbounded, and `.clipped()` does not clip HIT TESTING
   in SwiftUI — after deep zoom the stale wide image can sit invisibly over
   the track-info column swallowing clicks (matches "info area dead when
   zoomed in"). Fix: scale stale images by the points-per-second ratio, and
   mark the entire lane visual subtree (+ playhead overlay leaf)
   `.allowsHitTesting(false)` — lane interaction lives on the loop overlay,
   never on the lane visuals.
3. **Zoomed playback-follow flicker** — expected to be the same two causes;
   re-test after.
4. **Timeline cursor fixes were never on this branch** (they live uncommitted
   in the main tree) — port them (dead `frameAutosaveName` guard →
   `window === mainWindow`; hot-zone re-assert; scrub-end shape recording).
5. **New, pre-existing audio bug (WP-4b): audible gap between loop repeats at
   20+ tracks.** At wrap, `restartPlayback` synchronously stops → reschedules
   → restarts all N player nodes on the main thread at the moment the loop
   ends ([PlaybackController.swift:1726](Sources/Takes/PlaybackController.swift:1726)).
   Fix: gapless pre-queueing — schedule the next loop iteration's segments
   onto the players before the current iteration ends; the wrap becomes an
   anchor/audibility update only. Invalidate pre-queues on seek / loop change
   / track changes / repeat-mode change.

WP-4a (items 1–4, ContentView) and WP-4b (item 5, PlaybackController) are
delegated to parallel agents; WP-4b branches off the perf branch in its own
worktree since the files are disjoint.

## STATUS 2026-07-08 — WP-4a verified good; WP-5 in flight; WP-4b parked

WP-4a landed (commits `f5139b0`, `72622c2`): never-cancelled per-lane render
loop with ~5 Hz progress throttling, scale-aware stale-image placement (pinned
to the ruler under zoom), `.allowsHitTesting(false)` across all lane visuals,
cursor fixes ported. Notable finding: the zoomed-in dead info column was
primarily the lanes' near-transparent full-window base fill overhanging the
frozen column (hit-testable despite `.clipped()`) — present since Iteration 1.

User re-test ([docs/performance-manual-testing-results.md](performance-manual-testing-results.md)):
zoom sync GOOD, info-column clicks GOOD, playhead/loop-handle drags GOOD,
vertical scroll during initial render decent. Cursor probes re-verified at
runtime (grabber/handles/scrub cycle all pass on the branch build).

**WP-5 (in flight, same branch)** from the user's remaining items:

- **5a — peak pyramid.** `waveformPath` walks every bucket in the window per
  render (256 frames/bucket, ≈41k buckets per 4-min track; ~800k bucket
  visits × 20 lanes per zoom-out step) — why hi-res renders lag the stale
  placeholders ("scaled low-res then pop-in" / blank zoom-out). Fix is the
  GarageBand technique: in-memory multi-resolution peak levels, path built
  from the level nearest ~1–2 buckets/vertex → O(viewport px) at any zoom.
- **5b — vertical visibility culling.** Only lanes in the vertical viewport
  (±2 rows overscan) rasterize; fixed row heights make the range pure math;
  quantized/equality-guarded so per-event vertical scroll stays off the
  container (3c pattern). Addresses the user's resize-to-1-track test.
- **5c — bounded, top-first waveform generation.** Concurrency cap (2–3) in
  session order + a static "pending" lane visual (no repeat-forever SwiftUI
  animation — CA-only rule).

**WP-4b (loop-gap) parked, lowest priority per user:** its agent hit a session
limit mid-implementation; `/private/tmp/takes-loopgap` (branch
`perf/loop-gap-fix`) holds partial uncommitted pre-queue work. Resume after
WP-5 lands and is verified.

---

## Iteration 0 — Baseline instrumentation (do first)

Establish repeatable measurement before changing anything.

- Build a Release/Profile build and capture an **Instruments** trace during
  playback with 20 tracks using **Time Profiler** + the **SwiftUI** template
  (View Body / Update counts). Confirm the hypothesis: waveform-lane `Canvas`
  draw + SwiftUI `ViewGraph` update dominate, scaling with track count.
- Re-measure the user's CPU table (1/2/3/4/5/6/10/20 tracks, playing) via
  Activity Monitor, plus the three UI-scroll/drag cases and the idle-background
  case, so each later iteration has a concrete before/after.
- Measure the CPU table **both zoomed-out and zoomed-in with playhead-follow**:
  when zoomed in, `followPlayheadIfZoomed()` moves `visibleStart` every tick,
  so lanes legitimately redraw — that scenario has a different (higher) floor
  and needs its own baseline.
- **Establish the audio-engine floor**: measure 20-track playback with the
  window minimized/occluded (SwiftUI stops drawing) to isolate pure
  audio-render cost. Takes keeps all N players rendering with muted mixers by
  design (instant A/B switching), so the realistic per-track floor is above
  QuickTime's ~1.6%/track — know that number so we don't chase UI ghosts
  below it.
- Sample audio for many-track testing lives in `Private/Audio Samples` at repo
  root (see memory) — use it to load 20 tracks quickly.
- `sample Takes 10` / `powermetrics` are scriptable supplements to Instruments
  for before/after tables.

No source changes in this iteration.

---

## Iteration 1 — Kill the 20 Hz whole-UI invalidation (largest win)

**Goal:** transport-position updates during playback should re-render only the
playhead + timestamp, not the waveform lanes. Target: flatten the CPU curve so
20 tracks playing is close to 1 track playing.

**Approach: migrate to the Observation framework (`@Observable`).**

Chosen over a surgical state-split because the coarse-observation problem is
structural (loop-drag, zoom, and reorder all mutate the same `session` and will
hit the same wall), macOS 14 already supports it, and it removes the whole class
of bug rather than one instance. It is a bounded change: one primary object plus
a handful of reference sites.

Primary changes:

- `PlaybackController` → `@Observable` (drop `ObservableObject` /
  `@Published`), [PlaybackController.swift:6-23](Sources/Takes/PlaybackController.swift:6).
  With `@Observable`, SwiftUI tracks per-property reads through the nested
  `ComparisonSession` value type, so a view that reads `waveform` +
  `activeTrackID` but not `transportPosition` won't re-render on transport ticks.
- Update reference sites:
  - `@ObservedObject var controller` → plain `var controller` (or `@Bindable`
    where two-way bindings are needed): [ContentView.swift:324](Sources/Takes/ContentView.swift:324),
    [ContentView.swift:927](Sources/Takes/ContentView.swift:927),
    [TakesApp.swift:773](Sources/Takes/TakesApp.swift:773).
  - `@StateObject private var controller` → `@State` in
    [TakesApp.swift:525](Sources/Takes/TakesApp.swift:525).
  - Replace the Combine subscription `controller.$session.sink { ... }`
    ([TakesApp.swift:231](Sources/Takes/TakesApp.swift:231)) — `$session` no
    longer exists. **Now-Playing: set-and-forget, not throttle.** Each
    `nowPlayingInfo` write is an XPC round-trip to mediaremoted; instead of
    rewriting it 20×/s, set `MPNowPlayingInfoPropertyElapsedPlaybackTime` +
    `PlaybackRate` once on play/pause/seek/track-switch/loop-wrap and let the
    system extrapolate position (the QuickTime approach). Zero per-tick writes.
- **Playhead via `TimelineView(.animation)` instead of the 20 Hz timer**
  (promoted from Iteration 4): drive the playhead overlay and timestamp from
  `TimelineView` + pure transport math off `CACurrentMediaTime()`. Smoother
  playhead (display-refresh rate instead of 20 fps) *and* the model write rate
  can drop to ~2–4 Hz — only needed for end-of-range detection and
  scroll-follow.
- **Waveform generation QoS**: `WaveformStore.start` runs at
  `Task.detached(priority: .utility)`
  ([WaveformStore.swift:80](Sources/Takes/WaveformStore.swift:80)) — utility
  gets throttled onto efficiency cores. This is user-visible work; bump to
  `.userInitiated`. (Addresses "initial waveform render is slower than other
  apps".)
- **Fold in the two tiny idle-CPU fixes from Iteration 2** (mouse-monitor mask,
  pulse animation) — they're independent one-liners and don't need to wait.
- Leave `AppSettings`, `SoftwareUpdater`, `YTDLPUpdateState`,
  `OpenFileCommandState` as `ObservableObject` for now (mixed paradigms are
  fine); migrate opportunistically only if they show up as hotspots.
- **`WaveformStore` is a known second coarse observable, not "likely fine"**:
  while N tracks generate simultaneously, each track's progress emits (up to
  20 Hz per track) invalidate every view reading the `@Published waveforms`
  dictionary — the exact load-time scenario the user flagged as slow. The
  equatable-lane subview should absorb this (a lane's inputs only change when
  *its* waveform changes) — verify that explicitly in this iteration's
  Instruments pass rather than assuming it.

Complementary safeguards (independent of the migration, cheap insurance so the
waveform `Canvas` doesn't redraw even if its view is re-evaluated):

- Make the waveform lane a **dedicated, equatable subview** keyed only on its
  inputs (waveform identity/generation, viewport `visibleStart`/`visibleSpan`,
  `isActive`, size), so it structurally can't depend on `transportPosition`.
  Today it's an inline `waveformLane(index:sessionTrack:)` computed function
  ([ContentView.swift:2482](Sources/Takes/ContentView.swift:2482)); extract it to
  a `struct` with `Equatable` (or `.equatable()`) inputs.
- Have the playhead overlay
  ([ContentView.swift:1861](Sources/Takes/ContentView.swift:1861)) and timestamp
  readout ([ContentView.swift:1259](Sources/Takes/ContentView.swift:1259)) be the
  only things reading `transportPosition`.

**Verify:** Instruments SwiftUI trace shows waveform-lane body/draw count no
longer scaling with playback ticks; CPU table should be near-flat across track
counts. Run `xcodebuild test` (transport/session/loop math is covered by
`TransportMappingTests`, `SessionTests`, `LoopingTests`).

---

## Iteration 2 — Idle / background CPU → ~0%

**Goal:** 0% when paused and backgrounded.

- Confirm with Instruments which run loop is waking. Prime suspects found in
  code:
  - The repeat-forever pulse animation
    ([ContentView.swift:1454](Sources/Takes/ContentView.swift:1454)):
    `.easeInOut(...).repeatForever(autoreverses: true)` runs indefinitely once
    `alignmentOutcome` is set. Ensure it is stopped/cleared (and not restarted)
    when the outcome resolves, so no forever-animation keeps the display link alive.
  - The `.mouseMoved` local monitor
    ([KeyMonitor.swift:63-77](Sources/Takes/KeyMonitor.swift:63)) fires its
    closure on every pointer move while key; the click monitor registers for
    `.mouseMoved` only to early-return
    ([ContentView.swift:2971](Sources/Takes/ContentView.swift:2971)). Drop
    `.mouseMoved` from the monitor mask where the handler ignores it.
  - Confirm both playback `Timer`s are torn down when not playing — `pause()`
    ([PlaybackController.swift:454](Sources/Takes/PlaybackController.swift:454))
    and `stop()` ([:467](Sources/Takes/PlaybackController.swift:467)) already
    invalidate; verify `scrollAnimationTimer`
    ([PlaybackController.swift:1197](Sources/Takes/PlaybackController.swift:1197))
    always stops.

**Verify:** Activity Monitor shows ~0% when paused + window backgrounded, and no
periodic wakeups in an Instruments idle sample.

---

## Iteration 3 — Scroll / drag / loop framerate at 20 tracks

**Goal:** smooth vertical + horizontal scroll, reorder, and loop-drag.

- **Vertical scroll:** the track list is a non-lazy `VStack` inside
  `ScrollView(.vertical)`
  ([ContentView.swift:1611-1635](Sources/Takes/ContentView.swift:1611)) — all N
  lanes (each a `GeometryReader` + `Canvas`) are always mounted. Evaluate
  `LazyVStack` so off-screen lanes aren't laid out/redrawn. (Note the overlaid
  loop layer and reorder-offset animation share this container — validate they
  still line up under lazy layout.)
- **Horizontal scroll / zoom:** the `Canvas` already draws only the viewport
  width and is O(viewport px)
  ([ContentView.swift:2768-2782](Sources/Takes/ContentView.swift:2768)); after
  Iteration 1 it should only redraw when `visibleStart`/`visibleSpan` actually
  change. Confirm horizontal scroll doesn't also invalidate unrelated state.
- **Designated fallback if scroll/zoomed-follow is still hot: translatable
  waveform bitmaps.** `Canvas` rasterizes paths on the CPU every redraw, and
  during zoomed playback-follow all lanes legitimately re-rasterize each tick.
  The DAW approach: render each lane's waveform into a cached image (or tiles)
  at the current zoom, and let scrolling *translate* the layer — GPU
  compositing does that for free; re-rasterize only on zoom change or
  generation progress. This subsumes (and beats) caching the built `Path`:
  path *fill* is the expensive part, not path build. A full Metal waveform
  renderer is overkill — don't go there.
- **Drag-to-reorder:** the reorder gesture drives `.offset`/`.animation` across
  all rows ([ContentView.swift:1626-1632](Sources/Takes/ContentView.swift:1626)).
  Ensure `onChanged` only updates lightweight offset state and doesn't touch
  `session` (which would re-run heavy bodies); memoize per-row offset math.
- **Drag-to-select-loop:** `handleLoopSelectionChanged`
  ([ContentView.swift:2656](Sources/Takes/ContentView.swift:2656)) writes loop
  state on every drag delta; keep the in-progress selection in local `@State`
  and commit to `session.loopRegion` only on `.onEnded`, so mid-drag doesn't
  invalidate the whole tree (largely mitigated by Iteration 1 + equatable lanes,
  but verify).

**Verify:** Instruments Animation Hitches / Core Animation FPS during each
interaction with 20 tracks; visually smooth via the `run-takes` skill.

---

## Iteration 4 — Trim residual per-tick work (if still needed)

Only if the CPU table isn't flat after Iterations 1–3. (Now-Playing
set-and-forget and the TimelineView playhead moved up into Iteration 1.)

- Lower the remaining model-write tick rate further if the playhead no longer
  depends on it.
- Re-profile and iterate.

---

## Iteration 5 — Load & analysis speed (align/analysis paths)

The DSP layer is already well-vectorized (vDSP waveform peaks, FFT-based
alignment correlation, vDSP `RealFFT`/Biquad analysis, one-shot CGImage
spectrogram). The remaining wins are redundant decoding and a few scalar hot
loops. **No disk caches** — users open different files on most launches
(see memory); in-memory, process-lifetime caches only.

- **Cache novelty envelopes in memory per file identity.** Every align run
  re-decodes every file from scratch; envelopes are tiny (1 kHz floats ≈
  240 KB/hour). Reuse the `WaveformSource.Identity` fingerprint pattern.
- Longer-term: a shared single-pass decode feeding waveform peaks + novelty
  (+ analysis accumulators) from one read, since decode dominates all three.
- **Vectorize `CorrelationScan.bestPeak`**
  ([TrackAligner.swift:599](Sources/Takes/TrackAligner.swift:599)) — scalar
  loop over up to millions of lags, run ~50× per track in the tempo pass; the
  hottest scalar code in the app. Energies come from prefix-sum differences,
  so the scan vectorizes: `vDSP.subtract` on shifted prefix slices, `vvsqrtf`,
  `vDSP.divide`, `vDSP_maxvi`.
- Opportunistic (only if traces say so): `smoothed` → `vDSP_vswsum`,
  `stretchedEnvelope` → `vDSP_vgenp`, `noveltyFromEnergy` → `vvlog10f`,
  mono downmix in `AudioAnalysisEngine.analyze` → `vDSP.add`/`vDSP_vsmul`,
  spectrogram per-pixel color loop → LUT + vDSP normalization.
- Explicitly **not** doing: GPU/Metal compute for analysis FFTs (one-shot work,
  vDSP is microseconds), explicit SIMD types (vDSP already covers it),
  waveform disk cache (rejected — see above).

---

## Verification (applies to every iteration)

1. **Instruments** (Release build): Time Profiler + SwiftUI template during
   20-track playback and during each scroll/drag interaction; idle sample when
   paused+backgrounded. Compare against the Iteration 0 baseline.
2. **CPU table**: re-measure Activity Monitor CPU at 1/2/3/4/5/6/10/20 tracks
   playing; target a near-flat curve.
3. **Tests** (canonical repo check per AGENTS.md):
   ```bash
   xcodebuild -project Takes.xcodeproj -scheme Takes \
     -destination 'platform=macOS' \
     -derivedDataPath /private/tmp/takes-derived-data \
     CODE_SIGNING_ALLOWED=NO test
   ```
   Focus: `TransportMappingTests`, `SessionTests`, `LoopingTests`,
   `TimelineHeaderMarkerTests`, `WaveformSourceTests`.
4. **Manual sanity** via the `run-takes` skill: playback transport, repeat modes,
   loop select/resize, reorder, zoom, blind-listening — confirm no behavior
   regressions against the invariants in AGENTS.md (shared signed timeline,
   duplicate detection, removal state-safety, blind-listening reapply,
   focus-safe shortcuts).

## Critical files

- [PlaybackController.swift](Sources/Takes/PlaybackController.swift) — object
  model, transport timer, scroll-follow timer.
- [ContentView.swift](Sources/Takes/ContentView.swift) — waveform lanes,
  playhead overlay, scroll container, reorder + loop gestures.
- [Models.swift](Sources/Takes/Models.swift) — `ComparisonSession` /
  `SessionTrack` value types.
- [TakesApp.swift](Sources/Takes/TakesApp.swift) — `@StateObject` owner,
  `$session` Combine sink, Now-Playing updates.
- [KeyMonitor.swift](Sources/Takes/KeyMonitor.swift) — mouse/key monitors.
- [WaveformStore.swift](Sources/Takes/WaveformStore.swift) — waveform cache
  (already off-main-thread; likely fine).
