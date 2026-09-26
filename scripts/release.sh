#!/bin/sh
# Builds a notarized SidePulse.app and zips it for a GitHub release.
set -eu

PROFILE=${SIDEPULSE_NOTARY_PROFILE:-notary}

usage() {
    echo "usage: scripts/release.sh [--sign IDENTITY] [--notary-profile NAME]" >&2
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
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 2 ;;
    esac
    shift
done

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/build/SidePulse.app"

if [ -z "${SIDEPULSE_CODESIGN_IDENTITY:-}" ]; then
    SIDEPULSE_CODESIGN_IDENTITY=$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | sort -u)
    case $SIDEPULSE_CODESIGN_IDENTITY in
        "")
            echo "error: no \"Developer ID Application\" identity in the keychain, and notarization needs one; pass --sign IDENTITY" >&2
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
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null; then
    cat >&2 <<EOF
error: the notarytool keychain profile "$PROFILE" does not work (see above). Store it once with
  xcrun notarytool store-credentials "$PROFILE" --apple-id YOU@EXAMPLE.COM --team-id TEAMID
TEAMID is the code in parentheses in your Developer ID identity. notarytool asks for an
app-specific password, which you create at account.apple.com. Or pass --notary-profile NAME.
EOF
    exit 1
fi

if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
    echo "warning: the working tree has uncommitted changes; they go into this build" >&2
fi

"$ROOT/scripts/build-app.sh" --distribution

if ! codesign -dvv "$APP" 2>&1 | grep -q '^Authority=Developer ID Application:'; then
    echo "error: $APP is not signed with a Developer ID Application certificate, which notarization requires" >&2
    exit 1
fi
# Every build config shares one SwiftPM output directory, so a concurrent build can swap in host-only binaries.
for bin in "$APP/Contents/MacOS/SidePulse" "$APP/Contents/Helpers/sidepulse"; do
    for arch in arm64 x86_64; do
        if ! lipo "$bin" -verify_arch "$arch"; then
            echo "error: $bin has no $arch slice; was another swift build running in this checkout?" >&2
            exit 1
        fi
    done
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sidepulse-release.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
ditto -c -k --keepParent "$APP" "$WORK/SidePulse.zip"

echo "Uploading to Apple's notary service..."
SUBMIT_JSON=$(xcrun notarytool submit "$WORK/SidePulse.zip" --keychain-profile "$PROFILE" --output-format json) || {
    echo "$SUBMIT_JSON" >&2
    exit 1
}
SUBMISSION=$(printf '%s' "$SUBMIT_JSON" | plutil -extract id raw -o - -)
echo "Submission $SUBMISSION; waiting for Apple (usually a few minutes)..."
# The final status comes from `info` below, whatever `wait` exits with.
xcrun notarytool wait "$SUBMISSION" --keychain-profile "$PROFILE" || true
STATUS=$(xcrun notarytool info "$SUBMISSION" --keychain-profile "$PROFILE" --output-format json \
    | plutil -extract status raw -o - -)
if [ "$STATUS" != Accepted ]; then
    echo "error: notarization of submission $SUBMISSION ended with status \"$STATUS\". Apple's log:" >&2
    xcrun notarytool log "$SUBMISSION" --keychain-profile "$PROFILE" >&2 || true
    exit 1
fi

# Stapling lets Gatekeeper accept the app without asking Apple, for example offline.
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
ZIP="$ROOT/dist/SidePulse-$VERSION.zip"
mkdir -p "$ROOT/dist"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA256=$(shasum -a 256 "$ZIP" | cut -d ' ' -f 1)

echo
echo "Release ready: $ZIP"
echo "SHA-256: $SHA256"
echo "Nothing was uploaded. To publish it, for example:"
echo "  gh release create v$VERSION \"$ZIP\""
