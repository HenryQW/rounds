#!/bin/bash
# Copies plugins/bouncer as the mod `bouncer-dev` into a session's dev-mods folder, for a band preview
# with real Bouncer data while the installed bouncer plugin stays as it is.
# The copy reads the installed plugin's data folder and hides the installed plugin's band row.
# Usage: scripts/bouncer-dev-preview.sh <dev-mods folder of the Bouncer session>
#   (~/.claude/dev-mods/<session uuid>; the session loads the plugin-authoring skill first, which starts its watch.)
# Remove the folder <dir>/bouncer-dev to end the preview.
set -euo pipefail
dir=${1:?usage: bouncer-dev-preview.sh <dev-mods folder>}
data=${BOUNCER_DATA:-$HOME/.claude/plugins/data/bouncer-rounds}
src=$(cd "$(dirname "$0")/../plugins/bouncer" && pwd)
[ -d "$data" ] || { echo "no installed bouncer data folder: $data" >&2; exit 1; }
dst="$dir/bouncer-dev"
tmp=$(mktemp -d)
cp -R "$src/." "$tmp/"
rm -f "$tmp/hooks/band.test.tsx"
sed -i '' 's/"name": "bouncer"/"name": "bouncer-dev"/' "$tmp/.claude-plugin/plugin.json"
sed -i '' "s/'bouncer': { pool: Pool }/'bouncer-dev': { pool: Pool }/" "$tmp/types/index.d.ts"
r="$tmp/hooks/register.tsx"
sed -i '' "s/atom({ plugin: 'bouncer', key: 'pool' }/atom({ plugin: 'bouncer-dev', key: 'pool' }/" "$r"
# The queue, questions and owner file of the installed plugin.
sed -i '' "s|const data = (await \$.process.hookEnv()).CLAUDE_PLUGIN_DATA|const data = '$data'|" "$r"
# Only this copy's band: the installed plugin's row leaves the band while the copy is loaded.
cat >> "$r" <<'EOF'

export const registerPreview: Register = on => {
  on('ui.render', { component: 'AbovePromptList' }, ($, e, next) => next({ ...e, rows: e.rows.filter(r => r.plugin !== 'bouncer') }))
    .catch(($, e, next) => next(e))
}
EOF
# Run the preview hook from register.
sed -i '' 's/^export const register: Register = (on, options) => {$/export const register: Register = (on, options) => {\n  registerPreview(on, options)/' "$r"
for s in "'bouncer-dev', key" "const data = '$data'" "registerPreview(on, options)"; do
  grep -qF "$s" "$r" || { echo "patch failed: $s" >&2; exit 1; }
done
mkdir -p "$dir"
rm -rf "$dst"
mv "$tmp" "$dst"
echo "$dst"
