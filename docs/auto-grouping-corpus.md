# Automatic grouping corpus and analyzer validation

Status, 2026-09-11: conservative baseline implemented. The four-file latency
example passes. Corpus accuracy gates remain unmet; Same Performance must stay
Debug-only. Same Recording is the fallback mode specified by the project plan,
but its broader accuracy acceptance is also incomplete.

## Corpus inventory and ground truth

`scripts/similarity-cli/corpus.json` inventories all 115 audio files reachable
through the two Finder aliases in `Private/Audio Samples/Auto-Grouping Tracks`.
The inventory resolves Finder aliases and canonical symlinks and skips hidden
files. Some recordings occur at multiple paths in the supplied directories;
they remain separate inventory entries. Eighty-eight within-directory candidate
pairs are included. Directory membership discovers candidates; it does not label
their relationship.

Three pairs have labels supported by measurements recorded before this analyzer
was built:

| Pair | Same Recording | Same Performance | Independent source |
| --- | --- | --- | --- |
| James Blake, Limit to Your Love | Yes | Yes | `docs/analysis-corpus.md`, 2026-08-27 correction: full-rate waveform coherence 0.985 in three probes; extra duration is trailing silence. Both files contain James Blake's performance. `[Feist Cover]` does not identify a second performer. |
| Elliott Smith, Can't Make a Sound | Yes | Yes | `docs/comparative-quality-analysis.md`, M3: interior aligned residuals at −20 dB or better; the discrepant leading probe contains near-silence. |
| Whiskeytown, Jacksonville Skyline | Yes | Yes | `docs/comparative-quality-analysis.md`, M3: same recorded performance, remastered transfer 0.25–0.5% faster. Same Recording includes remastering and transfer-speed changes under the accepted feature policy. |

The remaining 85 pairs have `null` labels. In particular, the Bob Dylan and
James Taylor pairs, regular/extended edits, Revolver mixes, and major/minor tempo
examples still require source verification or an independent listening/recording
provenance review. Existing filename-based expectations are not promoted to
ground truth. An analyzer result is not its own reference label.

No source-verified negative corpus labels have been established in this pass.
Consequently, a zero false-positive count cannot establish precision. The CLI
reports `accuracyGatesPassed: 0` while labels are incomplete or no verified
negatives exist, and includes positive denominators and unlabeled verdict counts.
Its exit status is nonzero for observed labeled false positives; other unmet
gates remain explicit summary fields rather than aborting diagnostic runs.

## Measured results

Reference hardware: MacBook Pro, Apple M1 Pro, 10 CPU cores, 32 GB RAM. CLI built
with Swift optimization (`-O`), one serial analysis worker, 64 MiB feature cache.
These are analyzer timings and exclude metadata loading, workspace commit,
waveform generation, and runtime activation.

The recorded run is `scripts/similarity-cli/benchmark-results.json`:

- 88 candidate pairs processed, no timeout or decode failure.
- Same Recording: 8 matches, 11 mismatches, 69 insufficient-evidence outcomes.
- Same Performance: 12 matches, 11 mismatches, 65 insufficient-evidence outcomes.
- Mean pair time 0.498 s, 95th percentile 0.976 s, maximum 1.980 s. This sequence
  reuses the bounded feature cache, so these are not independent cold-pair timings.
- Of the three independently labeled positives, Same Recording finds 2/3 and
  misses the speed-shifted Whiskeytown remaster; Same Performance finds 3/3.
  This small, positive-only subset does not demonstrate either accuracy gate.
- The three regular/extended candidates and both major-tempo candidates remain
  separate. These are unresolved diagnostics, not assumed ground-truth scores.

The cold four-file `batch` example uses both James Blake versions and both Bloc
Party versions. A single request with a five-second deadline evaluates all six
pairs in **2.936 s**: two Same Recording matches, four cross-song mismatches, no
timeout. This supplies the expected two independent matching pairs for clustering.
The run starts with an empty analyzer cache; OS file caches were not flushed.

## Algorithm and limits

The actor serializes decode and pair verification. One chunked audio pass builds
a 1 kHz onset-novelty envelope plus box-filtered mono audio. Six disjoint regions
are aligned with the existing TrackAligner correlation primitives. A match needs
five consistent regions, at least 80% directional coverage, and a global timing
fit within 80 ms. Same Recording additionally requires waveform corroboration
in five regions. Four fractional-hop probes reduce codec-delay quantization
error, and waveform verification compensates the fitted global speed ratio.
Same Performance currently requires stronger onset/peak-distinctiveness evidence.
Metadata cannot establish a match.

Cancellation and deadlines are checked per decode chunk and verification region.
The current correlation call itself is synchronous, so the deadline is cooperative
and can overshoot by one region's FFT/scan time. The cache evicts least-recently
used features by byte budget, keys entries by canonical path, resource identity,
size, and modification date, and removes superseded identities. Only the current
pair is retained outside the cache. Unsupported, corrupt, changing, or over-one-hour
files produce analysis failure; fewer than 24 active seconds abstain.

The baseline does not yet implement spectral candidate indexing, an explicit
global tempo-search grid, or edit-aware piecewise correspondence. It cannot
reliably cover the proposed Same Performance scope or all remasters. It also
uses a low-band mono signal for recording corroboration; channel cancellation,
strong EQ, and nonlinear/variable-speed processing can cause misses. Conservative
thresholds must not be loosened to make unverified folder expectations pass.

Before enabling Same Performance outside Debug, complete the independent corpus
labels, add adversarial negative batches and partial-reuse examples, implement
the missing tempo/edit verification, and rerun the 90% recall/zero false-positive
gate. Same Recording's 95% recall gate also needs broader validation and better
speed/EQ robustness. Album-sized and 100-item latency acceptance remains pending;
bounded timeout fallback is implemented but is not a substitute for those checks.

## Reproduction

```bash
bash scripts/similarity-benchmark.sh inventory
bash scripts/similarity-benchmark.sh manifest scripts/similarity-cli/corpus.json
bash scripts/similarity-benchmark.sh batch \
  'Private/Audio Samples/Quality Comparison Samples/James Blake/01_Limit_to_Your_Love.m4a' \
  'Private/Audio Samples/Quality Comparison Samples/James Blake/06 Limit to Your Love [Feist Cover].mp3' \
  'Private/Audio Samples/Quality Comparison Samples/Bloc Party/01 Like Eating Glass.m4a' \
  'Private/Audio Samples/Quality Comparison Samples/Bloc Party/01 Like Eating Glass.mp3'
```

Core Audio returned `CheckClientFormatSet` errors when decoding compressed files
inside the execution sandbox. The same local decoder succeeds with approved
Core Audio access outside that sandbox. No corpus audio was altered or uploaded.

`TrackSimilarityAnalyzerTests` covers pair-key ordering, gain/offset matching,
unrelated signals, performance-only evidence, partial reuse, reordered regions,
short/silent input, cancellation, deadline/failure distinction, decoding, and file
identity invalidation. All 11 tests passed after the final analyzer changes
(2026-09-11, focused `xcodebuild test`, exit 0). Existing unrelated Swift actor
isolation warnings in `SessionTests.swift` remain. Run the suite through Xcode,
never `swift test`:

```bash
xcodebuild -project Takes.xcodeproj -scheme Takes -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/takes-similarity-test-derived-data \
  CODE_SIGNING_ALLOWED=NO -only-testing:TakesTests/TrackSimilarityAnalyzerTests test
```
