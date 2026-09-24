#!/bin/bash
# Build and deploy Trois

set -e

# Get the directory where this script is located
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="Trois.app"
LOADER_DIR="$PROJECT_DIR/TroisLoader"
INJECTOR_DIR="$PROJECT_DIR/TroisInjector"

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
    clean build 2>&1 | grep -E "(error:|warning:|BUILD)" || true

APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME"

if [ ! -d "$APP_PATH" ]; then
    echo "Build failed - app not found at $APP_PATH"
    exit 1
fi

# Copy injection tools to app bundle Resources
echo "Bundling injection tools..."
RESOURCES_PATH="$APP_PATH/Contents/Resources"
cp -R "$LOADER_DIR/TroisLoader.bundle" "$RESOURCES_PATH/"
cp "$LOADER_DIR/trois-inject" "$RESOURCES_PATH/"

# Copy privileged helper to LaunchServices (required for SMJobBless)
echo "Bundling privileged helper..."
LAUNCH_SERVICES_PATH="$APP_PATH/Contents/Library/LaunchServices"
mkdir -p "$LAUNCH_SERVICES_PATH"
cp "$INJECTOR_DIR/com.trois.app.Injector" "$LAUNCH_SERVICES_PATH/"

# Re-sign after bundling, which broke Xcode's seal. The Developer ID keeps the
# designated requirement tied to the team, so Accessibility access survives rebuilds.
echo "Signing..."
codesign --force --sign "Developer ID Application: Mateo Yadarola (CL6XWJCS9R)" \
    --entitlements "$PROJECT_DIR/Eppie/Trois.entitlements" \
    "$APP_PATH"
codesign --verify --strict "$APP_PATH"

echo "Deploying to /Applications..."
rm -rf "/Applications/$APP_NAME"
cp -R "$APP_PATH" "/Applications/"

echo "Done! Trois.app deployed to /Applications/"
