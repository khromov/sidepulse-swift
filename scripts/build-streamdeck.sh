#!/bin/sh
# Builds build/io.sidepulse.swift.streamdeck.sdPlugin, the Stream Deck plugin, from this Swift package.
#
# --link links the build into Stream Deck's plugin folder and restarts the plugin, for development.
# --distribution builds a universal binary (Marketplace users may have Intel Macs) signed with the
# hardened runtime and a secure timestamp, which notarization (scripts/release-streamdeck.sh) requires.
set -eu

usage() {
    echo "usage: scripts/build-streamdeck.sh [--debug | --distribution] [--link]" >&2
}

CONFIG=release
DISTRIBUTION=0
LINK=0
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG=debug ;;
        --distribution) DISTRIBUTION=1 ;;
        --link) LINK=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $arg" >&2; usage; exit 2 ;;
    esac
done

IDENTITY=${SIDEPULSE_CODESIGN_IDENTITY:--}
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
    SIGN_FLAGS="--options runtime --timestamp"
fi

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

UUID=io.sidepulse.swift.streamdeck
PRODUCT=sidepulse-streamdeck
SOURCE="$ROOT/StreamDeck/$UUID.sdPlugin"
PLUGIN="$ROOT/build/$UUID.sdPlugin"
VERSION=$(plutil -extract Version raw -o - "$SOURCE/manifest.json")

rm -rf "$PLUGIN"
mkdir -p "$ROOT/build"
ditto "$SOURCE" "$PLUGIN"
mkdir -p "$PLUGIN/bin"

if [ "$DISTRIBUTION" -eq 1 ]; then
    echo "Building the Stream Deck plugin $VERSION (release, arm64 + x86_64)..."
    # Older toolchains need Xcode for a multi-arch `swift build`, and newer ones put every arch in one output
    # directory, so each slice is built and copied out on its own.
    SLICES=$(mktemp -d "${TMPDIR:-/tmp}/sidepulse-streamdeck-slices.XXXXXX")
    trap 'rm -rf "$SLICES"' EXIT
    for arch in arm64 x86_64; do
        swift build -c release --arch "$arch" --product "$PRODUCT"
        cp "$(swift build -c release --arch "$arch" --show-bin-path)/$PRODUCT" "$SLICES/$arch"
        if [ "$(lipo -archs "$SLICES/$arch")" != "$arch" ]; then
            echo "error: the $arch build produced '$(lipo -archs "$SLICES/$arch")'" >&2
            exit 1
        fi
    done
    lipo -create "$SLICES/arm64" "$SLICES/x86_64" -output "$PLUGIN/bin/$PRODUCT"
else
    echo "Building the Stream Deck plugin $VERSION ($CONFIG)..."
    swift build -c "$CONFIG" --product "$PRODUCT"
    cp "$(swift build -c "$CONFIG" --show-bin-path)/$PRODUCT" "$PLUGIN/bin/$PRODUCT"
fi
chmod 755 "$PLUGIN/bin/$PRODUCT"
"$PLUGIN/bin/$PRODUCT" --write-assets "$PLUGIN"

# Extended attributes such as FinderInfo make codesign fail.
xattr -cr "$PLUGIN" 2>/dev/null || true
codesign --force $SIGN_FLAGS --sign "$IDENTITY" --identifier "$UUID" "$PLUGIN/bin/$PRODUCT"
codesign --verify --strict "$PLUGIN/bin/$PRODUCT"

if [ "$IDENTITY" = "-" ]; then
    echo "Built $PLUGIN (signed ad hoc)"
else
    echo "Built $PLUGIN (signed with $IDENTITY)"
fi

if [ "$LINK" -eq 1 ]; then
    PLUGINS="$HOME/Library/Application Support/com.elgato.StreamDeck/Plugins"
    LINKED="$PLUGINS/$UUID.sdPlugin"
    if [ -e "$LINKED" ] && [ ! -L "$LINKED" ]; then
        echo "error: $LINKED is an installed copy (from the Marketplace or a .streamDeckPlugin file)." >&2
        echo "Uninstall SidePulse Swift in Stream Deck's preferences, then run this again." >&2
        exit 1
    fi
    mkdir -p "$PLUGINS"
    ln -sfn "$PLUGIN" "$LINKED"
    echo "Linked $LINKED -> $PLUGIN"
    # Stream Deck picks up a newly linked plugin only when it starts, and restarts a known one by URL only in
    # developer mode.
    if ! pgrep -xq "Stream Deck"; then
        :
    elif [ "$(defaults read com.elgato.StreamDeck developer_mode 2>/dev/null)" = 1 ]; then
        open -g "streamdeck://plugins/restart/$UUID"
        echo "Asked Stream Deck to restart the plugin; quit and reopen Stream Deck if it is not listed yet."
    else
        echo "Quit and reopen Stream Deck to load this build. To restart only the plugin after each build,"
        echo "turn on Stream Deck's developer mode once and reopen Stream Deck:"
        echo "  defaults write com.elgato.StreamDeck developer_mode -bool YES"
    fi
fi
