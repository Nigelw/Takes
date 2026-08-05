## v1

- **Loudness**: ITU-R BS.1770-4 integrated LUFS (K-weighting + gating, validated against the spec's reference points and matching ffmpeg within ~0.2 LU), sample peak, crest factor, clipped-run count
- **Tonal balance**: 7-band long-term spectrum, centroid, tilt
- **Clarity**: keyed on Air-band (10–22 kHz) collapse — tuning revealed centroid/rolloff false-positive on mellow real music
- **Hiss**: spectral flatness of the quietest blocks, measured 3–16 kHz where music is sparse but hiss is flat
- **Encoding/authenticity**: codec info plus a cutoff-shelf detector on the Welch average spectrum; a lossless container with a sharp shelf below ~0.91×Nyquist gets flagged with a bitrate-class guess (~16 kHz → MP3-128-class, etc.)

---

>  is there some other analysis that can be done to detect the properties of these audio sources even without quiet audio?

**Detecting analog sources without any quiet audio**

Yes, several approaches exist, in rough order of value-per-effort:

1. **Minimum-statistics noise estimation** (Martin 2001, standard in speech enhancement). Track the *minimum* energy per frequency band over a sliding window of a few seconds. Stationary hiss creates a stable nonzero floor in the 10–18 kHz bands even while music plays, because cymbals and other HF content are transient — between their decays, each band's minimum falls to the hiss level. A digital-clean source shows those minima collapsing toward zero. This is the natural v2 of the current detector and works on fully gapless material; the main tuning risk is dense sustained HF content (shoegaze walls of sound) inflating the estimate.
2. **Stereo decorrelation of the floor.** Analog noise is independent per channel; digitally clean quiet content is often correlated. Measuring inter-channel coherence of the HF residual strengthens the hiss verdict cheaply.
3. **Vinyl-specific artifacts**, which are detectable *under* music and are actually stronger evidence than hiss:
   - **Clicks and crackle** — impulsive, wideband, a few ms long. Classic detection is AR-model residual or high-order-derivative outlier counting (the declicking literature). A click-rate metric would positively identify vinyl even on loud passages.
   - **Wow** — slow pitch modulation (0.3–6 Hz) from off-center pressing; visible as coherent wobble of spectral lines. Detectable via modulation spectrum of a pitch track.
   - **Rumble** — coherent energy below ~30 Hz, predominantly in the stereo *difference* channel (vertical stylus motion), which digital masters rarely have.
4. **Tape-specific tells**: print-through (a faint pre-echo of loud transients ~1–2 s early, at the tape-wind spacing) and HF stereo phase wander from azimuth drift. These are rarer and harder; I'd not start here.

If you want, I can implement the minimum-statistics floor estimator — it slots into the existing streaming pass as another accumulator, and the corpus already contains the exact case (`real_hiss.wav`) that would flip from "documented limitation" to a passing benchmark. A click/crackle counter would be the next most useful addition since it detects vinyl positively rather than inferring it from noise.

---
> Is it also possible to detect poor quality lossy encodes? Not 64kbps mp3s which are more obvious, but things like 192kbps MP3s from the early days of MP3 encoding

Yes, though it's genuinely harder than the cutoff-shelf cases, because a 192 kbps encode from a decent encoder is *measurably* subtle for the same reason it's *audibly* subtle. But early-encoder 192s (Xing, Blade, pre-tuning FhG) had specific, well-documented failure modes, and most of them leave detectable fingerprints:

**Easy, and partially already in place:**

1. **Cutoff-vs-bitrate mismatch.** The current detector reports the cutoff but only judges it against the container. The sharper heuristic is judging it against the *claimed bitrate*: a modern LAME 192 keeps ~18.5–19.5 kHz, while old FhG/Xing encoders lowpassed at 16 kHz even at high bitrates. "192 kbps but 16 kHz shelf" is a strong early-encoder tell, and it's a small extension of what's built.
2. **Bitstream provenance (for files still in .mp3 form).** LAME writes an info tag with encoder version, lowpass, and quality settings; old Xing/FhG/Blade files lack it or carry distinctive frame-header patterns. Parsing the actual MP3 frames is cheap and gives you *direct* evidence instead of inference — this only fails once someone has transcoded to FLAC/WAV, which is exactly when the signal-domain methods below take over.

**Medium effort, high value — targets the actual audible defects:**

3. **Pre-echo measurement.** The signature early-encoder failure: Xing famously didn't use short MDCT blocks, so quantization noise smears up to ~26 ms *before* sharp transients (the castanets/applause killer samples). Detectable by finding strong attacks, then comparing the noise level in the few ms before the attack against the local baseline. This is attractive because it measures the artifact people actually hear, and it naturally grades severity.
4. **Intensity-stereo collapse.** Old encoders forced intensity stereo at high frequencies, mono-ifying the image above ~10 kHz. Inter-channel coherence in the top octaves separates that from a true-stereo modern encode. Cheap to add to the existing spectral pass.
5. **"Birdies"/spectral flicker.** Unstable per-band bit allocation makes 10–16 kHz bands toggle on and off frame to frame — a swirly, watery top end. Statistically visible as abnormally high on/off flicker in high-band energy at the codec's ~26 ms frame rate, distinguishable from natural musical modulation which is slower and smoother.

**Hard/research tier:**

6. **Granule-grid analysis** — MP3 quantization noise is structured on the 576-sample granule grid; realigning to that grid exposes it and can even survive transcoding to lossless. There's published work on encoder identification and double-compression detection from decoded PCM (this is how forensics tools classify encoder brands). Real, but a project in itself.

One framing note: for the "which sounds better" purpose, the pre-echo and flicker metrics matter most, because they degrade gracefully — they'd distinguish an early 192 from a modern 192 *and* rank a modern 128 below a modern 256 even when both cutoffs look reasonable. The cutoff table and bitstream sniffing are cheaper but more binary.

If you want to proceed, my suggested order is 1 + 2 first (small, concrete, and the corpus already has the AAC/MP3 bitrate ladder to validate against — I'd add a couple of old-encoder-style variants, e.g. ffmpeg's built-in MP3-free shine encoder or `lame --preset` with forced 16 kHz lowpass to simulate vintage behavior), then 3 (pre-echo) as the first artifact-domain metric, validated with a transient-heavy corpus addition (castanets-style click train, which the synthetic generator can produce exactly).

---

* For the analog/hiss audio detection I'm interested in 1, 2, and 3
* For the poor quality lossy encodes I'm interested in 1-5.

---
> Which toggles control these algorithms, Pre-echo measurement, Intensity-stereo collapse, "Birdies"/spectral flicker

All three map to the same toggle: **Lossy Encode Artifacts** (`AnalysisModule.lossyArtifacts`, rated Slow).

Looking at `LossyArtifactAnalyzer` in [LossyArtifactDSP.swift](Sources/Takes/Analysis/LossyArtifactDSP.swift):
- **Pre-echo measurement** → `preEchoScore` / `attackCount`
- **HF flicker ("birdies")** → `highBandFlickerScore`
- **Intensity-stereo collapse** → `hfStereoCoherence`

All three are computed in a single streaming pass by that one analyzer, so there's no way to enable one without the others — switching off "Lossy Encode Artifacts" in the configuration screen skips all three at once, and switching it on runs all three together.