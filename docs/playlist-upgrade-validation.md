# Playlist upgrade validation

Validation date: 2026-09-11. Branch: `codex/playlist-upgrade` at `9397091`,
plus the two passing scale/missing-playback tests saved in the final validation
checkpoint. No test or validation agent remains running.

This report separates observed manual behavior, automated coverage, failures,
and work blocked by unavailable external state. It does not infer a manual pass
from unit coverage. Manual checks use
`TAKES_PLAYLIST_WORKSPACE_DIRECTORY=/private/tmp/takes-playlist-validation-20260911`;
the earlier user-modified workspace is out of scope and must not be changed.

## Result summary

| Area | Status | Evidence |
|---|---|---|
| Canonical Xcode suite at production commit `9397091` | Pass | 382 unique tests, zero failures; 394 executions including dynamic parameters. |
| Four files, two groups, separate/regroup, Undo/Redo | Partial | Model identity flow passes; earlier UI evidence covers one group and Undo/Redo. Remaining UI flow is tool-blocked. |
| Album progression and Compare/Back position mapping | Partial | Transition tests and earlier manual Compare/Back evidence pass; the complete UI flow is tool-blocked. |
| Restoration, missing-file repair, corrupt recovery UI | Partial | Recovery and repair behavior passes automated checks; UI presentation is tool-blocked. |
| 100-item playlist and 32-version comparison | Partial | Runtime isolation passes at both bounds; scrolling, waveform behavior, and window sizing are tool-blocked. |
| Import routes, media commands, focus, blind mode, loops, accessibility | Partial | Automated subsystem coverage passes; integrated UI/hardware checks are blocked as detailed below. |
| Performance invariants | Blocked | No current CPU or interaction measurement; app UI control could not attach. |

## Automated validation

### Current pass

- Canonical command:

  ```bash
  xcodebuild -project Takes.xcodeproj -scheme Takes -destination 'platform=macOS' -derivedDataPath /private/tmp/takes-playlist-validation-derived-data-20260911 -resultBundlePath /private/tmp/takes-playlist-validation-tests-20260911.xcresult CODE_SIGNING_ALLOWED=NO test
  ```

- Result bundle: `/private/tmp/takes-playlist-validation-tests-20260911.xcresult`
- Result: passed. The xcresult summary reports 382 unique tests, zero failures,
  and 394 executions in the device/configuration count because one parameterized
  test contributes 13 runs. This run includes every production change through
  `9397091`. The only later code changes are the two test additions below; their
  16-test focused suite compiled and passed after the final test edits.

### Organization refresh race regression

- Test: `synchronousFollowUpEditDoesNotCancelRequiredRuntimeRefresh` in
  `PlaylistCoordinatorTests.swift`.
- Trigger: play the first of two items, remove that active item, then rename the
  successor synchronously before the scheduled runtime refresh runs.
- Expected: the workspace and runtime both select the successor, the removed
  version is unloaded, playback is paused, and one runtime track remains.
- Observed on `6703eb7`: failed. The workspace contained only the successor, but
  `currentItemID` still referenced the removed item. The second metadata-only
  mutation canceled the refresh required by the removal.
- Focused result: 14 unique coordinator tests, 13 passed and 1 failed. Xcode
  printed duplicate execution records, but the xcresult summary reports the
  unique totals.
- xcresult:
  `/private/tmp/takes-playlist-race-derived-data-20260911/Logs/Test/Test-Takes-2026.09.11_6-21-27--0400.xcresult`.
- Classification: production bug, not a fixture or filter artifact. An earlier
  exact-method filter selected zero tests; the class-filtered rerun executed all
  14 coordinator tests and reproduced the failure.
- Fix: `mutateWorkspace` now starts a new navigation generation only when the
  current mutation itself requires a runtime refresh. A metadata-only follow-up
  edit no longer cancels the queued refresh.
- After-fix result: 14 unique coordinator tests passed, zero failures. Result
  bundle: `/private/tmp/takes-playlist-race-after-fix-20260911.xcresult`.

### Earlier checkpoint evidence

- The pre-final-change canonical run reported 388 tests and zero failures from
  `/private/tmp/takes-playlist-final-20260905.log`. This predates later
  coordinator and selection changes and is historical evidence only.
- The latest focused coordinator run reported 13 unique tests and zero failures,
  including Clear → Undo → Redo restoring stable version identity, paused
  position, and runtime count while preserving the source file. Log:
  `/private/tmp/takes-playlist-undo-tests.log`.
