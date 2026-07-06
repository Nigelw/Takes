#!/usr/bin/env bash
#
# make-analysis-corpus.sh — generate a benchmark test corpus for the
# experimental audio-analysis feature (loudness / tonal-tilt / bandwidth /
# "fake lossless" detection).
#
# Produces a synthetic reference signal plus a real-music reference, then a
# set of derivative files with known ground truth (gain offset, tonal tilt,
# lowpass cutoff, added hiss, lossy transcodes, and lossy-into-lossless
# "fake FLAC" traps). Every output is verified with ffprobe/ffmpeg and a
# spectrogram PNG is rendered per file for eyeballing.
#
# Usage:
#   scripts/make-analysis-corpus.sh [output-dir]
#
#   output-dir defaults to:
#     /Users/Nigel/Developer/Takes/Private/Analysis Corpus
#   (this lives at the MAIN repo checkout, is gitignored via Private/, and is
#   absent from worktrees — always resolved as an absolute path).
#
# Idempotent: re-running skips any output file that already exists unless
# FORCE=1 is set in the environment or --force is passed. Verification and
# the manifest data file are always regenerated so numbers stay fresh.
#
# Requires: ffmpeg (with libmp3lame + FLAC muxer), ffprobe, lame, flac,
# afconvert (for one AAC path). No sox is used.

set -euo pipefail

# ---- Config -----------------------------------------------------------
FFMPEG="/opt/homebrew/bin/ffmpeg"
FFPROBE="ffprobe"
REAL_SOURCE="/Users/Nigel/Developer/Takes/Private/Audio Samples/11 Where to Begin.m4a"
DEFAULT_OUT="/Users/Nigel/Developer/Takes/Private/Analysis Corpus"

FORCE=0
OUT_DIR=""
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    *) OUT_DIR="$arg" ;;
  esac
done
OUT_DIR="${OUT_DIR:-$DEFAULT_OUT}"
if [[ "${FORCE_ENV:-}" == "1" ]]; then FORCE=1; fi
if [[ "${FORCE:-0}" == "1" ]]; then FORCE=1; fi

SPEC_DIR="${OUT_DIR}/_spectrograms"
DATA_FILE="${OUT_DIR}/_verification.tsv"

mkdir -p "$OUT_DIR" "$SPEC_DIR"

echo "==> Analysis corpus output dir: ${OUT_DIR}"

# ---- Helpers ------------------------------------------------------------

# run CMD only if OUT file doesn't exist (or FORCE=1)
gen() {
  local out="$1"; shift
  if [[ -f "$out" && "$FORCE" -ne 1 ]]; then
    echo "skip  (exists) $(basename "$out")"
    return 0
  fi
  echo "make  $(basename "$out")"
  "$@"
}

# render a spectrogram PNG for a given audio file into _spectrograms/
spectrogram() {
  local in="$1"
  local base
  base="$(basename "$in")"
  local png="${SPEC_DIR}/${base%.*}.png"
  if [[ -f "$png" && "$FORCE" -ne 1 ]]; then
    return 0
  fi
  "$FFMPEG" -y -hide_banner -loglevel error -i "$in" \
    -lavfi "showspectrumpic=s=1024x512:legend=1" \
    "$png"
}

# ---- 1. Synthetic reference signal ---------------------------------------
#
# 30s / 44.1kHz / stereo / 24-bit "music-like" full-band signal:
#   - two independent pink-noise beds (L/R, different seeds -> decorrelated)
#   - two harmonic-stack tones (sawtooth-ish via summed sine harmonics),
#     one per channel bed, standing in for "melodic" content
#   - a periodic percussive burst train: white noise gated with a fast
#     exponential-decay envelope, repeating every 1.7s
#   - a slow linear chirp sweep from 200 Hz to 21 kHz across the full 30s,
#     giving genuine full-bandwidth content near Nyquist
#   - a ~2.5s near-silence gap (t=19..21.5s) for noise-floor ground truth
#   - fed through alimiter with a -3 dBFS (linear 0.708) ceiling so true
#     peak lands close to -3 dBFS
build_reference() {
  local out="${OUT_DIR}/reference.wav"
  if [[ -f "$out" && "$FORCE" -ne 1 ]]; then
    echo "skip  (exists) reference.wav"
    return 0
  fi
  echo "make  reference.wav"
  local dur=30
  local f0=200 f1=21000
  local k
  k=$(python3 -c "print((${f1}-${f0})/${dur})")

  "$FFMPEG" -y -hide_banner -loglevel error \
    -f lavfi -i "anoisesrc=color=pink:sample_rate=44100:duration=${dur}:amplitude=0.12:seed=1" \
    -f lavfi -i "anoisesrc=color=pink:sample_rate=44100:duration=${dur}:amplitude=0.12:seed=2" \
    -f lavfi -i "aevalsrc='0.20*sin(2*PI*110*t)+0.10*sin(2*PI*220*t)+0.05*sin(2*PI*330*t)+0.03*sin(2*PI*440*t)':sample_rate=44100:duration=${dur}" \
    -f lavfi -i "aevalsrc='0.20*sin(2*PI*164.81*t)+0.10*sin(2*PI*329.63*t)+0.05*sin(2*PI*494.44*t)':sample_rate=44100:duration=${dur}" \
    -f lavfi -i "anoisesrc=color=white:sample_rate=44100:duration=${dur}:amplitude=1.0:seed=3" \
    -f lavfi -i "aevalsrc='0.15*sin(2*PI*(${f0}*t + ${k}/2*t*t))':sample_rate=44100:duration=${dur}" \
    -filter_complex "\
[4]volume=eval=frame:volume='exp(-35*mod(t\,1.7))':precision=float[perc]; \
[0][2]amix=inputs=2:weights='1 1'[l1]; \
[1][3]amix=inputs=2:weights='1 1'[r1]; \
[l1][perc]amix=inputs=2:weights='1 0.8'[l2]; \
[r1][perc]amix=inputs=2:weights='1 0.8'[r2]; \
[l2][5]amix=inputs=2:weights='1 1'[l3]; \
[r2][5]amix=inputs=2:weights='1 1'[r3]; \
[l3]volume=1.9[lg]; \
[r3]volume=1.9[rg]; \
[lg]volume=eval=frame:volume='if(between(t\,19\,21.5)\,0.02\,1)'[lf]; \
[rg]volume=eval=frame:volume='if(between(t\,19\,21.5)\,0.02\,1)'[rf]; \
[lf][rf]join=inputs=2:channel_layout=stereo[joined]; \
[joined]alimiter=limit=0.708:level=disabled:attack=3:release=80[out]" \
    -map "[out]" \
    -ar 44100 -c:a pcm_s24le \
    "$out"
}

