# Comparative Quality Analysis

Status: complete through M9, plus a post-M9 fix to the cutoff-scalar defect
(see below). `xcodebuild test` passes 334/334, the comparative benchmark 14/14,
and the single-file benchmark 29/29. The feature is reachable
from Debug → Compare Quality (⇧⌘L) and is deliberately not wired into the main
UI.

Not yet done, and worth doing next: transcode simulation (the strongest
evidence available), tempo-corrected comparison for speed-shifted remasters,
and the blind-listening confirmation loop.

An experimental multi-file analysis that answers "which of these loaded
tracks is the better quality version?" without requiring a listening test.
Opened from Debug → Compare Quality; runs over every track currently loaded
in the session. Deliberately separate from the main comparison UI so
integration questions can be deferred.

Builds on the single-file engine documented in
[experimental-audio-analysis.md](experimental-audio-analysis.md); read that
first. This document covers only what comparison adds.

## Why this needs no training data

"Which is the better version" sounds perceptual, but for two copies of the
*same recording* it is mostly a provenance question: which file is closer to
the studio master. Degradation is directional — encoders remove bandwidth and
add quantization noise, vinyl adds clicks and rumble, transfers add hiss —
and none of it reverses. The ordering is therefore recoverable from evidence
rather than learned from examples.

What the feature does need is labeled **evaluation** data, and that can be
synthesized exactly: `scripts/make-analysis-corpus.sh` already builds
degradation chains whose ancestry is known by construction. Ground truth
comes from the generator, not from hand-labeled listening.

## The three questions hiding inside "which is better"

| Question | Decidable? | Feature's job |
| --- | --- | --- |
| Which is closer to the master? (fidelity / provenance) | Yes, from artifacts | Rank, with evidence |
| Which master do I prefer? (loudness war vs dynamic remaster, different EQ) | No — taste, not quality | Describe differences, refuse to rank |
| Are these even the same master? | Yes | Gate: decides which of the above applies |

Mixing fidelity and taste into one score is the fastest way to produce
untrustworthy output: a 2015 loudness-war remaster genuinely has more HF and
less dynamic range than a 1987 CD transfer, and no scalar reconciles that.
The ranking policy must therefore be a partial order with explicit
abstention, never a single number.

## Architecture

Relationship classification gates everything. Nothing ranks until the pair's
relationship is known.

```
1. Pair/cluster        every loaded track × every other, coarse first
2. Classify relation   identical | same master | different master | different recording
3. Comparative metrics only for same-master pairs (aligned, loudness-matched)
4. Rank                partial order + evidence + confidence, abstain by default
```

New files under `Sources/Takes/Analysis/`:

```
ComparativeModels.swift    — relationship, pair result, ranking (pure data)
PairAlignment.swift        — sample-accurate refinement + loudness match + residual
ComparativeDSP.swift       — difference spectrum, null depth, band/time divergence
ComparativeInference.swift — ranking policy, abstention rules, evidence text
ComparativeAnalysisEngine.swift — orchestration over N tracks
ComparisonWindowView.swift — Debug-menu window
```

### Relationship classifier (the gate)

1. **Coarse align** with the existing [TrackAligner](../Sources/Takes/TrackAligner.swift):
   1 ms novelty-envelope hops, already validated and already used by the app's
   Auto-Align. Gives a lag plus a confidence score.
2. **Refine to sample accuracy** by GCC-PHAT over a ±2 ms window around the
   coarse lag (±88 samples at 44.1 kHz) on a few seconds of decoded audio.
   Cheap once seeded; a full-file search is not needed.
3. **Loudness-match** by integrated LUFS, which the engine already computes.
4. **Residual**: subtract aligned, gain-matched signals; measure residual
   level relative to signal, and its spectral/temporal distribution.

Classification from the residual:

