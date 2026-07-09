[ ] Make info area have the smallest of drop shadows.

The playhead disappears under it (docs/small-tweaks-images/CleanShot 2026-07-08 at 9 .38.18.png), and a drop shadow will make this look intentional rather than a visual bug. Mimic GarageBand

---

[ ] Make the progress ring that shows up during "deep tempo analysis" based on theme’s indigo color, not orange/cyan highlight color

---

[ ] Reduce hit target of empty state “click to compare” button. make it a rectangle around the icon + text with just a little padding. Often clicking on the empty space unexpectedly brings up the open dialog box and we want to avoid this.

---

[ ] Add keyboard shortcuts for changing offset of active track without making input field active. Details:
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

[ ] Quick Open from Finder should accept folders.

Currently if you Quick Open from Finder and there’s a folder selected, Takes shows an alert: "No audio files are selected in the Finder.”

---

- [ ] Clicking in waveform area should update play position & switch tracks
- [ ] Change “Show in Finder” → “Reveal in Finder”
- [ ] rename transport bar → control bar
- [ ] Don’t allow blind mode to be set when no tracks are loaded
- [ ] Add haptic feedback
- [ ] Add setting for displaying filename vs track name
- [ ] make the vertical playhead indicator line draggable
- [ ] Make playhead handle a tiny bit lighter
- [ ] Tooltip improvements