# ---- 2. Real-music reference ---------------------------------------------
#
# Decode the AAC source to WAV, trimmed to a 30s window (skip the intro,
# start at 20s) so the real corpus entries stay comparable in length to the
# synthetic ones. This file is ALREADY lossy-sourced (AAC) so its own HF
# content is whatever the encoder left behind -- noted in the manifest, not
# something we can "fix".
build_real_reference() {
  local out="${OUT_DIR}/real_reference.wav"
  gen "$out" "$FFMPEG" -y -hide_banner -loglevel error \
    -ss 20 -t 30 -i "$REAL_SOURCE" \
    -ar 44100 -ac 2 -c:a pcm_s24le \
    "$out"
}

# ---- 3. Derivative variants -----------------------------------------------

make_variants_for() {
  local src="$1"       # e.g. reference.wav or real_reference.wav
  local prefix="$2"    # "" for synthetic, "real_" for real-music

  local base="${OUT_DIR}/${src}"

  # true_lossless.flac: straight FLAC encode, NOT a transcode, full bandwidth
  if [[ "$prefix" == "" ]]; then
    gen "${OUT_DIR}/true_lossless.flac" \
      flac --best --silent --force -o "${OUT_DIR}/true_lossless.flac" "$base"
  fi

  # loud / quiet masters: +-8dB into a limiter (loud one has reduced crest factor)
  gen "${OUT_DIR}/${prefix}loud.wav" "$FFMPEG" -y -hide_banner -loglevel error \
    -i "$base" -af "volume=8dB,alimiter=limit=0.95:level=disabled:attack=3:release=60" \
    -c:a pcm_s24le "${OUT_DIR}/${prefix}loud.wav"

  if [[ "$prefix" == "" ]]; then
    gen "${OUT_DIR}/quiet.wav" "$FFMPEG" -y -hide_banner -loglevel error \
      -i "$base" -af "volume=-8dB" \
      -c:a pcm_s24le "${OUT_DIR}/quiet.wav"
  fi

  # tonal tilt: bassy (low-shelf +6dB @120Hz) / bright (high-shelf +6dB @8kHz)
  if [[ "$prefix" == "" ]]; then
    gen "${OUT_DIR}/tilt_bassy.wav" "$FFMPEG" -y -hide_banner -loglevel error \
      -i "$base" -af "bass=g=6:f=120:width_type=q:w=0.7" \
      -c:a pcm_s24le "${OUT_DIR}/tilt_bassy.wav"

    gen "${OUT_DIR}/tilt_bright.wav" "$FFMPEG" -y -hide_banner -loglevel error \
      -i "$base" -af "treble=g=6:f=8000:width_type=q:w=0.7" \
      -c:a pcm_s24le "${OUT_DIR}/tilt_bright.wav"
  fi

  # muffled: lowpass ~4.5kHz. Cascade the (2-pole/12dB-oct) biquad twice for a
  # steeper ~24dB/oct slope so the result reads as clearly dull rather than a
  # gentle tilt; the -3dB point stays at 4.5kHz.
  gen "${OUT_DIR}/${prefix}muffled.wav" "$FFMPEG" -y -hide_banner -loglevel error \
    -i "$base" -af "lowpass=f=4500,lowpass=f=4500" \
    -c:a pcm_s24le "${OUT_DIR}/${prefix}muffled.wav"

  # hiss: add white noise at ~-50dBFS on top of the source
  gen "${OUT_DIR}/${prefix}hiss.wav" "$FFMPEG" -y -hide_banner -loglevel error \
    -i "$base" -f lavfi -i "anoisesrc=color=white:sample_rate=44100:amplitude=0.00316:seed=7" \
    -filter_complex "[1]aformat=channel_layouts=stereo[n];[0][n]amix=inputs=2:duration=first:weights='1 1'[out]" \
    -map "[out]" -c:a pcm_s24le "${OUT_DIR}/${prefix}hiss.wav"

  # mp3 128 / 320 via lame (only for synthetic + real per spec: real only needs mp3_128 for the fake-lossless trap)
  if [[ "$prefix" == "" ]]; then
    gen "${OUT_DIR}/mp3_128.mp3" bash -c \
      "lame --silent -b 128 '$base' '${OUT_DIR}/mp3_128.mp3'"
    gen "${OUT_DIR}/mp3_320.mp3" bash -c \
      "lame --silent -b 320 '$base' '${OUT_DIR}/mp3_320.mp3'"

    # aac 96 / 256 via ffmpeg's audiotoolbox AAC encoder (matches afconvert quality/behavior on macOS)
    gen "${OUT_DIR}/aac_96.m4a" "$FFMPEG" -y -hide_banner -loglevel error \
      -i "$base" -c:a aac_at -b:a 96k -movflags +faststart "${OUT_DIR}/aac_96.m4a"
    gen "${OUT_DIR}/aac_256.m4a" "$FFMPEG" -y -hide_banner -loglevel error \
      -i "$base" -c:a aac_at -b:a 256k -movflags +faststart "${OUT_DIR}/aac_256.m4a"

    # fake-lossless traps: decode a lossy file back to FLAC. Ground truth:
    # these ARE lossy transcodes wearing a lossless container.
    gen "${OUT_DIR}/fake_lossless_mp3128.flac" bash -c \
      "'$FFMPEG' -y -hide_banner -loglevel error -i '${OUT_DIR}/mp3_128.mp3' -ar 44100 -c:a pcm_s24le -f wav - | flac --best --silent --force -o '${OUT_DIR}/fake_lossless_mp3128.flac' -"

    gen "${OUT_DIR}/fake_lossless_aac128.flac" bash -c "
      '$FFMPEG' -y -hide_banner -loglevel error -i '$base' -c:a aac_at -b:a 128k -movflags +faststart '${OUT_DIR}/_tmp_aac128.m4a' && \
      '$FFMPEG' -y -hide_banner -loglevel error -i '${OUT_DIR}/_tmp_aac128.m4a' -ar 44100 -c:a pcm_s24le -f wav - | flac --best --silent --force -o '${OUT_DIR}/fake_lossless_aac128.flac' -
    "
    rm -f "${OUT_DIR}/_tmp_aac128.m4a"
  else
    # real_fake_lossless_mp3128.flac only
    gen "${OUT_DIR}/real_mp3_128.mp3" bash -c \
      "lame --silent -b 128 '$base' '${OUT_DIR}/real_mp3_128.mp3'"
    gen "${OUT_DIR}/real_fake_lossless_mp3128.flac" bash -c \
      "'$FFMPEG' -y -hide_banner -loglevel error -i '${OUT_DIR}/real_mp3_128.mp3' -ar 44100 -c:a pcm_s24le -f wav - | flac --best --silent --force -o '${OUT_DIR}/real_fake_lossless_mp3128.flac' -"
  fi
}