| Relationship | Signature |
| --- | --- |
| `identical` | Bit-identical, or residual below the quantization floor |
| `sameMaster` | Residual well below signal and *structured* — concentrated at HF, or impulsive around transients |
| `differentMaster` | Aligns confidently, but residual is broadband and comparable to signal (EQ/compression differences) |
| `differentRecording` | No confident alignment |

This gate is not academic. Opening "two copies of the same track" from
different sources hits `differentMaster` constantly.

### Comparative metrics (same-master pairs only)

Aligned pairs allow measurements no single-file heuristic can make. The v1
notes already record that absolute tilt verdicts only fire at extremes
because "bassier than it should be is inherently a comparison" — this is the
fix.

- **Difference spectrum by band** — where B lost energy relative to A.
- **Null depth over time** — where divergence concentrates; pre-echo appears
  directly as residual clustered before transients rather than inferred.
- **Directional asymmetry** — the proof structure. If B = degrade(A), A
  explains B but B cannot explain A. Bandwidth present in A and missing in B,
  plus quantization noise in the residual, orders the pair. Noise *added* to A
  (hiss, clicks) orders it the other way.

### Transcode simulation (strongest available evidence, later phase)

For a suspected lossy ancestor, reproduce rather than infer: encode A at the
settings B appears to use, decode, align against B, measure the null. A deep
null is near-proof that B is A run through that codec.

Feasibility caveat: AAC encoding is free in-app via AudioToolbox; macOS ships
no MP3 encoder, so MP3 simulation needs LAME bundled. Deferred past v1 until
that dependency question is decided.

## Trust strategy

Design discipline matters more than algorithms here.

- **Abstain by default.** "I can't distinguish these; here's what differs" is
  trustworthy. A tool that always names a winner is not — one wrong call on an
  inaudible difference destroys belief in the correct calls.
- **Evidence, not a score.** Extend the v2 `SourceConclusion` shape
  (statement / confidence / evidence lines) to comparison. Two facts pointing
  opposite ways is a tie, not an average.
- **Validate against constructed ancestry.** Extend the corpus with explicit
  chains (master → 320 → 192 → 128 → FLAC rewrap) and assert the engine
  reproduces the known partial order. Include adversarial cases: same encode
  at different gain, two different masters (must abstain), a de-noised vinyl
  rip.
- **Real-world fixtures.** `Private/Audio Samples/Quality Comparison Samples/`
  holds seven real pairs covering every relationship class, including a
  different-performance pair (James Blake original vs Feist cover) and a
  remaster-vs-original pair (Whiskeytown). These check the gate against
  material the synthetic corpus cannot simulate.
- **Blind confirmation loop** (later). The app already ships Blind Listening
  Mode. Letting the analysis propose the most-divergent segment and hide its
  verdict until the user commits builds calibration — and collects the only
  labels worth having, on exactly the cases the analyzer found ambiguous.

## Where ML would fit (deliberately not v1)

Not as the ranker. Two defensible later uses:

- **Full-reference perceptual metrics** (PEAQ, ViSQOL) on aligned same-master
  pairs, each file as reference for the other; the asymmetry indicates which is
  degraded. ViSQOL is open source but a substantial C++ dependency.
- **Learned codec-artifact classification** from decoded PCM, trained on
  synthetic data generated locally rather than hand labels. This is the
  granule-grid tier the v2 notes already flagged as a project in itself.

No-reference music quality models (the NISQA family) are speech-oriented and
weak on music. The feature must not depend on one.

## Milestones

| # | Milestone | Owner | State |
| --- | --- | --- | --- |
| M0 | This plan | main session | done |
| M1 | Frozen contracts in `ComparativeModels.swift` | main session | done |
| M2 | Corpus: regenerate v1/v2, add ordered degradation chains + adversarial cases; fixture manifest for the real comparison samples | subagent | done |
| M3 | Relationship classifier (`PairAlignment.swift`) | main session | done |
| M3t | `PairAlignmentTests.swift` + pbxproj registration | subagent | done |
| M4 | Directional findings (merged into `ComparativeInference.swift`) | main session | done |
| M5 | Ranking policy with abstention (`ComparativeInference.swift`) | main session | done |
| M6 | N-track orchestration (`ComparativeAnalysisEngine.swift`) | main session | done |
| M7 | Debug → Compare Quality window over loaded tracks | main session | done |
| M8 | CLI/benchmark extension + tuning to all-pass | main session | done |
| M9 | Docs, AGENTS.md update, full build | main session | done |

