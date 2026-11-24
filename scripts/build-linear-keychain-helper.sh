#!/bin/sh
# Rebuild only when the helper changes. An ordinary app build uses these exact Mach-O bytes.
set -eu
cd -P "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
xcrun clang -arch arm64 -mmacos-version-min=27.0 -O2 -fobjc-arc -Wall -Wextra -Werror \
    -Wl,-no_adhoc_codesign -framework Foundation -framework Security \
    Sources/LinearKeychain/main.m -o "$WORK/LinearKeychain.macho"
install -m 644 "$WORK/LinearKeychain.macho" Resources/LinearKeychain.macho
shasum -a 256 Sources/LinearKeychain/main.m Resources/LinearKeychain.plist Resources/LinearKeychain.macho > Resources/LinearKeychain.sha256
