#!/bin/sh
# Build "build/Rounds.app" (ad-hoc signed). --install also copies it to /Applications.
set -e
cd "$(dirname "$0")/.."
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="build/Rounds.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/Rounds" "$APP/Contents/MacOS/Rounds"
cp "$BIN/rounds-hook" "$APP/Contents/Helpers/rounds-hook"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# VERSION is the one place the version lives; Settings reads it from there.
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $(cat VERSION)" "$APP/Contents/Info.plist"
cp Resources/*.svg Resources/rounds-pi.ts "$APP/Contents/Resources/"
cp Resources/AppIcon.icns Resources/henry.png "$APP/Contents/Resources/"
codesign --force --deep -s - "$APP"
if [ "$1" = "--install" ]; then
    rm -rf "/Applications/Rounds.app"
    cp -R "$APP" /Applications/
    APP="/Applications/Rounds.app"
fi
echo "$APP"
