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

One window, 360 pt wide by default, in both modes.

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
| Playlist, artwork hidden | 360 | 412 |
| Compare, artwork shown | 360 | 760 |
| Compare, artwork hidden | 360 | 412 |

- Width is the same in both modes; mode switches never resize horizontally.
- Hiding the artwork removes the cover. The titlebar then overlays the
  top of the control bar (as v2.9.0's control bar already does), and the
  control bar's top padding grows from 12 to 24 pt so Shuffle and Repeat clear
  the window buttons. The window shrinks by the displayed cover height
  less 12 pt (348 pt at the default width).
- The window's top edge stays put when it shrinks or grows (grow and shrink
  downward), as `WorkspaceView.setPlaylistFrame` does today.
- This replaces the current playlist/comparison size policy:
  `TakesWindowPolicy.minimumContentWidth` (640), `playlistDefaultSize`
  (760 × 520), `resizeMainWindow(...)` for compare, and
  `applyModeWindowSize(previousMode:)` in `WorkspaceView.swift`.

**Decided (§13):** the window is user-resizable in both directions. The
sizes above are the defaults. The minimum width is 260 pt, leaving the
standard 10 pt inset beside Shuffle and Repeat. Every A2 element
must therefore stretch horizontally as well as vertically.

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

- Artwork: a full-width square when height allows, with no text overlay. A faint top shade
  (`black 35%` → clear over 40 pt) keeps the window buttons legible on hover.
- Window buttons at their standard position (10 pt in).
- While the cover is shown, the window buttons and the artwork toggle appear
  only when the pointer is over the cover area, including its placeholder.
  Both are always visible with the cover hidden.
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
  - Accessibility: "Hide Artwork" / "Show Artwork", toggle trait. The cover
    also has a "Hide Artwork" action when the button is out of view.
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
  colour, centred in a 30 × 40 pt slot. Each slot is centred midway between
  its window edge and the playlist's centre group, in both modes (§13,
  milestone 4 review); Blind no longer sits above compare's back button.
- Centre buttons use **v2.9.0's `CircleTransportButtonStyle`** unchanged
  (dark values from `TransportAppearance`):
  - Play: `.primary`, 56 pt, 22 pt glyph.
  - Previous, Next, Switch Track: `.secondary`, 40 pt, 15 pt glyph.
  - The inset bevel (rim light top → dark bottom, gloss, dark shadow above,
    light lip below) is the existing style; no drop shadows.
- Vertical padding: 12 pt above the row (24 pt when artwork is hidden),
  10 pt between the row and the readout.

### 5.2 Readout

Sits on the control-bar surface (no separate band), 10 pt side inset, 10 pt
below it to the divider.

- Frame: **v2.9.0 Glass style** (`ReadoutStyle.glass`, the convex tile in
  `DigitalTimeReadout.convexGlassPanel` / `convexGlassLight`): no bezel,
  `Theme.readoutGlass` fill, domed highlight centred high on the tile, 1 pt
  dark rim, lit top edge and shadowed bottom edge. Corner radius scales with
  height (v2.9.0: 11 pt at 56 pt tall): 9 pt at 42 and 41, 7 pt at 30.
- Content colour: `Theme.readoutGlow` (cyan LED in dark).

**Playlist readout, 41 pt tall, two lines** (42 on the canvas; see §13):
1. Seven-segment elapsed time (`SevenSegmentDisplay`), a faint divider, then
   the playing item's track title in the dot-matrix face with its original
   capitalization, e.g. `Taxman (1967 Mono Mix)`. Long titles scroll (`DotMatrixMarqueeDisplay`).
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
- Key version's title (13 pt semibold) over its artist (11 pt secondary).
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
- A circular check in a 34 pt column under the thumbnail marks the key
  version. Clicking the empty circle on a hovered version sets it as the
  key version.
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
| Playlist | `+`/`−` segmented (Add Files / Remove Selected) · `…` pull-down menu (the organisation commands from `PlaylistCommandContext`) | `6 tracks · 19:35` (item count and total duration) |
| Compare | `+`/`−` segmented (Add Version / Remove Active Version) · Align button | Zoom: magnifier − · small slider · magnifier + (no Fit button) |

