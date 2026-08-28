#!/bin/bash
# Compiles the UI-independent analysis engine sources plus the benchmark CLI
# (scripts/analysis-cli/main.swift) and runs it against the test corpus.
#
#   scripts/analysis-benchmark.sh                          # benchmark the corpus
#   scripts/analysis-benchmark.sh analyze F1 F2…           # ad-hoc metrics
#   scripts/analysis-benchmark.sh compare F1 F2…           # ad-hoc comparison
#   scripts/analysis-benchmark.sh compare-benchmark        # comparative pairs
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Private/ lives at the main checkout root, not in worktrees.
COMMON_ROOT="$(cd "$(git -C "$REPO_DIR" rev-parse --git-common-dir)/.." && pwd)"
CORPUS_DIR="${ANALYSIS_CORPUS_DIR:-$COMMON_ROOT/Private/Analysis Corpus}"
BUILD_DIR="$REPO_DIR/.build/analysis-cli"
BINARY="$BUILD_DIR/analysis-cli"

mkdir -p "$BUILD_DIR"

ENGINE_SOURCES=(
    "$REPO_DIR/Sources/Takes/Analysis/AnalysisModels.swift"
    "$REPO_DIR/Sources/Takes/Analysis/AnalysisModule.swift"
    "$REPO_DIR/Sources/Takes/Analysis/AnalysisDSP.swift"
    "$REPO_DIR/Sources/Takes/Analysis/AnalysisVerdicts.swift"
    "$REPO_DIR/Sources/Takes/Analysis/AnalogSourceDSP.swift"
    "$REPO_DIR/Sources/Takes/Analysis/LossyArtifactDSP.swift"
    "$REPO_DIR/Sources/Takes/Analysis/MP3BitstreamInspector.swift"
    "$REPO_DIR/Sources/Takes/Analysis/SourceInference.swift"
    "$REPO_DIR/Sources/Takes/Analysis/AudioAnalysisEngine.swift"
    "$REPO_DIR/Sources/Takes/Analysis/ComparativeModels.swift"
    "$REPO_DIR/Sources/Takes/Analysis/PairAlignment.swift"
    "$REPO_DIR/Sources/Takes/Analysis/ComparativeInference.swift"
    "$REPO_DIR/Sources/Takes/Analysis/ComparativeAnalysisEngine.swift"
    "$REPO_DIR/Sources/Takes/TrackAligner.swift"
    "$REPO_DIR/Sources/Takes/Models.swift"
    "$REPO_DIR/Sources/Takes/Analysis/SpectrogramRenderer.swift"
)

# Rebuild only when any input is newer than the binary.
needs_build=0
if [[ ! -x "$BINARY" ]]; then
    needs_build=1
else
    for source in "${ENGINE_SOURCES[@]}" "$REPO_DIR/scripts/analysis-cli/main.swift" \
        "$REPO_DIR/scripts/analysis-cli/comparative.swift"; do
        [[ "$source" -nt "$BINARY" ]] && needs_build=1
    done
fi

if [[ "$needs_build" == 1 ]]; then
    echo "building analysis-cli…" >&2
    swiftc -O \
        -framework AVFoundation -framework Accelerate -framework CoreGraphics \
        "${ENGINE_SOURCES[@]}" \
        "$REPO_DIR/scripts/analysis-cli/main.swift" \
        "$REPO_DIR/scripts/analysis-cli/comparative.swift" \
        -o "$BINARY"
fi

mode="${1:-benchmark}"
if [[ "$mode" == "benchmark" || "$mode" == "compare-benchmark" ]]; then
    if [[ ! -d "$CORPUS_DIR" ]]; then
        echo "corpus not found at $CORPUS_DIR — run scripts/make-analysis-corpus.sh first" >&2
        exit 1
    fi
    exec "$BINARY" "$mode" "$CORPUS_DIR"
else
    exec "$BINARY" "$@"
fi
