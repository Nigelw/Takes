# Culling: rejecting tracks and versions

Status: draft. Playlist mode first; compare follows in the same feature.

Photo apps let you step through a shoot and flag the frames you don't want.
Takes gets the same pass for audio: flag a track or a version as rejected,
and the app stops offering it to you without deleting it. Rejection is
reversible and persisted; it never removes files or versions.

The feature also retires the explicit key version. An item's key version
becomes the first version in its list that isn't rejected.

Visual treatment is not settled here. The explorations are in the
"Culling · Visual explorations" canvas (§9); pick from it and record the
decision in §9.

## 1. Terms

- **Track**: a playlist item (`PlaylistItem`), one row at the top level.
- **Version**: one file inside a track (`PlaylistVersion`), a child row in
  the playlist and a lane in compare.
- **Rejected**: a flag on a track or on a version. The two flags are
  independent: rejecting a track doesn't reject its versions, rejecting
  every version doesn't reject the track, and clearing one never clears the
  other.
- **Key version**: the version that represents a track (its row's title,
  thumbnail, duration and metadata) and that plays when the track is
  played. Derived, never stored (§3).
- **Explicit play**: a command that names one row or lane: double-click,
  Return/Enter on a selected row, clicking a lane, a compare number hotkey.
- **Sequential navigation**: a command that picks the next or previous one
  for you: Next/Previous Track, natural advancement at the end of a track,
  Shuffle, Repeat All wrapping, media keys, the cover-hover Previous/Next,
  and in compare Switch Track (X / ⇧X, the control-bar button) and Switch &
  Repeat.

Rejected tracks and versions are skipped by sequential navigation and
always available to explicit play.

## 2. Model

- `PlaylistItem.isRejected: Bool` and `PlaylistVersion.isRejected: Bool`,
  both default `false`.
- `PlaylistItem.selectedVersionID` is removed. In its place, a computed
  `PlaylistItem.keyVersion`:
  1. the first version in `versions` order whose `isRejected` is false;
  2. if every version is rejected, the first version.

  Availability does not enter into it. A key version whose file is missing
  stays the key version, and the track behaves as an unavailable track does
  today (skipped by sequential navigation, warning on the row). A key that
  moved when a drive was unplugged would change the row's title and
  artwork under the user.
- Rejection is part of the workspace value, saved by stable ID like gain
  and offset. Organization operations carry it with the version or item:
  moving a version to another track keeps its flag; Group as Versions keeps
  each version's flag and the destination track's flag (the absorbed
  tracks' flags are dropped with the tracks); Separate Versions gives each
  new track `isRejected = false` and keeps each version's flag.
- Comparison capture (`PlaylistPlaybackBoundary.capture`) no longer writes a
  key version. Leaving compare still keeps the audible version playing
  (§5.5), but as the listening state, not as a stored choice.

## 3. Key version (playlist)

- The key version is the first non-rejected version. To change it, reorder
  the versions (drag, Move Up/Down) or reject the versions above it.
- The circle/checkmark UI on version rows is removed: the
  `checkmark.circle.fill` key mark, the hover "Set as Key Version" circle,
  and the context menu's Set as Key Version. The 34 pt mark column under the
  thumbnail stays; it holds the missing-file warning, the rejection mark
  and the now-playing speaker (§9.1).
- Rejecting or un-rejecting a version, or reordering versions, can change
  the key version. The item row updates its title, thumbnail, duration and
  metadata to match, without a table reload (the existing cell-update path).
- Playing the track (item-row double-click, Return, sequential navigation)
  plays its key version. A track that is already the current track keeps
  its current version on resume.
- A key-version change does not interrupt playback. If the current version
  stops being the key, it keeps playing; the next time the track is reached
  by sequential navigation or played from its item row, the new key plays.
- The playlist summary total sums each track's key-version duration, as it
  sums the stored key version today.

## 4. Playlist mode

### 4.1 Commands

- **Reject** / **Clear Rejection**: one toggle command. Its title reads
  Reject unless every target is already rejected, then Clear Rejection.
  Applying Reject to a mixed selection rejects all of it.
- Targets follow `PlaylistCommandContext.rows`: the selection when the menu
  opens on a selected row, the clicked row alone otherwise. A selected item
  row targets the track only, not its versions (unlike Move Up/Down, where a
  selected track covers its child rows). Selected version rows target those
  versions.
- Where it appears: the Playlist menu, the row context menu, and the bottom
  bar's `…` pull-down (built by `playlistOrganizationMenuItems`, so all three
  stay in step). Enablement comes from `PlaylistOrganizationAvailability`:
  enabled when there is at least one target.
