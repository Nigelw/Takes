# Experimental Audio Analysis

Status: v2 complete (2026-07-04) — 29/29 corpus benchmark, full unit suite
green. v1 complete earlier the same day (20/20).

## v2: source provenance & encode quality (current phase)

Goal shift per Nigel: the headline output is **conclusions with evidence** —
"this lossless file is actually a reencode", "this m4a appears to be sourced
from a vinyl rip" — with the metrics serving as the explanation, not the
star. New `SourceConclusion` model (kind, statement, confidence, evidence
lines) rendered at the top of the results UI.

### Milestones

| # | Milestone | Owner | State |
| --- | --- | --- | --- |
| M0 | Commit v1, plan update | main session | done |
| M1 | Frozen metric/API contracts + stubs + pbxproj | main session | done |
| M2 | Corpus v2: vinyl/tape sims (gapless), old-encoder MP3s, transient material for pre-echo | subagent (sonnet) | done |
| M3a | Analog-source DSP: min-statistics noise floor, noise stereo-coherence, click/crackle detector, rumble, wow (stretch) — `AnalogSourceDSP.swift` | main session (subagent hit usage limit) | done (wow deferred) |
| M3b | Lossy-artifact DSP: pre-echo, HF flicker ("birdies"), HF stereo coherence — `LossyArtifactDSP.swift`; MP3 bitstream inspector (Xing/Info/LAME tag, encoder fingerprint) — `MP3BitstreamInspector.swift` | subagent (fable) + main session (inspector) | done |
| M4 | Engine integration + `SourceInference.swift` (conclusions from combined metrics, incl. cutoff-vs-bitrate table) | main session | done |
| M5 | Benchmark expansion + tuning to all-pass | main session | done — 29/29 |
| M6 | UI: conclusions section with evidence disclosure | subagent (opus) | done |
| M7 | Docs, final build + launch | main session | done |

### v2 tuning findings (thresholds in SourceInference.swift)

- **Stationary hiss under gapless music works**: the min-statistics floor
  reads the -50 dBFS hiss beds at -44/-38 on the real-music sims (music
  never below -20 dBFS) — the case v1 documented as impossible. Floor
  flatness separates hiss (0.31–0.42) from clean digital music (0.17);
  threshold 0.28.
- **Pre-echo needs an audibility floor**: measured against a near-silent
  bed, even LAME 320's faint granule noise read as a "42 dB rise". Gating
  the measurement at attack-peak -45 dB gives: clean 0.0 / LAME 320 -> 1.4
  / LAME 128 -> 6.6 dB. Threshold 4.
- **Clicks need a sub-millisecond sharpness rule**: a naive
  salience-over-median detector counts drum onsets — 104 "clicks"/min on
  clean real music. Requiring the envelope to collapse within ±0.5 ms of
  the peak: clean music ~20/min, vinyl sim 436/min. Threshold 60/min.
- **Sub-30 Hz side-channel rumble is mostly masked by real music**:
  ordinary stereo bass measures -32 dB; threshold -25 so only rumble that
  punches above musical LF counts (the vinyl sim reads -21).
- **M/S is not intensity stereo**: LAME 192's legitimate mid/side coding
  with a starved side channel reads HF coherence 0.93; true HF
  mono-ification reads 1.00. Threshold 0.97.
- **Early-encoder 192 detection works via cutoff-vs-bitrate**: 16.1 kHz at
  192 kbps flags (modern LAME 192 keeps 18.8 kHz), corroborated by the
  missing Xing/LAME header read straight from the bitstream.

### v2 limitations

- **Wow not implemented** (`wowPeakCents` always nil): needs a partial
  tracker that won't confuse vibrato with transport speed error.
- Clicks wider than ~1 ms are intentionally dropped by the sharpness rule;
  dense surface noise still measures hundreds/min so attribution is
  unaffected.
- Vinyl attribution requires clicks + corroborating hiss/rumble; a
  surgically de-noised vinyl rip will read clean — arguably correct.
- Intensity-stereo detection fires only on effectively full HF mono
  (coherence >= 0.97); partial intensity coding blends in with M/S.

### v2 detector design notes

- **Min-statistics noise floor** (Martin 2001): per-band minimum energy over
  a sliding multi-second window; stationary hiss leaves a stable floor in
  10–18 kHz bands even under gapless music. Replaces/augments quiet-gap
  analysis (fixes the `real_hiss.wav` limitation).
- **Noise stereo-coherence**: analog noise is decorrelated L/R; digital
  quiet is often correlated. Strengthens hiss → analog inference.
- **Clicks/crackle**: impulsive wideband outliers (high-order derivative /
  median-outlier salience), reported as clicks-per-minute — positive vinyl
  evidence that works on loud passages.
