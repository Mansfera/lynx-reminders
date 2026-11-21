#!/bin/bash
# Launches the built app on demo data and captures its main window.
#   Tools/screenshot.sh <out.png> <light|dark> <screen> [width height]
# screen: today | list:<name> | reminder:<title> | smart:<name> | signin
# Uses a scratch data folder (never your real reminders).
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$1"; LOOK="$2"; SCREEN="$3"
DATA="${TMPDIR:-/tmp}/lynx-shot-$$"
mkdir -p "$DATA"
defaults delete com.mansfera.lynxreminders.demo >/dev/null 2>&1 || true
pkill -f "Lynx Reminders.app/Contents/MacOS" >/dev/null 2>&1 || true
sleep 0.5
open -n "$DIR/build/Lynx Reminders.app" --env LYNX_DATA_DIR="$DATA" --env LYNX_DEMO=1 \
    --env LYNX_SCREEN="$SCREEN" --env LYNX_APPEARANCE="$LOOK"
sleep "${WAIT:-4}"
for _ in 1 2 3 4 5 6 7 8 9 10; do ID=$(swift "$DIR/Tools/window-id.swift" "Lynx Reminders" | head -1); [ -n "$ID" ] && break; sleep 1; done
screencapture -o -l"$ID" "$OUT"
echo "$OUT (window $ID)"
