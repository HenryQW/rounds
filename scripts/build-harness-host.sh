#!/bin/sh
# Build the pinned source. A supplied source checkout is read-only.
set -eu
cd -P "$(dirname "$0")/.."
ROOT="$PWD"
NODE="$(node -p 'process.execPath')"
scripts/check-harness-node.sh "$NODE"
PIN=5a14e69c067d40dfbff4f2fff7d3b34c897e2dc9
SOURCE="${1:-${ROUNDS_PI_SOURCE:-}}"
mkdir -p .build
STAGE="$(mktemp -d "$ROOT/.build/harness-source.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
if [ -z "$SOURCE" ]; then
    SOURCE="$STAGE/upstream"
    git init -q "$SOURCE"
    git -C "$SOURCE" fetch --depth 1 https://github.com/earendil-works/pi.git "$PIN"
    git -C "$SOURCE" checkout -q --detach FETCH_HEAD
fi
SOURCE="$(cd -P "$SOURCE" && pwd -P)"
[ "$(git -C "$SOURCE" rev-parse HEAD)" = "$PIN" ] || { echo "Wrong pi source commit." >&2; exit 1; }
git -C "$SOURCE" archive "$PIN" | tar -x -C "$STAGE"
# Generated model data is not tracked upstream. Use the checked cache when one was supplied.
if [ -d "$SOURCE/packages/ai/src/providers/data" ]; then
    cp -R "$SOURCE/packages/ai/src/providers/data" "$STAGE/packages/ai/src/providers/data"
fi
cd -P "$STAGE"
npm ci --ignore-scripts --no-audit --no-fund
for PACKAGE in telemetry schema chord codemode; do
    npm run build --workspace "packages/$PACKAGE"
done
if [ ! -d packages/ai/src/providers/data ]; then
    npm run hydrate-model-data --workspace packages/ai
fi
npm run build:offline --workspace packages/ai
npm run build --workspace packages/durable
mkdir -p "$ROOT/.build/harness-host"
cp "$ROOT/Resources/harness-host.mjs" host.mjs
node_modules/.bin/esbuild host.mjs --bundle --platform=node --format=esm \
    --outfile="$ROOT/.build/harness-host/host.mjs" \
    --banner:js='import { createRequire as __createRequire } from "node:module"; const require = __createRequire(import.meta.url);'
cp "$NODE" "$ROOT/.build/harness-host/node"
"$ROOT/scripts/check-harness-node.sh" "$ROOT/.build/harness-host/node"
printf '%s\n' "$PIN" > "$ROOT/.build/harness-host/commit"
"$ROOT/.build/harness-host/node" --check "$ROOT/.build/harness-host/host.mjs"
