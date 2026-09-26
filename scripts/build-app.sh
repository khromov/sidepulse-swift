#!/bin/sh
# Builds build/SidePulse.app from this Swift package.
#
# Sign with SIDEPULSE_CODESIGN_IDENTITY to keep macOS's removable-volume permission
# across rebuilds; an ad-hoc signature changes every build, so macOS asks again.
#
# --distribution signs with the hardened runtime and a secure timestamp because
# notarization (scripts/release.sh) rejects the app without them. Only a
# --distribution build keeps SUFeedURL, so only release builds update themselves.
set -eu

usage() {
    echo "usage: scripts/build-app.sh [--debug | --distribution]" >&2
}

CONFIG=release
DISTRIBUTION=0
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG=debug ;;
        --distribution) DISTRIBUTION=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $arg" >&2; usage; exit 2 ;;
    esac
done

IDENTITY=${SIDEPULSE_CODESIGN_IDENTITY:--}
ARCH_FLAGS=
SIGN_FLAGS=--timestamp=none
if [ "$DISTRIBUTION" -eq 1 ]; then
    if [ "$CONFIG" = debug ]; then
        echo "error: --distribution builds release binaries; drop --debug" >&2
        exit 2
    fi
    if [ "$IDENTITY" = "-" ]; then
        echo "error: --distribution needs SIDEPULSE_CODESIGN_IDENTITY (a \"Developer ID Application: …\" identity)" >&2
        exit 1
    fi
    ARCH_FLAGS="--arch arm64"
    SIGN_FLAGS="--options runtime --timestamp"
fi

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

VERSION=$(sed -n 's/^[[:space:]]*public static let version = "\([^"]*\)".*/\1/p' \
    Sources/SidePulseCore/Support/Paths.swift | head -n 1)
if [ -z "$VERSION" ]; then
    echo "error: could not read SidePulseConstants.version from Sources/SidePulseCore/Support/Paths.swift" >&2
    exit 1
fi

echo "Building SidePulse $VERSION ($CONFIG${ARCH_FLAGS:+, arm64})..."
# ARCH_FLAGS is unquoted on purpose: it holds zero or more separate arguments.
swift build -c "$CONFIG" $ARCH_FLAGS --product sidepulse
swift build -c "$CONFIG" $ARCH_FLAGS --product SidePulseApp
BIN=$(swift build -c "$CONFIG" $ARCH_FLAGS --show-bin-path)

APP="$ROOT/build/SidePulse.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# The CLI goes in Helpers/ because on case-insensitive APFS MacOS/sidepulse would
# collide with MacOS/SidePulse.
cp "$BIN/SidePulseApp" "$APP/Contents/MacOS/SidePulse"
cp "$BIN/sidepulse" "$APP/Contents/Helpers/sidepulse"
chmod 755 "$APP/Contents/MacOS/SidePulse" "$APP/Contents/Helpers/sidepulse"
sed "s/__VERSION__/$VERSION/g" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
if [ "$DISTRIBUTION" -eq 0 ]; then
    /usr/libexec/PlistBuddy -c 'Delete :SUFeedURL' "$APP/Contents/Info.plist"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$BIN/Sparkle.framework" "$SPARKLE"
# The XPC services are only for sandboxed apps, and the headers only for compiling against Sparkle.
for item in XPCServices Headers PrivateHeaders Modules; do
    rm -rf "${SPARKLE:?}/$item" "${SPARKLE:?}/Versions/B/$item"
done
if [ "$DISTRIBUTION" -eq 1 ]; then
    for bin in Sparkle Autoupdate Updater.app/Contents/MacOS/Updater; do
        lipo -thin arm64 "$SPARKLE/Versions/B/$bin" -output "$SPARKLE/Versions/B/$bin"
    done
fi

# Extended attributes such as FinderInfo make codesign fail; the bundle needs none.
xattr -cr "$APP" 2>/dev/null || true
# Nested code first, then the bundle (which seals Info.plist and the helper). Sparkle's
# docs sign its helpers one by one because --deep would mis-sign them.
codesign --force $SIGN_FLAGS --sign "$IDENTITY" --identifier io.sidepulse.swift.cli "$APP/Contents/Helpers/sidepulse"
codesign --force $SIGN_FLAGS --sign "$IDENTITY" "$SPARKLE/Versions/B/Autoupdate"
codesign --force $SIGN_FLAGS --sign "$IDENTITY" "$SPARKLE/Versions/B/Updater.app"
codesign --force $SIGN_FLAGS --sign "$IDENTITY" "$SPARKLE"
codesign --force $SIGN_FLAGS --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

if [ "$IDENTITY" = "-" ]; then
    echo "Built $APP (signed ad hoc; set SIDEPULSE_CODESIGN_IDENTITY to sign with a certificate)"
elif [ "$DISTRIBUTION" -eq 1 ]; then
    echo "Built $APP (arm64, signed for distribution with $IDENTITY)"
else
    echo "Built $APP (signed with $IDENTITY)"
fi