- **Rumble**: sub-30 Hz energy in the stereo *difference* channel (vertical
  stylus motion) — digital masters rarely have it.
- **Pre-echo**: noise-floor rise in the ~20 ms before strong attacks vs
  local baseline (bad/early encoders lack short-block switching).
- **HF flicker ("birdies")**: on/off toggling of 10–16 kHz bands at the
  codec frame rate (~26 ms), vs slower natural modulation.
- **HF stereo coherence**: intensity stereo (old encoders) mono-ifies the
  top octaves → coherence ≈ 1 where modern encodes stay decorrelated.
- **MP3 bitstream**: still-in-MP3 files carry direct provenance — LAME tag
  (encoder version, declared lowpass), Xing/Info header, CBR/VBR, and
  intensity-stereo mode-extension bits per frame.
- **Cutoff-vs-bitrate**: 192 kbps with a 16 kHz shelf ⇒ early/badly
  configured encoder; modern LAME 192 keeps ~19 kHz.

### Interruption recovery

If this session dies: contracts are frozen in `AnalysisModels.swift`
(structs `AnalogSourceMetrics`, `LossyArtifactMetrics`, `MP3StreamInfo`,
`SourceConclusion`) and stub classes exist in the three new files above.
Check the milestone table + git log; each milestone commits separately.
Benchmark with `scripts/analysis-benchmark.sh`.

An experimental single-file analysis window that measures the properties Nigel
cares about when deciding which of two takes sounds better. Opened from
Debug → Analysis (⌘⌥Z). Deliberately not integrated into the main comparison
UI yet; comparative (multi-file) analysis is a later phase.

## Questions the feature answers

| Question | Metrics | Approach |
| --- | --- | --- |
| Mastered louder or quieter? | Integrated loudness (LUFS), sample peak, crest factor | ITU-R BS.1770-4 K-weighting + absolute/relative gating |
| More bass / mid / treble? | Per-band energy relative to overall | Long-term average spectrum summed into 7 bands (sub <60, bass 60–250, low-mid 250–500, mid 500–2k, high-mid 2k–4k, treble 4k–10k, air >10k) |
| Clearer or muffled? | Spectral centroid, 95% rolloff, treble/air share | Derived from the same average spectrum |
| Background hiss (analog source)? | Noise floor level + spectral flatness of quiet frames | Frame RMS percentile → analyze quietest frames; broadband flat noise ⇒ hiss, tonal residue ⇒ room/bleed |
| Poor-quality encoding? | Codec, bitrate, measured bandwidth | Container/codec info via AVFoundation + cutoff analysis |
| Lossless file actually a lossy transcode? | High-frequency cutoff vs Nyquist | Detect sharp shelf in average spectrum; cutoff ≈16 kHz ⇒ ~128 kbps MP3 heritage, ≈19–20 kHz ⇒ high-bitrate MP3/AAC, no shelf ⇒ plausibly genuine |

## Architecture

```
Sources/Takes/Analysis/
  AnalysisModels.swift      — report structs, verdicts (pure data, testable)
  AnalysisDSP.swift         — vDSP primitives: K-weighted loudness, Welch average
                              spectrum, band energies, noise floor, cutoff finder
  AudioAnalysisEngine.swift — decode via AVAudioFile → run DSP → build verdicts
  SpectrogramRenderer.swift — STFT → log-magnitude CGImage (linear freq axis so
                              codec shelves are visible)
  AnalysisController.swift  — @MainActor ObservableObject; async analysis state
  AnalysisWindowView.swift  — SwiftUI window: file drop/open, verdicts, plots
```

- Engine is pure and UI-independent so a CLI harness (`scripts/analysis-cli`)
  can benchmark it against the corpus without launching the app.
- Analysis runs off-main via `Task.detached`; decodes to 44.1/48 kHz float
  deinterleaved buffers in chunks (no whole-file allocation for long files).

## Algorithm notes

- **Loudness**: BS.1770-4. Two-stage K-weighting biquads (high-shelf + high-pass),
  400 ms blocks with 75% overlap, −70 LUFS absolute gate then −10 LU relative
  gate. Good agreement with ffmpeg `ebur128` is the acceptance test.
- **Average spectrum**: Welch method, 8192-pt FFT, Hann, 50% overlap, averaged
  power → dB. Basis for bands, centroid, rolloff, and cutoff detection.
