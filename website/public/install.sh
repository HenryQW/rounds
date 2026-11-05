#!/bin/sh
# Installs Rounds: curl -fsSL https://rounds.henry.wang/install.sh | sh
# A download with curl gets no quarantine flag, so macOS does not call Rounds damaged. The script installs only a copy
# signed with the Rounds release certificate, then opens it.
set -eu

URL="https://github.com/HenryQW/rounds/releases/latest/download/Rounds.dmg"
APP="/Applications/Rounds.app"
# SHA-256 of the "Rounds Self-Signed" certificate (it expires on 2046-10-29). Another certificate can have the same name.
CERT="79d814d7989ef3f7b971c9025634c106f82b24aa6a888283748b7eb3eca296dd"

fail() { echo "$1" >&2; exit 1; }
[ "$(uname -m)" = arm64 ] || fail "Rounds needs a Mac with Apple silicon."
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 27 ] || fail "Rounds needs macOS 27 or later."

TMP="$(mktemp -d)"
trap 'hdiutil detach -quiet "$TMP/mnt" 2>/dev/null || true; rm -rf "$TMP"' EXIT

echo "Downloading Rounds..."
curl -fL --progress-bar "$URL" -o "$TMP/Rounds.dmg"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$TMP/mnt" "$TMP/Rounds.dmg"

codesign --verify --deep --strict "$TMP/mnt/Rounds.app" || fail "The download is not valid. Nothing is installed."
codesign -d --extract-certificates="$TMP/cert" "$TMP/mnt/Rounds.app" 2>/dev/null
[ "$(shasum -a 256 "$TMP/cert0" | cut -d' ' -f1)" = "$CERT" ] || fail "The download is not signed by Rounds. Nothing is installed."

# A running copy quits first, so the new one can replace it.
osascript -e 'quit app id "com.henryqw.rounds"' 2>/dev/null || true
rm -rf "$APP"
ditto "$TMP/mnt/Rounds.app" "$APP" || fail "Cannot write to /Applications. Sign in as an administrator and try again."
open "$APP"
echo "Rounds is installed. Its pill is at the right edge of your screen."
