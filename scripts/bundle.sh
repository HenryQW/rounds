#!/bin/sh
# Build or package a checked host payload. --install also copies the app to /Applications.
set -e
cd -P "$(dirname "$0")/.."
INSTALL=false
case "${1:-}" in
    --harness-payload)
        PAYLOAD="${2:?Expected the checked Harness payload directory.}"
        ;;
    ''|--install)
        [ "${1:-}" != --install ] || INSTALL=true
        scripts/build-harness-host.sh
        PAYLOAD=.build/harness-host
        ;;
    *) echo "Usage: $0 [--install | --harness-payload directory]" >&2; exit 1 ;;
esac
if [ "$(cat "$PAYLOAD/commit")" != 5a14e69c067d40dfbff4f2fff7d3b34c897e2dc9 ]; then
    echo 'Wrong Harness payload commit.' >&2
    exit 1
fi
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="build/Rounds.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Rounds" "$APP/Contents/MacOS/Rounds"
cp "$BIN/rounds-hook" "$APP/Contents/Helpers/rounds-hook"
HOST="$APP/Contents/Helpers/harness-host"
mkdir "$HOST"
cp "$PAYLOAD/node" "$PAYLOAD/host.mjs" "$PAYLOAD/commit" "$HOST/"
chmod 755 "$HOST/node"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# VERSION is the one place the version lives; Settings reads it from there, and Sparkle compares CFBundleVersion. A beta
# build (beta.yml) sets ROUNDS_VERSION and ROUNDS_SHORT_VERSION.
VERSION="${ROUNDS_VERSION:-$(cat VERSION)}"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${ROUNDS_SHORT_VERSION:-$VERSION}" -c "Add :CFBundleVersion string $VERSION" "$APP/Contents/Info.plist"
cp Resources/*.svg Resources/rounds-pi.ts "$APP/Contents/Resources/"
cp Resources/AppIcon.icns Resources/henry.png "$APP/Contents/Resources/"
# The stable self-signed identity when a keychain has it (the release, website/docs/release.md): each build then has the
# same designated requirement, so macOS permissions and Sparkle's code signature check hold across updates. Else ad hoc.
IDENTITY="Rounds Self-Signed"
security find-identity -p codesigning | grep -q "\"$IDENTITY\"" || IDENTITY=-
codesign --force --deep -s "$IDENTITY" "$APP"
if [ "$INSTALL" = true ]; then
    rm -rf "/Applications/Rounds.app"
    cp -R "$APP" /Applications/
    APP="/Applications/Rounds.app"
fi
echo "$APP"
