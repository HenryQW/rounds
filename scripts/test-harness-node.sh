#!/bin/sh
# Exercise the release Node library check with real Mach-O executables.
set -eu
cd -P "$(dirname "$0")/.."
CHECK="$PWD/scripts/check-harness-node.sh"
TMP_BASE="${TMPDIR:-/tmp}"
TMP="$(mktemp -d "${TMP_BASE%/}/rounds-node-check.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

printf 'int main(void) { return 0; }\n' > "$TMP/main.c"
printf 'int fixture(void) { return 1; }\n' > "$TMP/fixture.c"
printf 'int fixture(void); int main(void) { return fixture(); }\n' > "$TMP/linked.c"
clang "$TMP/main.c" -o "$TMP/standalone"
"$CHECK" "$TMP/standalone"

for NAME in '@rpath/libfixture.dylib' "$TMP/libfixture.dylib"; do
    clang -dynamiclib "$TMP/fixture.c" -install_name "$NAME" -o "$TMP/libfixture.dylib"
    clang "$TMP/linked.c" -L"$TMP" -lfixture -o "$TMP/linked"
    if "$CHECK" "$TMP/linked" > "$TMP/error" 2>&1; then
        echo "Accepted external library: $NAME" >&2
        exit 1
    fi
    grep -F "Node is not portable; external library: $NAME" "$TMP/error" > /dev/null
done

# The non-native slice of a universal executable must be checked too.
case "$(uname -m)" in
    arm64) OTHER_ARCH=x86_64 ;;
    x86_64) OTHER_ARCH=arm64 ;;
    *) echo 'Unsupported test architecture.' >&2; exit 1 ;;
esac
clang -arch "$OTHER_ARCH" -dynamiclib "$TMP/fixture.c" -install_name '@rpath/libfixture.dylib' -o "$TMP/libfixture.dylib"
clang -arch "$OTHER_ARCH" "$TMP/linked.c" -L"$TMP" -lfixture -o "$TMP/other"
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
