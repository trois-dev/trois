#!/bin/bash
# Builds, signs and notarizes Trois, and zips it for a GitHub release.
# Needs a notarytool keychain profile: NOTARY_PROFILE=name ./release.sh

set -eo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
OUT_DIR="$BUILD_DIR/release"
LOADER_DIR="$PROJECT_DIR/TroisLoader"
INJECTOR_DIR="$PROJECT_DIR/TroisInjector"
IDENTITY="${TROIS_SIGN_IDENTITY:-Developer ID Application: Mateo Yadarola (CL6XWJCS9R)}"

if [ -z "$NOTARY_PROFILE" ]; then
    echo "Set NOTARY_PROFILE to a profile made with: xcrun notarytool store-credentials"
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PROJECT_DIR/Trois/Info.plist")
ZIP="$OUT_DIR/Trois-$VERSION.zip"

"$LOADER_DIR/build.sh"
"$INJECTOR_DIR/build.sh"

echo "Building Trois $VERSION..."
xcodebuild -project "$PROJECT_DIR/Trois.xcodeproj" \
    -scheme Trois \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    clean build 2>&1 | { grep -E "(error:|BUILD)" || true; }

APP_PATH="$BUILD_DIR/Build/Products/Release/Trois.app"
if [ ! -d "$APP_PATH" ]; then
    echo "Build failed - app not found at $APP_PATH"
    exit 1
fi

RESOURCES_PATH="$APP_PATH/Contents/Resources"
LAUNCH_SERVICES_PATH="$APP_PATH/Contents/Library/LaunchServices"
cp -R "$LOADER_DIR/TroisLoader.bundle" "$RESOURCES_PATH/"
mkdir -p "$LAUNCH_SERVICES_PATH"
cp "$INJECTOR_DIR/com.trois.app.Injector" "$LAUNCH_SERVICES_PATH/"

# Notarization wants every executable signed with the Developer ID, the
# hardened runtime and a secure timestamp. Nested code is signed before the app.
echo "Signing..."
sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
sign "$RESOURCES_PATH/TroisLoader.bundle"
sign --entitlements "$INJECTOR_DIR/TroisInjector.entitlements" "$LAUNCH_SERVICES_PATH/com.trois.app.Injector"
sign --entitlements "$PROJECT_DIR/Trois/Trois.entitlements" "$APP_PATH"
codesign --verify --strict --deep "$APP_PATH"

mkdir -p "$OUT_DIR"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP_PATH" "$ZIP"

echo "Notarizing..."
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"

# Zipped again so the download carries the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP_PATH" "$ZIP"
spctl --assess --type execute --verbose "$APP_PATH"

echo "Done: $ZIP"