# ---- 3b. Phase 2: provenance-detection cases ------------------------------
#
# Analog-source simulations (gapless -- applied to real_reference.wav, which
# has no quiet passages, on purpose: v2 detectors must not rely on a silent
# window to find hiss/rumble/clicks) and lossy-encode-quality contrasts
# (LAME-tag presence, encoder-era lowpass behavior, intensity-stereo, and
# pre-echo around sharp transients).

GEN_DIR="${OUT_DIR}/_gen"
mkdir -p "$GEN_DIR"

# Small helper scripts are written into _gen/ (regenerated every run, not
# committed -- OUT_DIR lives under gitignored Private/). Keeping them as
# actual files on disk (rather than inline python3 -c one-liners) makes them
# inspectable/tweakable and keeps the shell quoting sane.

write_gen_scripts() {
  cat > "${GEN_DIR}/gen_clicks.py" <<'PYEOF'
#!/usr/bin/env python3
"""Sparse vinyl-click impulse WAV: irregular short wideband spikes,
~20-40 per minute, 0.5-2ms each, amplitude randomized. Mono, 44.1kHz, 24-bit.
Usage: gen_clicks.py <out.wav> <duration_seconds> <seed>
Prints the number of clicks placed to stdout.
"""
import sys, wave, struct, random

out_path, duration, seed = sys.argv[1], float(sys.argv[2]), int(sys.argv[3])
sr = 44100
rng = random.Random(seed)
n_samples = int(duration * sr)
buf = [0.0] * n_samples

rate_per_min = rng.uniform(20, 40)
n_clicks = max(1, round(rate_per_min * duration / 60.0))

placed = []
attempts = 0
while len(placed) < n_clicks and attempts < n_clicks * 200:
    attempts += 1
    t = rng.uniform(0.05, duration - 0.05)
    if all(abs(t - p) > 0.3 for p in placed):
        placed.append(t)
placed.sort()

for t in placed:
    click_len = max(1, int(rng.uniform(0.5, 2.0) / 1000.0 * sr))
    start = int(t * sr)
    amp = rng.uniform(0.5, 0.95)
    for i in range(click_len):
        if start + i >= n_samples:
            break
        decay = pow(2.71828, -6.0 * i / max(1, click_len))
        buf[start + i] += amp * decay * rng.uniform(-1, 1)

buf = [max(-0.98, min(0.98, s)) for s in buf]

with wave.open(out_path, 'wb') as w:
    w.setnchannels(1)
    w.setsampwidth(3)
    w.setframerate(sr)
    frames = bytearray()
    for s in buf:
        frames += struct.pack('<i', int(s * 8388607))[0:3]
    w.writeframes(bytes(frames))

print(len(placed))
PYEOF

  cat > "${GEN_DIR}/gen_crackle.py" <<'PYEOF'
#!/usr/bin/env python3
"""Dense low-level vinyl crackle: many short random-amplitude micro-impulses
per second (much denser/quieter than discrete clicks). Mono, 44.1kHz, 24-bit.
Usage: gen_crackle.py <out.wav> <duration_seconds> <seed> [density_per_sec] [peak_amp]
"""
import sys, wave, struct, random

out_path, duration, seed = sys.argv[1], float(sys.argv[2]), int(sys.argv[3])
density_per_sec = float(sys.argv[4]) if len(sys.argv) > 4 else 120.0
peak_amp = float(sys.argv[5]) if len(sys.argv) > 5 else 0.15
sr = 44100
rng = random.Random(seed)
n_samples = int(duration * sr)
buf = [0.0] * n_samples

n_impulses = int(density_per_sec * duration)
for _ in range(n_impulses):
    t = rng.uniform(0, duration - 0.01)
    start = int(t * sr)
    length = max(1, int(rng.uniform(0.1, 0.6) / 1000.0 * sr))
    amp = peak_amp * (rng.uniform(0.15, 1.0) ** 2)
    for i in range(length):
        if start + i >= n_samples:
            break
        decay = pow(2.71828, -8.0 * i / max(1, length))
        buf[start + i] += amp * decay * rng.uniform(-1, 1)

buf = [max(-0.9, min(0.9, s)) for s in buf]

with wave.open(out_path, 'wb') as w:
    w.setnchannels(1)
    w.setsampwidth(3)
    w.setframerate(sr)
    frames = bytearray()
    for s in buf:
        frames += struct.pack('<i', int(s * 8388607))[0:3]
    w.writeframes(bytes(frames))
PYEOF

  cat > "${GEN_DIR}/gen_transients.py" <<'PYEOF'
#!/usr/bin/env python3
"""Synthetic percussion transients: sharp castanet-like noise bursts with
instant onset, ~4/s on an irregular grid, over near-silence. Stereo,
44.1kHz, 24-bit. Peaks target ~-6 dBFS. Usage: gen_transients.py <out.wav> <duration_seconds> <seed>
"""
import sys, wave, struct, random

out_path, duration, seed = sys.argv[1], float(sys.argv[2]), int(sys.argv[3])
sr = 44100
rng = random.Random(seed)
n_samples = int(duration * sr)
bufL = [0.0] * n_samples
bufR = [0.0] * n_samples

t = rng.uniform(0.02, 0.15)
events = []
while t < duration - 0.02:
    events.append(t)
    t += 0.25 * rng.uniform(0.6, 1.4)

target_peak = 0.5011872336272722 * 1.18  # 10^(-6/20), boosted for envelope/pan headroom loss

for t in events:
    start = int(t * sr)
    burst_len = max(1, int(rng.uniform(1.0, 5.0) / 1000.0 * sr))
    amp = target_peak * rng.uniform(0.7, 1.0)
    pan = rng.uniform(0.3, 0.7)
    for i in range(burst_len):
        if start + i >= n_samples:
            break
        decay = pow(2.71828, -5.0 * i / max(1, burst_len))
        s = amp * decay * rng.uniform(-1, 1)
        bufL[start + i] += s * (1.0 - pan) * 1.4
        bufR[start + i] += s * pan * 1.4

def clip(b):
    return [max(-0.98, min(0.98, s)) for s in b]
bufL, bufR = clip(bufL), clip(bufR)

with wave.open(out_path, 'wb') as w:
    w.setnchannels(2)
    w.setsampwidth(3)
    w.setframerate(sr)
    frames = bytearray()
    for l, r in zip(bufL, bufR):
        for s in (l, r):
            frames += struct.pack('<i', int(s * 8388607))[0:3]
    w.writeframes(bytes(frames))

print(len(events))
PYEOF
}

