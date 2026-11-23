# A2 redesign: compact cover column

Handoff spec for implementing the A2 design. The design lives on the
**Design** page of the canvas
<https://claude.ai/artifact/ACWY27QaC8aWg8JT47VSDH> (artboards *A2 · Playlist*,
*A2 · Compare*, *A2 · Playlist, artwork hidden*). The **Archive** page holds
the rejected directions and every A2 iteration; read it only for history.

The artboards are HTML approximations drawn in dark appearance only; light
appearance is also required (§13). Where this spec and an artboard
disagree, this spec wins. Values marked **v2.9.0** were
taken from that tag's source and must match it; everything else is new.

Before starting, read `AGENTS.md`. The invariants there (one
`PlaybackController`, `NSOutlineView` playlist table, Core Animation for
continuous motion, track-row / lane-leaf isolation, gapless loop wraps) all
still apply.

## 1. Concept

One narrow window, 360 pt wide, in both modes.

- **Playlist mode:** album artwork on top, then the control bar (transport and
  readout), then the track list, then a bottom bar.
- **Compare mode:** the artwork and control bar stay exactly where they are.
  The track list is replaced by the comparison (ruler and waveform lanes),
  and the bottom bar changes its tools. Entering compare is a zoom into one
  item, not a different place.
- **Artwork hidden:** the cover collapses and the window gets shorter. The
  state persists and carries across both modes.

## 2. Window

| | Width | Height (default content) |
|---|---|---|
| Playlist, artwork shown | 360 | 760 |
| Playlist, artwork hidden | 360 | 414 |
| Compare, artwork shown | 360 | 760 |

- Width is the same in both modes; mode switches never resize horizontally.
- Hiding the artwork removes the 360 pt cover. The titlebar then overlays the
  top of the control bar (as v2.9.0's control bar already does), and the
  control bar's top padding grows from 10 to 24 pt so Shuffle and Repeat clear
  the window buttons. Net: the window shrinks by 346 pt.
- The window's top edge stays put when it shrinks or grows (grow and shrink
  downward), as `WorkspaceView.setPlaylistFrame` does today.
- This replaces the current playlist/comparison size policy:
  `TakesWindowPolicy.minimumContentWidth` (640), `playlistDefaultSize`
  (760 × 520), `resizeMainWindow(...)` for compare, and
  `applyModeWindowSize(previousMode:)` in `WorkspaceView.swift`.

**Open:** whether the window is user-resizable (taller lists and lanes, wider
lanes) or fixed. The design assumes fixed width; height could reasonably
stretch the list or lane area.

## 3. Shared layout grid

- **Edge inset: 10 pt** on both sides for everything that isn't full-bleed:
  window controls, artwork toggle, transport row, readout, list row
  highlights, bottom-bar controls. Lanes and the ruler run edge to edge.
- Control bar surface: `#2B2B2E` (dark). Track/lane area below it is darker.
- One divider between the control bar and the content below: a 1 pt
  `black 62%` line over a 1 pt `white 6%` line (the existing groove). No
  other divider sits directly beneath it; in compare, the ruler has **no**
  top border.

## 4. Titlebar and artwork

- Artwork: full-bleed 360 × 360 square, no text overlay. A faint top shade
  (`black 35%` → clear over 40 pt) keeps the window buttons legible.
