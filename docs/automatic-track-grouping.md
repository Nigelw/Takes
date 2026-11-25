# Automatic track grouping

When **Group similar tracks** is on, Takes groups imported files by title.

## How matching works

1. Takes prefers the embedded title tag and falls back to the title in filenames
   such as `Artist - Title.mp3`. Artist and duration do not affect grouping.
2. Comparison ignores capitalization, accents, punctuation, leading filename
   track numbers, and recognized codec, mastering, and mix labels.
3. Takes strips performance markers such as `live`, `demo`, `acoustic`,
   `alternate take`, and `cover`. A trailing parenthetical or bracketed
   description that contains one of these markers is removed in full, as in
   `Title (2019.11.12 Live at the Colosseum)`.
4. Normalized titles match exactly or at 92% edit-distance similarity.
5. The same rules apply to files imported together and to files added in
   later imports.

An empty normalized title cannot match. If more than one existing item qualifies,
Takes creates a new item for the incoming file or group. Imports remain one Undo
operation, and existing playlist items are never merged automatically.