write_gen_scripts

VINYL_GROUND_TRUTH="${OUT_DIR}/_vinyl_click_count.txt"

# real_vinyl_sim.wav: gapless vinyl-rip simulation applied to real_reference.wav
#   (a) stereo-decorrelated hiss ~-55dBFS (two independently seeded noise sources, one per channel)
#   (b) clicks: precomputed sparse impulse WAV (gen_clicks.py), ~20-40/min
#   (c) crackle: dense low-level impulsive noise (gen_crackle.py)
#   (d) rumble: <30Hz noise in the SIDE channel only (L=+n, R=-n), ~-35dBFS
build_real_vinyl_sim() {
  local out="${OUT_DIR}/real_vinyl_sim.wav"
  if [[ -f "$out" && "$FORCE" -ne 1 ]]; then
    echo "skip  (exists) real_vinyl_sim.wav"
    return 0
  fi
  echo "make  real_vinyl_sim.wav"
  local base="${OUT_DIR}/real_reference.wav"
  local dur=30

  local click_wav="${GEN_DIR}/real_vinyl_clicks.wav"
  local n_clicks
  n_clicks=$(python3 "${GEN_DIR}/gen_clicks.py" "$click_wav" "$dur" 501)
  echo "real_vinyl_sim.wav intended click count: ${n_clicks}" > "$VINYL_GROUND_TRUTH"

  local crackle_wav="${GEN_DIR}/real_vinyl_crackle.wav"
  python3 "${GEN_DIR}/gen_crackle.py" "$crackle_wav" "$dur" 502 120 0.15

  "$FFMPEG" -y -hide_banner -loglevel error \
    -i "$base" \
    -f lavfi -i "anoisesrc=color=white:sample_rate=44100:duration=${dur}:amplitude=1.0:seed=511" \
    -f lavfi -i "anoisesrc=color=white:sample_rate=44100:duration=${dur}:amplitude=1.0:seed=512" \
    -i "$click_wav" \
    -i "$crackle_wav" \
    -f lavfi -i "anoisesrc=color=brown:sample_rate=44100:duration=${dur}:amplitude=1.0:seed=513" \
    -filter_complex "\
[1]volume=0.00282[hl]; \
[2]volume=0.00282[hr]; \
[hl][hr]join=inputs=2:channel_layout=stereo[hiss]; \
[3]pan=stereo|c0=c0|c1=c0[clickstereo]; \
[4]pan=stereo|c0=c0|c1=c0[cracklestereo]; \
[5]lowpass=f=30,lowpass=f=30,volume=0.263[rumble]; \
[rumble]pan=stereo|c0=c0|c1=-1*c0[rumblestereo]; \
[0][hiss]amix=inputs=2:duration=first:weights='1 1':normalize=0[s1]; \
[s1][clickstereo]amix=inputs=2:duration=first:weights='1 1':normalize=0[s2]; \
[s2][cracklestereo]amix=inputs=2:duration=first:weights='1 1':normalize=0[s3]; \
[s3][rumblestereo]amix=inputs=2:duration=first:weights='1 1':normalize=0[out]" \
    -map "[out]" -ar 44100 -c:a pcm_s24le "$out"
}

