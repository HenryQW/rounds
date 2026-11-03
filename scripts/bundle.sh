#!/bin/sh
# Build "build/Rounds.app". --install also copies it to /Applications.
set -e
cd "$(dirname "$0")/.."
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="build/Rounds.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Rounds" "$APP/Contents/MacOS/Rounds"
cp "$BIN/rounds-hook" "$APP/Contents/Helpers/rounds-hook"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# VERSION is the one place the version lives; Settings reads it from there, and Sparkle compares CFBundleVersion.
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $(cat VERSION)" -c "Add :CFBundleVersion string $(cat VERSION)" "$APP/Contents/Info.plist"
cp Resources/*.svg Resources/rounds-pi.ts "$APP/Contents/Resources/"
cp Resources/AppIcon.icns Resources/henry.png "$APP/Contents/Resources/"
# The stable self-signed identity when a keychain has it (the release, website/docs/release.md): each build then has the
# same designated requirement, so macOS permissions and Sparkle's code signature check hold across updates. Else ad hoc.
IDENTITY="Rounds Self-Signed"
security find-identity -p codesigning | grep -q "\"$IDENTITY\"" || IDENTITY=-
codesign --force --deep -s "$IDENTITY" "$APP"
if [ "$1" = "--install" ]; then
    rm -rf "/Applications/Rounds.app"
    cp -R "$APP" /Applications/
    APP="/Applications/Rounds.app"
fi
echo "$APP"
