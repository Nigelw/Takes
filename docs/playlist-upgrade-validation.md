# Playlist upgrade validation

Validation date: 2026-09-11. Branch: `codex/playlist-upgrade` at `6703eb7`,
plus the validation test and report listed by `git status`.

This report separates observed manual behavior, automated coverage, failures,
and work blocked by unavailable external state. It does not infer a manual pass
from unit coverage. Manual checks use
`TAKES_PLAYLIST_WORKSPACE_DIRECTORY=/private/tmp/takes-playlist-validation-20260911`;
the earlier user-modified workspace is out of scope and must not be changed.

## Result summary

| Area | Status | Evidence |
|---|---|---|
| Canonical Xcode suite after all current edits | Pass | 382 unique tests, zero failures; 394 executions including dynamic parameters. |
| Four files, two groups, separate/regroup, Undo/Redo | Pending | Earlier evidence covers one group and Undo/Redo only. |
| Album progression and Compare/Back position mapping | Partial | Earlier manual evidence covers alternate version and paused position; full next-item progression is pending. |
| Restoration, missing-file repair, corrupt recovery UI | Partial | Automated storage/recovery checks previously passed; manual repair and recovery UI are pending. |
| 100-item playlist and 32-version comparison | Partial | A 100-item model test previously passed; manual scale/resource behavior is pending. |
| Import routes, media commands, focus, blind mode, loops, accessibility | Partial | Existing subsystem tests cover portions; integrated manual checks are pending. |
| Performance invariants | Pending | Baseline is documented in `performance-plan-status.md`; current branch measurement is pending. |

## Automated validation

### Current pass

- Canonical command:

  ```bash
  xcodebuild -project Takes.xcodeproj -scheme Takes -destination 'platform=macOS' -derivedDataPath /private/tmp/takes-playlist-validation-derived-data-20260911 -resultBundlePath /private/tmp/takes-playlist-validation-tests-20260911.xcresult CODE_SIGNING_ALLOWED=NO test
  ```

- Result bundle: `/private/tmp/takes-playlist-validation-tests-20260911.xcresult`
- Result: passed. The xcresult summary reports 382 unique tests, zero failures,
  and 394 executions in the device/configuration count because one parameterized
  test contributes 13 runs.

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
  rejection, and Finder/folder resolver behavior. Exact current-suite status is
  not assumed until the canonical run completes.

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

Pending build and launch.

## Acceptance ledger

| Requirement | Result | Evidence / limitation |
|---|---|---|
| Four files become two two-version items | Pending | |
| Separate and regroup without losing file identity | Pending manual; covered by model test | |
| Undo/Redo organization | Partial pass | One-group manual flow and coordinator Clear/Undo/Redo test passed. |
| Album playback advances through items | Pending | |
| Compare, select version, Back at same audible position, then Next | Partial pass | Compare/alternate-version/Back position observed; Next progression pending. |
| Saved gain, offset, loop, and viewport survive transitions | Pending manual; covered in focused model/coordinator tests | |
| Restore organization, adjustments, view, and position paused | Partial pass | Basic four-item paused restoration observed; all persisted comparison fields pending manual. |
| Missing files remain visible and repairable | Pending manual; covered by store/coordinator tests | |
| Corrupt snapshot preserves recoverable data and exposes recovery UI | Pending manual; covered by store/persistence tests | |
| 100-item playlist remains usable at chosen window size | Pending | |
| 32-version comparison loads only current item runtime | Pending manual; model/runtime bounds covered | |
| Finder/open and folder import routing | Pending integrated manual; resolver tests exist | |
| Music selection and streaming imports | Pending external/manual | |
| Media keys and Now Playing follow active mode | Pending external/manual | |
| Numeric-field editing remains focus-safe | Pending manual; existing command tests cover handler logic | |
| Blind listening remains comparison-only | Pending manual; boundary/session tests exist | |
| Comparison signed timeline and loops remain intact | Pending manual; mapping/loop tests exist | |
| Accessibility labels and keyboard navigation | Pending audit; earlier keyboard navigation passed | |
| Idle and playback performance retain baseline | Pending measurement | |

## Failures and blocked checks

- **Fixed and verified:** a synchronous metadata edit could cancel a runtime
  refresh scheduled by removal of the active item. The regression failed before
  the fix and all 14 coordinator tests passed afterward.

## Next actions

1. Finish the fresh canonical suite and classify every failure.
2. Build and launch the exact Debug product with the isolated workspace.
3. Exercise the highest-value manual acceptance flows: organization, playback
   transition, repair/recovery, and scale/resource behavior.
4. Record external-dependency checks as blocked when Music selection, a live
   streaming service, media hardware, or accessibility tooling is unavailable.
