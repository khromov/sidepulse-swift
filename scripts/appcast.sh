#!/bin/sh
# Writes dist/appcast.xml, the Sparkle update feed for one release zip, signed with
# the EdDSA key in the login keychain. Upload it to the GitHub release next to the zip:
# installed apps read it from releases/latest/download/appcast.xml.
set -eu

usage() {
    echo "usage: scripts/appcast.sh dist/SidePulse-VERSION.zip [NOTES.md]" >&2
}

case ${1:-} in
    -h|--help) usage; exit 0 ;;
esac
if [ $# -lt 1 ] || [ $# -gt 2 ]; then usage; exit 2; fi
ZIP=$1
NOTES=${2:-}

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
REPO=https://github.com/khromov/sidepulse-swift
TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
OUT="$ROOT/dist/appcast.xml"

if [ ! -f "$ZIP" ]; then echo "error: $ZIP does not exist" >&2; exit 1; fi
if [ -n "$NOTES" ] && [ ! -f "$NOTES" ]; then echo "error: $NOTES does not exist" >&2; exit 1; fi
NAME=$(basename "$ZIP" .zip)
case $NAME in
    SidePulse-*) VERSION=${NAME#SidePulse-} ;;
    *) echo "error: expected a zip named SidePulse-VERSION.zip, got $ZIP" >&2; exit 1 ;;
esac
if [ ! -x "$TOOLS/generate_appcast" ]; then
    swift package --package-path "$ROOT" resolve
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sidepulse-appcast.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

unzip -p "$ZIP" SidePulse.app/Contents/Info.plist > "$WORK/Info.plist"
APP_VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$WORK/Info.plist")
if [ "$APP_VERSION" != "$VERSION" ]; then
    echo "error: $ZIP holds SidePulse $APP_VERSION, but its name says $VERSION (the download URL uses the name)" >&2
    exit 1
fi
if ! plutil -extract SUFeedURL raw -o - "$WORK/Info.plist" >/dev/null 2>&1; then
    echo "error: $ZIP has no SUFeedURL, so it cannot update itself; build it with scripts/release.sh" >&2
    exit 1
fi
# Installed copies check updates against the key in their own Info.plist.
APP_KEY=$(plutil -extract SUPublicEDKey raw -o - "$WORK/Info.plist" 2>/dev/null) || APP_KEY=""
KEYCHAIN_KEY=$("$TOOLS/generate_keys" -p) || {
    echo "error: no Sparkle signing key in the keychain; restore it with: $TOOLS/generate_keys -f KEYFILE" >&2
    exit 1
}
if [ "$APP_KEY" != "$KEYCHAIN_KEY" ]; then
    echo "error: the app's SUPublicEDKey ($APP_KEY) is not the keychain's key ($KEYCHAIN_KEY)" >&2
    exit 1
fi

mkdir "$WORK/archives"
cp "$ZIP" "$WORK/archives/"
if [ -n "$NOTES" ]; then cp "$NOTES" "$WORK/archives/$NAME.md"; fi
mkdir -p "$ROOT/dist"
rm -f "$OUT"
"$TOOLS/generate_appcast" \
    --download-url-prefix "$REPO/releases/download/v$VERSION/" \
    --link "$REPO/releases/tag/v$VERSION" \
    --embed-release-notes \
    --maximum-deltas 0 \
    -o "$OUT" "$WORK/archives"

SIGNATURE=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$OUT")
if [ -z "$SIGNATURE" ] || ! "$TOOLS/sign_update" --verify "$ZIP" "$SIGNATURE"; then
    echo "error: $OUT has no valid signature for $ZIP" >&2
    exit 1
fi

echo "Wrote $OUT for SidePulse $VERSION. Publish it with the zip, for example:"
echo "  gh release create v$VERSION \"$ZIP\" \"$OUT\""