Two boundary changes from the original plan. The residual DSP moved into M3,
because classification depends on it. M4's directional-finding extraction then
had nowhere separate to live, so it merged into `ComparativeInference.swift`
alongside the ranking policy rather than getting its own `ComparativeDSP.swift`
— the two are one decision procedure and splitting them only hid that.

## M3 findings

What the corpus taught, in the order it mattered:

- **Sub-sample alignment is the whole game.** Half a sample of error leaves a
  residual only ~3 dB below the signal at 10 kHz, which drowns every real
  difference. GCC-PHAT finds the right sample but interpolates its own peak
  poorly (~0.02 samples of bias, a −35 dB floor). Fitting the cross-spectrum's
  phase slope instead recovers the delay exactly, and applying it as a
  frequency-domain phase ramp — rather than a windowed-sinc kernel — takes the
  null from −42 dB to −132 dB, the float32 floor. The sinc kernel's error was
  not evenly spread: it sat almost entirely in the air band, the one octave
  this feature cannot afford to get wrong.
- **The coarse aligner must not hold a veto.** `TrackAligner`'s peak-contrast
  gate rejects repetitive material outright, which failed every synthetic
  chain pair. Trying offset 0 as well, and letting the residual decide, fixed
  all of them. The residual is a far better test of whether two files line up
  than novelty contrast is.
- **Residual level alone cannot classify.** A 128 kbps re-encode and a
  different master overlap in overall residual. Two statistics separate them
  cleanly:
  - `midBandResidualToSignalDB` (60 Hz – 4 kHz, energy-weighted). The sub band
    is excluded deliberately — it holds too little energy to judge and reads
    alarmingly high on encodes that are otherwise transparent. A per-band
    *maximum* over the low bands had exactly that failure; the energy-weighted
    aggregate does not.
  - `midBandTiltDifferenceDB`, the real discriminator. A codec is
    level-preserving below its cutoff, so long-term band balance survives it
    almost exactly. Across the corpus, same-master pairs top out at 1.6 dB and
    different masters start at 4.2 dB.
- **Pool by median, not by energy.** On the Elliott Smith pair the leading
  probe window read −1.9 dB while every other window read −20 dB or better: it
  landed on the intro, where the two encoders disagree about near-silence.
  Energy-pooling let that one window set the verdict. Median across windows,
  plus insetting the windows away from both edges of the overlap, fixed it.
- **The Nyquist bin needs rotating too.** `spectralShift` originally left the
  packed Nyquist term alone, on the grounds that it carries little energy. It
  cost 6e-3 on every odd-sample integer shift, and 63 dB of null depth on the
  corpus's offset pair, which went from −71 dB to −134 dB once fixed. A real
  signal's Nyquist component is x·cos(πn), so a delay of s scales it by
  cos(πs): exactly ±1 for integer shifts, an attenuation for fractional ones.
  Caught by a unit test using full-band white noise, which is exactly the
  adversarial input that makes the approximation visible.
- **Remasters are often at a different speed.** The Whiskeytown pair is the
  same performance transferred ~0.25–0.5% faster, which destroys any fixed-lag
  comparison. Detected by scanning tempo-stretched novelty envelopes; a speed
  difference is itself proof of a different transfer, so it classifies as
  `differentMaster` rather than `differentRecording`.

A note on the fractional case: because `cos(πs)` attenuates rather than
rotates, a *fractional* shift is not reversible at Nyquist. That is correct —
no fractional delay of a real signal can preserve a Nyquist-frequency component
— but it means round-trip tests need band-limited input. Production only ever
applies a single shift, so it is unaffected.

