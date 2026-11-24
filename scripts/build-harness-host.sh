#!/bin/sh
# Build the pinned source. A supplied source checkout is read-only.
set -eu
cd -P "$(dirname "$0")/.."
ROOT="$PWD"
unset SIGNING_CERTIFICATE_P12 SIGNING_CERTIFICATE_PASSWORD SPARKLE_ED_PRIVATE_KEY TAP_TOKEN
NODE="$(node -p 'process.execPath')"
scripts/check-harness-node.sh "$NODE"
PIN=5a14e69c067d40dfbff4f2fff7d3b34c897e2dc9
SOURCE="${1:-${ROUNDS_PI_SOURCE:-https://github.com/earendil-works/pi.git}}"
# A local source supplies Git objects only. Its replacement refs, archive attributes and worktree are not inputs.
export GIT_NO_REPLACE_OBJECTS=1
if [ "$SOURCE" != https://github.com/earendil-works/pi.git ]; then
    SOURCE="$(cd -P "$SOURCE" && pwd -P)"
    [ "$(git -C "$SOURCE" rev-parse HEAD)" = "$PIN" ] || { echo "Wrong pi source commit." >&2; exit 1; }
fi
mkdir -p .build
WORK="$(mktemp -d "$ROOT/.build/harness-source.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
REPO="$WORK/upstream"
STAGE="$WORK/source"
git init -q --bare --template= "$REPO"
git -C "$REPO" fetch --no-tags --depth 1 "$SOURCE" "$PIN"
mkdir "$STAGE"
GIT_ATTR_NOSYSTEM=1 git -C "$REPO" -c core.attributesFile=/dev/null archive --output="$WORK/source.tar" "$PIN"
tar -xf "$WORK/source.tar" -C "$STAGE"
cd -P "$STAGE"
npm ci --ignore-scripts --no-audit --no-fund
for PACKAGE in telemetry schema chord codemode; do
    npm run build --workspace "packages/$PACKAGE"
done
# Hydrate with the pinned generator, which validates the data against the tracked catalog.
npm run hydrate-model-data --workspace packages/ai
npm run build:offline --workspace packages/ai
npm run build --workspace packages/durable
mkdir -p "$ROOT/.build/harness-host"
cp "$ROOT"/Resources/harness-*.mjs .
node_modules/.bin/esbuild harness-host.mjs --bundle --platform=node --format=esm \
    --outfile="$ROOT/.build/harness-host/host.mjs" \
    --banner:js='import { createRequire as __createRequire } from "node:module"; const require = __createRequire(import.meta.url);'
cp "$NODE" "$ROOT/.build/harness-host/node"
"$ROOT/scripts/check-harness-node.sh" "$ROOT/.build/harness-host/node" "$ROOT/.build/harness-host/host.mjs" "$PIN"
printf '%s\n' "$PIN" > "$ROOT/.build/harness-host/commit"
"$ROOT/.build/harness-host/node" --check "$ROOT/.build/harness-host/host.mjs"

if [ "${ROUNDS_TEST_HARNESS_WORKFLOW:-0}" = 1 ]; then
    for TEST in test-harness-approval-gate.mjs test-harness-task-dispatch.mjs; do
        cp "$ROOT/scripts/$TEST" .
        node_modules/.bin/esbuild "$TEST" --bundle --platform=node --format=esm \
            --outfile="$WORK/$TEST" \
            --banner:js='import { createRequire as __createRequire } from "node:module"; const require = __createRequire(import.meta.url);'
    done
    "$NODE" --test "$WORK/test-harness-approval-gate.mjs" "$WORK/test-harness-task-dispatch.mjs"
fi
