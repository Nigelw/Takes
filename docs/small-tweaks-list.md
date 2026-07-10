[x] Make info area have the smallest of drop shadows.

Status: done on `codex/tweak-info-shadow`.

Testing notes: targeted Debug build passed in `/private/tmp/takes-small-tweaks/info-shadow` with `xcodebuild -project Takes.xcodeproj -scheme Takes -configuration Debug -derivedDataPath /private/tmp/takes-debug-derived-data-info-shadow CODE_SIGNING_ALLOWED=NO build`; worker noted an unrelated existing `AnalysisWindowView.swift` main-actor warning. Manual UI pass still pending.

The playhead disappears under it (docs/small-tweaks-images/CleanShot 2026-07-08 at 9 .38.18.png), and a drop shadow will make this look intentional rather than a visual bug. Mimic what GarageBand does: 'docs/small-tweaks-images/CleanShot 2026-07-08 at 10 .33.16.png'

---

[x] Make the progress ring that shows up during "deep tempo analysis" based on theme’s indigo color, not orange/cyan highlight color

Status: done on `codex/tweak-tempo-ring-indigo`.

Testing notes: targeted Debug build passed in `/private/tmp/takes-small-tweaks/tempo-ring-indigo` with `xcodebuild -project Takes.xcodeproj -scheme Takes -configuration Debug -derivedDataPath /private/tmp/takes-small-tweaks-derived-data CODE_SIGNING_ALLOWED=NO build`. Styling-only change; no tests added.

---

[x] Reduce hit target of empty window state's “click to compare” button. make it a rectangle around the icon + text with just a little padding. Often clicking on the empty space unexpectedly brings up the open dialog box and we want to avoid this.

Status: done on `codex/tweak-empty-click-target`.

Testing notes: targeted Debug build passed in `/private/tmp/takes-small-tweaks/empty-click-target` with `xcodebuild -project Takes.xcodeproj -scheme Takes -configuration Debug -derivedDataPath /private/tmp/takes-empty-click-target-derived CODE_SIGNING_ALLOWED=NO build`; worker noted an unrelated existing `AnalysisWindowView.swift` main-actor warning. Manual UI pass still pending.

---

[x] Add keyboard shortcuts for changing offset of active track without making input field active. Details:
- cmd+j/k: nudge to decrease/increase offset
- cmd+shift+j/k: large nudge to decrease/increase offset

Add these items to the playback menu, and rearrange the whole menu like this:

Status: done on `codex/tweak-offset-shortcuts`.

Testing notes: full `xcodebuild test` was run in `/private/tmp/takes-small-tweaks/offset-shortcuts`; app built and the new shortcut tests passed, but the suite still reported one unrelated existing failure in `TrackDropHighlightTests.openFileCommandStateCancelsRegisteredStreamingTaskOnDismiss()` at `#expect(await recorder.didCancel)`. New behavior is focus-safe and uses configured offset nudge amounts.

```
Play
Switch Track
Switch to Previous Track
---
Jump to Beginning
Jump to End
Skip > (skip items Moved to submenu)
<divider>
Repeat > (repeat modes remain in submenu)
Blind Listening Mode
<divider>
Auto-Align Tracks
Nudge Track > (new nudge shortcuts in submenu)
```

---

[x] Quick Open from Finder should accept folders.

Status: done on `codex/tweak-finder-folders`.

Testing notes: targeted `xcodebuild test` passed for `TakesTests/TrackDropHighlightTests` in `/private/tmp/takes-small-tweaks/finder-folders`. Added a focused test proving Finder folder selections recurse into nested audio files; worker noted an unrelated existing `AnalysisWindowView.swift` main-actor warning.

Currently if you Quick Open from Finder and there’s a folder selected, Takes shows an alert: "No audio files are selected in the Finder.”

---

[x] Clicking in waveform area should update play position & switch tracks as well as play position

Status: done on `codex/tweak-waveform-click-switch`.

Testing notes: targeted `xcodebuild test` passed for `TakesTests/SessionTests` in `/private/tmp/takes-small-tweaks/waveform-click-switch`. Added focused row-mapping policy tests; timeline ruler and shift-click loop selection are unchanged.

