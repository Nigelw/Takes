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

## STATUS 2026-07-07 — Iteration 3 work packages 3a + 3b DONE

Both landed in this worktree branch as two commits (3a, then 3b), each with a
green Debug build and full `xcodebuild test` pass. They target the two
Iteration-3 root causes for jerky horizontal scroll and drag-to-reorder at ~20
tracks: per-scroll-event whole-row diffing, and synchronized grid-boundary
rasterization. Not yet measured with Instruments / the CPU table and not yet
manually driven (the worktree has no `Private/Audio Samples`), so the numbers
and feel still need a pass on a checkout that can load 20 tracks.

**3a — row-body isolation (all in `ContentView.swift`):**

- The track row is now `TrackRowView: View, Equatable`, applied `.equatable()`
  in the container `ForEach`. It stores only value inputs (index, `SessionTrack`,
  `Waveform?`, isActive, showsTrash, isBlind, offset-field focus, infoWidth,
  row height, offset config, badge appearance, debug flag, and the
  grid-quantized lane-window fields) plus `controller`/action closures that are
  excluded from a hand-written `==`. The row body reads no observable state; the
  container builds the values (`trackRowView(...)`) and passes actions as
  closures. A scroll event or reorder gap move now costs N `==` checks + trivial
  leaf/transform updates instead of N full row rebuilds.
- The per-scroll-event lane slide moved into a new `LaneShiftView` leaf that
  alone reads `visibleStart`/`visibleSpan` and applies `.offset(x: -shiftX)`;
  `LaneViewport.shiftX` was removed (the struct now carries only grid-quantized
  fields). The reorder gap `offset(y:)`/`opacity`/animation stay applied by the
  container outside the equatable row, so gap moves animate transforms without
  re-running row bodies.
- Support changes: index badge extracted to shared `TrackIndexBadgeView` (also
  used by the reorder preview card); `NumericControlConfiguration` made
  `Equatable`. `==` is marked `nonisolated` (Swift 6 mode, since the type stores
  main-actor closures/`controller`).

**3b — async lane-window rasterization (all in `ContentView.swift`):**

- `WaveformLaneView`'s non-blind Canvas path-fill is replaced by
  `LaneWaveformImage`, which shows a pre-rendered template image of the 2×
  window. Rendering runs off the main thread via `LaneWaveformRenderer.makeImage`
  (a `nonisolated` enum method, so it executes on the cooperative pool), reusing
  the moved `waveformPath` math to fill into a CGContext. `.task(id: renderKey)`
  coalesces: a new window/zoom/waveform-revision/scale/offset cancels the prior
  render and starts one; the result of a superseded render is dropped.
- The previous image is retained (`@State`) and shown until the next is ready,
  positioned by its own `windowStart` (`translation` term) so its peaks stay at
  the correct absolute time within the target-window frame — the 2× window's
  half-viewport slack covers the screen during the swap, and it stays aligned
  with the vector tick guides (which still track the target window). First frame
  is a clean empty→drawn cut (no flash).
- The image is an alpha (template) mask tinted by `foregroundStyle`, so an
  active/inactive A/B color swap re-tints without re-rasterizing (`isActive` is
  excluded from `renderKey`). Rendered at `displayScale` (2×) for crispness.
  In-memory only; nothing hits disk. Major-tick guides, the 0:00 marker, and the
  blind-listening placeholder stay cheap vector/Canvas overlays; blind lanes
  still get a `nil` waveform so nothing routes through the image renderer.

**Deviations from the 3b spec:** none material. The alpha-only 8-bit context
(`CGColorSpaceCreateDeviceGray()` + `.alphaOnly`) was verified at runtime to
create successfully and to tint correctly through an `isTemplate` `NSImage`, so
the tiny-memory goal is met; a `premultipliedLast` RGBA context is kept as an
automatic fallback in case a future OS rejects that layout. `NSImage` crosses
the actor boundary via `-> sending NSImage?` (Swift 6).

