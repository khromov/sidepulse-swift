#!/bin/sh
# Builds build/SidePulse.app from this Swift package.
#
# Sign with SIDEPULSE_CODESIGN_IDENTITY to keep macOS's removable-volume permission
# across rebuilds; an ad-hoc signature changes every build, so macOS asks again.
set -eu

usage() {
    echo "usage: scripts/build-app.sh [--debug]" >&2
}

CONFIG=release
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG=debug ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $arg" >&2; usage; exit 2 ;;
    esac
done

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

VERSION=$(sed -n 's/^[[:space:]]*public static let version = "\([^"]*\)".*/\1/p' \
    Sources/SidePulseCore/Support/Paths.swift | head -n 1)
if [ -z "$VERSION" ]; then
    echo "error: could not read SidePulseConstants.version from Sources/SidePulseCore/Support/Paths.swift" >&2
    exit 1
fi

echo "Building SidePulse $VERSION ($CONFIG)..."
swift build -c "$CONFIG" --product sidepulse
swift build -c "$CONFIG" --product SidePulseApp
BIN=$(swift build -c "$CONFIG" --show-bin-path)

APP="$ROOT/build/SidePulse.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

# The CLI goes in Helpers/ because on case-insensitive APFS MacOS/sidepulse would
# collide with MacOS/SidePulse.
cp "$BIN/SidePulseApp" "$APP/Contents/MacOS/SidePulse"
cp "$BIN/sidepulse" "$APP/Contents/Helpers/sidepulse"
chmod 755 "$APP/Contents/MacOS/SidePulse" "$APP/Contents/Helpers/sidepulse"
sed "s/__VERSION__/$VERSION/g" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Extended attributes such as FinderInfo make codesign fail; the bundle needs none.
xattr -cr "$APP" 2>/dev/null || true
# Nested code first, then the bundle (which seals Info.plist and the helper).
IDENTITY=${SIDEPULSE_CODESIGN_IDENTITY:--}
codesign --force --timestamp=none --sign "$IDENTITY" --identifier io.sidepulse.swift.cli "$APP/Contents/Helpers/sidepulse"
codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

if [ "$IDENTITY" = "-" ]; then
    echo "Built $APP (signed ad hoc; set SIDEPULSE_CODESIGN_IDENTITY to sign with a certificate)"
else
    echo "Built $APP (signed with $IDENTITY)"
fi
