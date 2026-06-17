#!/usr/bin/env bash
# Usage: bash .claude/skills/run-takes/smoke.sh [--no-build]
# Kills any running Takes instance, optionally rebuilds, then launches the app.
# Run from the Takes/ repo root.
set -euo pipefail

APP=".derived-data/Build/Products/Debug/Takes.app"
BUNDLE_ID="com.nigelwarren.Takes"

# Kill any running instance
pkill -x Takes 2>/dev/null || true
sleep 0.5

if [[ "${1:-}" != "--no-build" ]]; then
  echo "Building Takes..."
  xcodebuild \
    -project Takes.xcodeproj \
    -scheme Takes \
    -configuration Debug \
    -derivedDataPath .derived-data \
    build 2>&1 | grep -E "^(Build|error:|warning:|CodeSign|FAILED|SUCCEEDED)" || true
fi

echo "Launching $APP..."
open "$APP"

# Wait until the process appears (up to 10 s)
for i in $(seq 1 20); do
  if pgrep -x Takes > /dev/null 2>&1; then
    echo "Takes is running (PID $(pgrep -x Takes))."
    exit 0
  fi
  sleep 0.5
done

echo "ERROR: Takes did not start within 10 seconds." >&2
exit 1
