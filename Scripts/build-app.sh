#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_COMMAND="${WORDLINKS_SWIFT_EXECUTABLE:-swift}"
BUILD_SDK="${SDKROOT:-$(/usr/bin/xcrun --sdk macosx --show-sdk-path)}"
# A local extraction of Apple's signed developer tools can be used without
# installing it globally. Explicit toolchain overrides always take precedence.
LOCAL_TOOLS="$ROOT/build/AppleDeveloperTools/CommandLineTools"
if [[ ! -d "$BUILD_SDK/System/Library/Frameworks/FoundationModels.framework" &&
      -z "${SDKROOT:-}" && -z "${WORDLINKS_SWIFT_EXECUTABLE:-}" && -z "${DEVELOPER_DIR:-}" &&
      -d "$LOCAL_TOOLS/SDKs/MacOSX.sdk/System/Library/Frameworks/FoundationModels.framework" ]]; then
    export DEVELOPER_DIR="$LOCAL_TOOLS"
    export SDKROOT="$LOCAL_TOOLS/SDKs/MacOSX.sdk"
    BUILD_SDK="$SDKROOT"
    SWIFT_COMMAND="$LOCAL_TOOLS/usr/bin/swift"
fi
# Packaged apps include the native provider even when this Mac cannot enable it.
# Older SDKs may run isolated protocol tests, but must not silently produce a
# release in which Apple Intelligence can never be used on a compatible Mac.
if [[ ! -d "$BUILD_SDK/System/Library/Frameworks/FoundationModels.framework" ]]; then
    printf 'Building Wordlinks.app requires Xcode 26 or later and the macOS 26+ SDK for Apple Intelligence.\n' >&2
    printf 'Select the newer tools with DEVELOPER_DIR, or supply WORDLINKS_SWIFT_EXECUTABLE and SDKROOT.\n' >&2
    exit 1
fi
# Hold the lock through compilation, packaging, and signing so concurrent builds
# cannot replace executable pages or resources while another build seals them.
mkdir -p "$ROOT/build"
touch "$ROOT/build/.packaging.lock"
zmodload zsh/system
if ! zsystem flock -t 60 -f PACKAGING_LOCK_FD "$ROOT/build/.packaging.lock"; then
    printf 'Timed out waiting for another Wordlinks app build.\n' >&2
    exit 1
fi

APP="$ROOT/build/Wordlinks.app"
LEGACY_APP="$ROOT/build/ReadingToolDaily.app"
"$SWIFT_COMMAND" build --build-system native --package-path "$ROOT" --sdk "$BUILD_SDK" -c release -Xswiftc -DWORDLINKS_REQUIRE_APPLE_INTELLIGENCE
BIN_DIR="$("$SWIFT_COMMAND" build --build-system native --package-path "$ROOT" --sdk "$BUILD_SDK" -c release --show-bin-path)"

# Keep the bundle filename aligned with CFBundleName so Finder can apply its
# localized display name. Move the existing bundle instead of leaving a copy.
if [[ ! -e "$APP" && ! -L "$APP" && -d "$LEGACY_APP" && ! -L "$LEGACY_APP" ]]; then
    mv "$LEGACY_APP" "$APP"
elif [[ -e "$APP" && -d "$LEGACY_APP" && ! -L "$LEGACY_APP" ]]; then
    printf 'Both Wordlinks.app and ReadingToolDaily.app exist; keeping the old bundle untouched.\n' >&2
fi

CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
mkdir -p "$MACOS"
# Replace the executable atomically so rebuilding a running app does not alter
# the signed pages that macOS has already mapped into the old process.
cp "$BIN_DIR/WordLinks" "$MACOS/WordLinks.new"
mv -f "$MACOS/WordLinks.new" "$MACOS/WordLinks"
rm -f "$MACOS/ReadingToolDaily" "$MACOS/ReadingToolDaily.new"
mkdir -p "$CONTENTS/Resources"
rm -rf "$CONTENTS/Resources/ReadingToolDaily_ReadingToolDaily.bundle"
for bundle in "$BIN_DIR"/*.bundle(N); do
    rm -rf "$CONTENTS/Resources/$(basename "$bundle")"
    ditto "$bundle" "$CONTENTS/Resources/$(basename "$bundle")"
done
for localization in zh-Hans en; do
    mkdir -p "$CONTENTS/Resources/$localization.lproj"
    cp "$ROOT/AppResources/$localization.lproj/InfoPlist.strings" \
        "$CONTENTS/Resources/$localization.lproj/InfoPlist.strings"
done

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>WordLinks</string>
    <key>CFBundleIdentifier</key><string>com.readingtool.daily</string>
    <key>CFBundleName</key><string>Wordlinks</string>
    <key>CFBundleDisplayName</key><string>Wordlinks</string>
    <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
    <key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string></string>
</dict>
</plist>
PLIST

python3 "$ROOT/Scripts/install-app-icon.py" "$APP"
python3 "$ROOT/Scripts/install-native-icon.py" "$APP"
zsh "$ROOT/Scripts/sign-app.sh" "$APP"
printf 'Built %s\n' "$APP"
