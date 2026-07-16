# Performance Investigation — Findings (for review before implementation)

Status: **investigation only, nothing implemented.** Measurements are on this
machine (Apple Silicon), Debug app build for the UI case and an `-O` CLI build
for the analysis case, 20 tracks / a 4-min AAC file respectively.

---

## Area 1 — Mouse-move CPU spike over the window

### Measured (20 tracks loaded)

| Scenario | Main-thread CPU (avg / max) |
|---|---|
| Mouse sweeping over window, **Takes is key** | **37% / 57%** |
| Mouse sweeping over window, **Takes in background (non-key)** | **24% / 35%** |
| Idle (no mouse movement) | ~0% |

Both scale with track count (more rows = more cost), matching the report of
"0 → 25–50% depending on how many tracks are loaded."

### Root cause (from `sample` call graphs)

Two distinct costs, one per mouse-move event:

1. **Per-move hit-testing of the row tree.** Every mouse move makes SwiftUI
   hit-test the track list (`NSScrollView → NSClipView → DocumentView →
   ViewResponder.hitTest`) to resolve hover. This is driven by the **N per-row
   `.onHover`** modifiers (`TrackRowView` line ~3695, feeding `hoveredTrackID`),
   each of which installs a tracking area. The walk is O(rows × view depth), so
   it grows with track count. **This fires even when Takes is a background
   window** — which is the entire background-CPU cost, and it's pure waste
   there because no hover state is shown when not key.
2. **Layout storm when the hovered row changes (key window only).** Crossing a
   row boundary flips `hoveredTrackID`, which changes each row's `showsTrash`
   (a `TrackRowView` equatable input), re-runs the container body, and triggers
   a `StackLayout.sizeThatFits` pass over the rows (dominant symbol in the
   key-window profile, ~6200 samples). In the background case this term is
   near-zero (`sizeThatFits` ≈ 130) because the hover state doesn't change —
   confirming background cost is purely the hit-test walk.

The app's own `MouseMonitor` per-move handler (`updateTimelineCursor` +
gated iBeam hit-test) is cheap and **not** a meaningful contributor.

### IMPLEMENTED — result + a corrected assumption

Shipped on branch `perf/hover-cpu`:

- **Leaf-isolated the trash button.** Hover now writes a hovered-id into a
  small `@Observable TrackHoverStore` that **only a `TrackRowTrashButton` leaf
  reads** — `showsTrash` is no longer a `TrackRowView` equatable input. A hover
  change re-evaluates that one leaf (an opacity flip, no layout), so the
  container no longer re-runs and the rows no longer re-lay-out. `.onHover` is
  kept (routed into the store), which preserves exact hit-test hover/occlusion
  semantics and avoids the geometry-hover risk. Reorder suppression preserved
  (hover writes gated on `reorderDraggingID == nil`; cleared on drag start).
- **Gated the mouse monitor's per-move cursor work on `window.isKeyWindow`** —
  the app now does zero per-move work for an inactive window.

**Measured (same 20-track sweep):**

| Scenario | Before | After |
|---|---|---|
| Key window | 37% / 57% | **27% / 35%** |
| Background (non-key) | 24% / 35% | **24% / 32%** (unchanged) |

**Corrected assumption:** the doc's proposed geometry-hover fix assumed
`.onHover` drove the background cost. A cheap experiment (remove `.onHover`,
re-measure) **disproved that**: removing `.onHover` dropped the *key* case
(37→26, i.e. the ~11% was the layout storm) but left the *background* case
unchanged (24→24). So the ~24% floor — present in both cases, scaling with row
count — is **AppKit/SwiftUI hit-testing the interactive row tree for cursor
resolution on every mouse move**, not hover. It is not reachable by app-level
levers: removing `.onHover` (no effect on background), and
`acceptsMouseMovedEvents = false` when inactive (24→23, within noise) were both
tried. Reducing it would mean bypassing SwiftUI's built-in cursor/hit-testing
of the row controls (a large, risky rewrite) — **not recommended** for a
background-only cost. The layout-storm removal (the part that *was* fixable) is
the shipped win.

### Proposed direction (not yet implemented)

- **Replace the N per-row `.onHover` with a single geometry-based hover
  computation** in the existing mouse monitor: derive the hovered row from the
  pointer's Y and the fixed row height (the timeline cursor manager already
  does this style of geometry math). Write the result into a small leaf-observed
  store that **only the trash button reads** (the `LaneViewportStore` pattern).
  This removes the N tracking areas (kills the hit-test walk) *and* isolates
  `showsTrash` so a hover change no longer re-runs the container or re-lays-out
  the `VStack`.
