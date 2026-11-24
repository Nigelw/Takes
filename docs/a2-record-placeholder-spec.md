# A2 artwork placeholder: the record

A change to what Takes shows when a version has no embedded artwork. Today
both places draw SF Symbols' `music.note` on a flat grey tile:

- the cover (`ArtworkCoverView`, `Theme.artworkPlaceholderFill` and
  `Theme.artworkPlaceholderGlyph`);
- the playlist row's 34 pt thumbnail (`PlaylistThumbnailView`'s
  `noteGlyph` on `PlaylistRowPalette.thumbnailFill`/`thumbnailGlyph`).

This change replaces both with a detailed black record that has an indigo
label: fully printed on the cover, simplified on the thumbnail. It is the
same for every track.

Design reference, on the Design page of the canvas,
https://claude.ai/artifact/ACWY27QaC8aWg8JT47VSDH (read it with the Artifact
tool's read action):

- "A2 · Record placeholder, round 3: Pressing"
  (`A2-RecordPressing.dc.html`): the chosen design. The middle column is the
  cover and the playlist rows in dark and light, with the thumbnail at 2×;
  the right column is the label at 2.5×.
- "A2 · Record placeholder, round 2" (`A2-RecordPlaceholder.dc.html`) and
  "A2 · Artwork placeholders: 5 explorations" (`A2-Placeholders.dc.html`):
  the exploration that led here.

The artboards are HTML approximations; the numbers below come from the
script that generated them. Where an artboard and this document disagree,
this document wins. One deliberate difference: the artboard's thumbnail
reuses the cover's large cast shadow, clipped by the tile; §4 gives it a
small shadow instead.

Sizes are points. Colours are sRGB. Angles start at 12 o'clock and run
clockwise (CSS `conic-gradient` convention); convert when drawing with Core
Graphics, whose angles start at 3 o'clock and run counter-clockwise in a
flipped context.

## 1. Where it shows

- **Cover:** whenever `ArtworkCoverView` has no image. Since 081e43d the
  cover's square is `min(width, height)` of the cover area, so it can be
  smaller or larger than 360 pt; the cover itself is as wide as the window.
  The record is centred in that square and scales with it (§3), and the
  ground fills the whole cover.
- **Thumbnail:** whenever `PlaylistThumbnailView` has no image and its
  status is not `.warning`. The warning state keeps today's behaviour: the
  plain tile, scrim and warning triangle, with no record. The stacked-card
  edges of a multi-version item are unchanged.
- The accessibility label stays "No Artwork".

Nothing else changes: artwork loading, the cover's crop-or-fit rule, the
titlebar shade (which only shows over loaded artwork), the thumbnail's
size, radius and status overlays.

## 2. The record is the same in both appearances

The record itself (disc, grooves, sheen, rim and label) is identical in
light and dark. Only the ground behind it and its shadows change (§3, §6).

## 3. Cover

Every value in this section is given for a 360 pt square. For a square of
side s, multiply every length (diameters, radii, ring widths, shadow
offsets and blurs, the groove step) by s / 360; colours, opacities, angles
and the label's 100-unit art don't change. In practice: draw the record at
the reference size and scale the image (§5).

### 3.1 Ground

A radial gradient centred at (50%, 38%) of the square, reaching the
farthest corner:

| | 0% | 62% | 100% |
|---|---|---|---|
| Dark | `#34343A` | `#1D1D20` | `#141416` |
| Light | `#FBFBFD` | `#E6E6EB` | `#D4D4DB` |

The gradient is sized to the square (its centre and radius move with it).
Where the cover is wider than the square, extend the 100% colour to the
cover's edges.

A **floor shadow** under the record: an ellipse spanning 18%–82% of the
square's width, 8% of its height, its bottom 7% above the square's bottom;
radial from black at 50% (dark) or 22% (light) to clear, blurred 4 pt.

### 3.2 Disc

Diameter **D = 288** at 360 (80% of the square's side), centred in the
square; radius r = 144.
Layers, bottom to top:

1. **Cast shadow.** Dark: 0, 22 offset, 44 blur, black 60%; plus 0, 4, 10,
   black 45%. Light: 0, 22, 40, black 30%; plus 0, 4, 10, black 22%.
2. **Base:** radial from the centre: `#121215` at 0, `#0A0A0C` at 70%,
   `#0D0D10` at 100%.
3. **Grooves:** concentric rings from 0.44 r to 0.965 r, every 1.7 pt,
   0.45 pt white strokes, each at a fixed pseudo-random opacity between
   2% and 6% (5% × a uniform 0.4–1.2, seeded so it never changes).
4. **Smooth zones** (vinyl without grooves), `#0C0C0E`:
   - the lead-in: a ring centred on 0.972 r, 8.06 pt wide (D × 0.028), so
     its outer edge stops at the disc's edge (the design's first version let
     it overrun and clip the disc flat at four points);
   - the run-out: a filled circle of 0.43 r.
