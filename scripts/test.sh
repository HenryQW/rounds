#!/bin/sh
# Command Line Tools builds can miss the Swift Testing macro plugin on incremental builds.
set -e
plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [ -f "$plugins/libTestingMacros.dylib" ]; then
    swift build
    exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
fi
exec swift test "$@"