# real_tape_sim.wav: stereo-decorrelated hiss only, ~-50dBFS, gapless on real_reference.wav
build_real_tape_sim() {
  local out="${OUT_DIR}/real_tape_sim.wav"
  gen "$out" bash -c "
    '$FFMPEG' -y -hide_banner -loglevel error \
      -i '${OUT_DIR}/real_reference.wav' \
      -f lavfi -i 'anoisesrc=color=white:sample_rate=44100:duration=30:amplitude=1.0:seed=611' \
      -f lavfi -i 'anoisesrc=color=white:sample_rate=44100:duration=30:amplitude=1.0:seed=612' \
      -filter_complex \"[1]volume=0.0053[hl];[2]volume=0.0053[hr];[hl][hr]join=inputs=2:channel_layout=stereo[hiss];[0][hiss]amix=inputs=2:duration=first:weights='1 1':normalize=0[out]\" \
      -map '[out]' -ar 44100 -c:a pcm_s24le '$out'
  "
}

# mp3_192_modern.mp3: LAME CBR 192, default modern settings (keeps ~19kHz, LAME/Xing tag present)
build_mp3_192_modern() {
  local out="${OUT_DIR}/mp3_192_modern.mp3"
  gen "$out" bash -c \
    "lame --silent -b 192 '${OUT_DIR}/reference.wav' '$out'"
}

# mp3_192_early.mp3: simulated late-90s encoder -- worst quality, 16kHz lowpass,
# -t suppresses the Xing/LAME tag entirely (no marker anywhere near the file start).
build_mp3_192_early() {
  local out="${OUT_DIR}/mp3_192_early.mp3"
  gen "$out" bash -c \
    "lame -b 192 -q 9 --lowpass 16 -t --silent '${OUT_DIR}/reference.wav' '$out'"
}