### M3 limitations

- **The detected speed ratio is not trustworthy as a number.** Both real pairs
  that trip it report exactly 1.0025, the smallest scanned step. The useful
  signal is "does not align at a fixed lag but does when stretched"; the ratio
  itself should not be shown as a measurement.
- **Cross-rate pairs are a weaker comparison.** B is resampled to A's rate via
  `AVAudioConverter`, which puts a floor under how deep the null can go. Not
  yet quantified against a corpus case.
- **No tempo-corrected residual.** A speed-shifted pair is classified but not
  measured; ranking it on fidelity would need resampling B by the ratio first.
- **`differentRecording` needs the probe to run.** It is inferred from every
  probe window's correlation peak landing astray. A pair too short for one
  probe window reads `indeterminate` instead.

### Corrections to the corpus manifest

The James Blake pair is documented as original-vs-Feist-cover, i.e.
`differentRecording`. That is wrong: James Blake's "Limit to Your Love" *is*
the Feist cover, and both files hold the same recording. Measured waveform
coherence is 0.985 across three probe windows, which cannot happen between
different performances. `docs/analysis-corpus.md` has been corrected.

## M4–M8 findings

Tuning the findings and ranking against the corpus turned up three ways the
feature could have looked confident and been wrong:

- **Clipped-run counts are not fidelity evidence between two lossy files.**
  Decoding a lossy file produces its own intersample overshoot, so two encodes
  of one master routinely differ by 15–30% in clipped runs with no fidelity
  difference at all. Left unguarded this *decided* the Mos Def pair and forced
  a false conflict on Elliott Smith. Clipping now needs a 4× disparity before
  it counts.
- **Bitrate does not compare across codecs.** AAC at 256 kbps beats MP3 at
  320. The bitrate finding is now restricted to pairs sharing a codec.
- **Neither does the HF-flicker score.** It is measured against the codec frame
  cadence (~26 ms, an MP3 granule pair), and an AAC file's 1024-sample frames
  beat against that window differently. Comparing it across codecs made an AAC
  256 look worse than an MP3 128, which was the single failing case in the
  benchmark. Also restricted to same-codec pairs.

The general lesson: a metric tuned for absolute single-file judgement is not
automatically valid as a *comparison* between two files, and the ones keyed to
a particular codec's behaviour are the dangerous ones.

Two smaller decisions worth keeping:

- Tonal balance is read from each file's own long-term band levels rather than
  from the residual, so it stays valid when the pair does not align — and the
  pairs where tonal balance is most worth describing are exactly those.
- Confidence rises when independent dimensions agree. Two low-confidence
  findings pointing the same way become medium; two medium become high.

## The cutoff-scalar defect (found after M9)

A user comparing spectrograms of two Mos Def files spotted a difference the
engine had missed, and unpicking it exposed three linked defects. Worth
recording because the same shape of mistake is easy to repeat.

The pair: an AAC at 287 kbps with content rolling gently off to 22 kHz, and an
MP3 at 210 kbps cliffing at ~19 kHz. Measured from the average spectrum:

| | 18 kHz | 20 kHz | 22 kHz |
| --- | --- | --- | --- |
| m4a | −83.5 dB | −87.2 dB | −93.4 dB |
| mp3 | −90.7 dB | −104.1 dB | −104.8 dB |

The engine reported cutoffs of **17.7 kHz and 17.6 kHz** and ranked the *MP3*
better. What went wrong:

1. **A low-confidence measurement fed a high-confidence conclusion.** The
   cutoff detector scans down from Nyquist for where the level recovers to
   within ~35 dB of the 1–8 kHz median. This master is dark — air band 33 dB
   below total — so the whole top end sits under that absolute threshold and
   both files cross it in the same place. The detector said `.low` confidence,
   correctly. `SourceInference` then compared that number against the
   cutoff-vs-bitrate table and concluded, at **high** confidence, that the
   287 kbps file was "an early or badly configured encoder" — penalising it for
   having a bitrate high enough to raise expectations. Now gated on
   `bandwidth.confidence != .low`.
