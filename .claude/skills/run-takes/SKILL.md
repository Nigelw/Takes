---
name: run-takes
description: Run, launch, start, build, screenshot, or verify the Takes macOS audio comparison app. Use when asked to run Takes, take a screenshot of Takes, test Takes UI, or confirm a UI change works.
---

Takes is a native macOS SwiftUI app for comparing multiple audio tracks on a shared transport timeline. It is driven by launching the `.app` bundle with `open` and then using **computer-use** tools to take screenshots and click. There is no headless or CLI path — the app requires a display.

All paths below are relative to the repo root (`Takes/`).

## Prerequisites

- macOS (required — app won't build or run on Linux)
- Xcode with command-line tools: `xcode-select --install`
- No extra `apt-get` or `brew` packages needed

## Build

```bash
xcodebuild \
  -project Takes.xcodeproj \
  -scheme Takes \
  -configuration Debug \
  -derivedDataPath .derived-data \
  build
```

Output app: `.derived-data/Build/Products/Debug/Takes.app`

Build time: ~30 s cold, seconds incremental. Look for `** BUILD SUCCEEDED **` at the end.

## Run (agent path)

Use `smoke.sh` to kill any existing instance, build, and launch:

```bash
bash .claude/skills/run-takes/smoke.sh
```

Skip the rebuild if the app is already built:

```bash
bash .claude/skills/run-takes/smoke.sh --no-build
```

After the script prints `Takes is running`, use computer-use tools to interact:

1. Call `request_access` with `["Takes"]` (tier: full).
2. Call `screenshot` to see the current state.
3. Use `left_click`, `key`, `type`, etc. to interact.
4. Call `screenshot` (with `save_to_disk: true`) to capture the result.

### What the UI looks like at launch

- Transport bar at top: **Play** (disabled), **Switch Track** (disabled), time counter `00:00 / 00:00`
- Track toolbar: **+** button (opens "Open Finder Selection" / "Open Apple Music Selection" dropdown), **Clear All**, offset timestamp
- Track 1 row left panel: label "Track 1", "No file loaded"
- Track 1 row right panel: "Drop audio file here" drop zone

### Quit the app

```bash
pkill -x Takes
```

## Run (human path)

```bash
open .derived-data/Build/Products/Debug/Takes.app
```

Or open `Takes.xcodeproj` in Xcode and press Cmd-R.

## Test (non-UI)

Compile both app and test targets without requiring Apple test infrastructure:

```bash
xcodebuild \
  -project Takes.xcodeproj \
  -scheme Takes \
  -configuration Debug \
  -derivedDataPath .derived-data \
  build-for-testing
```

Use this to verify PRs that touch `TransportMapping.swift`, `Models.swift`, or other non-UI logic. `xcodebuild test` may be blocked in sandboxed environments — `build-for-testing` is the reliable local check.

## Gotchas

- **`open` returns immediately** — the process takes ~1 second to appear. `smoke.sh` polls `pgrep -x Takes` to wait. Don't screenshot immediately after calling `open`; wait for the script to confirm the PID.
- **`Switch Track` is always disabled with fewer than 2 loaded tracks.** Don't interpret a grayed-out Switch Track as a bug when there's only one track.
- **Music import requires Automation permission.** The first time a user clicks "Open Apple Music Selection", macOS shows a permission dialog. The app will hang on that dialog until approved.
- **Dropping files from Finder into the Takes window works**; the drop zone is the right panel of each track row, but any part of the window accepts the drop.
- **The `+` button itself** (not the chevron) opens a native file picker; the chevron opens the "Open Finder Selection / Open Apple Music Selection" menu.
- **Escape does not close the `+` dropdown menu** — click elsewhere in the window to dismiss it.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `** BUILD FAILED **` with missing Sparkle framework | Run `xcodebuild` once; it fetches the SPM dependency automatically on first run. If it still fails, open `Takes.xcodeproj` in Xcode once to resolve packages. |
| `open` reports the app can't be opened (damaged/quarantine) | Run `xattr -d com.apple.quarantine .derived-data/Build/Products/Debug/Takes.app` |
| `pgrep -x Takes` never succeeds after launch | Check Console.app for crash logs; usually a missing entitlement or code-signing issue on unsigned builds. Re-run the full build step. |
| Takes is already running from a previous session | `pkill -x Takes` before launching, or `smoke.sh` does this automatically. |
