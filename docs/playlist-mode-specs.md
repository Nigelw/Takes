## compare mode
control bar
- play/pause
- swap tracks
- repeat
- blind mode
- playlist/compare mode toggle (← or in status bar?)

timeline control bar
- align
- quality analysis
- solo/mix mode toggle (compare/combine?). make icons like kaleidoscope "two-up" and "difference" buttons

track info
- index
- name
- metadata
- offset
- gain (button/popover next to offset)

status bar
*don't need to add this if we keep zoom in control bar and there's space for qual analysis button in timeline control area*
- add/remove tracks
- zoom


## play mode
control bar
- previous
- play/pause
- next
- progress bar
- repeat
- shuffle
- playlist/compare mode toggle (← or in status bar?)

track info
- column headers (replaces timeline control bar)
- index + name + info columns

status bar
- add/remove tracks
- \# of songs, total time

## play mode functional notes
- sequential playback, use as a normal music player
- play to the end of each track rather than the entire timeline, then continue to next track
- no longer need to keep all audio loaded & playing
- change global app behavior: persist loaded tracks across launches
- play mode UX change: click to select, double click to play
- row design needs to be rethought
  - no interactive waveform area
  - show metadata instead? or minimal version of waveform?
- no offset field
- readout display needs rethinking to display more info: interactive progress indicator, track name + artist - album
- “Previous" button restarts the current track once you're 3s in
- change external file drop behavior: insert at drop position (or at end if dropped on control bar)
- disable menu items: switch/switch prev track, auto-align, blind mode
- review features: neutral (reviewing)/keep/delete buckets. group tracks and send to trash/apps/services

mode transitions:
- see what we can do to allow unlimited tracks (instead of 32 limit) so there’s one universal list across modes.
  - In compare mode, load 10 tracks at once. if you switch to a range outside of the current 10, center the range on the new selection (selecting a track at beginning/end of the list should still select 10 tracks even if there aren’t enough preceding/subsequent tracks to place the selection in the middle)
- or if not a shared unlimited playlist:
  - compare → play: if play mode list is empty, populate play mode’s list with compare mode’s tracks. if not empty, don’t modify play mode’s list
  - play → compare: populates compare mode’s tracks with selected tracks from play mode. if >32, use standard error handling (load them & show an alert for others)

settings:
- add setting to open tracks in compare/play/last used mode