- **Gate all hover/cursor per-move work on `window.isKeyWindow`** — when the
  window isn't key, do nothing (no hover states are shown anyway). This is the
  direct answer to "reduce background CPU when hovering."
- **First implementation step / open question:** confirm the background
  hit-testing is driven by the `.onHover` tracking areas (vs. AppKit cursor-rect
  resolution) with a quick experiment — remove `.onHover` and re-measure the
  background case. If cursor-rect resolution also contributes, the fixed cursor
  rects (`ResizeHandleNSView.addCursorRect`, etc.) may need trimming too.

Expected result: per-move cost drops to ~O(1) geometry + one leaf update in the
key window, and ~0 in the background. Effort: moderate (touches the hover
mechanism + cursor manager). Risk: medium — must preserve trash-button behavior
and its suppression during reorder drags.

### UX considerations of geometry-based hover

- **Info-column resize will NOT stutter.** The hover math is purely vertical
  (pointer Y + scroll offset → row index, with fixed row height); it does not
  depend on the info-column width. Resizing the column changes width only, so
  it never touches the hover computation. (If anything the current `.onHover`
  does *more* on resize — SwiftUI re-establishes tracking areas on layout
  change — so geometry hover is neutral-to-better here.)
- **Vertical scroll stays correct, and is arguably better:** with a stationary
  pointer, the hovered row updates as content scrolls (recomputed from the live
  scroll offset), which some hover implementations get wrong.
- **Things to get explicitly right** (these are the actual risk, not resize):
  1. Return "no row hovered" cleanly when the pointer is over the header /
     control bar / empty space below the last row, and when the window isn't
     key (the gate handles this).
  2. Preserve the existing reorder-drag suppression (`reorderDraggingID == nil`)
     so the trash button doesn't flash across rows mid-drag.
  3. **Occlusion:** geometry hover computes from Y and does not automatically
     respect a view covering a row (the floating reorder card, the import
     drop-target highlight, an alert). In this list the only real occluder is
     the reorder card, already covered by (2); drop-highlight and alerts are
     transient/modal. Manageable, but it's the one semantic difference from
     hit-test-based hover worth a deliberate check.
- **Lower-risk fallback** if we want to keep exact hit-test occlusion semantics:
  keep `.onHover` but (a) leaf-isolate `showsTrash` into a store so a hover
  change no longer re-runs the container / re-lays-out, and (b) gate on
  `isKeyWindow`. This removes the layout storm and the background waste, but may
  leave some per-move hit-test cost in the key window. Geometry hover is the
  more complete fix; this is the safer partial.

---

## Area 2 — Analysis engine slow analyses

### Measured (4-min AAC `.m4a`, best of 3, `-O` CLI = the shipping engine code)

| Selection | Time | Incremental over decode |
|---|---|---|
| loudness only (≈ decode + trivial) | **242 ms** | — (this is ~the decode floor) |
| **spectrogram** only | **198 ms** | **~0 ms** (cheaper than loudness) |
| **lossyArtifacts** only | **504 ms** | **~300 ms** |
| **analogSource** only | **460 ms** | **~260 ms** |
| ALL modules | **889 ms** | (decode shared once) |

### Spectrogram internal breakdown (decode vs STFT vs render)

Decoding to mono once, then timing the spectrogram's own stages (4-min AAC):

| Stage | Time |
|---|---|
| decode → mono | **211 ms** |
| STFT (`process`, all FFTs) | **7.1 ms** |
| render (`finalize`, image build) | **7.2 ms** |
| **spectrogram compute (STFT + render)** | **14.3 ms** |

**The spectrogram's own compute is already effectively free (~14 ms).** SIMD /
parallelization / a render LUT would shave single-digit milliseconds off a
~225 ms wall — not worth doing. **The spectrogram experience *is* decode
(~93%).** Its STFT and render are already at the floor; there is no
spectrogram-specific acceleration work worth doing.

**A decoded-PCM cache was considered and rejected** (see the cache section
below): decode is already amortized once per `analyze()` across all modules, so
a cache would only help *toggle-and-re-run-the-same-file*, and the planned
multi-file analyze window would make such a cache balloon (N files' PCM
resident). The memory-safe way to make analysis faster is **parallelism**, not
caching — which does nothing for the spectrogram's compute (it's already ~14 ms)
but cuts the heavy modules' wall time. Net: for the spectrogram, the honest
answer is "already as fast as it can be; the ~200 ms is decode you pay once per
file regardless."

### Key finding: the measured cost contradicts the assumed priority

- **Decode is a ~200 ms floor**, shared once per analysis (the engine already
  does a single streaming decode pass over all modules — no redundant reads).