- **Cutoff detection**: from the average spectrum, compute a mid-band reference
  level (1–8 kHz median). Scan downward from Nyquist for the highest frequency
  where the level recovers to within ~35 dB of the reference; a sharp drop
  (>25 dB within ~1 kHz) sustained to Nyquist marks a codec lowpass shelf.
  Report cutoff + confidence; flag lossless containers with cutoff <0.44×sr.
  Known mapping: ~16 kHz → MP3 ≈128 kbps; ~18–19 kHz → MP3 ≈192; ~20 kHz →
  MP3 320/V0 or AAC ≥256 (weak signal); ≥20.5 kHz/no shelf → plausibly genuine.
- **Hiss**: rank 100 ms frames by RMS; take the 5th–20th percentile ("quiet
  frames"), measure their broadband level and spectral flatness. Flatness above
  ~0.25 with level above −72 dBFS ⇒ hiss verdict (analog source hint).
- **Clipping**: count runs of ≥3 consecutive samples with |x| ≥ 0.999.

## Benchmark corpus

Generated by `scripts/make-analysis-corpus.sh` into
`<repo>/Private/Analysis Corpus/` (gitignored; script is committed and
reproducible). Manifest with ground truth: `docs/analysis-corpus.md`.
Cases: loud/quiet masters, bass/bright tilts, muffled lowpass, added hiss,
MP3 128/320, AAC 96/256, fake-lossless FLACs from MP3-128 and AAC-128,
true-lossless FLAC, plus real-music derivatives from a library sample.

## Benchmark harness

`scripts/analysis-benchmark.sh` compiles the UI-independent engine sources
with `swiftc` plus `scripts/analysis-cli/main.swift` and checks every corpus
file against ground-truth expectations (LUFS ±1 LU vs ffmpeg's ebur128,
cutoff ranges, required/forbidden verdicts). Also usable ad hoc:

```
scripts/analysis-benchmark.sh                    # 20-case corpus benchmark
scripts/analysis-benchmark.sh analyze <files…>   # metrics for any files
```

## Findings from tuning (thresholds live in AnalysisVerdicts.swift)

- **LUFS agreement**: engine matches ffmpeg `loudnorm` measurements within
  ~0.2 LU across the corpus.
- **Fake-lossless detection works**: all four trap cases (MP3-128→FLAC ×2,
  AAC-128→FLAC, on synthetic and real music) flag as likely transcodes with
  correct cutoff estimates (~16 kHz for MP3-128, ~18.7 kHz for AAC-128).
- **Muffledness**: rolloff/centroid are useless on real music (bass dominates
  total energy; mellow tracks legitimately centroid <400 Hz). The Air band
  (10–22 kHz) level relative to total is the discriminator: ≈ −30 dB for
  mellow-but-fine real music vs −69 dB for the same track lowpassed at
  4.5 kHz. Threshold −38 dB.
- **Hiss**: quiet-block flatness must be measured 3–16 kHz only, and only on
  blocks within 10 dB of the file's quietest block, or musical residue
  swamps it.
- **Noise floor** reads as "quietest passage level" on gapless material —
  that's inherent to single-file analysis, not a bug.

## Known limitations (v1, single-file)

- Hiss under gapless music is undetectable: the real-music hiss case has a
  −50 dBFS hiss bed under music whose quietest passage is −20 dBFS — no gap
  exists to measure in. (An HF-noise-between-transients approach could help;
  out of scope.)
- Absolute bass/treble tilt verdicts only fire at extremes (tilt >30 dB or
  <0 dB vs the real-music norm of +15…+25), because "bassier than it should
  be" is inherently a comparison — a +6 dB/120 Hz shelf on bright synthetic
  material is invisible in absolute terms. Comparative mode is the answer.
- `real_reference.wav` (a WAV decoded from ~283 kbps AAC) is *not* flagged:
  its soft ~19–20 kHz rolloff lacks the sharp shelf the detector keys on.
  Flagging it would be defensible, but soft-slope heuristics false-positive
  dark masters, so v1 stays conservative.
- True peak is sample peak (no 4× oversampling), so intersample overs read
  slightly low (corpus `loud.wav` measures −0.4 dBFS sample peak vs
  +2.8 dBTP true peak).

## Work log

- 2026-07-04: Plan written. Corpus generation delegated to a subagent
  (script + generated files + manifest, 20 files). DSP engine + unit tests
  implemented and validated against BS.1770 reference points. Analysis
  window UI built (delegated). CLI benchmark harness built; thresholds tuned
  from 15/20 to 20/20 (quiet-block windowing, HF-restricted flatness,
  Air-band muffledness, realistic tilt bounds).

## Later ideas (out of scope for v1)

- Comparative two-file mode (difference spectrum, loudness-matched A/B)
- True peak (4× oversampled) instead of sample peak
- MP3/AAC frame-grid detection for stronger transcode evidence
- Wow/flutter + click detection for vinyl sources