**Still needs manual re-testing** (couldn't be done in-worktree): the actual
scroll/reorder smoothness and CPU/Instruments numbers at 20 tracks; that the
waveform envelope renders visibly (template path exercised only in unit build,
not on real audio here); grid-boundary swaps look seamless during fast scroll;
zoom, offset editing, blind-listening toggle, active-row A/B, loop
select/resize, and the reorder lifted-row fade-in all still behave.

**3c — kill the per-scroll-event container re-run (added after architect
measurement: 3a/3b landed the reorder win and removed the boundary hitch, but
flick scrolling still near-saturated the main thread via a shared
`sizeThatFits` walk).**

The remaining bottleneck was structural: `@Observable` tracks `session` as ONE
property, so `scrollTimeline`'s per-event `session.visibleStart` write
invalidated every view reading any part of `session` — the whole `ContentView`
body re-ran and the rows ZStack re-laid-out per event even with equatable
rows. Fix, in three parts:

- `visibleStart` / `visibleSpan` (+ derived `visibleEnd`) moved OUT of
  `ComparisonSession` onto `PlaybackController` as their own observable stored
  properties, so per-event window writes no longer touch `\.session`. All
  mutations go through one guarded `setVisibleWindow(start:span:)` (with
  `@Observable`, same-value writes still invalidate observers, hence the
  equality guards).
- New stored `laneWindowStart`: the grid-quantized window start, updated
  inside `setVisibleWindow` with an equality guard. `makeLaneViewport` reads
  it (plus `visibleSpan`) instead of quantizing raw `visibleStart`, so the
  container body's window dependencies change only at boundary crossings and
  on zoom — never per scroll event.
- Every remaining per-event body reader became a self-observing leaf (the
  3a `LaneShiftView` pattern): `TimelineHeaderRulerView` (the moving ruler —
  legitimately redraws per event), `TimelineScrollOverlayLeaf` (the
  scroll-event NSView needs the live window for its event math),
  `TimelinePlayheadOverlayView` (positions the untouched CALayer playhead;
  one representable update per event/anchor), and `LoopOverlayContentView`
  (selection rectangle + resize-handle x-positions; the gesture LOGIC —
  thresholds, draft state, commit, click-to-seek fallthrough — stays in
  `ContentView` closures, which are not observation-tracked). `globalTime` /
  `xPosition` remain as gesture/event-closure helpers only, with a comment
  banning body use.

Net: a horizontal scroll event now re-runs ~N+4 trivial leaf bodies (lane
slides, ruler, scroll overlay, playhead, loop overlay) and nothing else — no
container body re-run, no rows ForEach, no ZStack re-layout. Zoomed
playback-follow gets the same isolation for free (it writes the same window
path). Tests updated (`controller.session.visibleStart` →
`controller.visibleStart` in `SessionTests`); `ComparisonSession` no longer
carries the visible window. Full suite green (one unrelated flaky
streaming-cancellation timing test passed on re-run). Needs the measurement
harness re-run plus a manual pass on zoom (buttons / pinch / slider), ruler
scrub, loop select/resize, and zoomed playback-follow.

**WP-4a — async-render regressions from the 20+-track feel test (scroll +
reorder wins confirmed; these were the reported breakages):**

- *Cancellation starvation* (blank lanes on load that then "flash in in
  chunks"; waveforms frozen during zoom; blank/flicker during fast scroll and
  zoomed follow): `.task(id: renderKey)` cancelled the in-flight render on
  every key change, so any key churn faster than one render (generation
  progress ~20 Hz/lane, pinch-zoom, fast scroll) meant nothing ever landed.
  Replaced with a per-lane render loop (`LaneRenderModel`): in-flight renders
  are never cancelled — finish, publish, then chain into the newest key;
  intermediate keys skipped, newest never. Progress-only re-renders throttled
  to ~5 Hz/lane with a guaranteed trailing edge; `isComplete` bypasses the
  throttle. Rasterization stays off-main.
- *Stale-image placement* was scale-blind: the previous window's bitmap kept
  its rendered width during zoom while ruler/playhead moved live. Now the
  stale image is translated AND rescaled in current points-per-second so its
  absolute time range stays pinned to the ruler (stretched until the fresh
  render lands, never frozen); the fresh swap is atomic (translation 0 /
  width = wideWidth in the same body update). Drawing is bounded: skipped
  when off the lane frame or stretched beyond 16×.
- *Track-info column un-clickable when zoomed in*: `.clipped()` does not clip
  SwiftUI hit-testing, and the lane subtree (2× viewport wide, slid left by
  `shiftX` — which is > 0 whenever the viewport is off the half-viewport grid,
  i.e. effectively always when zoomed in) extended invisibly over the info
  column; its near-transparent base fill (and post-3b the translated stale
  image) swallowed the clicks. The whole `WaveformLaneView` subtree and
  `TimelinePlayheadOverlayView` are now `.allowsHitTesting(false)` — lane
  interaction lives only on the loop/scroll overlays. Note this base-fill
  overhang predates 3b (it came with Iteration 1's windowed lanes); the stale
  image made it worse.
- *Cursor fixes ported* from the main tree (they were never on this branch):
  `updateTimelineCursor` window guard compares `window === mainWindow` (the
  old `frameAutosaveName` compare against the defaults-key string was dead
  code), timeline cursors are re-asserted on every mouse move inside a hot
  zone (AppKit cursor-rects quietly reset them), and a ruler-scrub mouse-up
  records `.playheadGrab` in the manager so the next move can reset it.
- Span-clamp audit: `LaneShiftView`, `makeLaneViewport`, and
  `setVisibleWindow` all clamp with `max(visibleSpan, 0.001)` — no quantum
  mismatch left.

Still open for runtime verification: progressive load rendering feel, zoom
tracking, scroll blanking, zoomed-in info-column clicks, cursor probe, and
whether zoomed playback-follow is still jumpy after these fixes (if so, next
suspect is follow's `setVisibleWindow` writes interleaving with
boundary-triggered row rebuilds — investigate before changing architecture).

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
