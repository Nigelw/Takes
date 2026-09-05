# Playlist upgrade implementation plan

Status: implementation integrated; coordinator review and UI acceptance are unfinished.
The latest full suite passed 388 tests, but subsequent edits are not yet verified.
See the current status below before resuming work.

Feature contract: [playlist-upgrade-spec.md](playlist-upgrade-spec.md).
Development branch: `codex/playlist-upgrade`.

Shared interfaces: [playlist-upgrade-contracts.md](playlist-upgrade-contracts.md).
UI handoff: [playlist-upgrade-ui-integration.md](playlist-upgrade-ui-integration.md).

## Current status — 2026-09-05

This section supersedes earlier progress notes. Implementation is on
`codex/playlist-upgrade`. The foundation is committed as `bd72b55`. Work-in-progress checkpoint `8d68d00`
commits the runtime, coordinator, persistence, UI integration, tests, and status
documentation. The incomplete work and verification limits below still apply.
Nothing has been merged or released.

### Done and verified

- Workspace value model, stable item/version IDs, atomic organization operations,
  canonical duplicate checks, 32-version per-item limit, and comparison/file-time
  conversion are implemented. Foundation validation passed 356 tests, including
  22 model/boundary tests and a 100-item model case.
- Runtime replacement, coordinator operations, embedded metadata import,
  versioned snapshot storage/recovery, persistence event/checkpoint wiring,
  retained streaming storage, playlist/comparison UI, and mode-aware commands
  are integrated. These are implemented surfaces, not a claim that every
  acceptance scenario has passed.
- The integrated canonical Xcode suite passed **388 reported tests, zero
  failures**. Fresh DerivedData: `/private/tmp/takes-playlist-final-20260905`.
  Log: `/private/tmp/takes-playlist-final-20260905.log`. The first sandboxed
  attempt failed to resolve GitHub for Sparkle; the permitted rerun passed.
- A separate Debug build succeeded. Manual checks confirmed that four synthetic
  files import in supplied order, show their 20-second durations, and start
  playback by double-click. Normal quit wrote both snapshot files. Relaunch
  restored four items and the saved 00:20 position, paused.
- `AGENTS.md` now describes the integrated ownership, one-runtime architecture,
  captured import destinations, restoration protection, and new test suites.

Focused checkpoint verification after `8d68d00`: **22 unique tests passed**,
zero failures, across coordinator, persistence, and runtime suites. Xcode
reported 42 passes because some cases were reported more than once. Log:
`/private/tmp/takes-playlist-checkpoint-tests.log`.

Primary review then found two traversal defects: unchanged organization reset
shuffle progress, and deleting an item could jump to the first occurrence of a
repeated history entry. Both fixes and regression tests passed: **12 unique coordinator tests**, zero
failures. Log: `/private/tmp/takes-playlist-traversal-tests.log`. The fixes are
checkpointed separately from the ongoing UI selection work.

### In flight / incomplete

| Area | Owner | Current state and next action |
|---|---|---|
| Playlist row selection | Astra (`ui_integration_design`) | **Known blocking UI defect:** single-click/multiselection fails, so manual grouping cannot proceed. Removing row double-click gestures and using native List primaryAction did not fix it. Next proposed fix is a flat ForEach of directly tagged item/version rows; that flattening is not yet in the file. |
| UI file references | Astra | Reveal in Finder and missing-file checks now resolve bookmarks. Included in the latest successful Debug build; moved-file behavior still needs manual verification. |
| Coordinator review | Luna (`coordinator`) | Edits address shuffle anchoring/history, explicit-play traversal, Next/Previous availability, shared comparison entry (bookmarks, blind ordering, viewport), stale natural-end callbacks, missing-item reporting, and resolved-file duplicate detection. Review handoff and focused regression results are still required; do not treat these edits as covered by the 388-test run. |
| Runtime transition/Undo tests | Luna | Audio-backed selected-version/Compare/Back regression exists. Remaining review requests include Undo refresh cancellation and redo position fidelity, missing-file traversal, shuffle/history mutations, and comparison-entry state restoration. Exact coverage must be checked against the final handoff. |
| Persistence observation test | Primary | `workspaceEditsSaveAutomaticallyAndObservationRearms` passed in the focused checkpoint run, confirming automatic saves rearm after a second mutation. |
| Final integration review | Primary | Review agent handoffs, rebuild after fixes, run relevant tests and final canonical verification, then finish manual acceptance and documentation. |

