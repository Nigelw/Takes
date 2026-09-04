# Playlist upgrade implementation plan

Status: milestone 1 in progress; workspace model and comparison value boundary implemented,
runtime/coordinator and UI integration pending.

Feature contract: [playlist-upgrade-spec.md](playlist-upgrade-spec.md).
Development branch: `codex/playlist-upgrade`.

Shared interfaces: [playlist-upgrade-contracts.md](playlist-upgrade-contracts.md).
UI handoff: [playlist-upgrade-ui-integration.md](playlist-upgrade-ui-integration.md).

## Implementation log

- 2026-09-04: Primary started milestone 1 on the existing development branch.
  Luna owns the workspace value model and organization tests. Astra owns the
  UI integration design. Primary owns the comparison value bridge, persistence
  and asynchronous context contracts, Xcode registration, and integration review.
- Baseline canonical Xcode suite passed using fresh DerivedData at
  `/private/tmp/takes-playlist-baseline-20260904` (code signing disabled).
- Runtime/UI integration, persistence implementation, and milestones 2–5 remain
  pending. The new model is not yet the running app's source of truth.
- Implemented `PlaylistWorkspace` value types, validation, canonical duplicates,
  atomic organization operations, per-item limits, and stable file-time listening
  state. Implemented `PlaylistPlaybackBoundary` for session materialization and
  adjustment capture without persisting blind-shuffled order. Added 22 focused
  tests across the model and boundary, including the 100-item model case.
- Review corrected paused-listening selection, offset translation during moves,
  successor selection after multiple removals, and snapshot value validation.
  No UndoManager, disk persistence, runtime activation, or UI behavior is claimed
  by this foundation. Astra's UI integration handoff is reviewed; implementation
  starts after the coordinator's callable surface is available.
- Final canonical Xcode suite passed: 356 reported test cases, including all 22
  new model/boundary tests. DerivedData was created fresh for this foundation at
  `/private/tmp/takes-playlist-foundation-20260904`; final log is
  `/private/tmp/takes-playlist-foundation-final-20260904.log`. The first run found
  a filename expectation mismatch; a later test fixture compile error was also
  corrected before the passing run. No manual UI verification was performed
  because this slice does not change the running interface.

### Next integration step

Luna: add a runtime-only replacement API to `PlaybackController`, preserving
version IDs and invalidating stale async work without deleting downloads, then
implement `PlaylistCoordinator` against the shared contracts. Sequence this with
all other controller work. Astra: wire `WorkspaceView` and playlist/comparison
navigation once that interface is reviewed. Do not mount a second controller or
route navigation through `clearTracks()`.

## Orchestration and ownership

- The primary agent orchestrates work, defines shared interfaces, reviews every handoff, integrates changes, and verifies milestone completion.
- **All UI design and implementation is assigned to a subagent running `gpt-6-astra` with `high` reasoning effort.** This includes playlist rows, expansion and selection, comparison navigation, mode-specific controls, window behavior, and accessibility.
- Use subagents running **`gpt-5.6-luna` with `max` reasoning effort** for bounded model, persistence, playback, and test implementation tasks.
- Run at most three subagents concurrently. Use explicit file ownership; sequence changes that touch shared controller or view files.
- Supply each subagent with the feature specification, applicable repository instructions, its bounded deliverable, agreed interfaces, and verification requirements. Explicit model overrides require a fresh or limited context fork rather than a full-history fork.
- Review and correct each handoff before dependent work proceeds. Agents must not independently broaden scope, merge, or release.
- Preserve the pre-existing uncommitted changes in `docs/playlist-mode-specs.md`. They are exploratory notes, not authorization to add features outside the approved specification.

## Milestones

### 1. Workspace model and playback boundary

- Luna: introduce item/version ownership, grouping operations, stable identities, and focused model tests.
- Primary agent: establish coordinator and persistence interface contracts and review compatibility with `ComparisonSession`.
- Adapt the existing comparison view to one item; assign UI changes to Astra after the interfaces are settled.
- Acceptance: current comparison behavior and canonical tests remain intact.

### 2. Playlist UI and manual organization

- Astra: implement metadata rows, expansion, selection, reorder, grouping controls, version management, and Undo affordances.
- Luna: implement supporting metadata extraction and organization operations against the agreed interfaces, without editing Astra-owned UI files.
- Acceptance: four imported files become two items with two versions each; separation and regrouping preserve file identity and Undo restores organization.

### 3. Playlist playback and comparison transitions

- Luna: implement coordinator/controller integration, sequential playback, shuffle, repeat, seeking, and position mapping.
- Astra: implement mode-specific controls, comparison navigation, and mode-aware window behavior against the agreed playback interface.
- Primary agent: review media commands, import routing, asynchronous context safety, and preservation of comparison scheduling invariants.
- Acceptance: play through an album, compare a song, select another version, return at the same audible location, and continue to the next song.

### 4. Workspace restoration and resource lifecycle

- Luna: implement snapshots, file recovery, retained streaming downloads, startup ordering, and lazy runtime loading.
- Persistence work may start alongside earlier milestones once model contracts are stable; controller integration remains sequential with its owner.
- Astra: implement missing-file repair and restoration error presentation.
- Acceptance: reopen with the same organization, adjustments, view, and position, paused; missing files remain repairable and corrupt snapshots do not destroy recoverable data.

### 5. Integration and release validation

- Luna: add focused regression coverage for grouping/Undo, repeat/shuffle traversal, offset mapping, stale async completions, restoration failures, and missing-file handling.
- Primary agent: run the canonical Xcode suite, review the complete diff, and verify integration and performance. Route UI corrections to Astra.
- Exercise Finder, folder drops, Music selection, streaming imports, media keys, accessibility, blind listening, and imports during playback.
- Manually verify a 100-item playlist and a 32-version comparison. Confirm inactive playlist items do not retain audio nodes or trigger waveform decoding; compare playback and idle performance against the existing baseline.
- Update milestone status in this document and update `AGENTS.md` ownership, invariants, and test map as changes land. Review it after every PR or merge as required by repository instructions.

## Verification and completion

Use `xcodebuild test`, not `swift test`, with fresh DerivedData under `/private/tmp`:

```bash
xcodebuild \
  -project Takes.xcodeproj \
  -scheme Takes \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/takes-playlist-derived-data \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Read and follow the `run-takes` skill for manual app/UI verification. Preserve the existing waveform, observation, Core Animation, and gapless comparison-loop invariants; consult `docs/performance-plan-status.md` before performance work.

Completion requires all five milestones, passing canonical tests, manual playback/UI verification, and updated documentation. Keep all development on `codex/playlist-upgrade`; merging and releasing are separate work. Record failures and material limitations rather than declaring incomplete milestones complete.
