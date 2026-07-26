#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Pi Desktop"
APP="$ROOT/dist/$APP_NAME.app"

cd "$ROOT"
echo "Building release binary…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PiDesktop" "$APP/Contents/MacOS/PiDesktop"
chmod +x "$APP/Contents/MacOS/PiDesktop"

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
    codesign --force --deep --sign - "$APP" >/dev/null
fi

echo "Created: $APP"
echo "Run with: open '$APP'"