# mp3_192_intensity.mp3: intensity-stereo simulation. Split at 8kHz (acrossover,
# 8th order / 48dB-oct), downmix the high band to mono and feed it identically
# to both channels, keep the low band's original stereo image, recombine, then
# lame CBR 192. This IS a simulation of intensity-stereo joint coding, not the
# real thing -- ground truth noted in the manifest.
build_mp3_192_intensity() {
  local out="${OUT_DIR}/mp3_192_intensity.mp3"
  if [[ -f "$out" && "$FORCE" -ne 1 ]]; then
    echo "skip  (exists) mp3_192_intensity.mp3"
    return 0
  fi
  echo "make  mp3_192_intensity.mp3"
  local tmp_wav="${GEN_DIR}/_tmp_intensity.wav"
  "$FFMPEG" -y -hide_banner -loglevel error \
    -i "${OUT_DIR}/reference.wav" \
    -filter_complex "\
[0]acrossover=split=8000:order=8th[low][high]; \
[high]pan=mono|c0=0.5*c0+0.5*c1[highmono]; \
[highmono]pan=stereo|c0=c0|c1=c0[highstereo]; \
[low][highstereo]amix=inputs=2:duration=first:weights='1 1':normalize=0[out]" \
    -map "[out]" -c:a pcm_s24le "$tmp_wav"
  lame --silent -b 192 "$tmp_wav" "$out"
  rm -f "$tmp_wav"
}

# transient_reference.wav: 30s synthetic percussion, sharp castanet-like
# attacks over near-silence -- pre-echo probe material.
build_transient_reference() {
  local out="${OUT_DIR}/transient_reference.wav"
  if [[ -f "$out" && "$FORCE" -ne 1 ]]; then
    echo "skip  (exists) transient_reference.wav"
    return 0
  fi
  echo "make  transient_reference.wav"
  python3 "${GEN_DIR}/gen_transients.py" "$out" 30 701 > "${OUT_DIR}/_transient_event_count.txt"
}

# transient_mp3_128.mp3 / transient_mp3_320.mp3: lame CBR 128/320 of the
# transient probe -- 128 shows pre-echo, 320 shows little (contrast pair).
# transient_fake_lossless_mp3128.flac: decode the 128kbps MP3 back to FLAC --
# pre-echo survives into the fake-lossless case, same trap as the v1 files.
build_transient_variants() {
  local base="${OUT_DIR}/transient_reference.wav"

  gen "${OUT_DIR}/transient_mp3_128.mp3" bash -c \
    "lame --silent -b 128 '$base' '${OUT_DIR}/transient_mp3_128.mp3'"
  gen "${OUT_DIR}/transient_mp3_320.mp3" bash -c \
    "lame --silent -b 320 '$base' '${OUT_DIR}/transient_mp3_320.mp3'"

  gen "${OUT_DIR}/transient_fake_lossless_mp3128.flac" bash -c \
    "'$FFMPEG' -y -hide_banner -loglevel error -i '${OUT_DIR}/transient_mp3_128.mp3' -ar 44100 -c:a pcm_s24le -f wav - | flac --best --silent --force -o '${OUT_DIR}/transient_fake_lossless_mp3128.flac' -"
}

