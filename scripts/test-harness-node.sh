#!/bin/sh
# Exercise the release Node library and runtime checks with real executables.
set -eu
cd -P "$(dirname "$0")/.."
CHECK="$PWD/scripts/check-harness-node.sh"
PIN=5a14e69c067d40dfbff4f2fff7d3b34c897e2dc9
TMP_BASE="${TMPDIR:-/tmp}"
TMP="$(mktemp -d "${TMP_BASE%/}/rounds-node-check.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

printf 'int main(void) { return 1; }\n' > "$TMP/main.c"
printf 'int fixture(void) { return 1; }\n' > "$TMP/fixture.c"
printf 'int fixture(void); int main(void) { return fixture(); }\n' > "$TMP/linked.c"
clang -arch arm64 "$TMP/main.c" -o "$TMP/standalone"
clang -arch x86_64 "$TMP/main.c" -o "$TMP/intel"
if "$CHECK" "$TMP/intel" > "$TMP/error" 2>&1; then
    echo 'Accepted an Intel-only binary.' >&2
    exit 1
fi
grep -F 'Node has no Apple silicon arm64 slice:' "$TMP/error" > /dev/null
if "$CHECK" "$TMP/standalone" > "$TMP/error" 2>&1; then
    echo 'Accepted an executable without Node runtime capabilities.' >&2
    exit 1
fi
grep -F 'Node cannot load node:sqlite DatabaseSync:' "$TMP/error" > /dev/null
if [ -n "${ROUNDS_TEST_UNSUPPORTED_NODE:-}" ]; then
    if "$CHECK" "$ROUNDS_TEST_UNSUPPORTED_NODE" > "$TMP/error" 2>&1; then
        echo 'Accepted a Node runtime without node:sqlite.' >&2
        exit 1
    fi
    grep -F 'Node cannot load node:sqlite DatabaseSync:' "$TMP/error" > /dev/null
fi

# A Homebrew Node is allowed for the test runner, but it cannot be packaged.
# Use it for the live capability checks only when it passes the release check.
if command -v node > /dev/null 2>&1; then
    NODE="$(node -p 'process.execPath')"
    if "$CHECK" "$NODE" > "$TMP/node-check" 2>&1; then
        printf 'import "node:rounds_missing_fixture";\n' > "$TMP/broken-host.mjs"
        if "$CHECK" "$NODE" "$TMP/broken-host.mjs" "$PIN" > "$TMP/error" 2>&1; then
            echo 'Accepted a host with an unavailable module.' >&2
            exit 1
        fi
        grep -F 'Node cannot run the bundled harness host:' "$TMP/error" > /dev/null
        printf 'throw new Error("Unexpected NODE_OPTIONS");\n' > "$TMP/preload.cjs"
        NODE_OPTIONS="--require=$TMP/preload.cjs" "$CHECK" "$NODE"
        for BAD_REPLY in health shutdown; do
            cat > "$TMP/wrong-commit.mjs" <<EOF
import { createInterface } from "node:readline";
createInterface({ input: process.stdin }).on("line", (line) => {
    const request = JSON.parse(line);
    const commit = request.command === "$BAD_REPLY" ? "wrong" : "$PIN";
    const reply = { version: 1, id: request.id, command: request.command, ok: true, commit, scheduling: "paused" };
    process.stdout.write(JSON.stringify(reply) + "\\n", () => {
        if (request.command === "shutdown") process.exit(0);
    });
});
EOF
            if "$CHECK" "$NODE" "$TMP/wrong-commit.mjs" "$PIN" > "$TMP/error" 2>&1; then
                echo "Accepted an incorrect commit in the $BAD_REPLY reply." >&2
                exit 1
            fi
            grep -F "Unexpected host $BAD_REPLY reply:" "$TMP/error" > /dev/null
        done
    fi
fi
if [ -n "${ROUNDS_HARNESS_PAYLOAD:-}" ]; then
    NODE_OPTIONS="--require=$TMP/preload.cjs" "$CHECK" "$ROUNDS_HARNESS_PAYLOAD/node" "$ROUNDS_HARNESS_PAYLOAD/host.mjs" "$PIN"
fi

for NAME in '@rpath/libfixture.dylib' "$TMP/libfixture.dylib"; do
    clang -dynamiclib "$TMP/fixture.c" -install_name "$NAME" -o "$TMP/libfixture.dylib"
    clang "$TMP/linked.c" -L"$TMP" -lfixture -o "$TMP/linked"
    if "$CHECK" "$TMP/linked" > "$TMP/error" 2>&1; then
        echo "Accepted external library: $NAME" >&2
        exit 1
    fi
    grep -F "Node is not portable; external library: $NAME" "$TMP/error" > /dev/null
done

# Check the Intel slice of a universal executable too.
clang -arch x86_64 -dynamiclib "$TMP/fixture.c" -install_name '@rpath/libfixture.dylib' -o "$TMP/libfixture.dylib"
clang -arch x86_64 "$TMP/linked.c" -L"$TMP" -lfixture -o "$TMP/other"
lipo -create "$TMP/standalone" "$TMP/other" -output "$TMP/universal"
if "$CHECK" "$TMP/universal" > "$TMP/error" 2>&1; then
    echo 'Accepted an external library in a universal executable.' >&2
    exit 1
fi
grep -F 'Node is not portable; external library: @rpath/libfixture.dylib' "$TMP/error" > /dev/null

if "$CHECK" "$TMP/main.c" > "$TMP/error" 2>&1; then
    echo "Accepted a file that is not a Mach-O executable." >&2
    exit 1
fi
grep -F 'Cannot inspect Node libraries' "$TMP/error" > /dev/null
printf '%s\n' 'Node packaging checks passed.'