---

[x] Change File->Show in Finder → File->Reveal in Finder

Status: done on `codex/tweak-reveal-in-finder`.

Testing notes: targeted Debug build passed in `/private/tmp/takes-small-tweaks/reveal-in-finder`; label-only change, no tests added. Existing `Shift-Command-R` behavior is unchanged.

---

[x] Disable blind mode button when no tracks are loaded

Status: done on `codex/tweak-disable-blind-empty`.

Testing notes: fresh Debug build passed in `/private/tmp/takes-small-tweaks/disable-blind-empty`; targeted existing blind-listening runtime tests passed. No direct view-state test harness exists for the toolbar/menu enablement.

---

[x] make the vertical playhead indicator line draggable

Status: done on `codex/tweak-draggable-playhead`.

Testing notes: full `xcodebuild test` passed in `/private/tmp/takes-small-tweaks/draggable-playhead`. The new drag target routes through existing seek/loop-deselect behavior; worker noted the existing `AnalysisWindowView.swift` main-actor warning during build.

---

[x] Make the light mode playhead handle a tiny bit lighter (show me where in code the color is defined so I can tweak myself if needed)

Status: done on `codex/tweak-light-playhead-handle`.

Testing notes: targeted Debug build passed in `/private/tmp/takes-small-tweaks/light-playhead-handle`; worker noted the existing `AnalysisWindowView.swift` actor-isolation warning. The tweak point is `PlayheadTint` in `Sources/Takes/ContentView.swift`; it feeds the playhead line and grabber without changing shared `Theme.secondary`.

---

[-] Add haptic feedback as an experimental setting in the debug window

Status: in progress on `codex/tweak-haptics-debug`.

macOS supports 3 types of haptic feedback via NSHapticFeedbackManager API in AppKit:
* .alignment: Indicates two UI elements have snapped into alignment, such as guides in a design app.
* .levelChange: Indicates stepping between discrete values, such as volume or zoom increments.
* .generic: A general-purpose click when neither of the above is appropriate.

Add a window (opened from the debug menu) that allows you to set the 3 types of macOS haptic feedback for these events:

- Dragging playhead to beginning/end of timeline
- Scrolling to beginning/end of timeline
- Using zoom control (it should trigger only at a few thresholds rather than continuously)
- Zooming with pinch zoom (not sure if possible?)
- Transport bar button presses
- Hovering over the playhead/playhead handle
- Hovering over the loop selection controls

---

[-] Add setting for displaying filename vs track name

Status: in progress on `codex/tweak-track-name-setting`.

Track name should fallback to filename if metadata doesn’t exist

--- 

[x] Track name tooltip improvements

Status: done on `codex/tweak-track-tooltip`.

Testing notes: targeted Debug build passed in `/private/tmp/takes-small-tweaks/track-tooltip`. Tooltip is now scoped to the rendered title label and only registered when the visible title is truncated; AppKit still controls final tooltip bubble placement. Manual check should cover short, long/truncated, and blind-mode row titles.

- only show tooltips if names are truncated
- position pop-up directly over the name if possible

---

[x] Make the install dmg prettier

Status: done on `codex/tweak-pretty-dmg`.

Testing notes: `bash -n scripts/build-release.sh` passed, `scripts/make-dmg-background.swift` rendered a valid 1200x800 PNG, and `sips` confirmed the output dimensions. Full signed/notarized DMG assembly was not run; remaining risk is `create-dmg` placement/rendering during the real release build.

When we generate the dmg as part of the build process, the icons are vertically centered. Would also be nice to have a subtle background in the window if you can generate something nice.

---

[x] If you scroll playhead off screen during playback, let inertial scroll come to a stop before scrolling the playhead in view

Status: done on `codex/tweak-playhead-inertial-scroll`.

Testing notes: targeted `xcodebuild test` passed for `TakesTests/SessionTests` in `/private/tmp/takes-small-tweaks/playhead-inertial-scroll`. No automated test was kept because the behavior depends on AppKit live-scroll/inertial lifecycle and real playback timing; manual verification should confirm auto-follow waits until inertial scrolling fully stops.
