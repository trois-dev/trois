#!/bin/bash
# Build TroisInjector command-line tool

set -e

cd "$(dirname "$0")"

# Signs with the maintainer's Developer ID when it's in the keychain, ad hoc otherwise.
IDENTITY="${TROIS_SIGN_IDENTITY:-Developer ID Application: Mateo Yadarola (CL6XWJCS9R)}"
[[ "$(security find-identity -v -p codesigning)" == *"$IDENTITY"* ]] || IDENTITY=-

echo "Building TroisInjector..."

# Injection only supports arm64 targets, see Injector.swift.
clang -o com.trois.app.Injector \
    main.m UniversalInj.c \
    -arch arm64 \
    -mmacosx-version-min=11.0 \
    -fobjc-arc \
    -O2 \
    -Wall \
    -framework Foundation

codesign --force --sign "$IDENTITY" \
    --entitlements TroisInjector.entitlements \
    --options runtime \
    com.trois.app.Injector

echo "Built: com.trois.app.Injector"
