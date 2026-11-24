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
HOST_RESOURCES="$APP/Contents/Resources/harness-host"
mkdir "$HOST" "$HOST_RESOURCES"
install -m 755 "$PAYLOAD/node" "$HOST/node"
cp "$PAYLOAD/host.mjs" "$PAYLOAD/commit" "$HOST_RESOURCES/"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# VERSION is the one place the version lives; Settings reads it from there, and Sparkle compares CFBundleVersion. A beta
# build (beta.yml) sets ROUNDS_VERSION and ROUNDS_SHORT_VERSION.
VERSION="${ROUNDS_VERSION:-$(cat VERSION)}"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${ROUNDS_SHORT_VERSION:-$VERSION}" -c "Add :CFBundleVersion string $VERSION" "$APP/Contents/Info.plist"
cp Resources/*.svg Resources/rounds-pi.ts "$APP/Contents/Resources/"
cp Resources/AppIcon.icns Resources/henry.png "$APP/Contents/Resources/"
# Use the release certificate when it is available. An ad-hoc development build uses the Keychain directly.
RELEASE_CERT=981b67fc67872c2a9dd89da60aa84ed6690c62a8
if security find-identity -p codesigning | grep -i "$RELEASE_CERT" > /dev/null; then
    IDENTITY="$RELEASE_CERT"
else
    IDENTITY=-
fi
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --deep -s "$IDENTITY" "$SPARKLE"
codesign --force -s "$IDENTITY" "$APP/Contents/Helpers/rounds-hook" "$HOST/node"
if [ "$IDENTITY" = - ]; then
    codesign --force -s - "$APP"
else
    shasum -a 256 -c Resources/LinearKeychain.sha256
    SERVICE="$APP/Contents/XPCServices/com.henryqw.rounds.linear-keychain.xpc"
    mkdir -p "$SERVICE/Contents/MacOS"
    cp Resources/LinearKeychain.plist "$SERVICE/Contents/Info.plist"
    install -m 755 Resources/LinearKeychain.macho "$SERVICE/Contents/MacOS/Rounds Linear Keychain"
    # Sign the same helper bytes with the same options for both channels. Do not re-sign nested code from the app.
    codesign -s "$IDENTITY" --options runtime --timestamp=none "$SERVICE"
    /usr/libexec/PlistBuddy -c 'Add :RoundsLinearKeychainHelper bool true' "$APP/Contents/Info.plist"
    sh scripts/sign-keychain-client.sh "$IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"
if [ "$INSTALL" = true ]; then
    rm -rf "/Applications/Rounds.app"
    cp -R "$APP" /Applications/
    APP="/Applications/Rounds.app"
fi
echo "$APP"