- Shortcut: see §8, question 1.
- Undo: each Reject / Clear Rejection is one undoable organization edit
  ("Undo Reject", "Undo Clear Rejection"), rebased by stable ID like the
  other organization edits.
- Rejecting never changes the selection, and never moves rows.

### 4.2 Playback

- Sequential navigation skips rejected tracks the way it skips unavailable
  files today (`PlaylistCoordinator.advancePlaylist`): a rejected track is
  passed over and is not added to listening history. This covers Next,
  Previous (history and list order), natural advancement, Repeat All
  wrapping, Shuffle, the media keys and the cover-hover Previous/Next.
- Next past the last track returns to the first track that is neither
  rejected nor unavailable, paused. If there is none, Next does nothing.
- Natural advancement with every remaining track rejected ends playback, as
  it does at the end of the list today.
- Repeat One repeats the current track even if it is rejected: the user
  chose to play it.
- Explicit play ignores the flag. Double-click or Return on a rejected
  track plays its key version; on a version row it plays that version from
  the beginning, rejected or not. Sequential navigation then continues from
  that track to the next non-rejected one.
- Rejecting the current track doesn't stop it. It plays to its end and
  advancement moves on; Previous within the restart threshold (3 s) still
  restarts it.
- Space with a current track resumes it whether or not it is rejected. With
  no current track, Play starts the first non-rejected, available track.
- Rejecting a version changes no playback behaviour of its own: playlist
  mode never plays versions one after another. Its only effects are the
  visual treatment and, through the key-version rule, which version the
  track plays.

### 4.3 Display

Both row types get a rejected treatment, specified in §9.1. Rules that
hold across it:

- Rejected and missing dim to the same level. The × marks a rejection
  and the warning triangle a missing file; a row that is both shows both.
- It must survive selection (emphasized background) and now playing. A
  rejected track can be now playing (explicit play).
- A rejected track whose versions are not rejected shows the track
  treatment on the item row only; its version rows show their own state.
- The item row's thumbnail, title and metadata are the key version's. A
  track whose every version is rejected (key falls back to the first
  version) shows no extra state on the item row unless the track itself is
  rejected; the versions carry it.
- VoiceOver: rejected rows add "Rejected" to the row's accessibility
  value. The command is reachable from the context menu, as today's
  organization commands are.

### 4.4 Cover and readout

- The cover and the readout title follow the current version, as now.
- `CoverVersionRule`'s blind fallback (the item's playback version) becomes
  the key version.

## 5. Compare mode

### 5.1 What a rejection is in compare

A lane is a version, so rejecting in compare sets the same
`PlaylistVersion.isRejected` flag the playlist's version rows show. A lane
rejected in compare shows as rejected in the playlist after leaving, and
vice versa. Rejecting the track (item) is a playlist command; compare does
not offer it.

### 5.2 Commands

- **Reject** / **Clear Rejection** acts on the active version. Available
  from the Playlist menu's command (the same menu item; its target in
  compare is the active lane), its shortcut, and the lane strip's context
  menu, where it targets the right-clicked lane.
- Rejecting the active lane doesn't switch away from it; it stays active
  and audible until the user switches.
- Undo as in the playlist.

### 5.3 Switching

