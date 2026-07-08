## analysis mode
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


## playlist mode
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
- # songs, total time

## playlist mode functional notes
- sequential playback, use as a normal music player
- play to the end of each track rather than the entire timeline, then continue to next track
- no longer need to keep all audio loaded & playing
- change global app behavior: persist loaded tracks across launches
- UX change: click to select, double click to play
- rows are minimized and waveforms replaced by metadata columns
- no offset field
- readout gains info: timeline, track name + artist - album (track info should only scroll when it’s key window)
- change external file drop behavior: insert at drop position (or at end if dropped on transport bar)
- disable menu items: switch/switch prev track, auto-align, blind mode

mode transitions:
- compare → play: if play mode list is empty, populate play mode’s list with compare mode’s tracks. if not empty, don’t modify play mode’s list
- play → compare: populates compare mode’s tracks with selected tracks from play mode. if >32, use standard error handling (load them & show an alert for others)