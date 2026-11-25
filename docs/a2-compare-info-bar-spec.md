# A2 compare: info bar instead of the readout

A variant of A2's compare mode ([a2-redesign-spec.md](a2-redesign-spec.md),
§5.2 and §8). The compare control bar loses its readout and back button. A
32 pt info bar takes their place directly above the ruler: the take count on
the left, the elapsed time in a small Glass frame in the centre, and a Done
button on the right.

The canvas calls it the title bar; the app calls it the info bar so it isn't
confused with the window's titlebar.

Design reference: the "A2 · Compare, title bar instead of the readout"
artboard (`A2-CompareTitle.dc.html`) on the Design page of the canvas,
https://claude.ai/artifact/ACWY27QaC8aWg8JT47VSDH (read it with the Artifact
tool's read action). It derives from round 1 of the compare history on the
Archive page. Like the other artboards it is a dark-only HTML approximation:
where it disagrees with this document, this document wins.

Playlist mode does not change.

## 1. Layout, top to bottom

1. Cover and titlebar: unchanged.
2. Control bar: the transport row only (Blind · Play · Switch Track ·
   Repeat), unchanged in size and position. The readout row below it is
   removed, along with `ControlBarMetrics.readoutTopSpacing` and
   `readoutBottomPadding` for compare; the bar ends at the transport row's
   bottom padding (10 pt).
3. The control bar's divider: unchanged.
4. **Info bar, new, 32 pt.**
5. Ruler (26 pt plus its 1 pt bottom border), lanes, bottom bar: unchanged
   apart from the ruler labels (§3).

Net effect with the default sizes: the content below the divider starts
10 pt higher in compare than today (the 30 pt readout and its 12 pt gap go;
the 32 pt info bar arrives below the divider instead). Lanes keep their
fixed 96 pt height; the extra space shows more of the lanes. Below the
transport row the playlist bar keeps 64 pt (10 + 42 pt readout + 12) and the
compare bar now keeps 10, so the compare bar is 54 pt shorter rather than
12; update the "control-bar heights differ by mode" decision accordingly.
The transport row itself doesn't move between modes.

## 2. Info bar

- **Height** 32 pt, full width, 10 pt edge insets.
- **Background:** the same as the ruler's, with no line between them, so the
  info bar and ruler read as one band. In the app the ruler has no fill of
  its own and shares the well with the lanes (a2-redesign-spec §13, "Lane
  waveform"), so the info bar uses the well colour too. The canvas draws the
  ruler and info bar `#27272a` on a `#1f1f21` well; follow the app, not the
  canvas.
- **Three columns:** left and right take equal flexible widths and the
  time stays centred. Long timestamps scale down when the space between
  the side columns is narrower than the clock.

### 2.1 Take count (left)

- Text: `N takes`, singular `1 take` (removal can leave compare with one
  version). N is the number of versions loaded in compare.
- One style: 12 pt medium, secondary label colour. No caps, no second weight.
- Leading-aligned, single line, tail truncation if it ever meets the time.
- Blind Listening Mode shows it unchanged: the count reveals nothing.

### 2.2 Elapsed time (centre)

- The existing seven-segment digits (`SevenSegmentDisplay`, 14 pt digit
  height), showing what the compare readout's time shows today, in the
  readout glow colour.
- In a Glass frame (`readoutGlass`): 24 pt tall, 6 pt corner radius, 9 pt
  horizontal padding, width from its content.
- Light appearance: the light readout's backlit LCD treatment, as the
  playlist readout uses.
- **Performance invariant:** reuse `ControlBarElapsedDigits` as the isolated
  leaf. It re-renders once per displayed second; nothing else in the title
  bar may read `playingReadoutText` or the transport position. No per-frame
  work, no `TimelineView`, no `withAnimation`.
- Not interactive (clicks pass through, as the readout's do). Accessibility:
  "Elapsed Time" with the time as its value.

### 2.3 Done (right)

- Leaves compare: the same action as today's back button, so §9's rule
  holds (the audible version becomes the item's playback version). Esc and
  ⌘[ keep working.
- A rectangular button, not a pill: 22 pt tall, 5 pt corner radius, 12 pt
  horizontal padding, title "Done" in 12 pt semibold white, primary accent
  fill with a faint top highlight and a small drop shadow (the canvas's
  values). Light appearance: the light primary fill.
- Trailing-aligned. Help tag and accessibility label: "Back to Playlist".
- `.borderedProminent` with `.controlSize(.small)` is close but tinted by the
  system accent and sized differently; prefer a custom style built from the
  values above unless it matches.

## 3. Ruler labels

The time labels move up so the playhead grabber (14 × 16 pt, tip on the
ruler's bottom edge, so its top is 11 pt below the ruler's top) never
overlaps them.

- `TimelineRulerMetrics.labelTopInset`: 3 → 0.
- The label's line must end at or above 10 pt from the ruler's top, leaving
  at least 1 pt clear of the grabber. With the current caption font check
  the rendered glyph bounds, not the nominal line height; tighten the line
  height to 10 pt if needed (the canvas uses 10 pt type on a 10 pt line).
- Notches, label x positions, the 26 pt ruler height and the playhead are
  unchanged.

## 4. What goes

- `CompareControlBarReadout` (back button and readout line) from the compare
  control bar. Compare no longer shows the audible version's title anywhere
  in the control bar; the active lane (tint, filled badge, primary waveform)
  and the cover (`CoverVersionRule`) carry it. `ControlBarReadoutTitle
  .comparison` and its blind `TRACK n` rule are then unused: remove them, or
  keep them only if something else still calls them.
- The compare readout's marquee, which only existed for that title.

Nothing else in compare changes: lanes, strips, offset fields, bottom bar,
zoom, loop and reorder behaviour, and every keyboard shortcut stay as they
are.

## 5. Done when

- The canonical `xcodebuild test` passes. Update or add tests for the
  compare control-bar height, the info bar's height, the take-count text
  (singular and plural), and the ruler label inset against the grabber's
  top (`labelTopInset` plus the label height ≤ `CompareLaneLayout.seatBottom
  - 16 - 1`).
- Light and dark both checked in the running app, with the artwork shown and
  hidden, and in a window wider than 360 pt (the time stays centred).
- `AGENTS.md` updated: the ownership entries for `DotMatrixReadout.swift` and
  `ContentView.swift`, the invariants about the readouts, readout titles,
  "Compare leaves through the readout's back button", and the control-bar
  layout, plus the Test Map.
- `a2-redesign-spec.md` §13 records the change (or links here), including
  the new control-bar height difference.

## 6. Open questions

- Should the info bar also appear when the artwork is hidden? This document
  assumes yes: it sits below the control bar, so the artwork state doesn't
  affect it.
- Does the take count need a tooltip or menu (for example the item's title)?
  The canvas has none; this document adds none.
