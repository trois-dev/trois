#!/bin/bash
# Builds Trois and replaces /Applications/Trois.app. Pass --no-deploy to only build.

set -eo pipefail

# Get the directory where this script is located
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="Trois.app"
LOADER_DIR="$PROJECT_DIR/TroisLoader"
INJECTOR_DIR="$PROJECT_DIR/TroisInjector"

# Signs with the maintainer's Developer ID when it's in the keychain, ad hoc otherwise.
# The Developer ID keeps Accessibility access across rebuilds; ad hoc builds must be re-allowed.
IDENTITY="${TROIS_SIGN_IDENTITY:-Developer ID Application: Mateo Yadarola (CL6XWJCS9R)}"
[[ "$(security find-identity -v -p codesigning)" == *"$IDENTITY"* ]] || IDENTITY=-

# Build TroisLoader first
echo "Building TroisLoader..."
"$LOADER_DIR/build.sh"

# Build TroisInjector privileged helper
echo "Building TroisInjector..."
"$INJECTOR_DIR/build.sh"

echo "Building Trois..."
xcodebuild -project "$PROJECT_DIR/Eppie.xcodeproj" \
    -scheme Eppie \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    clean build 2>&1 | { grep -E "(error:|warning:|BUILD)" || true; }

APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME"

if [ ! -d "$APP_PATH" ]; then
    echo "Build failed - app not found at $APP_PATH"
    exit 1
fi

# Copy injection tools to app bundle Resources
echo "Bundling injection tools..."
RESOURCES_PATH="$APP_PATH/Contents/Resources"
cp -R "$LOADER_DIR/TroisLoader.bundle" "$RESOURCES_PATH/"

# Injector.swift installs the helper from here with an admin prompt.
echo "Bundling privileged helper..."
LAUNCH_SERVICES_PATH="$APP_PATH/Contents/Library/LaunchServices"
mkdir -p "$LAUNCH_SERVICES_PATH"
cp "$INJECTOR_DIR/com.trois.app.Injector" "$LAUNCH_SERVICES_PATH/"

# Re-sign after bundling, which broke Xcode's seal. Nested code is signed first.
echo "Signing..."
codesign --force --options runtime --sign "$IDENTITY" "$RESOURCES_PATH/TroisLoader.bundle"
codesign --force --options runtime --sign "$IDENTITY" \
    --entitlements "$PROJECT_DIR/Eppie/Trois.entitlements" \
    "$APP_PATH"
codesign --verify --strict "$APP_PATH"

if [ "$1" = "--no-deploy" ]; then
    echo "Done: $APP_PATH"
    exit 0
fi

echo "Deploying to /Applications..."
rm -rf "/Applications/$APP_NAME"
cp -R "$APP_PATH" "/Applications/"

echo "Done! Trois.app deployed to /Applications/"