5. **Track bands** at 0.55, 0.64, 0.75 and 0.87 r: a 2.0 pt black 95% ring
   (D × 0.007), with a 0.6 pt white 7% ring 1.3 pt (D × 0.0045) outside
   it.
6. **Sheen:** a conic gradient of white, two highlights opposite each
   other. Stops (angle, white opacity): 0° 0, 18° 3.5%, 40° 24%, 63° 3.5%,
   95° 0, 180° 0, 198° 3%, 220° 17%, 243° 3%, 275° 0, 360° 0. Masked by
   a radial falloff, 25% at 30% of r rising to 100% at 70% of r, so the
   sheen fades toward the label.
7. **Iridescence**, screen blend, same falloff mask: a conic with
   transparent at 28°, `rgba(255,110,200,.07)` 36°, `rgba(110,210,255,.08)`
   44°, `rgba(160,255,190,.05)` 51°, transparent 58°; transparent 208°,
   `rgba(110,210,255,.05)` 216°, `rgba(190,140,255,.07)` 224°, transparent
   232°.
8. **Light fall:** a linear gradient at 160° (top left to bottom right):
   white 7% → clear at 45% → black 28%.
9. **Rim:** a 2.2 pt ring at the disc's edge, filled with a vertical
   gradient: white 42% at the top, 6% at the middle, 18% at the bottom.
10. **Label** (§3.3).
11. **Spindle hole:** radius 7.5 (D × 0.026). Radial at (50%, 60%) from
    `#26262A` to `#050506`; inner shadow 0, 1, 1.5 black 90%; a 0.5 pt
    white 25% highlight on its lower lip.

### 3.3 Label

Diameter **L = 100.8** (0.35 D), centred. Art below is in a 100-unit box
scaled to L (1 unit ≈ 1 pt).

**Paper**, bottom to top:

1. Base: radial at (50%, 30%): `#8D86FA` 0, `#6C63E9` 52%, `#4C44C6` 100%.
2. Grain: fractal noise at 1.1 cycles/unit, 3 octaves, mapped once to white
   specks (22% opacity) and once, with a different seed, to dark specks
   (26%). Fine and even; never blotchy.
