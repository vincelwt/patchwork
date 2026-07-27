#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Pi Desktop"
APP="$ROOT/dist/$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_NAME.app"

cd "$ROOT"
echo "Building release binaries…"
# One `swift build` invocation per product: `--product` does not accumulate across repeated
# flags (a later one wins), it only selects a single target to build.
swift build -c release --product PiDesktop
swift build -c release --product pi-deskd
swift build -c release --product pidesk
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/PiDesktop" "$APP/Contents/MacOS/PiDesktop"
chmod +x "$APP/Contents/MacOS/PiDesktop"

# The control-plane daemon and its CLI, bundled so the app can start/stop its own background
# service instead of requiring scripts/install-daemon.sh (docs/daemon-api.md, "Lifecycle").
# `Contents/Helpers/` rather than `Contents/MacOS/` because these are auxiliary tools the app
# launches itself, not alternate entry points for the bundle — `DaemonSupervisor`/`DaemonControl`
# both know to look here first.
cp "$BIN_DIR/pi-deskd" "$APP/Contents/Helpers/pi-deskd"
cp "$BIN_DIR/pidesk" "$APP/Contents/Helpers/pidesk"
chmod +x "$APP/Contents/Helpers/pi-deskd" "$APP/Contents/Helpers/pidesk"

# Keep the vector SVG as the source of truth and regenerate a complete iconset.
swift scripts/make-icon.swift
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Source of truth for the activity-heartbeat extension the app installs into
# ~/.pi/agent/extensions/; see ActivityExtensionInstaller.swift.
cp "$ROOT/Resources/pi-desktop-activity.ts" "$APP/Contents/Resources/pi-desktop-activity.ts"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Pi Desktop</string>
    <key>CFBundleExecutable</key>
    <string>PiDesktop</string>
    <key>CFBundleIdentifier</key>
    <string>dev.pi.desktop</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>Pi Desktop</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
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
    # Each helper is launched as its own process (never loaded into PiDesktop's address space),
    # so it needs a valid signature of its own — sign both before the whole-bundle pass below,
    # which then reseals the outer bundle's resource envelope around the now-signed helpers.
    codesign --force --sign - "$APP/Contents/Helpers/pi-deskd" >/dev/null
    codesign --force --sign - "$APP/Contents/Helpers/pidesk" >/dev/null
    codesign --force --deep --sign - "$APP" >/dev/null
    codesign --verify --deep --strict "$APP"
fi

rm -rf "$INSTALLED_APP"
ditto "$APP" "$INSTALLED_APP"

echo "Created: $APP"
echo "Installed: $INSTALLED_APP"
echo "Run with: open '$INSTALLED_APP'"
echo "Bundled helpers: Contents/Helpers/pi-deskd, Contents/Helpers/pidesk"
