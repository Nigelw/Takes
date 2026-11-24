# A2 control bar: lit side buttons with lens lamps

A change to the A2 control bar's side buttons
([a2-redesign-spec.md](a2-redesign-spec.md) §5): Shuffle (playlist), Blind
Listening Mode (compare) and Repeat (both). Since A2 made them plain icons
(`ControlBarSideButtonStyle`), their on state is a change of glyph colour with
a soft glow, which reads as highlighted rather than on. This change makes the
on glyph brighter and adds a small lamp under every side button: unlit when
off, lit when on.

Design reference, on the Design page of the canvas,
https://claude.ai/artifact/ACWY27QaC8aWg8JT47VSDH (read it with the Artifact
tool's read action):

- "A2 · Side-button lamps: lens lamp, dark and light"
  (`A2-SideButtonLight.dc.html`): the top two rows are the chosen design,
  dark and light. The rows below are rejected options.
- The four main A2 artboards (`A2-Playlist`, `A2-PlaylistNoArt`,
  `A2-Compare`, `A2-CompareTitle`) show it in place, dark only.
- "A2 · Shuffle, Blind and Repeat: active-state options"
  (`A2-SideButtonStates.dc.html`): the exploration that led here.

The artboards are HTML approximations; where they disagree with this
document, this document wins.

Nothing else in the control bar changes: the circle transport buttons, the
readout, the layout and the side buttons' positions stay as they are.

## 1. Geometry

- The side slot stays 30 × 40 pt (`ControlBarMetrics.sideSlotSize`) with
  the 20 pt glyph centred in it, so the glyph doesn't move.
- **Lamp:** a 4 pt circle, horizontally centred in the slot, its centre
  36 pt below the slot's top (4 pt below the glyph's bottom edge at 30). It
  stays inside the slot, so the row's height and hit area don't change.
- The lamp is part of the button: clicks on it toggle the button, and the
  pressed and disabled opacities (0.55, 0.35) apply to glyph and lamp
  together.

## 2. Off state

| | Dark | Light |
|---|---|---|
| Glyph | `#86868C` (one step dimmer than today's secondary label) | secondary label at about 42% black (today's) |
| Lamp | dark glass: radial gradient from white 26% at the top (centre 50%, 30%) to white 4% at the edge; 0.5 pt black 60% ring; 0.5 pt white 8% highlight below | recessed grey: radial gradient from white 90% at the top to black 18% at the edge; 0.5 pt black 22% ring; 0.5 pt white 90% highlight below |

The unlit lamp is always visible, so the three side buttons show at a glance
which are on.

## 3. On state

| | Dark | Light |
|---|---|---|
| Glyph colour | `#F4F2FF`, near-white indigo (brighter than today's `#DAD7FF`) | `Theme.primary` light, `#6C63E9` (today's) |
| Glyph glow | three layers: 1.5 pt `#B0AAFF` at 100%, 5 pt primary at 95%, 11 pt primary at 55% | two layers: 2 pt primary at 55%, 6 pt primary at 30% (today's) |
| Lamp | lens: radial gradient (centre 50%, 30%) `#FFFFFF` 0 → `#D6D2FF` 30% → `#8F87F5` 70% → `#6C63E9` 100%; 0.5 pt rim `rgba(40,32,140,0.7)`; halo 3 pt primary 85% and 8 pt primary 45% | lens: radial gradient (centre 50%, 35%) `#D9D5FF` 0 → `#7D75F0` 45% → `#5A51DF` 100%; 0.5 pt rim `rgba(60,50,180,0.6)`; halo 4 pt primary 40% |

Notes:

- The glow radii are CSS blur radii. Match them by eye in the running app
  rather than by number; SwiftUI's `shadow(radius:)` spreads differently.
- Put the values in `TransportAppearance` (the existing
  `activeGlyphGlow*`/`activeGlyphBloom*` fields, plus new lamp fields) so the
  Debug Appearance Tuner can adjust them, and make the new values the
  defaults. Add a `Theme` token for the dark on glyph if
  `primaryLitGlyph`'s dark value changes; the artwork toggle uses
  `primaryLitGlyph` too, and must not change.
- The lamp's gradient and halo are static. Draw them with SwiftUI shapes
  and shadows (or one pre-rendered image per state); no per-frame work, no
  `TimelineView`, no `withAnimation`. The on/off change may use the button's
  existing short ease.

## 4. Repeat glyphs

Repeat's lamp lights for every mode other than Off. Its glyph still names
the mode:

- Playlist: Off and All `repeat`, One `repeat.1` (unchanged).
- Compare: Repeat One changes from `repeat` to `repeat.1`, as the compare
  artboards show, so a lit Repeat says which mode it is in. Switch & Repeat
  keeps its symbol.

## 5. Accessibility

The lamp is decorative (hidden from accessibility). Labels, values and help
tags stay as they are.

## 6. Done when

- `ControlBarSideButtonStyle` draws the lamp and the new glyph states;
  Shuffle, Blind and both Repeats use it as today. No other button changes.
- The canonical `xcodebuild test` passes. Add tests for the lamp geometry
  (4 pt, centred, centre 36 pt from the slot's top, inside the slot) and the
  compare repeat symbol per mode.
- Checked in the running app, dark and light, with each button off and on,
  pressed, and disabled (Blind is disabled when `canToggleBlindListeningMode` is false).
- `AGENTS.md` updated: the control-bar invariant's "Side buttons are plain
  icons" line, and the Test Map.
- `a2-redesign-spec.md` §13 records the change (or links here).

## 7. Decisions

- **The lamp was dropped** after it was built and reviewed in the app. §1,
  the lamp rows of §2–3 and §5 no longer apply; the glyph colours and glows,
  §4's repeat glyphs and the decisions below stand.

- The artwork toggle takes the side buttons' lit glyph
  (`Theme.sideButtonLitGlyph`) and glow too; it has no lamp.
- The side buttons' values are their own `SideButtonAppearance`
  (`TransportAppearance.lightSideButton`/`darkSideButton`) rather than the
  secondary appearance's `activeGlyphGlow*`/`activeGlyphBloom*` fields,
  which hold two layers and stay with the circle buttons.
