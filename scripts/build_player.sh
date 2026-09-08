#!/bin/bash
#
# build_player.sh
# Compile bh_player.swift into bin/bh_player.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SOURCE="$PROJECT_DIR/bh_player.swift"
BIN_DIR="$PROJECT_DIR/bin"
OUTPUT="$BIN_DIR/bh_player"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "Error: swiftc not found. Install Xcode Command Line Tools:" >&2
    echo "  xcode-select --install" >&2
    exit 1
fi

mkdir -p "$BIN_DIR"

echo "Building bh_player..."
echo "  source: $SOURCE"
echo "  output: $OUTPUT"

swiftc \
    -O \
    -module-cache-path "${TMPDIR:-/tmp}/bh_player-module-cache" \
    -framework AudioToolbox \
    -framework CoreAudio \
    -framework Foundation \
    "$SOURCE" \
    -o "$OUTPUT"

chmod +x "$OUTPUT"
echo "Built: $OUTPUT"
