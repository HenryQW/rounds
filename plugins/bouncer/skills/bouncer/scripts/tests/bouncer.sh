#!/usr/bin/env bash
# Fixture test for bouncer-data, bouncer-title, bouncer-route, bouncer-queue, bouncer-report and bartender-branch. Boundary cases first. No network.
# Run: bash scripts/tests/bouncer.sh (from the skill folder)
set -uo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2] want [$3]"; fail=1; fi; }

# bouncer-title: with BOUNCER_STATUS_CODES and no stored option unset it uses the status_codes default in plugin.json
unset BOUNCER_STATUS_CODES
export CLAUDE_CONFIG_DIR="$tmp/config"
ok "title: bouncer at 0" "$(./bouncer-title --bouncer 0)" "Bouncer"
ok "title: bouncer count" "$(./bouncer-title --bouncer 2)" "!2 Bouncer"
./bouncer-title --bouncer -1 2>/dev/null; ok "title: negative count exits 2" $? 2
./bouncer-title "Not A Status" ABC-1 r 2>/dev/null; ok "title: unknown status exits 2" $? 2
./bouncer-title "In Progress" ABC-1 2>/dev/null; ok "title: missing repo exits 2" $? 2
ok "title: idle" "$(./bouncer-title --idle my-repo)" "[Idle] Bartender - my-repo"
ok "title: bartender (default codes)" "$(./bouncer-title "In Progress" ABC-1234 my-repo)" "[Dev] ABC-1234 - Bartender - my-repo"
ok "title: github closed (default codes)" "$(./bouncer-title Closed 12 my-repo)" "[Done] 12 - Bartender - my-repo"
ok "title: empty option uses the default" "$(BOUNCER_STATUS_CODES=" " ./bouncer-title Todo T r)" "[Todo] T - Bartender - r"
BOUNCER_STATUS_CODES="Todo=Todo" ./bouncer-title Closed T r 2>/dev/null; ok "title: a set option replaces the default" $? 2
BOUNCER_STATUS_CODES="Todo" ./bouncer-title Todo T r 2>/dev/null; ok "title: pair without = exits 2" $? 2
mkdir -p "$tmp/config"; echo '{"pluginConfigs": {"bouncer@rounds": {"options": {"status_codes": "Won'"'"'t Do=Wont"}}}}' > "$tmp/config/settings.json"
ok "title: the stored option without the env var" "$(./bouncer-title "Won't Do" ABC-9 web)" "[Wont] ABC-9 - Bartender - web"
ok "title: the env var wins over the stored option" "$(BOUNCER_STATUS_CODES="Won't Do=WD" ./bouncer-title "Won't Do" ABC-9 web)" "[WD] ABC-9 - Bartender - web"
rm "$tmp/config/settings.json"
ok "title: custom codes, apostrophe, cta, spaces" "$(BOUNCER_STATUS_CODES=" Won't Do = Wont ;; Code Review=CR; " ./bouncer-title "Won't Do" ABC-9 web --cta)" "![Wont] ABC-9 - Bartender - web"

# bouncer-route
route() { echo "$1" | ./bouncer-route | jq -r "$2"; }
echo '{"sessions": []}' | ./bouncer-route >/dev/null; ok "route: no request exits 2" $? 2
echo '{"sessions": [], "request": {"ticket": "ABC-1", "repo": ""}}' | ./bouncer-route >/dev/null; ok "route: empty repo exits 2" $? 2
ok "route: empty pool starts" "$(route '{"sessions": [], "request": {"ticket": "ABC-1", "repo": "a"}}' .action)" start
S='[{"sessionId":"s1","title":"[Dev] ABC-1 - Bartender - a","isRunning":true},
    {"sessionId":"s2","title":"[Idle] Bartender - b","isRunning":false},
    {"sessionId":"s3","title":"![CR] ABC-3 - Bartender - c"},
    {"sessionId":"s4","title":"[Spec] ABC-4 - Bartender - d"},
    {"sessionId":"s5","title":"[Idle] Bartender - e","isRunning":true},
    {"sessionId":"s6","title":"[Dev][ABC-7] Reply button"},
    {"sessionId":"s7","title":"[Idle] Bartender - f","isArchived":true}]'
ok "route: idle Bartender in repo is assigned" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"ABC-9\", \"repo\": \"b\"}}" '.action+" "+.sessionId')" "assign s2"
ok "route: idle title but running is busy" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"ABC-9\", \"repo\": \"e\"}}" .action)" queue
ok "route: busy repo under cap starts (one per ticket)" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"ABC-9\", \"repo\": \"a\"}, \"caps\": {\"active\": 9}}" .action)" start
ok "route: 4 active at cap 3 queues" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"ABC-9\", \"repo\": \"z\"}}" .action)" queue
ok "route: under cap starts" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"ABC-9\", \"repo\": \"z\"}, \"caps\": {\"active\": 5}}" .action)" start
ok "route: archived Bartender is ignored" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"ABC-9\", \"repo\": \"f\"}, \"caps\": {\"active\": 5}}" .action)" start

