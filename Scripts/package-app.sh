#!/usr/bin/env bash
# Builds EchoEdge.app from the Swift package, signs it (and notarizes a Developer ID build), zips it
# and checks the zip by unpacking it again.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="EchoEdge"
VERSION="0.1.0"
BUILD="1"
APP_BUNDLE="dist/${APP_NAME}.app"
ZIP_PATH="dist/${APP_NAME}.zip"
VERIFY_DIR="dist/verify-extracted"
ICONSET_DIR="dist/AppIcon.iconset"
ICON_OUT="dist/AppIcon-compiled"
SIGNING_REPORT="dist/signing.txt"
SIGN_MODE="${SIGN_MODE:-adhoc}"
export SIGN_MODE

rm -rf "$APP_BUNDLE" "$ZIP_PATH" "$ZIP_PATH.sha256" "$VERIFY_DIR" "$ICONSET_DIR" "$ICON_OUT" "$SIGNING_REPORT"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks" "dist"

swift build --configuration release --product EchoEdgeApp
install -m 755 ".build/release/EchoEdgeApp" "$APP_BUNDLE/Contents/MacOS/EchoEdge"
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "Resources/Acknowledgements.txt" "$APP_BUNDLE/Contents/Resources/Acknowledgements.txt"
cp "LICENSE" "$APP_BUNDLE/Contents/Resources/LICENSE.txt"
test -x "$APP_BUNDLE/Contents/MacOS/EchoEdge"

# Sparkle comes from the exact version SwiftPM resolved and checksummed.
SPARKLE_FRAMEWORKS=()
while IFS= read -r framework; do
    SPARKLE_FRAMEWORKS+=("$framework")
done < <(find .build/artifacts -type d -path '*/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework' -prune)
if [[ "${#SPARKLE_FRAMEWORKS[@]}" -ne 1 ]]; then
    printf 'Expected one Sparkle.framework in .build/artifacts, found %s.\n' "${#SPARKLE_FRAMEWORKS[@]}" >&2
    exit 1
fi
ditto "${SPARKLE_FRAMEWORKS[0]}" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Resources/Info.plist" | grep -Fx '2.10.0'
test -x "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
test -x "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater"
otool -L "$APP_BUNDLE/Contents/MacOS/EchoEdge" | grep -F '@rpath/Sparkle.framework/Versions/B/Sparkle'
otool -l "$APP_BUNDLE/Contents/MacOS/EchoEdge" | grep -F 'path @executable_path/../Frameworks'
grep -F 'Sparkle 2.10.0' "$APP_BUNDLE/Contents/Resources/Acknowledgements.txt"

# The classic icon (.icns) for Finder and older systems, from the flat 1024-point art.
mkdir -p "$ICONSET_DIR"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/AppIcon-1024.png --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Resources/AppIcon-1024.png --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
test -s "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# The macOS 26+ icon: compile the Icon Composer file (Resources/AppIcon.icon) into Assets.car.
# Without it, newer macOS versions show the classic .icns shrunk onto a grey plate in the Dock.
# actool can exit 0 even when it skips the icon, so the output is checked, not the exit code.
mkdir -p "$ICON_OUT"
xcrun actool Resources/AppIcon.icon \
    --compile "$ICON_OUT" \
    --platform macosx \
    --target-device mac \
    --minimum-deployment-target 26.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$ICON_OUT/partial.plist" \
    --output-format human-readable-text \
    --errors --warnings --notices || { echo "error: actool couldn't compile Resources/AppIcon.icon" >&2; exit 1; }
ls -l "$ICON_OUT"
if [ ! -s "$ICON_OUT/Assets.car" ]; then
    echo "error: actool didn't produce Assets.car from Resources/AppIcon.icon" >&2
    exit 1
fi
icon_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconName" "$ICON_OUT/partial.plist" 2>/dev/null || true)"
echo "actool partial Info.plist CFBundleIconName: ${icon_name:-<none>}"
if [ "$icon_name" != "AppIcon" ]; then
    car_info="$(xcrun assetutil --info "$ICON_OUT/Assets.car" 2>&1 || true)"
    case "$car_info" in
        *'"AppIcon"'*) echo "Assets.car lists AppIcon." ;;
        *) printf '%s\n' "$car_info" >&2; echo "error: Assets.car doesn't contain an app icon named AppIcon" >&2; exit 1 ;;
    esac
fi
cp "$ICON_OUT/Assets.car" "$APP_BUNDLE/Contents/Resources/Assets.car"

# Each check names the key that doesn't match, so a failure is never silent.
expect_plist() {
    local plist="$1" key="$2" expected="$3" actual
    actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist")"
    if [ "$actual" != "$expected" ]; then
        echo "error: $plist $key is '$actual', expected '$expected'" >&2
        exit 1
    fi
}

INFO="$APP_BUNDLE/Contents/Info.plist"
plutil -lint "$INFO"
expect_plist "$INFO" CFBundleExecutable EchoEdge
expect_plist "$INFO" CFBundleIdentifier com.echoapps.echoedge
expect_plist "$INFO" CFBundleName EchoEdge
expect_plist "$INFO" CFBundleIconName AppIcon
expect_plist "$INFO" LSUIElement true
expect_plist "$INFO" LSMinimumSystemVersion 26.0
expect_plist "$INFO" CFBundleShortVersionString "$VERSION"
expect_plist "$INFO" CFBundleVersion "$BUILD"
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO" | grep -E '^https://'
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO" | grep -E '^[A-Za-z0-9+/]{43}=$'

# Signing is the last change to the app; everything after only zips, checks and hashes it.
bash Scripts/sign-app.sh "$APP_BUNDLE"

NOTARIZED="no"
if [[ "$SIGN_MODE" == "developer-id" ]]; then
    bash Scripts/notarize.sh "$APP_BUNDLE"
    NOTARIZED="yes"
fi

mkdir -p "$VERIFY_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
ditto -x -k "$ZIP_PATH" "$VERIFY_DIR"
EXTRACTED_APP="$VERIFY_DIR/${APP_NAME}.app"
test -x "$EXTRACTED_APP/Contents/MacOS/EchoEdge"
test -s "$EXTRACTED_APP/Contents/Resources/AppIcon.icns"
test -s "$EXTRACTED_APP/Contents/Resources/Assets.car"
test -x "$EXTRACTED_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
test -L "$EXTRACTED_APP/Contents/Frameworks/Sparkle.framework/Versions/Current"
plutil -lint "$EXTRACTED_APP/Contents/Info.plist"
expect_plist "$EXTRACTED_APP/Contents/Info.plist" CFBundleShortVersionString "$VERSION"
expect_plist "$EXTRACTED_APP/Contents/Info.plist" CFBundleVersion "$BUILD"
codesign --verify --deep --strict "$EXTRACTED_APP"
if [[ "$NOTARIZED" == "yes" ]]; then
    xcrun stapler validate "$EXTRACTED_APP"
    spctl --assess --type execute --verbose=2 "$EXTRACTED_APP"
fi
(
    cd "$(dirname "$ZIP_PATH")"
    shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$ZIP_PATH").sha256"
    shasum -a 256 -c "$(basename "$ZIP_PATH").sha256"
)
{
    printf 'mode=%s\n' "$SIGN_MODE"
    printf 'notarized=%s\n' "$NOTARIZED"
    codesign --display --requirements - "$EXTRACTED_APP" 2>/dev/null | sed -n 's/^designated => /requirement=/p'
} > "$SIGNING_REPORT"
cat "$SIGNING_REPORT"
printf 'Packaged and verified: %s\n' "$ZIP_PATH"
