#!/bin/sh
# Command Line Tools builds can miss the Swift Testing macro plugin on incremental builds; pass its path explicitly.
set -e
scripts/test-harness-node.sh
if [ -n "${ROUNDS_HARNESS_PAYLOAD:-}" ]; then
    "$ROUNDS_HARNESS_PAYLOAD/node" --test scripts/test-harness-bouncer.mjs
fi
swift build
exec swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing "$@"