# bouncer-data
fake="$tmp/home/.claude/plugins/cache/mkt/bouncer/9.9.9/skills/bouncer/scripts"; mkdir -p "$fake"; cp bouncer-data "$fake/"
ok "data: a marketplace install uses <name>-<marketplace>" "$(env -u BOUNCER_DATA -u CLAUDE_PLUGIN_DATA CLAUDE_CONFIG_DIR="$tmp/cfg" "$fake/bouncer-data")" "$tmp/cfg/plugins/data/bouncer-mkt"
ok "data: the folder and tickets/ are made" "$([ -d "$tmp/cfg/plugins/data/bouncer-mkt/tickets" ] && echo yes)" yes
ok "data: CLAUDE_PLUGIN_DATA wins over the path" "$(env -u BOUNCER_DATA CLAUDE_PLUGIN_DATA="$tmp/pd" "$fake/bouncer-data")" "$tmp/pd"
dev="$tmp/checkout/plugins/bouncer/skills/bouncer/scripts"; mkdir -p "$dev"; cp bouncer-data "$dev/"   # not ./: the installed copy runs from plugins/cache
ok "data: a --plugin-dir checkout uses bouncer-inline" "$(env -u BOUNCER_DATA -u CLAUDE_PLUGIN_DATA CLAUDE_CONFIG_DIR="$tmp/cfg" "$dev/bouncer-data")" "$tmp/cfg/plugins/data/bouncer-inline"

# bouncer-queue (in the data folder)
export BOUNCER_DATA="$tmp/data"
./bouncer-queue pop >/dev/null 2>&1; ok "queue: pop on empty exits 1" $? 1
./bouncer-queue add "ABC-1 | a | Fast | x" 2>/dev/null; ok "queue: bad mode exits 2" $? 2
./bouncer-queue add "ABC-1 | a | Code" 2>/dev/null; ok "queue: 3 fields exits 2" $? 2
./bouncer-queue add "ABC-1 | a | Code | x | y" 2>/dev/null; ok "queue: 5 fields exits 2" $? 2
./bouncer-queue nope 2>/dev/null; ok "queue: bad command exits 2" $? 2
./bouncer-queue add "ABC-1 | a | Code | Linear"
./bouncer-queue add " ABC-2|b|Spike|notion "
./bouncer-queue add "ABC-1 | a | Mechanical | doc"
ok "queue: list keeps order, stale line replaced" "$(./bouncer-queue list | tr '\n' ';')" "ABC-2 | b | Spike | notion;ABC-1 | a | Mechanical | doc;"
ok "queue: the file is queue.md in the data folder" "$(head -n 1 "$tmp/data/queue.md")" "ABC-2 | b | Spike | notion"
ok "queue: pop prints the first line" "$(./bouncer-queue pop)" "ABC-2 | b | Spike | notion"
ok "queue: pop removes it" "$(./bouncer-queue list)" "ABC-1 | a | Mechanical | doc"
./bouncer-queue remove 2>/dev/null; ok "queue: remove without a ticket exits 2" $? 2
./bouncer-queue remove ABC-7 2>/dev/null; ok "queue: remove of a missing ticket exits 1" $? 1
./bouncer-queue add "ABC-3 | c | Code | x"
./bouncer-queue remove ABC-1; ok "queue: remove drops only that line" "$(./bouncer-queue list)" "ABC-3 | c | Code | x"
./bouncer-queue remove ABC-3
BOUNCER_DATA="$tmp/data2" ./bouncer-queue add "T | r | Spike | user's msg" 2>/dev/null; ok "queue: apostrophe is kept" "$(cat "$tmp/data2/queue.md")" "T | r | Spike | user's msg"
unset BOUNCER_DATA

# bouncer-report
R='STATUS: DONE
TICKET: ABC-1
LINEAR: CR
RESULT: fixed the reply button
QUESTION: none
EVIDENCE: https://github.com/o/r/pull/1'
rep() { printf '%s' "$1" | ./bouncer-report; }
rep "" >/dev/null; ok "report: empty exits 2" $? 2
fill() { printf 'x%.0s' $(seq 1 $(( $1 - ${#R} ))); }   # pad RESULT so the report has $1 chars
rep "${R/RESULT: /RESULT: $(fill 401)}" >/dev/null; ok "report: 401 chars exits 2" $? 2
rep "${R/RESULT: /RESULT: $(fill 400)}" >/dev/null; ok "report: 400 chars passes" $? 0
rep "${R/STATUS: DONE/STATUS: FINISHED}" >/dev/null; ok "report: bad STATUS exits 2" $? 2
rep "${R/EVIDENCE: https:\/\/github.com\/o\/r\/pull\/1/}" >/dev/null; ok "report: missing EVIDENCE exits 2" $? 2
rep "${R/STATUS: DONE/STATUS: NEEDS_INPUT}" >/dev/null; ok "report: NEEDS_INPUT without question exits 2" $? 2
rep "Done, report below.
$R" >/dev/null; ok "report: leading prose passes" $? 0
rep "$(fill 900)
$R" >/dev/null; ok "report: long prose line passes" $? 0
rep "Prose first.
${R/RESULT: /RESULT: $(fill 401)}" >/dev/null; ok "report: field lines over 400 chars exit 2" $? 2
ok "report: last block wins" "$(rep "${R/ABC-1/ABC-0}
then:
${R/STATUS: DONE/STATUS: WORKING}" | jq -c '[.status,.ticket]')" '["WORKING","ABC-1"]'
ok "report: good report parses" "$(rep "$R" | jq -c '[.status,.ticket,.linear,.question]')" '["DONE","ABC-1","CR",null]'

# bartender-branch
g="$tmp/g"; br() { (cd "$g" && "$OLDPWD/bartender-branch" "$@"); }
git init -q -b main "$g" && git -C "$g" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
br 2>/dev/null; ok "branch: no ticket exits 2" $? 2
echo x > "$g/f"; git -C "$g" add f; br TEST-1 >/dev/null 2>&1; ok "branch: dirty tree exits 1" $? 1
ok "branch: dirty tree stays on main" "$(git -C "$g" branch --show-current)" main
git -C "$g" rm -q --cached f; mkdir -p "$g/.context"; touch "$g/.context/TEST-0.md"
ok "branch: prints the lower-case branch" "$(br TEST-1)" test-1
ok "branch: switched to it" "$(git -C "$g" branch --show-current)" test-1

exit $fail
