## Make info area have the smallest of drop shadows

- Status: done on `codex/tweak-info-shadow` commit `5ef024db948d38503be0dee6befc75d65e52b1ac`.

- Testing notes: targeted Debug build passed in `.codex/worktrees/tweak-info-shadow` with `xcodebuild -project Takes.xcodeproj -scheme Takes -configuration Debug -derivedDataPath /private/tmp/takes-debug-derived-data-info-shadow CODE_SIGNING_ALLOWED=NO build`; worker noted the existing `AnalysisWindowView.swift` main-actor warning. Manual UI pass still pending.

The playhead disappears under it (docs/small-tweaks-images/CleanShot 2026-07-08 at 9 .38.18.png), and a drop shadow will make this look intentional rather than a visual bug. Mimic what GarageBand does: 'docs/small-tweaks-images/CleanShot 2026-07-08 at 10 .33.16.png'

---

## Make the progress ring that shows up during "deep tempo analysis" based on theme’s indigo color, not orange/cyan highlight color

- Status: done on `codex/tweak-tempo-ring-indigo` commit `04974f3d06aac8560d0fd90d1f2f3d76df013bf4`.

- Testing notes: targeted Debug build passed in `.codex/worktrees/tweak-tempo-ring-indigo` with `xcodebuild -project Takes.xcodeproj -scheme Takes -configuration Debug -derivedDataPath /private/tmp/takes-debug-derived-data CODE_SIGNING_ALLOWED=NO build`; worker noted an existing `AnalysisWindowView.swift` main-actor warning. Styling-only change; no tests added.

---

## Reduce hit target of empty window state's “click to compare” button

- Status: done on `codex/tweak-empty-click-target` commit `fb059db6045336eb827b30e66bc11abce7eafb9a`.

- Testing notes: targeted Debug build passed in `.codex/worktrees/tweak-empty-click-target` with `xcodebuild -project Takes.xcodeproj -scheme Takes -configuration Debug -derivedDataPath /private/tmp/takes-debug-derived-data CODE_SIGNING_ALLOWED=NO build`; worker noted an unrelated existing `AnalysisWindowView.swift` main-actor warning. Manual UI pass still pending.

Make it a rectangle around the icon + text with just a little padding. Often clicking on the empty space unexpectedly brings up the open dialog box and we want to avoid this.

---

## Add keyboard shortcuts for changing offset of active track without making input field active

- Status: done on `codex/tweak-offset-shortcuts` commit `c5dc97cd94d649c5c3d85ba9ac9b20ca8ee05833`.
- Testing notes: full `xcodebuild test` passed in `.codex/worktrees/tweak-offset-shortcuts` with `/private/tmp/takes-derived-data-offset-shortcuts` DerivedData. Added focused coverage for active-track offset nudging with custom configured small/large nudge values; worker noted existing compiler warnings around `AnalysisWindowView.swift` actor isolation and `SessionTests` `renderableRowRange`.

Details:
- cmd+j/k: nudge to decrease/increase offset
- cmd+shift+j/k: large nudge to decrease/increase offset

Add these items to the playback menu, and rearrange the whole menu like this:

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

## Quick Open from Finder should accept folders

- Status: done on `codex/tweak-finder-folders` commit `65a7276c600b3f29c6780aad0cc55de81b1abe43`.

- Testing notes: targeted `xcodebuild test` passed for `TakesTests/TrackDropHighlightTests` in `.codex/worktrees/tweak-finder-folders` with `/private/tmp/takes-small-tweaks-finder-folders` DerivedData. Added focused tests for Finder folder recursion and folder selections containing no audio; worker noted an unrelated existing `AnalysisWindowView.swift` main-actor warning.

Currently if you Quick Open from Finder and there’s a folder selected, Takes shows an alert: "No audio files are selected in the Finder.”

---

## Clicking in waveform area should update play position & switch tracks as well as play position

- Status: done on `codex/tweak-waveform-click-switch` commit `4c0a39477970f95bf3d0c6e2422cde694acc2541`.

- Testing notes: targeted `xcodebuild test` passed for `TakesTests/SessionTests` in `.codex/worktrees/tweak-waveform-click-switch` with `/private/tmp/takes-small-tweaks/waveform-click-switch` DerivedData. Added focused row-mapping policy tests; timeline ruler and shift-click loop selection are unchanged. Worker noted the existing unrelated `AnalysisWindowView.swift` main-actor warning.

---

## Change File->Show in Finder → File->Reveal in Finder

- Status: done on `codex/tweak-reveal-in-finder` commit `5ebb95078575492865d3a92b8c5e7efa3947e6b7`.

- Testing notes: targeted Debug build passed in `.codex/worktrees/tweak-reveal-in-finder` with `xcodebuild -project Takes.xcodeproj -scheme Takes -configuration Debug -derivedDataPath /private/tmp/takes-debug-derived-data-tweak-reveal-in-finder CODE_SIGNING_ALLOWED=NO build`; label-only change, no tests added. Existing action and shortcut are unchanged.

