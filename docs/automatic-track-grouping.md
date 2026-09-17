# Automatic track grouping

When **Group similar tracks** is set to **Automatic**, Takes groups imported
files using their descriptive metadata. It does not analyze the audio.

## How matching works

1. Takes prefers the embedded title and artist tags. If they are missing, it
   reads the same information from filenames such as `Artist - Title.mp3`.
2. Comparison ignores capitalization, accents, punctuation, track numbers,
   codec labels, mastering labels, and ordinary mono/stereo mix labels.
3. Small title spelling differences are accepted when the artist matches.
4. Terms that can identify another performance—such as `live`, `demo`,
   `acoustic`, `alternate take`, or `cover`—remain part of the title and
   therefore prevent an unsafe match.
5. Duration is a safeguard, not a reason to match. Ordinary versions may
   differ by at most `max(5 seconds, 5%)`. Explicit radio, single, album, or
   extended edits and recognized mono/stereo mix variants may differ by at
   most `max(2 minutes, 35%)`.
6. The same rules apply whether related files arrive together, in later
   imports, or match an existing playlist item.

If metadata is insufficient, durations conflict, or more than one existing
item is a possible destination, Takes leaves the track separate. Imports remain
one Undo operation, and existing playlist items are never merged automatically.
