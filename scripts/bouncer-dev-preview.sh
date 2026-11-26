#!/bin/bash
# Copies plugins/bouncer as the mod `bouncer-dev` into a session's dev-mods folder, for a band preview
# with real Bouncer data while the installed bouncer plugin stays as it is.
# The copy reads the installed plugin's data folder and hides the installed plugin's band row.
# Usage: scripts/bouncer-dev-preview.sh <dev-mods folder of the Bouncer session>
#   (~/.claude/dev-mods/<session uuid>; the session loads the plugin-authoring skill first, which starts its watch.)
# Remove the folder <dir>/bouncer-dev to end the preview.
# BOUNCER_RECORDS=<folder> gives the copy the ticket records (the records_dir option), for the Due count and PR links.
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
# bouncer-ledger runs from the copy, with the installed data folder and, given BOUNCER_RECORDS, those records.
sed -i '' "/^const ledgerList = /,/^}/s|const env = await \$.process.hookEnv()|const env = { ...(await \$.process.hookEnv()), CLAUDE_PLUGIN_ROOT: '$dst', CLAUDE_PLUGIN_DATA: '$data' }|" "$r"
[ -n "${BOUNCER_RECORDS:-}" ] && sed -i '' "s|const records = String(options.records_dir ?? '').trim()|const records = '$BOUNCER_RECORDS'|" "$r"
# The copy starts with an empty pool: it turns on at load when the installed owner file names this session,
# and only then hides the installed plugin's row, so the band is never empty. Bartenders show once renamed.
cat >> "$r" <<'EOF'

const seedPreview = async ($: EngineInterface) => {
  if ((await dataFile($, 'bouncer')).trim() === (await $.session.id())) await update($, pool, p => (p.isOn ? p : { ...p, isOn: true }))
}

export const registerPreview: Register = on => {
  on('ui.render', { component: 'AbovePromptList' }, async ($, e, next) =>
    (await read($, pool)).isOn ? next({ ...e, props: { ...e.props, rows: e.props.rows.filter(r => r.plugin !== 'bouncer') } }) : next(e))
    .catch(($, e, next) => next(e))
}
EOF
# Run the preview hook from register.
sed -i '' 's/^export const register: Register = (on, options) => {$/export const register: Register = (on, options) => {\n  registerPreview(on, options)/' "$r"
# Seed the pool at session start (a reload runs it too), before its refresh.
sed -i '' 's/^    if ((await read(\$, pool)).isOn) {$/    await seedPreview($).catch(() => undefined)\n&/' "$r"
for s in "'bouncer-dev', key" "const data = '$data'" "CLAUDE_PLUGIN_ROOT: '$dst'" "registerPreview(on, options)" "    await seedPreview(\$)"; do
  grep -qF "$s" "$r" || { echo "patch failed: $s" >&2; exit 1; }
done
mkdir -p "$dir"
rm -rf "$dst"
mv "$tmp" "$dst"
echo "$dst"
