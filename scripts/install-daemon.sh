#!/usr/bin/env bash
set -euo pipefail

# Installs pi-deskd as a per-user LaunchAgent: builds the release binary, copies it to a stable
# location outside any git worktree (worktrees come and go per scripts/worktree.sh; the running
# daemon must not depend on one surviving), writes the plist, and (re)loads it.
#
# Only needed for always-on use without Pi Desktop.app (e.g. a headless machine): by default the
# app starts and stops its own bundled pi-deskd as it launches and quits (docs/daemon-api.md,
# "Lifecycle"). If both are present, the app defers to the LaunchAgent installed here rather than
# running a second daemon.
#
# Usage:
#   scripts/install-daemon.sh              build, install/update, (re)load
#   scripts/install-daemon.sh --uninstall  unload and remove everything this script wrote
#   scripts/install-daemon.sh --status     report whether the LaunchAgent is loaded
#
# Idempotent: safe to re-run after a rebuild, after an uninstall, or on a machine where it was
# never installed at all.

LABEL="dev.pi.desktop.daemon"
SUPPORT_DIR="$HOME/Library/Application Support/Pi Desktop"
BIN_DIR="$SUPPORT_DIR/bin"
INSTALLED_BINARY="$BIN_DIR/pi-deskd"
LOG_DIR="$HOME/Library/Logs/Pi Desktop"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$LABEL.plist"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOMAIN="gui/$(id -u)"

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--uninstall|--status]

Installs pi-deskd as a LaunchAgent (RunAtLoad, restarts on crash) at:
  $PLIST_PATH
running the binary installed at:
  $INSTALLED_BINARY

  (no args)     build pi-deskd, install/update the LaunchAgent, (re)load it
  --uninstall   unload the LaunchAgent and remove the plist and installed binary
  --status      print whether the LaunchAgent is currently loaded
USAGE
}

is_loaded() {
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
}

unload_if_loaded() {
    if is_loaded; then
        launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
        # bootout is asynchronous; give it a moment before reusing the binary/plist.
        for _ in 1 2 3 4 5; do
            is_loaded || break
            sleep 0.2
        done
    fi
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    --uninstall)
        echo "Stopping $LABEL…"
        unload_if_loaded
        rm -f "$PLIST_PATH"
        rm -f "$INSTALLED_BINARY"
        echo "Removed $PLIST_PATH and $INSTALLED_BINARY."
        echo "Schedules, run history, and logs were left in place."
        exit 0
        ;;
    --status)
        if is_loaded; then
            echo "$LABEL is loaded."
            exit 0
        fi
        echo "$LABEL is not loaded."
        exit 1
        ;;
    "")
        ;;
    *)
        usage
        exit 2
        ;;
esac

echo "Building pi-deskd (release)…"
(cd "$ROOT" && swift build -c release --product pi-deskd)
BUILT_BINARY="$(cd "$ROOT" && swift build -c release --show-bin-path)/pi-deskd"
if [ ! -x "$BUILT_BINARY" ]; then
    echo "error: build did not produce an executable at $BUILT_BINARY" >&2
    exit 1
fi

mkdir -p "$BIN_DIR" "$LOG_DIR" "$LAUNCH_AGENTS_DIR"
chmod 700 "$SUPPORT_DIR"

# Stop any running instance before replacing the binary it is executing.
unload_if_loaded

cp "$BUILT_BINARY" "$INSTALLED_BINARY"
chmod 700 "$INSTALLED_BINARY"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALLED_BINARY</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
        <key>Crashed</key>
        <true/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/daemon.stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/daemon.stderr.log</string>
</dict>
</plist>
PLIST
chmod 644 "$PLIST_PATH"

echo "Loading $LABEL…"
launchctl bootstrap "$DOMAIN" "$PLIST_PATH"
launchctl enable "$DOMAIN/$LABEL" >/dev/null 2>&1 || true

sleep 1
if is_loaded; then
    echo "pi-deskd installed and running."
    echo "  binary: $INSTALLED_BINARY"
    echo "  plist:  $PLIST_PATH"
    echo "  logs:   $LOG_DIR/daemon.log (application log)"
    echo "          $LOG_DIR/daemon.stdout.log, daemon.stderr.log (launchd)"
else
    echo "warning: LaunchAgent did not report as loaded; check $LOG_DIR/daemon.stderr.log" >&2
    exit 1
fi
