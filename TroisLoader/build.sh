#!/bin/bash
# Build TroisLoader.bundle

set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="$DIR/TroisLoader.bundle"

echo "Building TroisLoader.bundle..."
rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/Contents/MacOS"

# arm64 only, like the injector.
clang -fobjc-arc -fmodules \
    -arch arm64 \
    -mmacosx-version-min=11.0 \
    -framework AppKit \
    -framework Foundation \
    -bundle \
    -o "$OUTPUT/Contents/MacOS/TroisLoader" \
    "$DIR/TroisLoader.m"

cp "$DIR/Info.plist" "$OUTPUT/Contents/"
echo "Built: $OUTPUT"
