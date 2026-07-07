# Performance Improvement Plan — Status

Tracks progress on the playback/UI performance work. Original root-cause
analysis and full iteration plan: see the "Playback Model" and general
architecture notes in [AGENTS.md](../AGENTS.md) for context on what these
iterations touch.

## Background

Playback CPU scaled with track count (39% at 1 track → 105% at 20 tracks),
while comparable players (QuickTime, Music.app, Fission) stayed in the single
digits even at 10–20 tracks. Root cause: a 20 Hz transport timer wrote a
single coarse `@Published var session` on `PlaybackController`, invalidating
every view holding it — including every waveform lane, which each rebuilt a
full peak `Path` from scratch on every tick. Idle/backgrounded CPU was also
3–4% instead of ~0%.

## Done

**Iteration 1 — kill the 20 Hz whole-UI invalidation.** Landed in
[PR #53](https://github.com/Nigelw/Takes/pull/53).
- `PlaybackController` migrated to `@Observable`; the transport tick no
  longer writes `session.transportPosition` — position during playback is
  derived from schedule anchors (written only at play/pause/seek/stop/wrap).
- Playhead is driven by a `CALayer` + one `CABasicAnimation` per anchor event,
  not a SwiftUI animation — SwiftUI/`TimelineView(.animation)` both
  interpolate on the main thread every frame on macOS, which was a fixed
  15–38% CPU cost for the duration of playback. This was the biggest single
  finding of the iteration.
- Transport readout is a controller-maintained string updated ~1×/s instead
  of every tick.
- Now Playing / `MPRemoteCommand` updates moved off a 20 Hz Combine sink onto
  `withObservationTracking` over a snapshot that reads schedule anchors, not
  the ticking position.
- `WaveformLaneView` extracted as an `Equatable` value-input subview so
  transport ticks and other tracks' waveform-generation progress can't
  redraw a lane that doesn't depend on them.

**Iteration 2 — idle/background CPU → ~0%.** Landed in PR #53.
- `AVAudioEngine` is paused on pause/stop/end-of-range.
- Mouse-moved monitor gated on the stuck-iBeam case instead of firing on
  every pointer move.
- Auto-align outcome pulse animation made finite (`repeatCount`) instead of
  `repeatForever`.

**Iteration 3 — scroll/drag/loop framerate at high track counts.** Landed in
PR #53, alongside a round of interaction bugs the playhead rearchitecture
introduced along the way (ruler drag creating a loop instead of moving the
playhead; loop deselect/pinch-zoom breaking with an active loop; missing
cursor feedback; handle clicks getting swallowed) — all fixed in the same PR.
- Waveform lanes are windowed: each lane's `Canvas` covers ~2× the viewport,
  anchored to a half-viewport time grid, so horizontal scroll and zoomed
  playback-follow slide the window with a plain offset instead of
  re-rasterizing every lane on every scroll event.

**Measured results** (Release build, Activity Monitor/`top`), all at or below
QuickTime's numbers:

| Scenario | Before | After |
|---|---|---|
| 1 track playing | 39% | ~2% |
| 10 tracks playing | 90% | ~5% |
| 18–20 tracks playing | 105% | ~8.5% |
| Paused / idle | 3–4% | 0.0% |

The residual per-track slope is the audio engine rendering all muted
player/mixer nodes (by design, for instant A/B switching) — not a UI cost.

Full test suite (`xcodebuild test`, 262 tests) passes.

## Not started

**Iteration 4 — trim residual per-tick work.** Was scoped as "only if the CPU
table isn't flat after Iterations 1–3." It essentially is now (~8.5% at 20
tracks vs. QuickTime's 32%) — treat as **not needed** unless someone wants to
chase the remaining gap further.

**Iteration 5 — load & analysis speed** (auto-align / tempo-search / the
`Analysis/` DSP paths). Not started:
- In-memory cache of novelty envelopes keyed like
  `WaveformSource.Identity` ([WaveformStore.swift](../Sources/Takes/WaveformStore.swift))
  so re-running auto-align doesn't re-decode every file from scratch.
  **No disk cache** — users open different files most launches, so
  persistence would add cache-management overhead for little gain.
- Vectorize `CorrelationScan.bestPeak`
  ([TrackAligner.swift:599](../Sources/Takes/TrackAligner.swift)) — the
  hottest scalar loop in the app, run ~50×/track during tempo search.
  Energies come from prefix-sum differences, so it vectorizes with
  `vDSP.subtract` on shifted prefix slices + `vvsqrtf` + `vDSP.divide` +
  `vDSP_maxvi`.
- Opportunistic-only (verify with a trace before touching): `smoothed` →
  `vDSP_vswsum`, `stretchedEnvelope` → `vDSP_vgenp`, `noveltyFromEnergy` →
  `vvlog10f`, the analysis mono downmix → `vDSP.add`/`vDSP_vsmul`.
- Explicitly **not** doing: GPU/Metal for analysis FFTs (one-shot work, vDSP
  is already microseconds), explicit SIMD types (vDSP covers it), waveform
  disk cache (see above).

**Manual verification still open** (flagged in PR #53, not something CI or
scripted computer-use fully covers):
- Blind-listening mode and loop-playback wrap behavior — both touch the
  reworked playhead/readout paths; unit tests cover the underlying logic but
  not the visual/interaction layer.
- General interaction feel of the Iteration 3 fixes (pinch-zoom with an
  active loop, cursor behavior, ruler-drag feel) under real use.

## Related PRs

- [#53](https://github.com/Nigelw/Takes/pull/53) — the perf + interaction
  work described above (draft).
- [#52](https://github.com/Nigelw/Takes/pull/52) — unrelated: hides the
  experimental Analysis window from the Window menu. Found uncommitted on
  `main` while working this branch; split out separately since it's
  unrelated to performance.
