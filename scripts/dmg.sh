#!/bin/sh
# Pack build/Rounds.app into build/Rounds.dmg, with a link to /Applications to drag it onto and a note on the first
# launch. A release publishes this one file for the download, the Homebrew cask and Sparkle updates.
set -e
cd "$(dirname "$0")/.."
DMG="build/Rounds.dmg"
STAGE="$(mktemp -d)"
cp -R build/Rounds.app "$STAGE/"
# macOS calls the downloaded app damaged; this note says how to open it.
cp "packaging/dmg/Read me if Rounds is damaged.txt" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
diskutil image create from --format UDZO --volumeName Rounds "$STAGE" "$DMG" >/dev/null
rm -rf "${STAGE:?}"
echo "$DMG"
