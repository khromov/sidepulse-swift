#!/bin/sh
# Builds and installs SidePulse for the current user.
set -eu

LABEL=io.sidepulse.swift
BUNDLE_ID=io.sidepulse.swift
APP_DIR="$HOME/Applications"
RUN_SETUP=1

usage() {
    echo "usage: scripts/install.sh [--no-setup] [--app-dir DIR] [--sign IDENTITY]" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --no-setup) RUN_SETUP=0 ;;
        --app-dir)
            if [ $# -lt 2 ]; then usage; exit 2; fi
            APP_DIR=$2
            shift
            ;;
        --app-dir=*) APP_DIR=${1#--app-dir=} ;;
        --sign)
            if [ $# -lt 2 ]; then usage; exit 2; fi
            SIDEPULSE_CODESIGN_IDENTITY=$2
            shift
            ;;
        --sign=*) SIDEPULSE_CODESIGN_IDENTITY=${1#--sign=} ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 2 ;;
    esac
    shift
done
if [ -n "${SIDEPULSE_CODESIGN_IDENTITY:-}" ]; then export SIDEPULSE_CODESIGN_IDENTITY; fi

bundle_id() {
    /usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

# Absolute and symlink-free, because the ~/.local/bin link must not be relative and
# running copies are matched by their exact executable path.
mkdir -p "$APP_DIR"
APP_DIR=$(CDPATH='' cd -- "$APP_DIR" && pwd -P)

SRC_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SRC="$SRC_ROOT/build/SidePulse.app"
DEST="$APP_DIR/SidePulse.app"
APP_BIN="$DEST/Contents/MacOS/SidePulse"
USER_ID=$(id -u)
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# Never replace another app's bundle (the Python SidePulse.app is io.sidepulse.cli).
if [ -e "$DEST" ] && [ "$(bundle_id "$DEST")" != "$BUNDLE_ID" ]; then
    echo "error: $DEST is not SidePulse (bundle id '$(bundle_id "$DEST")'); move it away or use --app-dir" >&2
    exit 1
fi

"$SRC_ROOT/scripts/build-app.sh"

installed_app_pids() {
    for pid in $(pgrep -x SidePulse 2>/dev/null || true); do
        if [ "$(ps -o comm= -p "$pid" 2>/dev/null || true)" = "$APP_BIN" ]; then
            echo "$pid"
        fi
    done
}

WAS_LOADED=0
if launchctl print "gui/$USER_ID/$LABEL" >/dev/null 2>&1; then
    echo "Stopping SidePulse (launchctl bootout gui/$USER_ID/$LABEL)..."
    launchctl bootout "gui/$USER_ID/$LABEL" 2>/dev/null || true
    WAS_LOADED=1
fi
# A copy opened by hand from the install location is not managed by launchd.
for pid in $(installed_app_pids); do
    echo "Stopping SidePulse (pid $pid)..."
    kill "$pid" 2>/dev/null || true
done
# Wait for the old app to exit, or the instance setup starts finds the event socket
# still owned and exits as "already running".
tries=0
while [ -n "$(installed_app_pids)" ] && [ "$tries" -lt 50 ]; do
    sleep 0.2
    tries=$((tries + 1))
done
if [ -n "$(installed_app_pids)" ]; then
    echo "warning: SidePulse is still running; quit it from the menu bar before using the new version" >&2
fi

rm -rf "$DEST"
ditto "$SRC" "$DEST"
echo "Installed $DEST"

BIN_DIR="$HOME/.local/bin"
LINK="$BIN_DIR/sidepulse"
TARGET="$DEST/Contents/Helpers/sidepulse"
mkdir -p "$BIN_DIR"
if [ -L "$LINK" ]; then
    OLD=$(readlink "$LINK")
    if [ "$OLD" != "$TARGET" ]; then
        echo "Replacing $LINK (was a symlink to $OLD)"
    fi
    rm -f "$LINK"
elif [ -e "$LINK" ]; then
    echo "Moving existing $LINK aside to $LINK.previous"
    mv -f "$LINK" "$LINK.previous"
fi
ln -s "$TARGET" "$LINK"
echo "Linked $LINK -> $TARGET"

SETUP_STATUS=0
if [ "$RUN_SETUP" -eq 1 ]; then
    "$LINK" setup || SETUP_STATUS=$?
elif [ "$WAS_LOADED" -eq 1 ] && [ -f "$PLIST" ]; then
    launchctl bootstrap "gui/$USER_ID" "$PLIST" 2>/dev/null || true
fi

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "Note: $BIN_DIR is not on your PATH; add it to use the sidepulse command." ;;
esac
if codesign -dv "$DEST" 2>&1 | grep -q '^Signature=adhoc'; then
    echo "Note: SidePulse.app is signed ad hoc, so macOS asks again for access to removable volumes"
    echo "      (the SidePulse device) after each update, and the LEDs wait until you answer. To keep"
    echo "      the permission, install with --sign IDENTITY (see: security find-identity -v -p codesigning)."
fi
if [ "$SETUP_STATUS" -ne 0 ]; then
    echo "SidePulse is installed, but setup did not finish (see above); run 'sidepulse setup' once that is fixed." >&2
    exit "$SETUP_STATUS"
fi
echo "SidePulse is installed."