- **Spectrogram *compute* is essentially free** (~0–40 ms on top of decode —
  it targets ~1100 columns regardless of file length, and the FFT/render are
  bounded). It is the **cheapest** of the three, not the most expensive.
- **Lossy (~300 ms) and Analog (~260 ms) dominate.** These run a full
  streaming STFT with per-frame, per-bin **scalar** band-power loops.

So if the **spectrogram feels slow in the app**, the time is almost certainly
**not** its compute — more likely the UI displaying/scaling the resulting
`CGImage`, or simply that enabling it runs the whole (single-threaded) analysis.
**Worth confirming what "slow" means for the spectrogram** before optimizing its
compute, since the compute is already cheap.

### Rejected: in-memory decoded-PCM cache

Considered as the headline lever, then rejected — the reasoning matters for
anyone revisiting this:

- **Gain is marginal.** The engine already decodes each file **once** per
  `analyze()` and streams all modules off that single pass, so decode is
  amortized within any run (single or batch). A cache only helps the narrow
  *toggle-a-module-and-re-run-the-exact-same-file* case.
- **It balloons under the planned multi-file analyze window.** Batch analysis
  of N files would want all N decodes resident (N × ~85 MB for 4-min stereo →
  gigabytes), and a bounded single-entry "current file" cache gives nothing
  during a batch (no single focused file). The one workflow the cache helps is
  exactly the one multi-file breaks.

Decode speed itself (~200 ms/file) is treated as a floor: parallel AAC-chunk
decoding is complex, risky, and first-run-only. Not pursuing.

### Proposed levers (biggest first, not yet implemented)

These are all **memory-safe** and scale *with* the multi-file future:

1. **Parallelize the heavy modules within one file** over the shared decoded
   buffer (`TaskGroup`/`concurrentPerform`). Lossy and Analog are independent
   accumulators; running them concurrently takes one file from ~889 ms toward
   `decode + max(module)` ≈ **~500 ms**. Memory: the one file's decode, which
   already exists. Low real risk (modules don't share state).
2. **(Multi-file future) analyze files with bounded concurrency** (e.g. 2–4 at
   once, like `WaveformStore`'s 2-at-a-time), for near-linear batch speedup on
   multicore. Peak memory = concurrency limit × one-file decode, **not** N
   files — this is the memory-safe substitute for the rejected cache.
3. **Module-internal cleanups** (each low-risk, help every run, zero memory):
   - Compute one **shared, vectorized mono mix** — currently the engine builds
     `monoMix` for the spectral path *and* Analog and Lossy each recompute their
     own mono from the channel arrays (mono done ~3×).
   - Vectorize the scalar mono-downmix loop
     ([AudioAnalysisEngine.swift:83-88](Sources/Takes/Analysis/AudioAnalysisEngine.swift:83))
     → `vDSP.add` / `vDSP_vsmul`.
   - Drop the per-chunk `channels.prefix(...).map(Array.init)` allocation
     ([AudioAnalysisEngine.swift:95](Sources/Takes/Analysis/AudioAnalysisEngine.swift:95));
     pass buffer pointers through.
   - Vectorize the per-bin band-power scalar loops in Lossy
     (`analyzeSpectralFrame`) and Analog (`storeFrame`) — `vDSP.sum` over each
     bin range instead of `for bin in range`.
4. **Spectrogram render LUT** (per-pixel color via a 256-entry lookup +
   vectorized dB normalization, replacing the branchy per-pixel `color(for:)`
   over ~560 k pixels): **low priority** given compute is already cheap;
   revisit only if the UI-display path turns out to be the real cost.

### Resolved
- **Multi-file analyze window is coming** → no per-file decode cache (see
  rejected section); use bounded-concurrency parallelism instead.
- **Spectrogram** is always-run and the user wants it as fast as possible. The
  data says its compute is already at the floor (~14 ms); its cost is the shared
  ~200 ms decode. No spectrogram-specific acceleration is warranted. If it ever
  *feels* slow in the app, suspect the UI displaying/scaling the `CGImage`, not
  the engine — a separate, UI-side investigation if needed.

---

## Suggested prioritization (pending your call)

- **Area 1:** single fix (geometry hover + key-window gate) addresses both the
  key-window spike and the background waste. Clear win, self-contained.
- **Area 2:** **intra-file module parallelism** (lever 1) is the one big,
  memory-safe win now (~890 ms → ~500 ms per file); **bounded-concurrency batch
  analysis** (lever 2) lands with the multi-file window; **vectorization
  cleanups** (lever 3) are incremental. No decode cache. No spectrogram-compute
  work — it's already optimal.