- Switch Track (X / ⇧X and the control-bar button), Switch & Repeat, and the
  cover-hover Previous/Next skip rejected lanes in the displayed order
  (Blind Listening's shuffled order when it is on). They wrap as today.
- From a rejected active lane, Switch Track goes to the next non-rejected
  lane in that direction.
- `ComparisonSession.canSwitchPlayback` becomes: at least one non-rejected
  track other than the active one. When it is false, the Switch Track
  button and X / ⇧X are disabled and Switch & Repeat behaves like Repeat
  One, as it does with one track today.
- Explicit selection ignores the flag: clicking a lane, and the number
  hotkeys (`selectTrackForHotkey`), which name a lane by position.
- Missing lanes are unchanged: they stay in the switch order and are silent
  while active. A lane can be both missing and rejected.

### 5.4 Display

- Each lane gets a rejected treatment (§9.1). It must work on the active
  lane (primary tint, primary waveform, filled badge) and not interfere
  with the strip's controls or the playhead.
- Missing lanes change too: they draw the same hatching as rejected lanes
  in place of today's dashed warning band
  (`WaveformLaneView.missingExtent`), across the whole lane as on a
  rejected lane, and keep `File Not Found` in the strip. A missing lane and a rejected missing
  lane look the same apart from the strip's × badge.
- Blind Listening Mode shows the treatment too. It reveals only that the
  user rejected this lane, never which file it is, and rejected lanes are
  out of the switching set anyway, which is how a blind cull narrows
  the candidates.
- Keep the lane isolation invariant: the flag is a `TrackRowView` /
  `LaneStripView` input that changes only on a rejection edit, never
  per scroll or zoom.

### 5.5 Entering and leaving

- Entering compare starts on the playing version if this item is playing
  (unchanged), otherwise on the key version.
- Leaving compare (Done, Esc, ⌘[) keeps the audible version as the current
  version of the playlist's current track, at the translated file time.
  It no longer becomes the stored key version. The key version is still
  the first non-rejected version, so the item row may show a different
  version from the one playing; the readout and cover show the one playing.

## 6. Persistence and migration

- Snapshot schema 1 → 2. Version 2 adds `isRejected` to items and versions
  and drops `selectedVersionID`.
- Decoding a version-1 snapshot: every flag is false, and each item's
  stored `selectedVersionID` version, if it exists and isn't already first,
  moves to the front of `versions`. The track keeps playing the version the
  user chose. Write version 2 on the next save.
- Both flags decode with `decodeIfPresent` and a `false` default.
- `PlaylistWorkspaceError.selectedVersionNotFound` and its validation go
  away.

## 7. Code touch points

- `PlaylistWorkspace.swift`: the two flags, `keyVersion`, removal of
  `selectedVersionID`/`selectedVersion`, validation, organization operations
  carrying the flags, the reject operation.
- `PlaylistWorkspaceStore.swift`: schema 2 and the migration.
- `PlaylistCoordinator.swift`: reject/clear with Undo; `advancePlaylist`
  skipping rejected tracks; `selectedVersion(for:)` → key version; removal
  of `selectPlaybackVersion` (a key change never replaces the runtime, so
  nothing replaces it); the Undo rebase that preserved
  `selectedVersionID`.
- `PlaylistPlaybackBoundary.swift`: session start on the key version;
  `capture` stops writing the key.
- `PlaybackController.swift` / `Models.swift`: rejected state on
  `SessionTrack` or `LoadedTrack`, `canSwitchPlayback`, `selectNextTrack` /
  `selectPreviousTrack` skipping, Switch & Repeat's `canSwitch`.
- `PlaylistOutlineView.swift`: remove the key mark, hover circle and menu
  item; rejected row and version styling; context menu item.
- `PlaylistView.swift`: Playlist menu item, `PlaylistOrganizationAvailability`,
  `playlistOrganizationMenuItems`.
- `ContentView.swift`: lane and strip treatment, strip context menu item.
- `Theme.swift`: rejected colors in `PlaylistRowPalette` and the lane theme.
- `AGENTS.md`: the key-version, double-click, compare-exit and switching
  invariants, and the Test Map.

Tests:

- `PlaylistWorkspaceTests`: key-version derivation (first non-rejected, all
  rejected falls back, missing key stays key), flags through move, group
  and separate.
- `PlaylistWorkspaceStoreTests`: schema-1 migration moves the selected
  version to the front; round trip of the flags.
- `PlaylistCoordinatorTests`: Next/Previous/natural advance/Shuffle/Repeat
  All skip rejected tracks and keep them out of history; explicit play of a
  rejected track; Next-past-end with rejected tracks; rejecting the current
  track keeps it playing; leaving compare keeps the audible version current
  without changing the key; Undo of reject.
- `SessionTests` (or a compare test): switching skips rejected lanes in
  normal and blind order, `canSwitchPlayback`, Switch & Repeat with only
  rejected others, number hotkeys select rejected lanes.

## 8. Open questions

1. **Shortcut.** Photo apps use X for reject; Takes uses X for Switch Track
   in compare. Recommendation: plain `R` in both modes, handled by the key
   monitor like X (so the outline's type-select must not take it), shown in
   the menu as the item's key equivalent. Alternatives: ⌥⌘R, `\`.
2. **Summary.** Should the playlist bottom bar's `N tracks · m:ss` exclude
   rejected tracks, or append `· 2 rejected`? Recommendation: keep counting
   every track and append the rejected count only when it's non-zero.
3. **A "Move to Top" command** for versions, so making a version key is one
   command instead of a drag or repeated Move Up. Not required for the
   first cut.
4. **Hide Rejected** as a view option. Photo apps offer it; it interacts
   with selection, drag and drop and the fitting heights, so it's out of
   scope here.
5. **Accept** (pick) flags. The key-version rule is written so a future
   "first accepted, else first non-rejected" rule can replace it without
   another migration.

## 9. Visual treatment

Explorations for the playlist item row, the version row and the compare
lane, in light and dark, with the selection, now-playing, hover, active and
missing combinations:
"Culling · Visual explorations",
https://claude.ai/artifact/LQ8SX9jutieHuZkAdLUZkR (a Design canvas with
three artboards: rejected tracks, rejected versions, rejected lanes; each
has a dark/light Theme tweak). Like the A2 artboards it is an HTML
approximation: where it disagrees with this document, this document wins.

Options on the canvas:

- Tracks: A Faded, B Struck, C Badge (grey thumbnail with a × badge),
  D Label (a Rejected tag).
- Versions: A Faded, B Struck, C Mark (a × in the freed mark column, with
  a hover × where the key-version circle was), D Label, E Mark plus a dot
  on the derived key version.
- Lanes: A Faded, B Hatched, C Flattened (× badge, grey waveform at a third
  of its height), D Label.

The canvas's Final page holds one artboard, "Culling · Final designs",
with the decided playlist and compare states in dark and light; it is the
design reference for §9.1. Every exploration, including the options
above, the "Indicators" icon pairs and rounds 2–4, is on its Archive page.

### 9.1 Decisions

- **Indicator.** A filled circle with a knocked-out × (Indicators, option
  2). Only rejection is designed for now; a picked state is out of scope.
- **Playlist colour.** Grey (Round 2 · Playlist, grey columns), not red.
- **Track rows.** Option C: the thumbnail goes greyscale at 45% and carries
  the × badge (14 pt, a 2 pt ring in the row's background) at its
  bottom-right corner, inset so the badge and its ring stay inside the
  46 pt row. Title and metadata use the dimmed colours.
- **Version rows.** Option C: the × in the 34 pt mark column, dimmed title,
  format and duration. No hover affordance; rejecting happens through the
  commands in §4.1, never a control on the row.
- **Missing files** dim exactly as much as rejected rows. The warning
  triangle is the only thing that tells them apart. A version that is both
  shows the triangle and the × side by side in the mark column.
- **Selected rejected rows** keep the selection colours with their text at
  65% opacity.
- **Now playing** (changes the current design):
  - No row background. `PlaylistRowView` stops drawing the now-playing
    tint; the speaker over the artwork, the title, the metadata and the
    duration take the tint instead (`PlaylistRowPalette`).
  - A rejected track that is playing looks like any playing track, plus
    the badge; the tint replaces the rejected dimming.
  - **Expanded tracks split the state.** The item row keeps its tinted
    text; the speaker moves from its artwork to the playing version's mark
    column, and that version's title, format and duration take the tint. A
    playing rejected version shows the speaker and the × together.
    Collapsing the track moves the speaker back to the artwork.
- **Compare lanes.** The strip from option C (an × badge in place of the
  index, a dimmed title) over the hatching from option B, in grey to match
  the playlist: the playlist's grey badge with the knocked-out ×, the
  dimmed title and format colours, neutral hatching, and the inactive
  waveform colour (Round 3 · Compare, grey; Round 2 · Compare is the
  same layout in red). Missing lanes take the same hatching and dimmed
  strip instead of the dashed band (§5.4); the active tint stays on an
  active rejected lane.

### 9.2 Deferred

- **Now-playing emphasis** (Round 3), deferred. Ship the existing speaker
  with the tinted text (§9.1). The explored additions, to revisit later: A
  equalizer bars in place of the speaker, B an accent ring around the
  artwork, C a progress line under the row's text. Whichever is chosen
  moves to the version row under the split rule; for C, decide whether
  the line sits under the item row or the version row.
