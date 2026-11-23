#!/bin/sh
# Build the private client with Dagger nesting disabled for foreground commands.
set -eu
cd -P "$(dirname "$0")/.."
root=$PWD
pin=89ebe7765ec067a07c51de104822056eb217c1b9
source=${1:-https://github.com/dagger/container-use.git}
if [ "$source" != https://github.com/dagger/container-use.git ]; then
    source=$(cd -P "$source" && pwd -P)
fi
clean_git() {
    env -i PATH="$PATH" HOME=/var/empty GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        GIT_NO_REPLACE_OBJECTS=1 GIT_TERMINAL_PROMPT=0 git "$@"
}
out="$root/.build/container-use"
mkdir -p "$out"
work=$(mktemp -d "$out/.build.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
clean_git init --quiet --template= "$work"
clean_git -C "$work" fetch --quiet --no-tags --depth 1 "$source" "$pin"
clean_git -C "$work" checkout --quiet --detach "$pin"
clean_git -C "$work" apply "$root/scripts/container-use-foreground.patch"
cd "$work"
CGO_ENABLED=0 GOENV=off GOFLAGS= GOWORK=off GOTOOLCHAIN=local go build -mod=readonly -trimpath -buildvcs=false \
    -o "$work/container-use" ./cmd/container-use
mv "$work/container-use" "$out/container-use"
"$out/container-use" --version
