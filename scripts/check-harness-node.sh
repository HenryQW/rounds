#!/bin/sh
# A copied Node executable must use macOS libraries and support the host.
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

# The input comes first: an older lipo (Xcode 16) reads every word after -verify_arch as an architecture.
if ! lipo "$NODE" -verify_arch arm64; then
    echo "Node has no Apple silicon arm64 slice: $NODE" >&2
    exit 1
fi

if ! env -i PATH=/usr/bin:/bin arch -arm64 "$NODE" --input-type=commonjs -e '
    const { DatabaseSync } = require("node:sqlite");
    if (typeof DatabaseSync !== "function") throw new Error("DatabaseSync is unavailable");
'; then
    echo "Node cannot load node:sqlite DatabaseSync: $NODE" >&2
    exit 1
fi

# Exercise the bundled imports and storage using the executable that will ship.
if [ "$#" -ge 2 ]; then
    HOST="$2"
    COMMIT="${3:?Expected Harness source commit.}"
    TMP_BASE="${TMPDIR:-/tmp}"
    TMP="$(mktemp -d "${TMP_BASE%/}/rounds-host-check.XXXXXX")"
    trap 'rm -rf "$TMP"' EXIT HUP INT TERM
    if ! env -i PATH=/usr/bin:/bin ROUNDS_HARNESS_RUN_ID=00000000-0000-0000-0000-000000000000 \
        arch -arm64 "$NODE" --input-type=commonjs - "$HOST" "$TMP" "$COMMIT" <<'NODE_CHECK'
const { spawn } = require("node:child_process");
const host = spawn(process.execPath, [process.argv[2], process.argv[3],
    "ROUNDS_HARNESS_RUN_ID=00000000-0000-0000-0000-000000000000"],
    { stdio: ["pipe", "pipe", "inherit"] });
let buffer = "";
let step = 0;
let failed = false;
const timer = setTimeout(() => fail("Host health check timed out."), 20000);
function fail(message) {
    if (failed) return;
    failed = true;
    console.error(message);
    host.kill("SIGKILL");
    process.exitCode = 1;
}
host.on("error", (error) => fail(error.message));
host.stdin.on("error", (error) => fail(error.message));
host.stdout.on("data", (chunk) => {
    buffer += chunk;
    let end;
    while ((end = buffer.indexOf("\n")) !== -1) {
        const line = buffer.slice(0, end);
        buffer = buffer.slice(end + 1);
        let reply;
        try { reply = JSON.parse(line); } catch { return fail("Invalid host reply."); }
        const command = step === 0 ? "health" : "shutdown";
        if (step > 1 || reply.version !== 1 || reply.id !== command ||
            reply.command !== command || reply.ok !== true || reply.commit !== process.argv[4] ||
            (command === "health" && reply.scheduling !== "paused")) {
            return fail(`Unexpected host ${command} reply: ${line}`);
        }
        step++;
        if (step === 1) host.stdin.write('{"version":1,"id":"shutdown","command":"shutdown"}\n');
    }
});
host.on("close", (code, signal) => {
    clearTimeout(timer);
    if (!failed && (code !== 0 || signal || step !== 2)) fail("Host did not complete the health and shutdown checks.");
});
host.stdin.write('{"version":1,"id":"health","command":"health"}\n');
NODE_CHECK
    then
        echo "Node cannot run the bundled harness host: $NODE" >&2
        exit 1
    fi
fi