- Existing automated coverage includes the 100-item value model, grouping four
  files followed by separation/regrouping with stable IDs, the 32-version limit,
  file-time/offset mapping, saved loop handling, blind-order-safe capture,
  missing reference restoration, file repair identity, corrupt-primary fallback,
  automatic-save protection, restore-paused behavior, stale runtime/import
  rejection, and Finder/folder resolver behavior. All were included in the
  passing current canonical run.

### Scale and runtime isolation

- Added
  `hundredItemWorkspaceLoadsOnlyCurrentItemAndThirtyTwoVersionComparison`.
- The test creates a 100-item value workspace. One item owns 32 available audio
  versions, one item owns one available version, and 98 inactive items use
  distinct unavailable references. It verifies one runtime track in playlist
  mode, exactly 32 runtime tracks after entering the 32-version comparison, and
  one paused runtime track after Back.
- This proves the one-runtime ownership boundary at the acceptance limits. It
  does not prove list rendering or scrolling performance with 100 available
  files, and it does not observe waveform queue activity.
- Added `naturalEndSkipsMissingItemAndContinuesWithNextPlayableItem`. A short
  first item ends naturally, the unavailable middle item remains in the
  workspace and is reported, and playback continues on the third item with one
  runtime track.
- Focused coordinator result after both additions: 16 unique tests passed, zero
  failures. Result bundle:
  `/private/tmp/takes-playlist-scale-missing-tests-v2-20260911.xcresult`.

### Recovery and persistence

- Focused `PlaylistWorkspaceStoreTests` and
  `PlaylistPersistenceControllerTests`: 16 unique tests passed, zero failures.
  Result bundle: `/private/tmp/takes-playlist-recovery-tests-20260911.xcresult`.
- Covered behavior includes versioned primary/fallback round trips, missing file
  references, corrupt-primary fallback without overwriting the corrupt source,
  automatic-save blocking until recovery acceptance, preservation of the
  corrupt snapshot, unsupported newer schemas, retained downloads, restoration
  failure save protection, and rearmed automatic event saves.

## Manual validation

### Earlier observed checks

- Four synthetic files imported in supplied order with 20-second durations.
- Double-click started playlist playback.
- One two-version group entered comparison; Back retained group selection and
  expansion; Undo restored four items and Redo restored the grouped workspace.
- Compare while playing entered at 00:08. After pausing and switching versions,
  Back returned paused at 00:13 with the alternate version selected.
- Normal quit wrote primary and last-known-good snapshots; relaunch restored
  four items and position 00:20, paused.

These observations were made before this isolated validation pass and do not
cover the remaining acceptance rows below.

### Isolated pass

- Separate Debug build passed with DerivedData at
  `/private/tmp/takes-playlist-validation-debug-20260911`.
- Generated 100 synthetic WAV fixtures in
  `/private/tmp/takes-playlist-fixtures`: four distinct 20-second files and 96
  one-second scale files.
- Initial CUA attachment was aborted after hanging because the app had not yet
  been launched. No UI action occurred and no isolated workspace was created.
  This is a tooling/setup failure, not an app result.
- A second attempt started the exact Debug executable in a persistent shell with
  `TAKES_PLAYLIST_WORKSPACE_DIRECTORY=/private/tmp/takes-playlist-validation-20260911`.
  CUA `getApp` for that exact bundle ignored its 30-second timeout and hung for
  178.8 seconds before interruption. The earlier attachment had hung for 463
  seconds. The app produced no log output or isolated snapshot. The persistent
  process was then terminated.
- No UI assertion from this isolated pass is valid. Further CUA attempts were
  stopped after the repeated tooling failures.

## Acceptance ledger