3. Fibre: noise stretched 0.04 × 0.9, white, 18% opacity, rotated −24°.
4. Vignette: clear to 72% of the radius, black 20% at the edge.
5. A 0.6-unit white 16% ring at radius 47.6 (the label's lip).
6. The pressed ring round the spindle: a circle of radius 12.5 filled white
   5%, with a 0.5-unit black 14% outline.
7. Edge: a 1.2 pt black 60% outline outside the label; an inner top
   highlight (0, 0.8, 1.2 blur, white 30%) and an inner bottom shade
   (0, −3, 6 blur, black 18%).
8. The disc's sheen (§3.2 step 6) again, at 28% opacity, screen blend.
9. Gloss on top: linear from the top left, white 14% → clear at 45%.

Pre-rendering the noise (2–3) into a small tiled image is fine; it must look
like the 2.5× close-up.

**Printing**, all white (`#FFFFFF`) at the opacity given. Text is SF Pro
except the script.

| Element | Position | Type | Opacity |
|---|---|---|---|
| Outer rules | circles r 44 (0.45 stroke) and r 43 (0.25) | — | 50%, 25% |
| RAREBIT RECORDS | on the top arc, baseline radius 37, centred on 12 o'clock, letters standing outward | 5.2, Bold, tracking 1.6 | 88% |
| Takes | centred, baseline y 32 | Snell Roundhand Italic 12.5 | 94% |
| SIDE | centred on x 25, baseline y 48 | 3.2, Bold, tracking 1 | 62% |
| A | centred on x 25, baseline y 57.5 | 9, Bold | 90% |
| 33⅓ | centred on x 75, baseline y 54.5 | 6.6, Semibold, tracking −0.1 | 90% |
| RPM | centred on x 75, baseline y 59.5 | 3.2, Bold, tracking 1 | 62% |
| STEREO · RB-001 | on the bottom arc, baseline radius 39.5, centred on 6 o'clock, reading left to right with letters upright (standing inward); two spaces each side of the dot | 3.6, Semibold, tracking 1.3 | 70% |

Each string appears once. "Rarebit Records", "Side A", "33⅓ RPM", "Stereo"
and the catalogue number "RB-001" are fictional label furniture, not
information about the track; don't localize them.

## 4. Thumbnail (34 pt tile)

The tile keeps its 4 pt radius and clipping.

- **Ground:** §3.1's gradient at the tile's size, no floor shadow.
- **Disc:** diameter 29.9 (88% of 34), centred; r = 14.96.
  1. Cast shadow: 0, 1, 2 blur, black 50% (dark) or 25% (light).
  2. Base as §3.2.
  3. No grooves and no smooth zones.
  4. Two bands: 0.5 pt white 7% rings at 0.62 and 0.8 r.
  5. Sheen as §3.2 step 6 with the same falloff; no iridescence.
  6. Light fall as §3.2 step 8.
  7. Rim: 1.2 pt, gradient as §3.2 step 9.
  8. Label: diameter 12 (0.4 D), radial at (50%, 32%) `#9D96FF` 0, `#6C63E9`
     48%, `#3F37B5` 100%; 0.5 pt black 55% outline; inner top highlight
     white 35%; sheen at 35%, screen. No printing, grain or gloss.
  9. Spindle hole: radius 1.6, as §3.2 step 11 without the lip highlight.

## 5. Drawing

- The placeholder is static. Draw it into an image and reuse it: one
  cover record and one thumbnail per appearance and backing scale, held in
  memory (in `PlaylistArtworkStore` or beside it). No disk cache, no
  per-frame work, no `TimelineView`, no animation.
- The cover's square changes size with the window, so don't redraw the
  record per size. Render the record (disc and label, without the ground)
  at a reference side of 360 pt, or at the next 120 pt step above the
  current side when the square is larger than 360, and show it resizable
  with high-quality interpolation at the square's size. Re-render for a
  larger step only after a live resize ends, never during one; scaling the
  existing image down is always fine. The ground is a plain gradient and
  can be drawn live (a SwiftUI `RadialGradient` sized to the square).
- Every playlist row without artwork shares the one thumbnail image; draw it
  through the tile's existing `contentsImage` path (the image shown when
  artwork loads), not as a separate view per row.
- Re-render on appearance change (the effective appearance of the window)
  and backing-scale change.
- Core Graphics or SwiftUI `ImageRenderer` are both fine. The deployment
  target is macOS 14, so `CGContext.drawConicGradient` is available for the
  sheen. Lay the arc text glyph by glyph with Core Text (SwiftUI has no text
  on a path).
- Put the placeholder's geometry in one place (for example
  `RecordPlaceholderMetrics`: D, L, hole radius, band radii, groove range
  and step, rim width, the thumbnail's values) so tests can check it.
- Remove `Theme.artworkPlaceholderGlyph`, `PlaylistRowPalette.thumbnailGlyph`
  and the `noteGlyph` view once nothing uses them. Keep
  `PlaylistRowPalette.thumbnailFill`: the warning state and the stacked-card
  edges still use the plain tile.

## 6. Light appearance

The canvas draws light for both sizes; the values are in §3.1 and the cast
shadows in §3.2 and §4. The record does not lighten.

## 7. Done when

- The cover and the thumbnail draw the record when there is no artwork, in
  both appearances; loaded artwork, the warning state, the stacked edges and
  the now-playing overlay look as they do today.
- The canonical `xcodebuild test` passes. Add tests for the geometry in
  `RecordPlaceholderMetrics` (cover disc 288 and label 100.8 centred in
  the 360 square, and scaled with the square's side; the lead-in ring's
  outer edge inside the disc; thumbnail
  disc 29.9 and label 12 inside the 34 tile) and for the thumbnail
  rule (record when there is no image and no warning; plain tile with a
  warning).
- Live-resizing the window with the cover showing redraws nothing but the
  scaled image and the gradient; the record stays centred in the square at
  every width, below and above 360 pt.
- Checked in the running app against the round 3 artboard and its 2.5×
  close-up, dark and light, on a Retina display: the disc is round (no flat
  edges), the arc text is centred and legible, and the paper reads as fine
  grain.
- Scrolling a long playlist of tracks without artwork stays smooth: rows
  reuse the one image.
- `AGENTS.md` updated: `CoverArtwork.swift`'s ownership line, the artwork
  invariant (the placeholder is drawn once per size and appearance, in
  memory), the thumbnail sentence that mentions the placeholder note, and
  the Test Map.
- `a2-redesign-spec.md` §13 records the change (or links here).
