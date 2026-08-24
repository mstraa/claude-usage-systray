#!/bin/bash
#
# Builds ClaudeUsage and assembles a launchable .app bundle.
# Requires only the Command Line Tools — no Xcode.
#
set -euo pipefail

APP_NAME="ClaudeUsage"
BUNDLE_ID="com.mstraa.claude-usage"
VERSION="1.0.0"
BUILD_NUMBER="1"
MIN_MACOS="13.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "==> Building (release)"
swift build -c release --package-path "$ROOT"

BIN="$(swift build -c release --package-path "$ROOT" --show-bin-path)/$APP_NAME"
if [ ! -x "$BIN" ]; then
    echo "error: expected executable at $BIN" >&2
    exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# Info.plist must be written BEFORE codesigning: editing it afterwards breaks the seal, and
# the only visible symptom is SMAppService silently reporting .notFound, so launch-at-login
# stops working while the app still starts normally.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Claude Usage</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>LSMinimumSystemVersion</key>
	<string>$MIN_MACOS</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" > /dev/null

# Re-signing is mandatory, not cosmetic: SwiftPM emits a "linker-signed" signature whose
# Info.plist is "not bound". Signing the bundle binds it and writes _CodeSignature, which is
# what Background Task Management needs to recognise the app.
# --deep is deprecated for signing and is a no-op here (single Mach-O, no nested code).
echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo
echo "Built: $APP"
echo
echo "Run it:      open \"$APP\""
echo "Check data:  \"$APP/Contents/MacOS/$APP_NAME\" --dump"
echo "Install:     cp -R \"$APP\" /Applications/"
echo
echo "Note: 'spctl -a -vv' reports 'rejected' for any ad-hoc-signed app. That is expected"
echo "and does not block launching — Gatekeeper only blocks bundles carrying the"
echo "com.apple.quarantine attribute, which a locally built app does not have."
