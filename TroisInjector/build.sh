#!/bin/bash
# Build TroisInjector command-line tool

set -e

cd "$(dirname "$0")"

echo "Building TroisInjector..."

# Compile UniversalInj.c
clang -c UniversalInj.c -o UniversalInj.o \
    -arch arm64 \
    -mmacosx-version-min=11.0 \
    -O2

# Compile main.m
clang -c main.m -o main.o \
    -arch arm64 \
    -mmacosx-version-min=11.0 \
    -fobjc-arc \
    -O2

# Link
clang -o com.trois.app.Injector \
    main.o UniversalInj.o \
    -arch arm64 \
    -mmacosx-version-min=11.0 \
    -framework Foundation

# Sign with Developer ID and entitlements
codesign --force --sign "Developer ID Application: Mateo Yadarola (CL6XWJCS9R)" \
    --entitlements TroisInjector.entitlements \
    --options runtime \
    com.trois.app.Injector

# Cleanup
rm -f *.o

echo "Built: com.trois.app.Injector"