2. **Comparing derived scalars threw away the shape.** Two cutoff numbers
   cannot express "one cliffs, one rolls off gently". The comparative bandwidth
   finding now differences the two average spectra sub-band by sub-band
   (`highBandDifferences`, 2 kHz bands from 12 kHz up, each measured relative
   to its own file's 1–8 kHz median). The single `Air` band (10–22 kHz) was
   also too coarse: it is dominated by 10–16 kHz, where two encodes of one
   master usually agree, which is why the residual air difference read −0.2 dB
   on a pair differing by 17 dB at 20 kHz. Cutoffs are still used to *phrase* a
   finding, but only when both were measured confidently.
3. **Provenance was double-counting encode quality.** `provenanceTier` ranked
   `poorLossyEncode` below `cleanLossyEncode`, but that verdict is itself
   derived from pre-echo, flicker, intensity stereo and bandwidth — the same
   measurements the `bandwidth` and `codecArtifacts` dimensions compare
   directly. The confidence rule then read one signal as two independent
   dimensions agreeing. Provenance is now about the *kind* of file only:
   genuinely lossless > lossy > lossy in a lossless container.

Effect on the real-world pairs: Bloc Party, Digable Planets and Elliott Smith
all moved to high-confidence correct rankings (Digable Planets was low
confidence, Elliott Smith was undetermined). Mos Def moved from a confidently
wrong answer to `undetermined` — the m4a wins decisively on bandwidth, the mp3
on HF stereo width, and those genuinely disagree.

**On spectrograms.** The spectrogram is an STFT rendered as an image; the
information in it is the same STFT data the Welch accumulator already averages,
and averaging over a whole track is strictly better for a static cutoff than a
picture is. Nothing here needed the spectrogram — it needed the average
spectrum to stop being collapsed to one number too early. The spectrogram's
time axis would earn its place for something the average spectrum cannot show:
a cutoff that moves over time, dropouts, splices, localized artifacts.

### Remaining weakness

Mos Def's surviving `poorLossyEncode` conclusion rests on an HF stereo
coherence of 0.9736 against a 0.97 threshold — a knife edge, and the v2 notes
place legitimate M/S coding at 0.93 and true mono-ification at 1.00, so the
threshold's placement is genuinely uncertain for this material. It is measured
over 10 kHz to the *detected cutoff*, which on dark masters is the same
untrusted number. Retuning it needs its own corpus work.

## Scope and constraints

- **Experimental and debug-only.** Reachable from Help → Debug, same as the
  single-file Analysis window. No main-UI integration in this phase.
- **Runs over all loaded session tracks**, not a file picker — the session is
  the input.
- **Cost.** `analogSource` and `lossyArtifacts` are rated Slow in
  [AnalysisModule.swift](../Sources/Takes/Analysis/AnalysisModule.swift), and
  comparison multiplies by pair count. Cluster by master first so the pairwise
  cost stays bounded; keep analysis off-main via `Task.detached` as the
  single-file controller does.
- **Corpus is absent from worktrees** (`Private/` lives at the main checkout
  root and is gitignored). `scripts/analysis-benchmark.sh` already resolves the
  common root; the corpus itself must be regenerated with
  `scripts/make-analysis-corpus.sh` before benchmarking.

## Work log

- 2026-08-27: Plan written. Corpus regenerated and extended with phase 3
  comparative cases (delegated). Contracts frozen in `ComparativeModels.swift`.
  Relationship classifier built and tuned to 13/13 synthetic + 7/7 real-world.
  Findings, ranking policy and N-track orchestration built; Debug → Compare
  Quality window wired up. CLI gained `compare` and `compare-benchmark` modes;
  comparative benchmark passes 14/14, single-file benchmark still 29/29.
  22 unit tests added (delegated); one of them caught a real defect in the
  Nyquist handling of `spectralShift`. Full suite 325/325.
