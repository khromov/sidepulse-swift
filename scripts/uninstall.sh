#!/bin/sh
# Removes SidePulse for the current user.
#
#   scripts/uninstall.sh [--purge] [--app-dir DIR]
#
# 1. `sidepulse uninstall` (agent hooks) and `sidepulse app uninstall` (LaunchAgent)
# 2. stops a copy started by hand, removes the installed SidePulse.app and the
#    ~/.local/bin/sidepulse link when it points into a SidePulse.app
# 3. keeps settings and logs unless --purge
#
# The app removed is the one the ~/.local/bin/sidepulse link points into, else the
# one the LaunchAgent runs, else DIR/SidePulse.app (default ~/Applications);
# --app-dir DIR always wins. A bundle whose identifier is not io.sidepulse.swift
# (such as the Python SidePulse.app) is never removed.
set -eu

LABEL=io.sidepulse.swift
BUNDLE_ID=io.sidepulse.swift
APP_DIR="$HOME/Applications"
APP_DIR_GIVEN=0
PURGE=0

usage() {
    echo "usage: scripts/uninstall.sh [--purge] [--app-dir DIR]" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --purge) PURGE=1 ;;
        --app-dir)
            if [ $# -lt 2 ]; then usage; exit 2; fi
            APP_DIR=$2
            APP_DIR_GIVEN=1
            shift
            ;;
        --app-dir=*) APP_DIR=${1#--app-dir=}; APP_DIR_GIVEN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 2 ;;
    esac
    shift
done

LINK="$HOME/.local/bin/sidepulse"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
# Fixed path on purpose: never rm -rf a path taken from the environment.
DATA_DIR="$HOME/Library/Application Support/SidePulse"
USER_ID=$(id -u)

points_into_app() {
    [ -L "$1" ] || return 1
    case "$(readlink "$1")" in
        */SidePulse.app/Contents/Helpers/sidepulse) return 0 ;;
        *) return 1 ;;
    esac
}

bundle_id() {
    /usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

# Which SidePulse.app is installed (see the header).
PROGRAM=$(/usr/libexec/PlistBuddy -c 'Print ProgramArguments:0' "$PLIST" 2>/dev/null || true)
if [ "$APP_DIR_GIVEN" -eq 0 ] && points_into_app "$LINK"; then
    TARGET=$(readlink "$LINK")
    case "$TARGET" in /*) ;; *) TARGET="$(dirname -- "$LINK")/$TARGET" ;; esac
    DEST=${TARGET%/Contents/Helpers/sidepulse}
elif [ "$APP_DIR_GIVEN" -eq 0 ] && [ "${PROGRAM%/SidePulse.app/Contents/MacOS/SidePulse}" != "$PROGRAM" ]; then
    DEST=${PROGRAM%/Contents/MacOS/SidePulse}
else
    DEST="$APP_DIR/SidePulse.app"
fi
# Absolute, symlink-free, so running copies match by their exact executable path.
if [ -d "$DEST" ]; then
    DEST=$(CDPATH='' cd -- "$DEST" && pwd -P)
fi
HELPER="$DEST/Contents/Helpers/sidepulse"
OURS=0
if [ "$(bundle_id "$DEST")" = "$BUNDLE_ID" ]; then OURS=1; fi

# Prefer the CLI of the app being removed; never run some other `sidepulse`.
CLI=""
if [ "$OURS" -eq 1 ] && [ -x "$HELPER" ]; then
    CLI=$HELPER
elif points_into_app "$LINK" && [ -x "$LINK" ]; then
    CLI=$LINK
fi

if [ -n "$CLI" ]; then
    "$CLI" uninstall || echo "warning: hook removal failed; run 'sidepulse uninstall' manually" >&2
    "$CLI" app uninstall || echo "warning: LaunchAgent removal failed" >&2
else
    echo "warning: SidePulse CLI not found; agent hooks were not removed" >&2
fi

# Make sure the LaunchAgent is gone even if the CLI could not run.
launchctl bootout "gui/$USER_ID/$LABEL" 2>/dev/null || true
rm -f "$PLIST"

if [ "$OURS" -eq 1 ]; then
    for pid in $(pgrep -x SidePulse 2>/dev/null || true); do
        if [ "$(ps -o comm= -p "$pid" 2>/dev/null || true)" = "$DEST/Contents/MacOS/SidePulse" ]; then
            kill "$pid" 2>/dev/null || true
        fi
    done
fi

if points_into_app "$LINK"; then
    rm -f "$LINK"
    echo "Removed $LINK"
    if [ -e "$LINK.previous" ]; then
        echo "Note: the CLI that was there before is kept at $LINK.previous"
    fi
elif [ -e "$LINK" ] || [ -L "$LINK" ]; then
    echo "Leaving $LINK (not a SidePulse.app link)"
fi

if [ "$OURS" -eq 1 ]; then
    rm -rf "$DEST"
    echo "Removed $DEST"
elif [ -e "$DEST" ]; then
    echo "warning: leaving $DEST (bundle id '$(bundle_id "$DEST")' is not $BUNDLE_ID)" >&2
else
    echo "No SidePulse.app at $DEST (pass --app-dir DIR if it is elsewhere)"
fi

if [ "$PURGE" -eq 1 ]; then
    rm -rf "$DATA_DIR"
    echo "Removed $DATA_DIR"
else
    echo "Kept settings and logs in $DATA_DIR (use --purge to remove them)"
fi
echo "SidePulse is uninstalled."
