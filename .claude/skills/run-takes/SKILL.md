---
name: run-takes
description: Run, launch, start, build, screenshot, or verify the Takes macOS audio comparison app. Use when asked to run Takes, take a screenshot of Takes, test Takes UI, hand the app to the user to test, or confirm a UI change works.
---

Takes is a native macOS SwiftUI app for comparing multiple audio tracks on a shared transport timeline. It is driven by launching the `.app` bundle with `open`. From there you can either drive the UI yourself with **computer-use** tools, or just hand the running app to the user to test by hand.

All paths below are relative to the repo root (`Takes/`).

## Pick a mode

There are two ways to run the app. Choose based on what the user asked for:

- **Hand-off mode** — build, launch, and let the user test it themselves. Use this when the user says they want to test/try/drive it, "let me test", "I'll check it", or otherwise wants the app in front of them. Do **not** take screenshots or click around; just get it running and stop. See [Run (hand-off to user)](#run-hand-off-to-user).
- **Agent-driven mode** — build, launch, then verify the change yourself with computer-use (screenshots, clicks). Use this when asked to "take a screenshot", "confirm the change works", "verify the UI", or when the user isn't at the machine. See [Run (agent path)](#run-agent-path).

When it's ambiguous which mode is wanted, prefer hand-off mode and tell the user the app is ready for them to test.

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

Use `build-debug.sh` to kill any existing instance, build, and launch:

```bash
bash scripts/build-debug.sh
```

Skip the rebuild if the app is already built:

```bash
bash scripts/build-debug.sh --no-build
```

After the script prints `Takes is running`, use computer-use tools to interact:

1. Call `request_access` with `["Takes"]` (tier: full).
2. Call `screenshot` to see the current state.
3. Use `left_click`, `key`, `type`, etc. to interact.
4. Call `screenshot` (with `save_to_disk: true`) to capture the result.

## Load audio files (agent path)

To get audio into the app, **don't drive the open dialog with computer-use**. Instead load files straight from the shell. The app declares `public.audio` as a handled document type and routes opened URLs through `AppDelegate.application(_:open:)`, so `open -a` lands in the same code path as File ▸ Open / drag-and-drop:

```bash
APP="$PWD/.derived-data/Build/Products/Debug/Takes.app"
open -a "$APP" "/abs/path/track-a.m4a" "/abs/path/track-b.m4a"
```

- Use **absolute file paths** (and an absolute path to the `.app`).
- This **appends** to the current session, like opening files normally. For a clean load, quit/relaunch first (or click Clear All).
- The app must already be built and launched once so Launch Services has it registered (`build-debug.sh` handles build + launch).
- Sample audio for testing lives in `Private/Audio Samples/` (e.g. the two `Where to Begin` takes make a good comparison pair).

After loading, use computer-use only for what genuinely needs eyes — confirming the waveform rendered, checking playback, reading the UI.

### Quit the app

```bash
pkill -x Takes
```

## Run (hand-off to user)

Build and launch, then stop and let the user drive it. `build-debug.sh` kills any existing instance, builds, and launches:

```bash
bash scripts/build-debug.sh
```

Skip the rebuild if the app is already built and you only need it relaunched:

```bash
bash scripts/build-debug.sh --no-build
```

Once the script prints `Takes is running`, you're done — the app is on screen for the user. **Do not** call `request_access`, `screenshot`, or click anything. Tell the user it's ready to test, and optionally offer to preload sample audio (see [Load audio files](#load-audio-files-agent-path)) so they land on a populated timeline. Loading files from the shell is fine in this mode — it's the computer-use interaction you skip, not the setup.

## UI smoke checks

Use only the checks relevant to the change unless the user asks for a full manual pass:

1. Confirm the top transport shows play/pause, switch, blind listening,
   auto-align, zoom, repeat, and signed time readout controls.
2. Load one file and confirm it creates Track 1 and makes it active.
3. Load additional files and confirm they append in order.
4. Confirm switching cycles through three or more tracks in row order.
5. Confirm waveform lanes render progressively, the playhead spans visible
   lanes, and clicking a waveform lane seeks.
6. Confirm positive offsets create leading blank space and negative offsets
   extend the visible timeline left of zero.
7. Drag a row and confirm the session order changes without changing the active
   file unexpectedly.
8. Remove a non-active track during playback and confirm playback continues.
9. Remove the active track and confirm playback pauses and selects the next
    track, or previous if the removed track was last.
10. Toggle Repeat Off, Repeat One, and Switch & Repeat and confirm end-of-range
    behavior.
11. Drag a loop selection, play through it, resize it, then deselect it.
12. Zoom in/out, zoom to fit, and zoom to selection; confirm scroll/pinch keep
    the playhead and ruler aligned.
13. Toggle Blind Listening Mode and confirm rows show anonymous labels and
    placeholder waveforms without shifting layout.
14. Use Finder selection import, Music selection import, and Show in Finder from
    both UI/menu paths when those areas are affected.

## Gotchas

- **`open` returns immediately** — the process takes ~1 second to appear. `build-debug.sh` polls `pgrep -x Takes` to wait. Don't screenshot immediately after calling `open`; wait for the script to confirm the PID.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `** BUILD FAILED **` with missing Sparkle framework | Run `xcodebuild` once; it fetches the SPM dependency automatically on first run. If it still fails, open `Takes.xcodeproj` in Xcode once to resolve packages. |
| `open` reports the app can't be opened (damaged/quarantine) | Run `xattr -d com.apple.quarantine .derived-data/Build/Products/Debug/Takes.app` |
| `pgrep -x Takes` never succeeds after launch | Check Console.app for crash logs; usually a missing entitlement or code-signing issue on unsigned builds. Re-run the full build step. |
| Takes is already running from a previous session | `pkill -x Takes` before launching, or `build-debug.sh` does this automatically. |