---

## Disable blind mode button when no tracks are loaded

- Status: done on `codex/tweak-disable-blind-empty` commit `767bbb2c97185174676bfec8a79324466c5fc78c`.

- Testing notes: targeted `xcodebuild test` passed for `TakesTests/SessionTests/sessionReadinessUsesOrderedTracks` in `.codex/worktrees/tweak-disable-blind-empty`; worker noted the existing `AnalysisWindowView.swift` warning. Change adds shared `ComparisonSession.canToggleBlindListeningMode` used by toolbar and View-menu enablement.

---

## Make the vertical playhead indicator line draggable

- Status: done on `codex/tweak-draggable-playhead` commit `3a6be2acd5efeb4771b47a9271335f3cb1c66360`.

- Testing notes: full `xcodebuild test` passed in `.codex/worktrees/tweak-draggable-playhead` with `/private/tmp/takes-small-tweaks-draggable-playhead-test` DerivedData. The new drag target routes through existing preview/seek/loop-deselect behavior; worker noted the existing `AnalysisWindowView.swift` main-actor warning during build.

---

## Make the light mode playhead handle a tiny bit lighter

- Status: done on `codex/tweak-light-playhead-handle` commit `c7ca0957ed8dc96434f76eec37c96b6351d2a2eb`.

- Testing notes: targeted Debug build passed in `.codex/worktrees/tweak-light-playhead-handle` with `xcodebuild -project Takes.xcodeproj -scheme Takes -configuration Debug -derivedDataPath /private/tmp/takes-debug-derived-data-light-playhead CODE_SIGNING_ALLOWED=NO build`; worker noted the existing `AnalysisWindowView.swift` actor-isolation warning. The tweak point is `PlayheadGrabberArt` in `Sources/Takes/ContentView.swift`, specifically `lightModeHandleFill`; the line and shared theme tokens are unchanged.

Show where in code the color is defined so I can tweak myself if needed.

---

## Add haptic feedback as an experimental setting in the debug window

- Status: done on `codex/tweak-haptics-debug` commit `07ce547dcdcfeb06630f05feb44470e6840783d5`.

- Testing notes: full `xcodebuild test` built the haptics code and passed new haptics tests, but hit the existing flaky `TrackDropHighlightTests/openFileCommandStateCancelsRegisteredStreamingTaskOnDismiss`; isolated rerun of that test passed. Added focused pure-helper coverage for threshold bucketing and double-fire guards. Manual app-side feel pass on physical haptics is still needed.

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

## Add setting for displaying filename vs track name

- Status: done on `codex/tweak-track-name-setting` commit `e79e0be731a99aa4b6ccbe71e83b5914e3317b8f`.

- Testing notes: targeted `xcodebuild test` passed for `TakesTests/SessionTests`, and targeted Debug build passed in `.codex/worktrees/tweak-track-name-setting`. Added focused coverage for filename default behavior, metadata fallback, stored setting default/readback, and remote playback title behavior while blind mode remains anonymous.

Track name should fallback to filename if metadata doesn’t exist

---

## Track name tooltip improvements

- Status: done on `codex/tweak-track-tooltip` commit `44d821aa72c6be8895c2ba3a165b2f422a2dea31`.

- Testing notes: targeted Debug build passed in `.codex/worktrees/tweak-track-tooltip` with `/private/tmp/takes-small-tweaks/track-tooltip` DerivedData. Tooltip is scoped to the rendered title label and only registered when the visible title is truncated; AppKit still controls final tooltip bubble placement. Manual check should cover short, long/truncated, and blind-mode row titles.

- only show tooltips if names are truncated
- position pop-up directly over the name if possible

---

## Make the install dmg prettier

- Status: done on `codex/tweak-pretty-dmg` commit `a65eec699a3b011e051e90c1f1ad187720a61f81`.

- Testing notes: `bash -n scripts/build-release.sh` passed, `scripts/make-dmg-background.swift` rendered a valid 1200x800 PNG, and `sips` confirmed the output dimensions. Local `create-dmg` smoke build could not complete because `hdiutil` failed in this environment with `Device not configured`; full signed/notarized release build was not run.

When we generate the dmg as part of the build process, the icons are vertically centered. Would also be nice to have a subtle background in the window if you can generate something nice.

---

## If you scroll playhead off screen during playback, let inertial scroll come to a stop before scrolling the playhead in view

- Status: done on `codex/tweak-playhead-inertial-scroll` commit `30ead8be7cf057ff25e32b2f36c3f8d43973487b`.

- Testing notes: targeted `xcodebuild test` passed for `TakesTests/SessionTests` in `.codex/worktrees/tweak-playhead-inertial-scroll` with `/private/tmp/takes-playhead-inertial-scroll-dd` DerivedData. No automated test was added because the behavior depends on AppKit live-scroll/inertial lifecycle and real playback timing; manual verification should confirm auto-follow waits until inertial scrolling fully stops.
