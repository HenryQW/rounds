#!/bin/sh
# Run from the repository root. Check Swift target declarations and active macOS imports.
set -eu

manifest=$(swift package dump-package)
if ! printf '%s\n' "$manifest" | jq -e '
  def dependencies($name):
    [.targets[] | select(.name == $name) | .dependencies | map((.byName // .target // [null])[0])];
  dependencies("RoundsCore") == [[]] and
  dependencies("rounds-hook") == [["RoundsCore"]]
' >/dev/null; then
  echo 'RoundsCore must have no target or product dependencies. rounds-hook may depend only on RoundsCore.' >&2
  exit 1
fi
if ! printf '%s\n' "$manifest" | jq -e '
  (.swiftLanguageVersions // [(.toolsVersion._version | split(".")[0])]) == ["6"] and
  [.targets[] | select(.name == "RoundsCore") | .settings] == [[]]
' >/dev/null; then
  echo 'Update the import check for the new RoundsCore compiler settings.' >&2
  exit 1
fi

sources=$(mktemp)
trap 'rm -f "$sources"' EXIT
package=$(swift package describe --type json)
printf '%s\n' "$package" | jq -er '
  .targets[] | select(.name == "RoundsCore" and (.sources | length > 0)) |
  .path as $path | .sources[] | $path + "/" + .
' > "$sources"

sdk=$(xcrun --sdk macosx --show-sdk-path)
scan() {
  swiftc -frontend -scan-dependencies -import-prescan -sdk "$sdk" -swift-version 6 -D SWIFT_PACKAGE "$@"
}
implicit=$(scan - </dev/null)
debug=$(scan -module-name RoundsCore -D DEBUG -enable-testing -filelist "$sources")
release=$(scan -module-name RoundsCore -O -filelist "$sources")
unexpected=$(printf '%s\n' "$debug" "$release" | jq -rs --argjson implicit "$implicit" '
  if length != 2 or any(.[]; (.imports | type) != "array") then error("expected two Swift import scans")
  else [.[].imports[]] | unique - $implicit.imports - ["Darwin", "Foundation", "SQLite3"] | .[] end
')
if [ -n "$unexpected" ]; then
  printf 'RoundsCore imports a module outside its platform dependencies:\n%s\n' "$unexpected" >&2
  exit 1
fi
