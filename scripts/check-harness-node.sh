#!/bin/sh
# A copied Node executable must load only libraries supplied by macOS.
set -eu

NODE="$1"
if ! LIBRARIES="$(LC_ALL=C otool -arch all -L "$NODE")"; then
    echo "Cannot inspect Node libraries: $NODE" >&2
    exit 1
fi

printf '%s\n' "$LIBRARIES" | LC_ALL=C awk '
    /^[[:space:]]/ {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        if (line !~ / \(compatibility version .*\)$/) {
            print "Cannot parse Node library: " line > "/dev/stderr"
            bad = 1
            exit 1
        }
        sub(/ \(compatibility version .*\)$/, "", line)
        count++
        if (line !~ /^\/usr\/lib\// && line !~ /^\/System\/Library\// || line ~ /\/\.\.\//) {
            print "Node is not portable; external library: " line > "/dev/stderr"
            print "Use a standalone Node distribution, then rebuild." > "/dev/stderr"
            bad = 1
            exit 1
        }
    }
    END {
        if (!count && !bad) {
            print "Cannot inspect Node libraries; no libraries found." > "/dev/stderr"
            exit 1
        }
    }
'
