#!/bin/sh
# Command Line Tools builds can miss the Swift Testing macro plugin on incremental builds; pass its path explicitly.
set -e
swift build
exec swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing "$@"