| Requirement | Result | Evidence / limitation |
|---|---|---|
| Four files become two two-version items | Automated pass; UI blocked | Model organization test covers both groups; isolated UI control unavailable. |
| Separate and regroup without losing file identity | Automated pass; UI blocked | `groupingFourFilesThenSeparatingAndRegroupingRetainsAllVersionIDs` passed in the canonical suite. |
| Undo/Redo organization | Partial pass | One-group manual flow and coordinator Clear/Undo/Redo test passed. |
| Album playback advances through items | Automated pass; UI blocked | Natural end skips an unavailable middle item and starts the next playable item; full UI album audition remains unobserved. |
| Compare, select version, Back at same audible position, then Next | Partial pass; UI blocked | Earlier manual Compare/alternate-version/Back position passed; transition/boundary tests pass; one continuous UI flow remains unobserved. |
| Saved gain, offset, loop, and viewport survive transitions | Automated pass; UI blocked | Coordinator and boundary tests restore these fields and deselect an excluding loop. |
| Restore organization, adjustments, view, and position paused | Automated pass; partial manual | Snapshot round-trip includes all fields; runtime restore is paused; earlier basic four-item relaunch passed. |
| Missing files remain visible and repairable | Automated pass; UI blocked | Store preserves the missing reference and coordinator repair retains the version ID. Locate File presentation was not observed. |
| Corrupt snapshot preserves recoverable data and exposes recovery UI | Automated pass; UI blocked | Storage/persistence protection passes; recovery banner/button was not observed. |
| 100-item playlist remains usable at chosen window size | Runtime pass; UI/performance blocked | 100-item value/runtime boundary passed, using 98 inactive unavailable references; no scrolling/window observation. |
| 32-version comparison loads only current item runtime | Automated pass; waveform observation blocked | New integration test confirms 32 tracks for comparison and one after Back. |
| Finder/open and folder import routing | Automated pass; integrated UI blocked | Existing resolver/controller tests pass; the complete new shell/Finder UI route was not observed in this pass. |
| Music selection and streaming imports | Automated logic pass; external check blocked | Existing import and streaming subsystem tests pass; the complete new UI route was not exercised. No controlled Music selection or live streaming service was available for acceptance. |
| Media keys and Now Playing follow active mode | External hardware/system check blocked | No media-key or Now Playing surface was controlled in this pass. |
| Numeric-field editing remains focus-safe | Automated logic pass; UI blocked | Numeric focus/command tests pass; field editing was not observed. |
| Blind listening remains comparison-only | Automated pass; UI blocked | Boundary/session tests preserve playlist order and comparison shuffle behavior. |
| Comparison signed timeline and loops remain intact | Automated pass; UI blocked | Transport, loop, repeat, and offset tests pass; waveform interaction was not observed. |
| Accessibility labels and keyboard navigation | Partial manual/static; assistive-tech check blocked | Earlier keyboard navigation passed and playlist controls define labels; VoiceOver behavior was not exercised. |
| Idle and playback performance retain baseline | Blocked | Historical baseline exists; no current CPU, scroll, drag, loop, or waveform measurement was possible. |

## Failures and blocked checks

- **Fixed and verified:** a synchronous metadata edit could cancel a runtime
  refresh scheduled by removal of the active item. The regression failed before
  the fix and all 14 coordinator tests passed afterward.
- **UI tooling blocked:** two CUA `getApp` attempts hung for 463 seconds and
  178.8 seconds respectively; the second ignored a requested 30-second timeout.
  No isolated workspace snapshot or UI evidence was produced. This does not
  indicate an app pass or failure.
- **External checks blocked:** live Music selection, streaming download, media
  keys, Now Playing, and VoiceOver require controlled external state or system
  interaction that was not available in this pass.

## Next actions

Run these steps in an environment where the Debug app can be driven. Keep the
workspace isolated from normal Application Support:

1. In a persistent Terminal session, run:

   ```bash
   TAKES_PLAYLIST_WORKSPACE_DIRECTORY=/private/tmp/takes-playlist-validation-20260911 /private/tmp/takes-playlist-validation-debug-20260911/Build/Products/Debug/Takes.app/Contents/MacOS/Takes
   ```

2. Import `001-acceptance.wav` through `004-acceptance.wav` from
   `/private/tmp/takes-playlist-fixtures`. Group rows 1–2 and 3–4 separately;
   expand both; separate one version; regroup it; verify all four filenames;
   then Undo and Redo each organization state.
3. Play the first group, seek away from zero, enter Compare, change gain and
   offset, create a loop, change zoom/viewport, select the other version, and
   use Back. Verify the same audible file position and paused/playing state,
   then use Next and verify the following item starts.
4. Quit and relaunch. Verify organization, active view, selected version,
   comparison adjustments, viewport, and position return paused.
5. For repair, import a disposable copy and quit. Copy it to a separate repair
   path, then delete only the imported disposable copy (a rename may still
   resolve through its bookmark). Relaunch, verify
   `File unavailable`, and use Locate File. For recovery, make a clean quit,
   corrupt only
   `/private/tmp/takes-playlist-validation-20260911/workspace.json`, relaunch,
   verify the last-known-good warning and `Use Recovered Playlist`, accept it,
   and confirm the corrupt primary is preserved as a recovery file.
6. Import all 100 fixtures, resize and scroll the playlist, group 32 into one
   comparison, and observe waveform loading and runtime/resource behavior.
   Measure idle and playback CPU and exercise scroll, reorder, and loop drag
   against the baseline in `docs/performance-plan-status.md`.
7. With controlled sources available, exercise Finder selection, a folder
   drop, Music selection, a streaming URL, imports during playback, media keys,
   Now Playing, numeric text editing, Blind Listening, comparison loops, and
   VoiceOver labels/actions.
