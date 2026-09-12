# Automatic track grouping

Status: implemented as opt-in. Synthetic tests pass. The private audio corpus
does not yet contain enough verified labels to establish the accuracy gate for
either automatic mode.

## User behavior

Playlist imports use the **Group similar tracks** preference:

- **Off** creates one playlist item per file.
- **Same Recording** groups alternate encodes, transfers, and gain-adjusted
  copies of the same recording.
- **Same Performance** also accepts evidence that can survive a different mix
  or edit. It is exposed in Debug builds only until a labeled corpus validates
  its false-positive rate. **Off** remains the shipping default until the
  same-recording mode also meets its 95% recall and zero-false-positive gate.

Imports started inside comparison still append to the captured comparison item;
automatic grouping applies only to general playlist imports. The imported files
are committed as one Undo transaction. The resulting playlist items are selected
and expanded. When the batch resolves to one item with at least two versions,
Takes opens that comparison unless the user navigated while analysis was running.

The import overlay reports progress and offers cancellation. Cancellation,
metadata failure, or a stale destination cannot partially commit a batch.
Analysis failure or the five-second deadline is an abstention: affected tracks
remain separate and the summary reports the fallback.

## Similarity contract

`TrackSimilarityAnalyzer` accepts stable source IDs, explicitly requested pairs,
and a deadline. Each pair returns independent `sameRecording` and
`samePerformance` verdicts: match, mismatch, insufficient evidence, or analysis
failure.

The analyzer decodes without using the playback engine or waveform store. It
extracts a 1 kHz energy-novelty representation plus a low-rate mono waveform,
checks multiple regions, estimates a consistent offset and speed ratio, and uses
waveform coherence only as corroboration. Silence, short excerpts, partial
overlap, reordered regions, cancellation, and deadline exhaustion do not produce
positive identity claims.

Feature data is held in a process-lifetime, 64 MiB in-memory cache keyed by the
canonical path, resource identity, size, and modification date. There is no disk
cache. One analyzer actor bounds decode and correlation work to one worker.

## Group construction

`TrackSimilarityClusterer` is deterministic and independent of audio decoding.
Positive incoming edges create candidate components. A confident negative within
a component vetoes the merge; unknown evidence never creates an edge. Existing
playlist items are never merged or reordered.

An incoming component may attach to an existing item only when every incoming
member has a positive witness in that item, no member has a negative relationship
to any version in it, exactly one existing item qualifies, and capacity remains.
Ambiguous or incomplete evidence creates a new item. The 32-version limit is
preserved, with overflow becoming an ordered new item.

Similarity analysis runs against a value snapshot. At commit, canonical duplicate
checks run again and existing-item assignments are accepted only if item/version
membership is unchanged. If membership changed, the same analyzed incoming batch
is safely clustered into new items instead.

## Verification and tuning

`TrackSimilarityAnalyzerTests` covers gain and leading silence, unrelated audio,
shared events without waveform identity, partial overlap, reordered regions,
short/silent input, decode failure, cancellation, and deadlines.
`TrackSimilarityClusteringTests` covers transitive components, mismatch vetoes,
unknown evidence, existing-item ambiguity, heterogeneous groups, capacity, and
stable ordering. `PlaylistCoordinatorTests` covers two-pair grouping, preference
levels, existing-item attachment and comparison entry, timeout fallback,
cancellation, and single-step Undo.

Use `scripts/similarity-benchmark.sh` for corpus diagnostics and see
[auto-grouping-corpus.md](auto-grouping-corpus.md) for current measurements.
A release gate for exposing **Same Performance** requires zero false-positive
merges in the labeled negative set, at least 90% recall on supported positive
pairs, and a representative import completing within the five-second UI deadline
on supported hardware.
