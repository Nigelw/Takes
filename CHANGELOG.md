# Changelog

## 2.9.0 (2026-07-16)

### New

- Major performance improvements throughout the app
- Files open quicker
  - Waveforms render much faster and the UI remains responsive while loading
- CPU usage is drastically reduced
  - Playback with 1 track has been reduced from 40% → 2.5% (comparable to QuickTime player)
  - Playback with 20 tracks has been reduced from 103% → 8% (less than QuickTime Player at 32%)
  - Idle CPU consumption is now 0%
  - (All measurements taken with an M1 MacBook Pro)
- UI responsiveness is vastly improved
  - Zooming, scrolling, and playhead-following is fluid, even with dozens of files open
  - Dragging to rearrange tracks animates smoothly
  - Playhead glides continuously instead of ticking along

### Improved

- Loops are now gapless, wrapping seamlessly to the beginning of the next loop
- Quickly adjust a track's offset without selecting the input field using new keyboard shortcuts
- Improved waveform interactivity
  - The playhead can be dragged in the waveform area (previously dragging was limited to the grabber in the ruler area)
  - Clicking on a waveform switches playback to that track (previously you had to click in the info column)
- Quick Open from Finder now supports folder selections
- Added haptic feedback to the zoom slider
- Inertial scroll during playback behaves naturally: it settles to a stop before jumping to the playhead, rather than fighting with playhead-follow and causing jerkiness
- Refined the app's visual design, icons, and hit targets throughout

### Fixed

- Mouse cursor reliably changes state when hovering over overlapping UI elements to show which interaction has priority
- Tooltips are only shown when text has been truncated
- Shrunk the hit target of the "Click Here to Compare" button to prevent accidental clicks when there are no tracks loaded
- Blind Listening Mode is disabled when no tracks are loaded

## 2.8.2 (2026-07-06)

### Fixed

- Creating a loop no longer moves the playhead if it's already within the loop range

## 2.8.1 (2026-07-05)

### New

- Resizable track info column. Grab the divider and drag it left/right

### Improved

- Changing the loop range during playback no longer causes audio to stutter

## 2.8 (2026-07-04)

### New

- Import streaming audio from Apple Music, Spotify, and YouTube

### Improved

- Significantly improved drag and drop
  - Improved visual design and UX of track reordering
  - Improved visual indicator for external file drops onto Takes window
  - Support standard Mac conventions: drag track out of the window to copy its file to the Finder or another app, drop on window toolbar or menubar to cancel drag
- Switch tracks with the up/down arrow keys in addition to other keyboard shortcuts
- Added a link to the Takes website in the Help menu

### Fixed

- Many UI copy tweaks

## 2.7 (2026-07-03)

### New

- Auto-Align tracks: a single button lines your tracks up automatically by listening to the audio itself
  - Auto-Align can also handle tracks recorded at slightly different speeds, offering a deeper tempo analysis when the quick pass can't find a match
  - If tracks have tempo drift, you can auto-align anytime at the current playhead
  - Added setting to auto-align by default when opening files

### Improved

- Takes remembers its window position between launches
- Folders can be dropped on the app window
- Clearer error messages when files can't be loaded
- Small wording polish on the empty state

### Fixed

- App window can be moved by dragging anywhere in the control area

## 2.6.1 (2026-07-02)

### Improved

- Double-click the "ms" label in the offset text field to reset it to zero

### Fixed

- Playback now continues when the system audio device changes, such as when putting in AirPods
- The mouse cursor now resets correctly after interacting with a text field

## 2.6 (2026-07-02)

### New

- Blind listening mode: hide track details and shuffle playback order to compare takes without seeing which is which

## 2.5 (2026-07-02)

### New

- Major redesign with a brand new look and feel, every pixel reworked
  - New appearance settings: choose light or dark theme, and pick your preferred time readout display style
  - Redesigned track rows with clearer info at a glance
  - Redesigned timeline ruler and playhead, with an interactive grabber you can drag to scrub
  - Polished buttons and controls with satisfying pressed states and better dark mode contrast
- Control playback with your keyboard's media keys

### Improved

- A cleaner empty state — just drop your files onto the target to get started
- Shift-click the Switch Track button to switch to previous
- New menu commands for timeline zoom and track removal

### Fixed

- Fixed timeline overscroll getting stuck if an input field is active
- Various layout, contrast, and window-sizing refinements

## 2.1 (2026-07-02)

### New

- Loop audio by dragging or shift+clicking to select a range
  - Resize selection by dragging the selection handles
- Repeat modes: Off, Repeat One, and Switch & Repeat (to compare tracks back-to-back by toggling to the next on each loop)

### Fixed

- Starting playback at the end of a track now restarts playback from the beginning

## 2.0 (2026-07-01)

### New

- Timeline zooming
  - Pinch to zoom or use the zoom control
  - Waveform area uses native scroll inertia and bounce behavior
  - View smoothly slides to keep playhead in view while zoomed in

### Improved

- Improved timeline ruler tick marks and labeling, including dynamic scale when zoomed
- Added link to release notes in Help menu

### Fixed

- The playhead position is preserved when opening a new track while paused
- Adjusted default window position

## 2.0a3 (2026-06-19)

### New

- Waveform display: each track now renders real waveforms instead of a placeholder mockup
  - Rendering doesn't block the UI

## 2.0a2 (2026-06-18)

### New

- Renamed to Takes
- New UI
- New icon
- Compare up to 32 tracks
- Drag to reorder tracks
- Signed & notarized by Apple for public distribution, no longer requires bypassing Gatekeeper or building yourself
- Auto-updating via Sparkle

### Improved

- Customized menubar with commands and a full set of keyboard shortcuts like a proper Mac app
- Hidden keyboard shortcuts: use number keys 1–8 to quickly switch to correspondingly numbered track. Hitting 9 switches to the last track.
- Quick Open files from Finder or Apple Music selection
- Improved offset input field behavior
  - Arrow keys nudge value up/down
  - Shift+arrow keys nudge by larger amount
  - Esc key reverts to previous value
  - Left/right arrow keys navigate cursor instead of controlling playback
- Added settings for offset nudging intervals & auto-update behavior
- Improved drag and drop support
  - Drop files and folders on app icon to open
  - Simplified window drop target behavior for quicker interaction (removed ability to drop on individual rows to replace)
- Improved window behavior
  - Smart resizing when adding and removing tracks
  - More compact
  - Single window only

## 1.0.2 (2026-06-18)

### Improved

- This is v1.0.0 compiled, signed and notarized initial release for public distribution. Bumped version in order to release properly.
- No other changes between v1.0.0 and this. (v1.0.1 tag was a project documentation update.)

## 1.0.0 (2026-04-26)

### New

- Initial release of TrackSwitch: load two audio tracks and toggle playback between them
- A couple niceties to make loading tracks quicker than navigating the Open dialog box
  - Drop files onto Track A/B wells to open
  - Support for loading 2 of the currently selected tracks in Apple Music
- Adjust gain
- Adjust offset
