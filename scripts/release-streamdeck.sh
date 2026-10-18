#!/bin/sh
# Builds a notarized Stream Deck plugin and packs dist/io.sidepulse.swift.streamdeck.streamDeckPlugin for
# the Elgato Marketplace, plus the listing's images in dist/streamdeck-marketplace/.
#
# Elgato requires none of the signing; it keeps Gatekeeper out of the way if the binary ever arrives quarantined.
# Validating and packing use Elgato's CLI (`streamdeck`, or `npx @elgato/cli`), which needs Node.js 20 or later.
set -eu

PROFILE=${SIDEPULSE_NOTARY_PROFILE:-notary}
NOTARIZE=1
ELGATO_CLI_VERSION=1.10.2

usage() {
    echo "usage: scripts/release-streamdeck.sh [--sign IDENTITY] [--notary-profile NAME] [--no-notarize]" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --sign)
            if [ $# -lt 2 ]; then usage; exit 2; fi
            SIDEPULSE_CODESIGN_IDENTITY=$2
            shift
            ;;
        --sign=*) SIDEPULSE_CODESIGN_IDENTITY=${1#--sign=} ;;
        --notary-profile)
            if [ $# -lt 2 ]; then usage; exit 2; fi
            PROFILE=$2
            shift
            ;;
        --notary-profile=*) PROFILE=${1#--notary-profile=} ;;
        --no-notarize) NOTARIZE=0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 2 ;;
    esac
    shift
done

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
UUID=io.sidepulse.swift.streamdeck
PLUGIN="$ROOT/build/$UUID.sdPlugin"
BINARY="$PLUGIN/bin/sidepulse-streamdeck"
PACKAGE="$ROOT/dist/$UUID.streamDeckPlugin"
LISTING="$ROOT/dist/streamdeck-marketplace"

if command -v streamdeck >/dev/null 2>&1; then
    elgato() { streamdeck "$@"; }
elif command -v npx >/dev/null 2>&1; then
    elgato() { npx --yes "@elgato/cli@$ELGATO_CLI_VERSION" "$@"; }
else
    echo "error: Elgato's CLI is needed to validate and pack the plugin; install Node.js 20+ (for npx) or run" >&2
    echo "  npm install -g @elgato/cli" >&2
    exit 1
fi

if [ -z "${SIDEPULSE_CODESIGN_IDENTITY:-}" ]; then
    SIDEPULSE_CODESIGN_IDENTITY=$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | sort -u)
    case $SIDEPULSE_CODESIGN_IDENTITY in
        "")
            echo "error: no \"Developer ID Application\" identity in the keychain; pass --sign IDENTITY" >&2
            exit 1
            ;;
        *"
"*)
            echo "error: several Developer ID Application identities; pick one with --sign:" >&2
            echo "$SIDEPULSE_CODESIGN_IDENTITY" >&2
            exit 1
            ;;
    esac
fi
export SIDEPULSE_CODESIGN_IDENTITY

# Checked before building so missing or expired credentials fail in seconds.
if [ "$NOTARIZE" -eq 1 ] && ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null; then
    cat >&2 <<EOF
error: the notarytool keychain profile "$PROFILE" does not work (see above). Store it once with
  xcrun notarytool store-credentials "$PROFILE" --apple-id YOU@EXAMPLE.COM --team-id TEAMID
or pass --notary-profile NAME, or --no-notarize to skip notarization.
EOF
    exit 1
fi

if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
    echo "warning: the working tree has uncommitted changes; they go into this build" >&2
fi

"$ROOT/scripts/build-streamdeck.sh" --distribution

if ! codesign -dvv "$BINARY" 2>&1 | grep -q '^Authority=Developer ID Application:'; then
    echo "error: $BINARY is not signed with a Developer ID Application certificate" >&2
    exit 1
fi
ARCHS=$(lipo -archs "$BINARY")
case " $ARCHS " in
    *" arm64 "*" x86_64 "* | *" x86_64 "*" arm64 "*) ;;
    *)
        echo "error: $BINARY is built for '$ARCHS', not arm64 and x86_64" >&2
        exit 1
        ;;
esac

if [ "$NOTARIZE" -eq 1 ]; then
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/sidepulse-streamdeck.XXXXXX")
    trap 'rm -rf "$WORK"' EXIT
    # A bare executable cannot be stapled, so Gatekeeper looks the ticket up online when it checks.
    ditto -c -k --norsrc "$BINARY" "$WORK/sidepulse-streamdeck.zip"
    echo "Uploading the plugin binary to Apple's notary service..."
    SUBMIT_JSON=$(xcrun notarytool submit "$WORK/sidepulse-streamdeck.zip" --keychain-profile "$PROFILE" \
        --output-format json) || {
        echo "$SUBMIT_JSON" >&2
        exit 1
    }
    SUBMISSION=$(printf '%s' "$SUBMIT_JSON" | plutil -extract id raw -o - - 2>/dev/null) || SUBMISSION=""
    if [ -z "$SUBMISSION" ]; then
        echo "error: could not read the submission id from notarytool's reply:" >&2
        echo "$SUBMIT_JSON" >&2
        exit 1
    fi
    echo "Submission $SUBMISSION; waiting for Apple (usually a few minutes)..."
    xcrun notarytool wait "$SUBMISSION" --keychain-profile "$PROFILE" || true
    INFO=$(xcrun notarytool info "$SUBMISSION" --keychain-profile "$PROFILE" --output-format json) || INFO=""
    STATUS=$(printf '%s' "$INFO" | plutil -extract status raw -o - - 2>/dev/null) || STATUS=""
    if [ "$STATUS" != Accepted ]; then
        echo "error: notarization of submission $SUBMISSION ended with status \"${STATUS:-unknown}\". Apple's log:" >&2
        xcrun notarytool log "$SUBMISSION" --keychain-profile "$PROFILE" >&2 || true
        echo "Check it later with: xcrun notarytool info $SUBMISSION --keychain-profile \"$PROFILE\"" >&2
        exit 1
    fi
fi

elgato validate "$PLUGIN" --no-update-check
mkdir -p "$ROOT/dist"
rm -f "$PACKAGE"
elgato pack "$PLUGIN" --output "$ROOT/dist" --force --no-update-check
rm -rf "$LISTING"
"$BINARY" --write-marketplace "$LISTING"

VERSION=$(plutil -extract Version raw -o - "$PLUGIN/manifest.json")
echo
echo "Stream Deck plugin $VERSION ready: $PACKAGE"
echo "Listing images: $LISTING"
echo "Nothing was uploaded. Submit the .streamDeckPlugin and the images at https://maker.elgato.com"
echo "(listing text: StreamDeck/MARKETPLACE.md)."
