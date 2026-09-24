#!/bin/bash
# Build TroisLoader.bundle and trois-inject tool

set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="$DIR/TroisLoader.bundle"

echo "Building TroisLoader.bundle..."
rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/Contents/MacOS"

# Compile the loader bundle
clang -fobjc-arc -fmodules \
    -framework AppKit \
    -framework Foundation \
    -bundle \
    -o "$OUTPUT/Contents/MacOS/TroisLoader" \
    "$DIR/TroisLoader.m"

cp "$DIR/Info.plist" "$OUTPUT/Contents/"
echo "Built: $OUTPUT"

echo "Building trois-inject tool..."
# Compile the injector tool
clang -o "$DIR/trois-inject" \
    -I"$DIR" \
    "$DIR/MachInjector.c" \
    "$DIR/trois-inject.c"

# Sign with entitlements for task_for_pid
codesign --force --sign - --entitlements "$DIR/trois-inject.entitlements" "$DIR/trois-inject"

echo "Built: $DIR/trois-inject"
echo ""
echo "Done!"