- Window buttons at their standard position (10 pt in).
- **Artwork toggle**, top right, 10 pt from the edge, vertically centred on
  the window buttons. 26 × 22 pt hit area, 16 pt glyph.
  - Glyph: an album sleeve (rounded rectangle) with a record sliding out of
    its right edge (open arc plus a small centre dot). No SF Symbol matches;
    draw it as a template image or custom `Shape`.
  - **On = artwork showing.** Lit glyph (`Theme.primaryLitGlyph`, with a
    soft primary glow, as v2.9.0's engaged secondary buttons) on a frosted
    chip so it reads over any cover: 6 pt radius, ~50% dark fill with
    background blur (`.ultraThinMaterial`-like), 0.5 pt white 22% inner
    hairline, small drop shadow.
  - **Off = artwork hidden.** Plain grey glyph (secondary label colour), no
    chip, in the titlebar overlay.
  - Accessibility: "Hide Artwork" / "Show Artwork", toggle trait.
- Persist the state in `AppSettings` (new key). It applies to both modes.

## 5. Control bar

### 5.1 Transport row

Three groups; the side groups are the same width so the centre group stays
centred.

| Mode | Left (30 pt slot) | Centre (12 pt gaps) | Right (30 pt slot) |
|---|---|---|---|
| Playlist | Shuffle | Previous · **Play** · Next | Repeat |
| Compare | Blind | **Play** · Switch Track | Repeat |

- Blind takes Shuffle's place; Repeat never moves. Previous/Next have no
  compare equivalent and are not shown there.
- Side buttons are **plain icons** (no circle), 20 pt glyph, secondary
  colour, centred in a 30 × 40 pt slot. The slot width is chosen so Blind
  sits directly above compare's 30 pt back button.
- Centre buttons use **v2.9.0's `CircleTransportButtonStyle`** unchanged
  (dark values from `TransportAppearance`):
  - Play: `.primary`, 56 pt, 22 pt glyph.
  - Previous, Next, Switch Track: `.secondary`, 40 pt, 15 pt glyph.
  - The inset bevel (rim light top → dark bottom, gloss, dark shadow above,
    light lip below) is the existing style; no drop shadows.
- Vertical padding: 10 pt above the row (24 pt when artwork is hidden),
  10 pt between the row and the readout.

### 5.2 Readout

Sits on the control-bar surface (no separate band), 10 pt side inset, 12 pt
below it to the divider.

- Frame: **v2.9.0 Glass style** (`ReadoutStyle.glass`, the convex tile in
  `DigitalTimeReadout.convexGlassPanel` / `convexGlassLight`): no bezel,
  `Theme.readoutGlass` fill, domed highlight centred high on the tile, 1 pt
  dark rim, lit top edge and shadowed bottom edge. Corner radius scales with
  height (v2.9.0: 11 pt at 56 pt tall): 9 pt at 42, 7 pt at 30.
- Content colour: `Theme.readoutGlow` (cyan LED in dark).

**Playlist readout, 42 pt tall, two lines:**
1. Seven-segment elapsed time (`SevenSegmentDisplay`), a faint divider, then
   the playing item's track title in the dot-matrix face, uppercase, e.g.
   `TAXMAN (1967 MONO MIX)`. Long titles scroll (`DotMatrixMarqueeDisplay`).
2. LED progress meter: a row of ~80 cells lit up to the playhead, the
   leading cell brightest. The existing `DotMatrixProgressBar` (seekable) is
   the natural basis.

There is no separate progress bar or elapsed/remaining text anywhere else.

**Compare readout, 30 pt tall, one line,** with a back button on its left:
- Back button: 30 × 30 pt, 7 pt radius, the secondary button treatment
  (same fill/bevel/inset as §5.1), `chevron.left` glyph. Returns to playlist
  (same as Esc). Accessibility "Back to Playlist".
- Readout: seven-segment elapsed time, divider, then the **audible version's
  track title** in the same style as the playlist readout (e.g.
  `TAXMAN (2009 STEREO MIX)`). It follows Switch Track. It is narrower than
  the playlist readout, so long titles scroll.

## 6. Playlist list

Replaces the current column table. Still an `NSOutlineView`
(`PlaylistOutlineView.swift`); only the row views and metrics change.

**Item rows, 46 pt:**
- Leading disclosure chevron slot, always reserved (12 pt) so artwork and
  titles align whether or not a row has versions. Chevron only on items
  with more than one version; rotates when expanded.
- 34 pt artwork thumbnail, 4 pt radius. Items with versions show a stacked
  look: two offset card edges up and to the right (`3,-3` and `6,-6`).
  Items without artwork show a neutral tile with a music-note glyph.
- Title (13 pt semibold) over artist (11 pt secondary).
- Trailing duration (12 pt, tabular digits).
- Now playing: primary-tinted row background (~14%), title in the light
  primary tint, speaker glyph over the thumbnail.
- Missing file: title dimmed, warning triangle over a darkened thumbnail
  (not beside the duration).
- Hover on a multi-version item: a **Compare** pill before the duration.
  Opens compare for that item **without starting its playback**.
  Double-click still plays the item, as today.
- Selection highlight and every row background sit inside the 10 pt inset,
  6 pt radius.

**Version rows, 30 pt** (shown when the item is expanded):
- A check in a 34 pt column under the thumbnail marks the playback version;
  clicking a version row makes it the playback version.
- Name = the file's **track title tag**, not its filename
  (`Eleanor Rigby (2009 Stereo Mix)`), 12 pt, aligned with item titles.
- Format (e.g. FLAC, MP3) and duration, secondary.
- No drag handles; the whole row is draggable.

**Text truncation:** item and version titles use **middle truncation**
(`lineBreakMode = .byTruncatingMiddle`) so the song and the mix name both
survive. Artist lines keep tail truncation. Today `PlaylistOutlineView` uses
`.byTruncatingTail` for titles.

**Drag and drop** (behaviour unchanged from today's outline view):
- Drop a version on another item to move it there (target row gets a
  primary ring); drop between rows to make it its own item.

**Removed:** the version-count badge, the "PLAYLIST" header row, the
version selector under the transport, the Group and Compare header bar.

## 7. Bottom bar (both modes)

30 pt, darker surface, top hairline, 10 pt insets. All controls are standard
macOS **small** controls (`.controlSize(.small)`, 20 pt tall, 10 pt glyphs).

| Mode | Left | Right |
|---|---|---|
| Playlist | `+`/`−` segmented (Add Files / Remove Selected) · `…` pull-down menu (the organisation commands from `PlaylistCommandContext`) | `6 items · 19:35` (item count and total duration) |
| Compare | `+`/`−` segmented (Add Version / Remove Active Version) · Align button | Zoom: magnifier − · small slider · magnifier + (no Fit button) |

## 8. Compare area

Below the divider: ruler, lanes, bottom bar. No track-info column.

**Ruler, 26 pt** (v2.9.0's arrangement, shortened from 34 pt):
- Notches hang from the bottom edge: major 11 pt, minor 5 pt, colour
  `Theme.timelineRulerTick`.
- Labels 3 pt from the top, 4 pt right of their major notch
  (`TimelineHeaderLabelLayout.leading`), caption size, monospaced digits,
  `00:30` format.
- 1 pt bottom border; no top border.

**Playhead** (v2.9.0): 2 pt `Theme.secondary` line from the ruler's bottom
edge down through the lanes; v2.9.0's 14 × 16 pt `PlayheadHandle` grabber
with its tip seated on the ruler's bottom edge. Keep the existing
Core Animation playhead (`TimelinePlayheadVisual`).

**Lanes:** full width, equal height filling the space (≈74 pt each for three
versions in the default window). More than three versions scroll.
- Info overlaid on a 21 pt strip at the top of each lane, over a dark
  fade: index badge (15 pt; primary fill when active), version track title
  (11.5 pt semibold), format (10 pt secondary), and an offset field on the
  right (e.g. `0 ms`, editable).
- Waveform beneath the strip, centred in the remaining height.
- Active lane: primary-tinted background (~11%), primary waveform, filled
  badge. **No** leading accent bar.
- Inactive waveform: `Theme.waveformInactive`.

This drops `TrackRowView`'s info column. Keep the row/lane isolation
invariant: per-scroll/zoom values still flow only into lane leaves.

## 9. Behaviour

- **Enter compare:** the row's Compare pill on a multi-version item (plus
  the existing menu commands). Does not start playback of that item.
  Single-version items can't enter compare (§13). Double-click keeps its
  current meaning on every row: play (`PlaylistOutlineView.rowDoubleClicked`).
- **Leave compare:** back button or Esc. The version audible when leaving
  becomes the item's playback version (since there is no other in-place
  version picker besides the playlist's version rows).
- **Artwork toggle:** toggles and persists; applies to both modes; resizes
  the window as in §2.
- Transport semantics are unchanged from today (`AGENTS.md`, Playback Model).

## 10. Files likely touched

- `WorkspaceView.swift`: window sizing per mode/artwork state,
  `PlaylistTransportView`, titlebar overlay, artwork toggle placement.
- `TakesApp.swift`: `TakesWindowPolicy` sizes and minimums.
- `AppSettings.swift`: persisted artwork-visible setting.
- `TransportControls.swift`: reuse `CircleTransportButtonStyle`; readout
  frame sizes; small back-button variant.
- `DotMatrixReadout.swift`: two-line playlist readout, LED meter, compact
  compare readout.
- `PlaylistView.swift`: remove the header bar; add the bottom bar.
- `PlaylistOutlineView.swift`: new row and version-row views, thumbnails,
  middle truncation, hover Compare pill, version names from tags.
- `ContentView.swift`: compact compare layout, ruler sizing, overlaid lane
  info, removal of the info column and navigation bar, bottom bar.
- `AudioFileLoader.swift`: **new**: embedded artwork extraction for the cover
  and thumbnails (in-memory only, per the no-disk-caches rule).

## 11. Suggested milestones

Each is meant to fit one session and leave the app working.

1. **Window shell and artwork.** 360 pt window for both modes, artwork area,
   titlebar overlay, artwork toggle with persistence and resizing. Embedded
   artwork loading.
2. **Control bar.** New transport row layout, glass readout (playlist
   two-line with LED meter; compare one-line with back button). Remove the
   comparison navigation bar.
3. **Playlist rows.** Two-line rows, thumbnails, stacked art, version rows
   with tag names, middle truncation, hover Compare, missing-file overlay.
   Remove the header bar.
4. **Compact compare.** Drop the info column, overlaid lane info, 26 pt
   ruler, playhead seating, lane sizing and scrolling.
5. **Bottom bars.** Small-control bars for both modes; move organisation
   commands into the `…` menu.

Update `AGENTS.md` (ownership, invariants, test map) as each milestone lands.

## 12. Open questions

- Window resizability (§2).
- What the version check (§6) does when the playback version's file is
  missing.

## 13. Decisions

- **Light appearance is required.** The canvas only draws dark, so light
  values come from the existing tokens: v2.9.0's `lightPrimary` /
  `lightSecondary` `TransportAppearance`, the light `Theme` colours (amber
  backlit LCD readout, amber secondary accent), and system label colours.
  New elements need light designs of their own: the frosted artwork-toggle
  chip, the lane info strip's fade, the stacked-thumbnail card edges, and
  the list's row tints.
- **Teenage Engineering control-bar theme: out of scope.** A2 targets the
  classic theme only. Leave `ControlBarTheme.teenageEngineering` as it is;
  how it maps onto the A2 control bar is a later question.
- **Compare is unavailable for single-version items.** They show no
  disclosure chevron and no Compare pill.
- **Long readout titles scroll.** In both readouts, a title wider than its
  space scrolls as a marquee (pause, scroll, repeat) rather than truncating.
  Use the existing `DotMatrixMarqueeText` / `DotMatrixMarqueeDisplay`, which
  only animate lines that actually overflow. The compare readout is narrower,
  so it scrolls more often.
- **Double-click plays, on every row.** It does not open compare, even for
  multi-version items; the Compare pill is the way in.