Built in milestone 5; the decisions it settled (surface and light values,
the pull-down's contents, the summary, Remove Active Version, Align, zoom,
and the window minimum) are in §13.

## 8. Compare area

Below the divider: ruler, lanes, bottom bar. No track-info column.

**Ruler, 21 pt** (v2.9.0's arrangement, shortened from 34 pt; 26 pt until
the compare info-bar variant, §13):
- Notches hang from the bottom edge: major 19 pt, minor 8 pt (v2.9.0's
  heights; 11 and 5 until the compare info-bar variant, §13), colour
  `Theme.timelineRulerTick`.
- Labels with their digits' tops level with their major notch's top (2 pt
  from the ruler's top; 3 pt from the top until §13), 4 pt right of it
  (`TimelineHeaderLabelLayout.leading`), caption size, monospaced digits,
  `00:30` format.
- 1 pt bottom border; no top border.

**Playhead** (v2.9.0): 2 pt `Theme.secondary` line from the ruler's bottom
edge down through the lanes; v2.9.0's 14 × 16 pt `PlayheadHandle` grabber
with its tip seated on the ruler's bottom edge. Keep the existing
Core Animation playhead (`TimelinePlayheadVisual`).

**Lanes:** full width, one fixed height (96 pt with its divider; changed from
the canvas's equal shares in the milestone 4 review, §13). Lanes that don't
fit scroll.
- Info overlaid on a 21 pt strip at the top of each lane, with no fade (the
  canvas's fade was dropped in review, §13): index badge (15 pt; primary
  fill when active), version track title (11.5 pt semibold), format (10 pt
  secondary), and an offset field on the right (e.g. `0 ms`, editable).
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

1. **Window shell and artwork.** *Done.* 360 pt window for both modes,
   artwork area, titlebar overlay, artwork toggle with persistence and
   resizing. Embedded artwork loading.
2. **Control bar.** *Done.* New transport row layout, glass readout
   (playlist two-line with LED meter; compare one-line with back button).
   Remove the comparison navigation bar. Also removed the Teenage
   Engineering theme and the Retro readout frame, and dropped compare's
   zoom controls until milestone 5 (§13).
3. **Playlist rows.** *Done.* Two-line rows, thumbnails, stacked art,
   version rows with tag names, middle truncation, hover Compare,
   missing-file overlay. Removed the header bar, the version-count badge and
   the column headers. Entering compare no longer starts another item (§13).
4. **Compact compare.** *Done.* Dropped the info column with its width
   setting, resize handle and policy constants. Overlaid lane info strips,
   26 pt ruler, playhead seating, lane sizing and scrolling. Removed the
   compare header's import button, Align button and Remove All; their
   commands stay in the menus (§13).
5. **Bottom bars.** *Done.* One 30 pt small-control bar layout for both
   modes, below the playlist table and the compare lanes. Playlist: Add
   Files… / Remove Selected, the `…` pull-down with the Playlist menu's
   organisation commands, and the `6 tracks · 19:35` summary. Compare: Add
   Version… / Remove Active Version, the Align button (its progress, outcome
   flash and "Analyze Further" popover back from the pre-A2 header, replacing
   the interim alert), and zoom. Settled the window minimum height (§13).

Update `AGENTS.md` (ownership, invariants, test map) as each milestone lands.

## 12. Open questions

None open. The version check for a missing file was decided in milestone 3
(§13).

## 13. Decisions

- **Light appearance is required.** The canvas only draws dark, so light
  values come from the existing tokens: v2.9.0's `lightPrimary` /
  `lightSecondary` `TransportAppearance`, the light `Theme` colours (amber
  backlit LCD readout, amber secondary accent), and system label colours.
  New elements need light designs of their own: the frosted artwork-toggle
  chip, the lane info strip's fade, the stacked-thumbnail card edges, the
  list's row tints, and the bottom bar (each recorded below).
- **Teenage Engineering control-bar theme: removed** (milestone 2). A2 has
  one control-bar look, so the theme, `ControlBarTheme`, its setting and
  the Settings picker are gone. A stored `controlBarTheme` preference is
  ignored. The theme is in git history (before commit "Remove the Teenage
  Engineering control bar theme") if it is wanted again.
- **Retro readout frame: removed** (milestone 2). The readouts use the Glass
  frame only; `ReadoutStyle` and the "Readout frame" picker are gone, and a
  stored `readoutStyle` preference is ignored.
- **Readout titles** (milestone 2; compare's removed by the compare
  info-bar variant, below, which leaves the playlist rule only). Both
  readouts show a version's title tag,
  falling back to its filename without the extension. The playlist preserves
  the source capitalization. Playlist:
  the playing (or current) version. Compare: the audible version, except in
  Blind Listening Mode, where it shows `TRACK n` (the lane's position), as
  the lanes and Now Playing do, so the readout can't reveal the version. The
  playlist readout drops the pre-A2 readout's artist/album line and its small
  artwork tile; the cover carries the artwork.
- **Compare zoom controls** (milestone 2, back in milestone 5). The compare
  transport row has no room for them, so they moved to the bottom bar's
  right side (see "Bottom-bar zoom" below). ⌘+/⌘−, Zoom to Selection, Zoom
  to Fit and pinch zoom as well.
- **Esc leaves compare**, as the back button (now the info bar's Done)
  and ⌘[ do (§9). It goes through
  the same focus-safe shortcut gate, so text fields keep Esc.
- **Side-button placement** (milestone 4 review). Shuffle/Blind and Repeat
  are each centred midway between their window edge and the playlist's
  Previous · Play · Next group (160 pt): 50 pt from the edges in a 360 pt
  window, further in as it widens. Compare keeps those positions rather than
  re-centring against its narrower Play · Switch Track group, so the buttons
  never move between modes. The readout keeps the 10 pt insets, so compare's
  back button no longer sits under Blind.
- **Engaged side buttons** (Shuffle on, Blind on, Repeat not Off): the plain
  glyph lights in `Theme.primaryLitGlyph` with the secondary appearance's
  glow and bloom, the same treatment v2.9.0's engaged secondary buttons
  use, still without a circle. Disabled: 35% opacity.
- **LED meter:** 3 pt cells on a 4 pt pitch, 5 pt tall, across the full
  width (80 cells in a 360 pt window, the canvas's count). The lit run is
  drawn a step below full; the leading cell is brightest (white-hot in
  dark, full ink in light). It has 3 pt of extra hit area above and below.
  Matched to the canvas after the compare info-bar variant: the endcaps
  milestone 2 kept from `DotMatrixProgressBar` are gone, unlit cells are
  the canvas's 9% in dark (were 22%; light's LCD keeps 22%), and in dark
  the lit run glows (2 pt blur at 50%) and the leading cell glows brighter
  (5 pt blur, full strength), as the canvas's `box-shadow`s do. Light is an
  LCD, so it has no glow. The glow is two pre-blurred images clipped and
  stepped with the fill and head, so it adds no per-frame work. The cells
  stay square on the pixel grid rather than the canvas's stretched,
  0.5 pt-rounded ones.
- **Readout title face:** 1 pt dots with 1 pt gaps (13 pt capitals on an
  11 pt advance), the closest whole-point match to the canvas's 16 px Doto,
  sitting just under the 14 pt seven-segment digits. Playlist readout
  content, on whole points: 8 pt above the digits, 14 pt digits, 6 pt
  gap, 5 pt meter, 8 pt below, so the panel is 41 pt (the canvas's 42 pt
  panel would leave 8.5 pt margins); the 13 pt title line sits on the
  digits' bottom edge, its top at 9. Compare: the 13 pt line 8 pt from the top.
- **Divider:** the existing groove tokens (`Theme.transportDividerShadow`
  over `transportDividerHighlight`) drawn as two half-point lines, 1 pt in
  all, as the comparison section already drew it; the 1 pt + 1 pt in §3 is
  the canvas's approximation. Compare's 5 pt shadow under the control bar is
  gone, so the groove is the only edge there.
- **Control-bar heights differ by mode.** Milestone 2: the readouts were
  42 and 30 pt, so the compare bar was 12 pt shorter (119 vs 131 pt with
  artwork). Since the compare info-bar variant (below) compare has no
  readout. Its bar ends 10 pt under the transport row and is 51 pt shorter
  than the playlist's (79 vs 130 pt with artwork, 91 vs 142 under the
  titlebar). Its 32 pt info bar sits below the divider. The transport row
  and everything above it stay put when switching modes.
- **Side buttons light brighter** (after milestone 5;
  [a2-side-button-lamps-spec.md](a2-side-button-lamps-spec.md), §2–4 without
  the lamp). The dark on-glyph is brighter (#F4F2FF, three glow layers) and
  the dark off-glyph one step dimmer (#86868C); light is unchanged.
  Compare's Repeat One now shows `repeat.1`, as the playlist does. The
  spec's lens lamp under each glyph was built and then dropped: the lit
  glyph alone marks the on state. The values live in their own
  `SideButtonAppearance`, because the circle buttons' secondary glow fields
  were also the artwork toggle's. The artwork toggle takes the new lit glyph
  and glow too.
- **Compare is unavailable for single-version items.** They show no
  disclosure chevron and no Compare pill.
- **Long readout titles scroll.** In both readouts, a title wider than its
  space scrolls as a marquee (pause, scroll, repeat) rather than truncating.
  Use the existing `DotMatrixMarqueeText` / `DotMatrixMarqueeDisplay`, which
  only animate lines that actually overflow. The compare readout is narrower,
  so it scrolls more often.
- **The window is resizable in both directions** (§2). Defaults are the §2
  sizes. Minimum width is 260 pt. Minimum height is 519 pt with artwork and
  271 pt without (`TakesWindowPolicy.minimumHeightWithoutArtwork`). It fits
  the compare control bar (79 pt below the cover, 91 pt under the titlebar), its info bar (32),
  the ruler (22 with its border), one whole lane (96) and the bottom bar
  (30), so compare always shows its controls and one lane. Milestone 5
  settled the rule at 286 (a 133 pt control bar with the readout, no title
  bar and a 27 pt ruler); the compare info-bar variant kept the rule,
  which lowered it to 271 without artwork. The playlist's control bar
  is 51 pt taller, leaving room for two list rows and part of a third. Milestones
  1–4 used a provisional 300. Mode switches resize ("The playlist
  remembers its height; compare fits its lanes"); adding and removing
  tracks resizes too ("Window fits added and removed tracks"). The artwork
  toggle changes the height by the cover height less 12 pt, keeping any extra height the
  user added; a window that would run off the bottom of the screen moves up
  only as far as needed.
- **Cover in a wider window:** the square grows with the window width.
  At a wide, short size, it fits above the bars and one compare lane,
  centred over a blurred fill of the same image. The placeholder note
  scales with the cover.
- **Artwork-toggle chip, light appearance:** a pale frosted chip (system
  thin material under a white 50% fill), 0.5 pt white 70% inner hairline,
  black 20% drop shadow. The glyph is `Theme.primaryLitGlyph` with
  `lightSecondary`'s engaged glow. Dark uses the §4 values with
  `darkSecondary`'s glow.
- **Which cover:** in playlist mode, the playing (or current) version's
  artwork, as the readout shows. In compare, the audible version's, so
  Switch Track swaps the cover (milestone 4 review; milestone 1 kept the
  playback version). In Blind Listening Mode compare keeps the item's
  playback version, so the cover can't reveal which version is audible. The
  previous cover stays up until the next has loaded, so a switch never
  flashes the placeholder.
- **Double-click plays, on every row.** It does not open compare, even for
  multi-version items; the Compare pill is the way in.
- **Unavailable version file** (milestone 3, was §12). A version row whose
  file is unavailable shows a yellow warning triangle in the 34 pt check
  column and a dimmed title. An item row shows the triangle over its
  darkened thumbnail when any version is unavailable and dims its title
  when the playback version is unavailable. The triangle replaces the music
  note on a thumbnail without artwork. Hovering the triangle shows the load
  error. Locate File… is available in the context menu.
- **Entering compare never starts an item** (milestone 3, §9). Another
  item's playback stops and compare opens paused; the item already playing
  keeps playing. This applies to the Compare pill, the context menu and the
  Compare keyboard shortcut.
- **Row thumbnails** (milestone 3). Item rows show their playback version's
  embedded artwork, decoded only for rows inside the visible rect, 68 px,
  in memory, from a bounded cache separate from the cover's; a version whose
  cover is decoded is scaled from it. See `AGENTS.md` for the rule.
- **Version rows** (milestone 3). Name: the title tag, else the filename
  without its extension (the readout's rule). The format
  column shows the container alone (FLAC, MP3); sample rate, bit rate and the
  filename are in the row's tooltip. A single click selects the row.
  Double-click plays the version from the beginning. Click the empty circle
  on a hovered row to make it the key version. Rows being dragged stay in
  place, dimmed, until the drop lands.
- **Item rows without an artist tag** show the title alone, vertically
  centred.
- **Compare pill on hover only**, not on the selected row. Keyboard and
  VoiceOver users reach compare through the context menu.
- **Light row values.** Now-playing tint: light primary at 12% with a deep
  primary title (#4F46C8); hover: black 4%; drop target: primary 14% inside
  a 2 pt primary ring; thumbnail tile #DCDCE1 with a #9C9CA3 note; stacked
  edges step toward the background (near #B9B9C0, far #D5D5DA). Dark values
  are the canvas's. All live in `PlaylistRowPalette`.
- **Playlist summary** (milestone 5). The bottom bar's right side shows the
  item count and total duration, `6 tracks · 19:35` (`1 track · 2:07` for one;
  each item counts as one track, "items" until after milestone 5),
  in 11 pt secondary tabular digits. The total adds up each item's playback
  version, the duration its row shows, rounded once at the end; it gains an
  hours field past an hour (`16 tracks · 1:04:00`), as the rows do. Versions
  without a known duration add nothing. An empty playlist shows no summary:
  its empty state already says so. This replaces the header bar's `N items`
  label, removed in milestone 3.
- **Lane sizing** (milestone 4, changed in review). Every lane is a fixed
  96 pt: a 95 pt lane and its 1 pt bottom divider (`CompareLaneLayout`), the
  height five versions shared in a 986 pt window with the artwork shown.
  Lanes never resize with the window or the version count; those that don't
  fit scroll, and fewer leave the well empty below. In the default 760 pt
  window about two and a half lanes show (two and a third with the compare
  readout row, before the info-bar variant; two and a half before milestone 5's
  bottom bar). The first build gave lanes equal shares of the space
  (74 pt for three in the default window, 64 pt minimum), which resized
  every lane, and redrew every waveform, whenever a version was added or
  removed. The ruler is 21 pt (26 before the compare info-bar variant)
  plus its 1 pt bottom border, so the lanes and the playhead line start
  22 pt below the ruler's top, where the grabber's tip sits.
- **Lane waveform** (milestone 4). Centred in the space below the strip with
  5 pt clearance above and below. The active waveform is primary and inactive
  ones `Theme.waveformInactive`, at v2.9.0's 85% and 70% (the first milestone 4
  build drew both at full strength, as the canvas does; restored in review). The tick guides and the 0:00 line run the full
  lane height, behind the strip. The lanes and ruler mask their first point,
  so a guide, notch or 0:00 marker landing exactly on the window's left edge
  (as it does whenever the timeline starts at 0:00) isn't drawn as a stray
  line there; v2.9.0 hid it under the info column's edge. The ruler has no
  fill of its own: it shares the well with the lanes rather than the
  canvas's lighter band.
- **Lane strip** (milestone 4). No fade or background (dropped in review):
  it sits in the empty space above the waveform, its contents centred
  between the divider above the lane and the waveform (26 pt, review). 9 pt leading and 8 pt
  trailing insets, 6 pt gaps. Badge 15 pt, 4 pt radius, 10 pt bold digits, keeping the tunable
  bevel (`IndexBadgeAppearance`). Title: the version-row rule (title tag, else
  filename without extension), 11.5 pt semibold, middle truncation; it
  outranks the format, which truncates first. Format: container, sample rate
  and bit rate (`FLAC · 44.1 kHz`, as the canvas draws it and as the info
  column's metadata line showed). The duration and filename, which the
  column also showed, are in the strip's tooltip. Blind Listening Mode: `Track
  n`, no format, no tooltip; the waveform stays the redaction-bar hatch.
- **Offset field** (milestone 4). `0 ms` in a 17 pt box, 4 pt radius, 10 pt
  tabular digits, sized to its number and growing (or shrinking) as one is
  typed. No stepper: ↑/↓ while
  editing (⇧ for large steps), ⌘J/⌘K nudges, and double-clicking `ms` resets
  to zero. Focused: the primary ring and glow the old field had. Editing
  keeps the global shortcuts off, as every text field does. Hovering the box
  shows an "Offset" label (10 pt secondary) 4 pt to its left; the label
  takes room in the strip, so a long title or format truncates rather than
  running under it (review).
- **Strip interaction** (milestone 4). The strip is its own layer above the
  lanes' seek and loop gestures. Dragging the badge, title or format reorders
  the lane (with the lifted card, now showing badge, title and format) or
  copies the file out to Finder; a plain click makes the lane active. A
  right-click there opens Remove Version, Reveal in Finder (disabled while
  blind) and Reset Offset, acting on that lane; it replaces the info column's
  hover trash button. The strip's empty middle passes clicks through, so
  seeking, loop drags and the playhead band work across the whole lane. The
  strip draws over the playhead line (review); the grabber stays on the
  ruler, above everything.
- **Light lane values** (milestone 4). Active lane: light primary at 10%
  (dark: primary 11%). Ruler border and lane dividers: black 10% (dark 30%,
  the canvas's #18181A on #1F1F21). Offset field: white 85% with a black 16%
  hairline (dark: #141416 at 85% with a #3C3C40 hairline). All in `Theme`.
- **Compare header removed** (milestone 4). The import split button's other
  commands are in the File menu and Remove All is File ▸ Remove All Versions
  (⌘⌫) only. Milestone 5's bottom bar brought back Add Version…, Align and
  zoom; milestone 4's interim "Couldn't Align Tracks" alert is gone.
- **Missing files in compare.** Compare does not open an item while any of
  its versions' files is missing (unchanged by milestone 4), so lanes have no
  missing-file state; the playlist's version rows carry it (milestone 3).
- **Retired column width.** The stored `trackInfoColumnWidth` preference is
  removed on launch with the pre-A2 frame keys, and Reset Window Size no
  longer resets a column.
- **Bottom bar** (milestone 5). 30 pt including its 1 pt top hairline, 10 pt
  insets, 6 pt between controls, standard small controls. Surface: the
  well's scrim over the window material (`Theme.bottomBarSurface`: black 18%
  in dark, black 4% in light), the same as the playlist behind it, as the
  canvas draws it (#222224), and a step darker than the control bar in both
  appearances. Hairline: the lane
  divider's line (`Theme.bottomBarHairline`: black 30% in dark, the canvas's
  #18181A; black 10% in light). Like the control bar, empty bar space drags
  the window. The bar shortens the playlist table's and the lanes' scroll
  areas; lanes keep their 96 pt.
- **+/− control** (milestone 5). An AppKit momentary rounded segmented
  control at small size, 10 pt semibold `plus` / `minus` symbols; each
  segment's tooltip and VoiceOver label name its command (Add Files… /
  Remove Selected; Add Version… / Remove Active Version). + opens ⌘O's
  dialog, whose import destination is captured as usual (new items in the
  playlist, the compared item in compare); − runs Delete's command.
- **`…` pull-down** (milestone 5). A standard pull-down button (ellipsis and
  indicator) holding exactly the Playlist menu's list, shared as one view
  (`playlistOrganizationMenuItems`): Group as Versions,
  Separate Versions, Move Up, Move Down and Clear Playlist, acting
  on the selection with the menu's validation. It is disabled while the
  playlist is empty, when every command in it is.
- **Remove Active Version** (milestone 5, decided in review). Follows the
  lane strip's Remove Version and File ▸ Remove Version: enabled whenever a
  version is active, including an item's last version, whose removal removes
  the item and returns to the playlist; removing down to one version leaves
  a one-lane compare open. In Blind Listening Mode it removes the lane
  marked active and names no file.
- **Align button** (milestone 5). A small bordered button with the
  `arrow.right.and.line.vertical.and.arrow.left` glyph (the canvas's
  converging arrows). During the quick pass the glyph becomes a mini
  indeterminate spinner, during tempo analysis a mini determinate progress
  ring (both native `ProgressView`s), and for the controller's two-second
  outcome flash a green check or red cross with a static glow of the same
  colour. The pre-A2 glow pulsed with `withAnimation`; it no longer animates,
  since continuous motion in Takes is Core Animation's job. It is disabled
  with fewer than two versions and while a run is in flight (⌥⌘A's rule).
  "Couldn't Align Tracks" opens as a popover anchored above it and offers
  Analyze Further; closing it dismisses the offer. In Blind Listening Mode
  the popover lists the unaligned versions as `Track n`, their lane
  positions, rather than their file names, which would reveal the audible
  version by elimination (it is the alignment anchor, never listed).
- **Bottom-bar zoom** (milestone 5). Borderless `minus.magnifyingglass` and
  `plus.magnifyingglass` buttons, secondary colour, that step like ⌘− and ⌘+
  (the canvas draws them as plain icons; buttons keep the pre-A2 control's
  behaviour), around a 96 pt small slider. The slider is the existing log
  mapping of the visible span (`TimelineViewport.sliderValue`, through
  `PlaybackController.zoomSliderValue` / `setZoomSliderValue`): 0 at fit, 1
  at the 0.5 s maximum, so it, the magnifiers, ⌘+/⌘−, Zoom to Selection,
  Zoom to Fit and pinch all move one value. The pre-A2 haptic tick at each
  quarter of the range is kept. All three disable when the timeline is too
  short to zoom.
- **Compare info bar instead of the readout** (after milestone 5; see
  [a2-compare-info-bar-spec.md](a2-compare-info-bar-spec.md), which
  overrides §5.2's compare readout and §9's back button). The compare
  control bar is the transport row alone, ending 10 pt under it; the
  readout, its back button and its scrolling title are gone, and so is the
  compare readout title rule (`TRACK n` when blind). A 32 pt info bar
  sits between the divider and the ruler, on the well with no line to the
  ruler: `N takes` (`1 take`) on the left in 12 pt medium secondary, the
  elapsed time in a 24 pt Glass frame centred in the window, and a
  rectangular Done (22 pt, 5 pt radius, primary fill) on the right. Done
  leaves compare as the back button did (the audible version becomes the
  playback version); Esc and ⌘[ are unchanged. The notches went
  back to v2.9.0's heights (major 19 pt, minor 8, were 11 and 5), and the
  ruler shrank from 26 to 21 pt: the labels moved down so their digits'
  tops are level with the major notches' tops, 2 pt from the ruler's top.
  The playhead grabber now overlaps the labels; that was accepted, and it
  replaces the info-bar spec's §3 rule (labels 1 pt clear of the
  grabber). The window minimum is documented under "The window is resizable".
  The info bar shows
  whether or not the artwork is (the spec's first open question); the take
  count has no tooltip or menu (its second).
- **Window fits added and removed tracks** (after the info-bar variant):
  v2.9.0's resize, in both modes. Adding tracks grows a window too short
  to show every row (playlist: item rows and expanded version rows;
  compare: one lane per version); removing tracks shrinks a window taller
  than the rest need, never below the minimum. A window the user made
  taller than its content needs keeps its height as tracks are added. The
  top edge stays put and growth stops at the bottom of the screen. Mode
  switches, restoring the playlist, expanding or collapsing an item, and
  full screen don't trigger the fit (mode switches have their own rule,
  below). Lanes keep their fixed height; only the
  window changes. In the background, the playlist dims like compare.
- **The playlist remembers its height; compare fits its lanes** (after the
  track fit). Entering compare stores the playlist's window height and
  sizes the window to the item's lanes, growing or shrinking; within
  compare, the track fit applies. Leaving compare restores the playlist's
  height. Both keep the top edge fixed and stay on screen; the width is
  shared. The playlist height is stored without the cover, so toggling the
  artwork in compare carries over. Until a playlist height is stored, the
  playlist keeps the current height. (Briefly, compare remembered its own
  height too; it was dropped for fitting its lanes.)
