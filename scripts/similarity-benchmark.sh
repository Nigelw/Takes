#!/bin/bash
# UI-independent analyzer diagnostics. No files are uploaded or altered.
# Usage: bash scripts/similarity-benchmark.sh compare FILE FILE [FILE ...]
#        bash scripts/similarity-benchmark.sh batch FILE FILE [FILE ...]
#        bash scripts/similarity-benchmark.sh inventory [DIRECTORY]
#        bash scripts/similarity-benchmark.sh manifest MANIFEST.json
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${SIMILARITY_BUILD_DIR:-/private/tmp/takes-similarity-cli}"
mkdir -p "$BUILD_DIR"
swiftc -O -parse-as-library -module-cache-path "$BUILD_DIR/module-cache" \
    -framework AVFoundation -framework Accelerate \
    "$REPO_DIR/Sources/Takes/Models.swift" \
    "$REPO_DIR/Sources/Takes/TrackAligner.swift" \
    "$REPO_DIR/Sources/Takes/TrackSimilarityAnalyzer.swift" \
    "$REPO_DIR/scripts/similarity-cli/main.swift" \
    -o "$BUILD_DIR/similarity-cli"
cd "$REPO_DIR"
"$BUILD_DIR/similarity-cli" "$@"