# ---- 4. Verification -------------------------------------------------------
#
# For every generated audio file: ffprobe format/rate/depth, integrated LUFS
# via loudnorm summary, and HF energy above 17kHz via highpass+astats RMS.
# Results are written to _verification.tsv (used to populate the manifest).
verify_all() {
  echo "==> Verifying outputs and rendering spectrograms..."
  : > "$DATA_FILE"
  printf "file\tformat\tsample_rate\tbit_depth_or_codec\tintegrated_lufs\ttrue_peak_dbtp\thf_rms_above_17k_db\n" >> "$DATA_FILE"

  local f
  for f in "${OUT_DIR}"/*.wav "${OUT_DIR}"/*.flac "${OUT_DIR}"/*.mp3 "${OUT_DIR}"/*.m4a; do
    [[ -e "$f" ]] || continue
    local base
    base="$(basename "$f")"
    echo "  verify: $base"

    # ffprobe basics
    local fmt rate depth
    fmt=$("$FFPROBE" -v error -show_entries format=format_name -of default=nk=1:nw=1 "$f" 2>/dev/null || echo "?")
    rate=$("$FFPROBE" -v error -select_streams a:0 -show_entries stream=sample_rate -of default=nk=1:nw=1 "$f" 2>/dev/null || echo "?")
    depth=$("$FFPROBE" -v error -select_streams a:0 -show_entries stream=bits_per_raw_sample,codec_name -of default=nk=1:nw=1 "$f" 2>/dev/null | tr '\n' '/' || echo "?")

    # integrated LUFS (single pass, "measured" input stats from loudnorm)
    local loud_line lufs tp
    loud_line=$("$FFMPEG" -hide_banner -i "$f" -af "loudnorm=print_format=summary" -f null - 2>&1 || true)
    lufs=$(echo "$loud_line" | grep "Input Integrated" | awk '{print $3}')
    tp=$(echo "$loud_line" | grep "Input True Peak" | awk '{print $4}')
    [[ -z "$lufs" ]] && lufs="n/a"
    [[ -z "$tp" ]] && tp="n/a"

    # HF energy above 17kHz: RMS level in dBFS from astats
    local hf_line hf_rms
    hf_line=$("$FFMPEG" -hide_banner -i "$f" -af "highpass=f=17000,astats=measure_overall=RMS_level" -f null - 2>&1 || true)
    hf_rms=$(echo "$hf_line" | grep -o "RMS level dB: [-0-9.infa]*" | tail -1 | awk '{print $4}')
    [[ -z "$hf_rms" ]] && hf_rms="n/a"

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$base" "$fmt" "$rate" "$depth" "$lufs" "$tp" "$hf_rms" >> "$DATA_FILE"

    spectrogram "$f"
  done

  echo "==> Verification data written to ${DATA_FILE}"
}

# ---- 4b. Phase 2 verification: provenance-specific measurements -----------
#
# Extra measurements the phase-1 pass doesn't cover: stereo decorrelation
# (RMS of L-R vs L+R above 10kHz), side-channel sub-30Hz rumble level,
# LAME/Xing/Info tag byte-offset presence, and a highpass cutoff sweep
# (14-20kHz) for the mp3_192_early/modern contrast pair. Written to a
# separate _verification_phase2.tsv so the phase-1 table format stays stable.
PHASE2_DATA_FILE="${OUT_DIR}/_verification_phase2.tsv"

# RMS in dBFS of mono-downmixed (mid or side) signal, optionally band-limited
_pan_rms() {
  local f="$1" expr="$2" band="$3"  # band: "" | "highpass=f=NNNN" | "lowpass=f=NNNN"
  local chain="pan=mono|c0=${expr}"
  [[ -n "$band" ]] && chain="${chain},${band}"
  chain="${chain},astats=measure_overall=RMS_level"
  local line
  line=$("$FFMPEG" -hide_banner -i "$f" -af "$chain" -f null - 2>&1 || true)
  echo "$line" | grep -o "RMS level dB: [-0-9.infa]*" | tail -1 | awk '{print $4}'
}

# byte offset of the first occurrence of a marker string in a file, or -1
_tag_offset() {
  local f="$1" marker="$2"
  python3 -c "
import sys
data = open(sys.argv[1], 'rb').read()
print(data.find(sys.argv[2].encode()))
" "$f" "$marker"
}

verify_phase2() {
  echo "==> Verifying phase-2 (provenance) specifics..."
  : > "$PHASE2_DATA_FILE"
  printf "file\tmeasurement\tvalue\n" >> "$PHASE2_DATA_FILE"

  # --- decorrelation: RMS(L-R) vs RMS(L+R) above 10kHz, for the hiss cases ---
  local f base side mid
  for f in "real_hiss.wav" "hiss.wav" "real_tape_sim.wav" "real_vinyl_sim.wav"; do
    local path="${OUT_DIR}/${f}"
    [[ -e "$path" ]] || continue
    side=$(_pan_rms "$path" "0.5*c0-0.5*c1" "highpass=f=10000")
    mid=$(_pan_rms "$path" "0.5*c0+0.5*c1" "highpass=f=10000")
    printf "%s\thf_side_rms_db\t%s\n" "$f" "${side:-n/a}" >> "$PHASE2_DATA_FILE"
    printf "%s\thf_mid_rms_db\t%s\n" "$f" "${mid:-n/a}" >> "$PHASE2_DATA_FILE"
  done

  # --- vinyl sim: side-channel <30Hz rumble level + intended click count ---
  if [[ -e "${OUT_DIR}/real_vinyl_sim.wav" ]]; then
    side=$(_pan_rms "${OUT_DIR}/real_vinyl_sim.wav" "0.5*c0-0.5*c1" "lowpass=f=30")
    mid=$(_pan_rms "${OUT_DIR}/real_vinyl_sim.wav" "0.5*c0+0.5*c1" "lowpass=f=30")
    printf "real_vinyl_sim.wav\tside_lt30hz_rms_db\t%s\n" "${side:-n/a}" >> "$PHASE2_DATA_FILE"
    printf "real_vinyl_sim.wav\tmid_lt30hz_rms_db\t%s\n" "${mid:-n/a}" >> "$PHASE2_DATA_FILE"
    if [[ -f "$VINYL_GROUND_TRUTH" ]]; then
      local click_count
      click_count=$(grep -o '[0-9]\+' "$VINYL_GROUND_TRUTH" | tail -1)
      printf "real_vinyl_sim.wav\tintended_click_count\t%s\n" "${click_count:-n/a}" >> "$PHASE2_DATA_FILE"
    fi
  fi
  # baseline side/mid for real_reference.wav, for contrast
  if [[ -e "${OUT_DIR}/real_reference.wav" ]]; then
    side=$(_pan_rms "${OUT_DIR}/real_reference.wav" "0.5*c0-0.5*c1" "lowpass=f=30")
    mid=$(_pan_rms "${OUT_DIR}/real_reference.wav" "0.5*c0+0.5*c1" "lowpass=f=30")
    printf "real_reference.wav\tside_lt30hz_rms_db\t%s\n" "${side:-n/a}" >> "$PHASE2_DATA_FILE"
    printf "real_reference.wav\tmid_lt30hz_rms_db\t%s\n" "${mid:-n/a}" >> "$PHASE2_DATA_FILE"
  fi

  # --- mp3_192_early vs mp3_192_modern: cutoff sweep + tag presence ---
  local rate
  for f in "mp3_192_early.mp3" "mp3_192_modern.mp3" "mp3_192_intensity.mp3"; do
    local path="${OUT_DIR}/${f}"
    [[ -e "$path" ]] || continue
    for hz in 14000 15000 16000 17000 18000 19000 20000; do
      rate=$("$FFMPEG" -hide_banner -i "$path" -af "highpass=f=${hz},astats=measure_overall=RMS_level" -f null - 2>&1 | grep -o "RMS level dB: [-0-9.infa]*" | tail -1 | awk '{print $4}')
      printf "%s\thp_%dhz_rms_db\t%s\n" "$f" "$hz" "${rate:-n/a}" >> "$PHASE2_DATA_FILE"
    done
    local off_lame off_xing off_info fsize
    off_lame=$(_tag_offset "$path" "LAME")
    off_xing=$(_tag_offset "$path" "Xing")
    off_info=$(_tag_offset "$path" "Info")
    fsize=$(stat -f%z "$path" 2>/dev/null || stat -c%s "$path")
    printf "%s\tlame_tag_offset\t%s\n" "$f" "$off_lame" >> "$PHASE2_DATA_FILE"
    printf "%s\txing_tag_offset\t%s\n" "$f" "$off_xing" >> "$PHASE2_DATA_FILE"
    printf "%s\tinfo_tag_offset\t%s\n" "$f" "$off_info" >> "$PHASE2_DATA_FILE"
    printf "%s\tfile_size_bytes\t%s\n" "$f" "$fsize" >> "$PHASE2_DATA_FILE"
  done

  # --- intensity-stereo: decorrelation above/below the 8kHz split ---
  if [[ -e "${OUT_DIR}/mp3_192_intensity.mp3" ]]; then
    local path="${OUT_DIR}/mp3_192_intensity.mp3"
    side=$(_pan_rms "$path" "0.5*c0-0.5*c1" "highpass=f=8000")
    mid=$(_pan_rms "$path" "0.5*c0+0.5*c1" "highpass=f=8000")
    printf "mp3_192_intensity.mp3\tside_above8k_rms_db\t%s\n" "${side:-n/a}" >> "$PHASE2_DATA_FILE"
    printf "mp3_192_intensity.mp3\tmid_above8k_rms_db\t%s\n" "${mid:-n/a}" >> "$PHASE2_DATA_FILE"
    side=$(_pan_rms "$path" "0.5*c0-0.5*c1" "lowpass=f=8000")
    mid=$(_pan_rms "$path" "0.5*c0+0.5*c1" "lowpass=f=8000")
    printf "mp3_192_intensity.mp3\tside_below8k_rms_db\t%s\n" "${side:-n/a}" >> "$PHASE2_DATA_FILE"
    printf "mp3_192_intensity.mp3\tmid_below8k_rms_db\t%s\n" "${mid:-n/a}" >> "$PHASE2_DATA_FILE"
  fi
  # reference.wav baseline for the same split, for contrast
  if [[ -e "${OUT_DIR}/reference.wav" ]]; then
    local path="${OUT_DIR}/reference.wav"
    side=$(_pan_rms "$path" "0.5*c0-0.5*c1" "highpass=f=8000")
    mid=$(_pan_rms "$path" "0.5*c0+0.5*c1" "highpass=f=8000")
    printf "reference.wav\tside_above8k_rms_db\t%s\n" "${side:-n/a}" >> "$PHASE2_DATA_FILE"
    printf "reference.wav\tmid_above8k_rms_db\t%s\n" "${mid:-n/a}" >> "$PHASE2_DATA_FILE"
  fi

  # --- transient set: peak level + rough pre-echo probe (RMS in the 40ms pre-onset window is
  # hard to automate generically here; the manifest documents visual/spectrogram confirmation) ---
  for f in "transient_reference.wav" "transient_mp3_128.mp3" "transient_mp3_320.mp3" "transient_fake_lossless_mp3128.flac"; do
    local path="${OUT_DIR}/${f}"
    [[ -e "$path" ]] || continue
    local peak
    peak=$("$FFMPEG" -hide_banner -i "$path" -af "astats=measure_overall=Peak_level" -f null - 2>&1 | grep -o "Peak level dB: [-0-9.infa]*" | tail -1 | awk '{print $4}')
    printf "%s\tpeak_level_db\t%s\n" "$f" "${peak:-n/a}" >> "$PHASE2_DATA_FILE"
  done
  if [[ -f "${OUT_DIR}/_transient_event_count.txt" ]]; then
    printf "transient_reference.wav\tevent_count\t%s\n" "$(cat "${OUT_DIR}/_transient_event_count.txt")" >> "$PHASE2_DATA_FILE"
  fi

  echo "==> Phase-2 verification data written to ${PHASE2_DATA_FILE}"
}

# ---- Main -------------------------------------------------------------

build_reference
build_real_reference

make_variants_for "reference.wav" ""
make_variants_for "real_reference.wav" "real_"

build_real_vinyl_sim
build_real_tape_sim
build_mp3_192_modern
build_mp3_192_early
build_mp3_192_intensity
build_transient_reference
build_transient_variants

verify_all
verify_phase2

echo "==> Done. Corpus at: ${OUT_DIR}"
echo "==> $(find "${OUT_DIR}" -maxdepth 1 -type f | wc -l | tr -d ' ') files, $(find "${SPEC_DIR}" -type f | wc -l | tr -d ' ') spectrograms."
