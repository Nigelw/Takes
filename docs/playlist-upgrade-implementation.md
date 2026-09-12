# Playlist upgrade implementation plan

Status: implementation integrated; automated validation passed. Remaining manual,
external-integration, and performance acceptance is blocked/unverified.
The current status and validation report below define the handoff.
See the current status below before resuming work.

Feature contract: [playlist-upgrade-spec.md](playlist-upgrade-spec.md).
Development branch: `codex/playlist-upgrade`.

Shared interfaces: [playlist-upgrade-contracts.md](playlist-upgrade-contracts.md).
UI handoff: [playlist-upgrade-ui-integration.md](playlist-upgrade-ui-integration.md).

## Current status — 2026-09-11

Automatic track grouping is implemented on top of the playlist import path.
It includes the audio analyzer, deterministic clustering, conservative
existing-item attachment, Settings preference, progress/cancel UI, selection,
comparison entry, one-step Undo, focused tests, and a corpus benchmark tool.
See [automatic-track-grouping.md](automatic-track-grouping.md). Automatic
grouping ships off by default because neither accuracy gate has sufficient
ground-truth coverage; **Same Performance** is also Debug-only.

The validation pass is finished for this environment. **Automated checks pass;
manual acceptance and performance validation remain incomplete because UI
control hung twice.** No validation agent or test process remains running.
Do not treat the feature as release-validated.

The detailed evidence, result bundles, limitations, and reproducible remaining
checklist are in [playlist-upgrade-validation.md](playlist-upgrade-validation.md).
That report distinguishes automated coverage from observed UI behavior.

### Implemented and checkpointed

- `bd72b55`: workspace foundation and comparison value boundary.
- `8d68d00`: integrated coordinator, runtime, persistence, imports, and UI.
- `7771bab`: one-subagent workflow and interruption-safe handoff policy.
- `a7f6a07`: verified shuffle-progress and repeated-history fixes.
- `da3f339`: native row-selection changes and handoff checkpoint.
- `6703eb7`: passing Clear/Undo/Redo runtime regression and selection handoff.
- `9397091`: verified organization/runtime race fix. Removing the active item
  followed by a synchronous rename no longer cancels the required audio refresh.
- This final validation checkpoint adds runtime-scale and missing-item advancement
  regressions, finalizes the evidence report, and updates these status notes.

All work remains on `codex/playlist-upgrade`. Nothing has been merged or released.

### Verification results

| Check | Result |
|---|---|
| Fresh canonical Xcode suite covering all production changes through `9397091` | 382 unique tests passed, zero failures; 394 executions including parameterized cases. |
| Coordinator suite after the two final test additions | 16 unique tests passed, zero failures. |
| Recovery and persistence suites | 16 unique tests passed, zero failures. |
| Separate Debug build | Passed. |
| 100-item workspace / 32-version comparison runtime isolation | Passed: one playlist runtime track, 32 comparison tracks, one paused track after Back. Uses 98 inactive unavailable references; does not measure UI or waveform performance. |
| Natural-end advancement past a missing item | Passed: missing item retained/reported; next playable item starts with one runtime track. |
| Earlier observed UI workflow | Import, single/Shift selection, keyboard movement, grouping, Compare/Back, Undo/Redo, double-click playback, alternate-version position transfer, and basic paused relaunch passed. |
| New isolated manual pass | Blocked: CUA attachment hung for 463 seconds, then 178.8 seconds after explicit launch despite a requested 30-second timeout. No new UI pass is claimed. |

The new tests are the only code changes after the canonical run; their focused
suite compiled and passed. The production race was reproduced by a failing test
before the fix and verified afterward. No unresolved production failure was
observed in the completed tests; untested behavior is not implied to pass.

### Remaining acceptance work

These are handoff tasks, not background work:

1. In a working UI-control environment, finish the two-group → separate/regroup
   flow, Command-toggle selection, and the continuous album → Compare → alternate
   version → Back → next-song flow with offsets, gain, loops, and viewport changes.
2. Observe Locate File and corrupt-snapshot recovery UI, including preservation
   of the corrupt primary. Automated storage/repair behavior passes.
3. Observe a 100-file playlist and 32-version comparison: resizing, scrolling,
   waveform generation, reorder, and loop interactions. Measure idle/playback CPU
   against the documented performance baseline.
4. With controlled external state, check Finder/folder/Music/streaming import
   routes, media keys/Now Playing, numeric field focus, blind listening, and
   VoiceOver behavior. Existing subsystem tests do not replace these checks.

Do not retry the same hanging CUA path indefinitely. Keep at most one subagent;
GPT-5.6 Sol performed this validation pass. Future fixes need affected tests and
updated evidence before another checkpoint.

### Milestone assessment

| Milestone | Status |
|---|---|
| 1. Workspace model and playback boundary | Implemented and tested. |
| 2. Playlist UI and organization | Implemented; main UI workflow passed, broader UI acceptance blocked. |
| 3. Playback and comparison transitions | Implemented; transition, traversal, runtime, and missing-item tests pass; full UI flow remains. |
| 4. Restoration and lifecycle | Implemented; automated checks and basic paused relaunch pass; repair/recovery UI remains. |
| 5. Integration and release validation | Automated pass complete; manual/external/performance checks remain. |

### Resume safely

Use the exact Debug app and commands in the validation report with a **fresh
isolated workspace**. The older `/private/tmp/takes-playlist-manual-workspace`
contains user-changed music items; do not clear or reuse it for synthetic tests.
The current fixtures are 100 WAV files under `/private/tmp/takes-playlist-fixtures`
(`001-acceptance.wav` through `004-acceptance.wav`, then `005-scale.wav` onward).
Temporary result bundles and fixtures may disappear; the report includes commands
and test names so a new agent can reproduce the automated evidence.

## Orchestration and ownership

- The primary agent orchestrates work, defines shared interfaces, reviews every handoff, integrates changes, and verifies milestone completion.
- **UI design and implementation is assigned to a subagent running `gpt-6-astra` with `high` reasoning effort.** The 2026-09-11 user instruction assigns remaining validation to GPT-5.6; Sol is selected for that validation pass. This includes playlist rows, expansion and selection, comparison navigation, mode-specific controls, window behavior, and accessibility.
- Use subagents running **`gpt-5.6-luna` with `max` reasoning effort** for bounded model, persistence, playback, and test implementation tasks.
- Run at most **one subagent** at a time (user instruction, 2026-09-05). Keep tasks bounded to conserve remaining usage. Use explicit file ownership; sequence changes that touch shared controller or view files.
- Keep this status document current before each new work slice. Record changed files, exact verification results, known failures, and the next action. Commit completed slices with their documentation so a usage interruption leaves a recoverable handoff.
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
