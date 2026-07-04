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

# ---- Main -------------------------------------------------------------

build_reference
build_real_reference

make_variants_for "reference.wav" ""
make_variants_for "real_reference.wav" "real_"

verify_all

echo "==> Done. Corpus at: ${OUT_DIR}"
echo "==> $(find "${OUT_DIR}" -maxdepth 1 -type f | wc -l | tr -d ' ') files, $(find "${SPEC_DIR}" -type f | wc -l | tr -d ' ') spectrograms."
