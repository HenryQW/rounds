#!/bin/sh
# Pack build/Rounds.app into build/Rounds-<VERSION>.dmg, with a link to /Applications to drag it onto.
set -e
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
DMG="build/Rounds-$VERSION.dmg"
STAGE="$(mktemp -d)"
cp -R build/Rounds.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
diskutil image create from --format UDZO --volumeName Rounds "$STAGE" "$DMG" >/dev/null
rm -rf "${STAGE:?}"
echo "$DMG"
