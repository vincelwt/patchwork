#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Patchwork"
APP="$ROOT/dist/$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_NAME.app"
LEGACY_APP="$ROOT/dist/Pi Desktop.app"
LEGACY_INSTALLED_APP="/Applications/Pi Desktop.app"

cd "$ROOT"
echo "Building release binaries…"
# One `swift build` invocation per product: `--product` does not accumulate across repeated
# flags (a later one wins), it only selects a single target to build.
swift build -c release --product PatchworkApp
swift build -c release --product patchworkd
swift build -c release --product patchwork
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/PatchworkApp" "$APP/Contents/MacOS/Patchwork"
chmod +x "$APP/Contents/MacOS/Patchwork"

# Patchwork hosts the control service in-process. Keep the standalone host only for the explicit
# `patchwork daemon install` LaunchAgent path, and bundle the CLI for direct terminal access.
cp "$BIN_DIR/patchworkd" "$APP/Contents/Helpers/patchworkd"
cp "$BIN_DIR/patchwork" "$APP/Contents/Helpers/patchwork"
ditto "$BIN_DIR/Patchwork_PatchworkWeb.bundle" "$APP/Contents/Resources/Patchwork_PatchworkWeb.bundle"
chmod +x "$APP/Contents/Helpers/patchworkd" "$APP/Contents/Helpers/patchwork"

# Compile the layered Icon Composer source. actool emits both the dynamic catalog used by
# current macOS and a legacy .icns fallback for the app's macOS 14 minimum.
ICON_OUT="$(mktemp -d)"
trap 'rm -rf "$ICON_OUT"' EXIT
xcrun actool "$ROOT/Resources/AppIcon.icon" \
  --compile "$ICON_OUT" \
  --output-format human-readable-text \
  --notices --warnings \
  --output-partial-info-plist "$ICON_OUT/generated.plist" \
  --app-icon AppIcon \
  --include-all-app-icons \
  --enable-on-demand-resources NO \
  --development-region en \
  --target-device mac \
  --minimum-deployment-target 14.0 \
  --platform macosx
cp "$ICON_OUT/AppIcon.icns" "$ICON_OUT/Assets.car" "$APP/Contents/Resources/"

# Source of truth for the activity-heartbeat extension the app installs into
# ~/.pi/agent/extensions/; see ActivityExtensionInstaller.swift.
cp "$ROOT/Resources/patchwork-activity.ts" "$APP/Contents/Resources/patchwork-activity.ts"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Patchwork</string>
    <key>CFBundleExecutable</key>
    <string>Patchwork</string>
    <key>CFBundleIdentifier</key>
    <string>app.patchwork.desktop</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>Patchwork</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Patchwork uses Apple Events to control Mac apps on your behalf.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc signing avoids a damaged-app warning for local builds. Distribution
# signing/notarization can replace this identity later.
if command -v codesign >/dev/null 2>&1; then
    cat > "$ICON_OUT/Patchwork.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
PLIST

    # The optional standalone host and CLI are separate executables, so sign them before the
    # whole-bundle pass reseals the outer resource envelope.
    codesign --force --sign - "$APP/Contents/Helpers/patchworkd" >/dev/null
    codesign --force --sign - "$APP/Contents/Helpers/patchwork" >/dev/null
    codesign --force --deep --sign - --entitlements "$ICON_OUT/Patchwork.entitlements" "$APP" >/dev/null
    codesign --verify --deep --strict "$APP"
    plutil -extract NSAppleEventsUsageDescription raw -o - "$APP/Contents/Info.plist" | grep -q .
    codesign -d --entitlements :- "$APP" 2>/dev/null > "$ICON_OUT/SignedEntitlements.plist"
    test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.automation.apple-events' "$ICON_OUT/SignedEntitlements.plist")" = true
fi

rm -rf "$INSTALLED_APP"
ditto "$APP" "$INSTALLED_APP"
rm -rf "$LEGACY_APP" "$LEGACY_INSTALLED_APP"

echo "Created: $APP"
echo "Installed: $INSTALLED_APP"
echo "Run with: open '$INSTALLED_APP'"
echo "Bundled CLI/optional host: Contents/Helpers/patchwork, Contents/Helpers/patchworkd"
