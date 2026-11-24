#!/bin/sh
# Sign the app after its nested code. Permit the installed Sparkle binary and macOS libraries.
set -eu
IDENTITY="$1"
APP="$2"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
HASH="$(codesign --display --arch arm64 --verbose=4 "$SPARKLE" 2>&1 | sed -n 's/^CDHash=//p')"
if [ "${#HASH}" -ne 40 ]; then
    echo 'Could not read the arm64 Sparkle signature.' >&2
    exit 1
fi
DATA="$(printf '%s' "$HASH" | xxd -r -p | base64)"
CONSTRAINT="$(mktemp)"
trap 'rm -f "$CONSTRAINT"' EXIT
cat > "$CONSTRAINT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>\$or</key><dict>
    <key>validation-category</key><integer>1</integer>
    <key>cdhash</key><data>$DATA</data>
</dict></dict></plist>
EOF
codesign --force -s "$IDENTITY" --options runtime --library-constraint "$CONSTRAINT" \
    --entitlements Resources/LinearKeychainClient.entitlements "$APP"