Current work slice: resolve playlist selection using Astra as the sole subagent.
The coordinator agent has been interrupted; its committed edits await primary
review and tests. Primary will run the existing regression suites and maintain
this document while Astra fixes and verifies selection. Follow-on work stays
sequential. The last Astra attempt stopped at an account usage limit; resume
its existing task rather than recreating its context.

### Not yet started / not yet verified

- The complete manual four-files → two groups → separate/regroup → Undo/Redo
  workflow, blocked by row selection.
- Manual album playback → Compare → choose another version → Back at the same
  audible position → next song, including saved offsets/gain/loop/viewport.
- Manual missing-file repair and corrupt-snapshot recovery. Automated storage
  recovery tests passed; that does not establish the UI workflow.
- Manual 100-item playlist and 32-version comparison, scrolling/window sizing,
  and runtime/waveform resource checks at those sizes. Synthetic fixtures exist;
  large-list UI and performance checks have not been performed.
- Manual folder drops, Finder selection, Music selection, streaming imports,
  media keys, accessibility, numeric-field shortcut isolation, blind listening,
  comparison loops, and imports during playback. Existing automated subsystem
  tests passed, but these new integrated routes still need acceptance checks.
- Playback/idle CPU comparison against the documented performance baseline.
- Final canonical test run covering all edits after the 388-test checkpoint.
- Merge and release are separate, not authorized by this implementation task.

### Milestone assessment

| Milestone | Status |
|---|---|
| 1. Workspace model and playback boundary | Foundation complete and tested; integrated runtime exists. |
| 2. Playlist UI and organization | Implemented; selection defect blocks manual acceptance. |
| 3. Playback and comparison transitions | Implemented; edge-case fixes and end-to-end verification in progress. |
| 4. Restoration and lifecycle | Implemented; automated storage tests and basic paused relaunch passed; repair/recovery UI acceptance pending. |
| 5. Integration and release validation | In progress; latest full suite passed, subsequent edits and broad manual/performance checks remain. |

### Resume details

- Debug app: `/private/tmp/takes-playlist-ui-20260905/Build/Products/Debug/Takes.app`.
  Select this exact path in CUA; selecting by name may target the installed app.
- Manual workspace: `/private/tmp/takes-playlist-manual-workspace`, selected with
  `TAKES_PLAYLIST_WORKSPACE_DIRECTORY`. Do not use the user's normal workspace.
- Fixtures: `/private/tmp/takes-playlist-fixtures` (100 synthetic WAV files;
  first four are 20 seconds, remaining files one second).
- Last launch used exec session `45046`; verify whether it is still running.
  Debug build log: `/private/tmp/takes-playlist-ui-build.log`.
  App log: `/private/tmp/takes-playlist-manual-app.log`.
- Last successful Debug build includes the first selection fix, which manual
  verification showed is insufficient. Rebuild after the replacement fix.
- Preserve all current changes. Remove only generated `default.profraw` from
  the repo when the test app has finished; it is a launch artifact.

## Orchestration and ownership

- The primary agent orchestrates work, defines shared interfaces, reviews every handoff, integrates changes, and verifies milestone completion.
- **All UI design and implementation is assigned to a subagent running `gpt-6-astra` with `high` reasoning effort.** This includes playlist rows, expansion and selection, comparison navigation, mode-specific controls, window behavior, and accessibility.
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
