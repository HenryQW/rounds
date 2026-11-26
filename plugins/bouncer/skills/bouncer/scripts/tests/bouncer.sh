#!/usr/bin/env bash
# Fixture test for bouncer-data, bouncer-title, bouncer-route, bouncer-queue, bouncer-questions, bouncer-grants, bouncer-ledger, bouncer-report, bouncer-accept, bouncer-overlap, bouncer-preflight and bartender-branch. Boundary cases first. No network.
# Run: bash scripts/tests/bouncer.sh (from the skill folder)
set -uo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2] want [$3]"; fail=1; fi; }

# bouncer-title: with BOUNCER_STATUS_CODES and no stored option unset it uses the status_codes default in plugin.json
unset BOUNCER_STATUS_CODES
export CLAUDE_CONFIG_DIR="$tmp/config"
ok "title: bouncer at 0" "$(./bouncer-title --bouncer 0 rounds)" "🚪 Bouncer rounds"
ok "title: bouncer count" "$(./bouncer-title --bouncer 2 rounds)" "!2 🚪 Bouncer rounds"
./bouncer-title --bouncer -1 rounds 2>/dev/null; ok "title: negative count exits 2" $? 2
./bouncer-title --bouncer 1 2>/dev/null; ok "title: bouncer without a repo exits 2" $? 2
./bouncer-title "Not A Status" ABC-1 r 2>/dev/null; ok "title: unknown status exits 2" $? 2
./bouncer-title "In Progress" ABC-1 2>/dev/null; ok "title: missing repo exits 2" $? 2
ok "title: idle" "$(./bouncer-title --idle my-repo)" "[Idle] 🍸 my-repo"
ok "title: idle skill type" "$(./bouncer-title --idle my-repo --type Skill)" "[Idle] 🔧 my-repo"
ok "title: cleanup type with cta" "$(./bouncer-title --type Cleanup "In Progress" old-sessions my-repo --cta)" "![Dev] 🧹 old-sessions my-repo"
ok "title: ticket type is the default" "$(./bouncer-title --type Ticket Todo ABC-1 r)" "[Todo] 🍸 ABC-1 r"
./bouncer-title --type Draft Todo ABC-1 r 2>/dev/null; ok "title: unknown type exits 2" $? 2
./bouncer-title Todo ABC-1 r --type 2>/dev/null; ok "title: --type without a value exits 2" $? 2
ok "title: bartender (default codes)" "$(./bouncer-title "In Progress" ABC-1234 my-repo)" "[Dev] 🍸 ABC-1234 my-repo"
ok "title: github closed (default codes)" "$(./bouncer-title Closed 12 my-repo)" "[Done] 🍸 12 my-repo"
ok "title: empty option uses the default" "$(BOUNCER_STATUS_CODES=" " ./bouncer-title Todo T r)" "[Todo] 🍸 T r"
BOUNCER_STATUS_CODES="Todo=Todo" ./bouncer-title Closed T r 2>/dev/null; ok "title: a set option replaces the default" $? 2
BOUNCER_STATUS_CODES="Todo" ./bouncer-title Todo T r 2>/dev/null; ok "title: pair without = exits 2" $? 2
mkdir -p "$tmp/config"; echo '{"pluginConfigs": {"bouncer@rounds": {"options": {"status_codes": "Won'"'"'t Do=Wont"}}}}' > "$tmp/config/settings.json"
ok "title: the stored option without the env var" "$(./bouncer-title "Won't Do" ABC-9 web)" "[Wont] 🍸 ABC-9 web"
ok "title: the env var wins over the stored option" "$(BOUNCER_STATUS_CODES="Won't Do=WD" ./bouncer-title "Won't Do" ABC-9 web)" "[WD] 🍸 ABC-9 web"
rm "$tmp/config/settings.json"
ok "title: custom codes, apostrophe, cta, spaces" "$(BOUNCER_STATUS_CODES=" Won't Do = Wont ;; Code Review=CR; " ./bouncer-title "Won't Do" ABC-9 web --cta)" "![Wont] 🍸 ABC-9 web"

# bouncer-route
route() { echo "$1" | ./bouncer-route | jq -r "$2"; }
echo '{"sessions": []}' | ./bouncer-route >/dev/null; ok "route: no request exits 2" $? 2
echo '{"sessions": [], "request": {"ticket": "ABC-1", "repo": ""}}' | ./bouncer-route >/dev/null; ok "route: empty repo exits 2" $? 2
ok "route: empty pool starts" "$(route '{"sessions": [], "request": {"ticket": "ABC-1", "repo": "a"}}' .action)" start
S='[{"sessionId":"s1","title":"[Dev] 🍸 ABC-1 a","isRunning":true},
    {"sessionId":"s2","title":"[Idle] 🍸 b","isRunning":false},
    {"sessionId":"s3","title":"![CR] 🍸 ABC-3 c"},
    {"sessionId":"s4","title":"[Spec] 🍸 ABC-4 d"},
    {"sessionId":"s5","title":"[Idle] 🍸 e","isRunning":true},
    {"sessionId":"s6","title":"[Dev][ABC-7] Reply button"},
    {"sessionId":"s7","title":"[Idle] 🍸 f","isArchived":true},
    {"sessionId":"s8","title":"[Idle] 🔧 g"}]'
ok "route: idle Bartender in repo is assigned" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"ABC-9\", \"repo\": \"b\"}}" '.action+" "+.sessionId')" "assign s2"
ok "route: idle title but running is busy" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"ABC-9\", \"repo\": \"e\"}}" .action)" queue
ok "route: busy repo under cap starts (one per ticket)" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"ABC-9\", \"repo\": \"a\"}, \"caps\": {\"active\": 9}}" .action)" start
ok "route: 4 active at cap 3 queues" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"ABC-9\", \"repo\": \"z\"}}" .action)" queue
ok "route: under cap starts" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"ABC-9\", \"repo\": \"z\"}, \"caps\": {\"active\": 5}}" .action)" start
ok "route: idle Skill Bartender gets Skill work" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"x\", \"repo\": \"g\", \"type\": \"Skill\"}}" '.action+" "+.sessionId')" "assign s8"
ok "route: an idle Skill Bartender does not take a ticket" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"ABC-9\", \"repo\": \"g\"}, \"caps\": {\"active\": 9}}" .action)" start
ok "route: an idle Ticket Bartender does not take Cleanup work" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"x\", \"repo\": \"b\", \"type\": \"Cleanup\"}, \"caps\": {\"active\": 9}}" .action)" start
echo '{"sessions": [], "request": {"ticket": "x", "repo": "a", "type": "Draft"}}' | ./bouncer-route >/dev/null; ok "route: unknown type exits 2" $? 2
ok "route: archived Bartender is ignored" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"ABC-9\", \"repo\": \"f\"}, \"caps\": {\"active\": 5}}" .action)" start

# bouncer-data
fake="$tmp/home/.claude/plugins/cache/mkt/bouncer/9.9.9/skills/bouncer/scripts"; mkdir -p "$fake"; cp bouncer-data "$fake/"
ok "data: a marketplace install uses <name>-<marketplace>" "$(env -u BOUNCER_DATA -u CLAUDE_PLUGIN_DATA CLAUDE_CONFIG_DIR="$tmp/cfg" "$fake/bouncer-data")" "$tmp/cfg/plugins/data/bouncer-mkt"
ok "data: the folder and tickets/ are made" "$([ -d "$tmp/cfg/plugins/data/bouncer-mkt/tickets" ] && echo yes)" yes
ok "data: CLAUDE_PLUGIN_DATA wins over the path" "$(env -u BOUNCER_DATA CLAUDE_PLUGIN_DATA="$tmp/pd" "$fake/bouncer-data")" "$tmp/pd"
dev="$tmp/checkout/plugins/bouncer/skills/bouncer/scripts"; mkdir -p "$dev"; cp bouncer-data "$dev/"   # not ./: the installed copy runs from plugins/cache
ok "data: a --plugin-dir checkout uses bouncer-inline" "$(env -u BOUNCER_DATA -u CLAUDE_PLUGIN_DATA CLAUDE_CONFIG_DIR="$tmp/cfg" "$dev/bouncer-data")" "$tmp/cfg/plugins/data/bouncer-inline"

# bouncer-queue (in the data folder)
# bouncer-data --repo: one folder a Bouncer repo
git init -q "$tmp/main-repo" && git -C "$tmp/main-repo" commit -q --allow-empty -m i && git -C "$tmp/main-repo" worktree add -q "$tmp/wt" 2>/dev/null
ok "data: --repo is the main checkout's name" "$(cd "$tmp/main-repo" && BOUNCER_DATA="$tmp/rd" "$OLDPWD/bouncer-data" --repo)" "$tmp/rd/main-repo"
ok "data: --repo from a worktree is the main checkout's name" "$(cd "$tmp/wt" && BOUNCER_DATA="$tmp/rd" "$OLDPWD/bouncer-data" --repo)" "$tmp/rd/main-repo"
ok "data: BOUNCER_REPO wins" "$(BOUNCER_DATA="$tmp/rd" BOUNCER_REPO=web ./bouncer-data --repo)" "$tmp/rd/web"
(cd / && env -u BOUNCER_REPO BOUNCER_DATA="$tmp/rd" "$OLDPWD/bouncer-data" --repo >/dev/null 2>&1); ok "data: --repo outside a repo exits 2" $? 2
BOUNCER_DATA="$tmp/rd" BOUNCER_REPO=../x ./bouncer-data --repo >/dev/null 2>&1; ok "data: a bad repo name exits 2" $? 2
mkdir -p "$tmp/old"; echo "OLD-1 | r | Code | x" > "$tmp/old/queue.md"; echo "OLD-1 | local_a | q?" > "$tmp/old/questions.md"
BOUNCER_DATA="$tmp/old" BOUNCER_REPO=r ./bouncer-queue list >/dev/null
ok "data: an old queue.md moves into the repo folder" "$(cat "$tmp/old/r/queue.md"; [ -e "$tmp/old/queue.md" ] || echo gone)" "OLD-1 | r | Code | x
gone"
ok "data: an old questions.md moves too" "$(cat "$tmp/old/r/questions.md")" "OLD-1 | local_a | q?"
echo "NEW | r | Code | y" > "$tmp/old/queue.md"; BOUNCER_DATA="$tmp/old" BOUNCER_REPO=r ./bouncer-queue list >/dev/null
ok "data: the move runs once" "$(cat "$tmp/old/r/queue.md")" "OLD-1 | r | Code | x"
ok "data: another repo has its own queue" "$(BOUNCER_DATA="$tmp/old" BOUNCER_REPO=web ./bouncer-queue list)" ""

export BOUNCER_REPO=r
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
ok "queue: the file is queue.md in the repo folder" "$(head -n 1 "$tmp/data/r/queue.md")" "ABC-2 | b | Spike | notion"
ok "queue: pop prints the first line" "$(./bouncer-queue pop)" "ABC-2 | b | Spike | notion"
ok "queue: pop removes it" "$(./bouncer-queue list)" "ABC-1 | a | Mechanical | doc"
./bouncer-queue remove 2>/dev/null; ok "queue: remove without a ticket exits 2" $? 2
./bouncer-queue remove ABC-7 2>/dev/null; ok "queue: remove of a missing ticket exits 1" $? 1
./bouncer-queue add "ABC-3 | c | Code | x"
./bouncer-queue remove ABC-1; ok "queue: remove drops only that line" "$(./bouncer-queue list)" "ABC-3 | c | Code | x"
./bouncer-queue remove ABC-3
BOUNCER_DATA="$tmp/data2" ./bouncer-queue add "T | r | Spike | user's msg" 2>/dev/null; ok "queue: apostrophe is kept" "$(cat "$tmp/data2/r/queue.md")" "T | r | Spike | user's msg"

# bouncer-questions (in the data folder)
export BOUNCER_DATA="$tmp/q"
ok "questions: count on empty is 0" "$(./bouncer-questions count)" 0
./bouncer-questions next >/dev/null 2>&1; ok "questions: next on empty exits 1" $? 1
./bouncer-questions add "ABC-1 | local_a" 2>/dev/null; ok "questions: no question exits 2" $? 2
./bouncer-questions add " | local_a | why?" 2>/dev/null; ok "questions: no ticket exits 2" $? 2
./bouncer-questions done 2>/dev/null; ok "questions: done without a ticket exits 2" $? 2
./bouncer-questions done ABC-9 2>/dev/null; ok "questions: done of a missing ticket exits 1" $? 1
./bouncer-questions nope 2>/dev/null; ok "questions: bad command exits 2" $? 2
./bouncer-questions add "ABC-1 | local_a | Will Henry post it himself, or allow save_comment? Default: post"
./bouncer-questions add "ABC-2|local_b|Ship A | or B?"
./bouncer-questions add "ABC-1 | local_a | Post it or not?"
ok "questions: a reworded head stays the head" "$(./bouncer-questions next)" "ABC-1 | local_a | Post it or not?"
ok "questions: a new question of the same ticket replaces the old in its place" "$(./bouncer-questions list | tr '\n' ';')" "ABC-1 | local_a | Post it or not?;ABC-2 | local_b | Ship A | or B?;"
ok "questions: count" "$(./bouncer-questions count)" 2
./bouncer-questions done ABC-2; ok "questions: done removes only that ticket" "$(./bouncer-questions list)" "ABC-1 | local_a | Post it or not?"
ok "questions: the file is questions.md in the repo folder" "$(cat "$tmp/q/r/questions.md")" "ABC-1 | local_a | Post it or not?"

# bouncer-grants (in the data folder)
./bouncer-grants has ABC-1 push 2>/dev/null; ok "grants: has with no grant exits 1" $? 1
./bouncer-grants get ABC-1 2>/dev/null; ok "grants: get with no grant exits 1" $? 1
./bouncer-grants done ABC-1 2>/dev/null; ok "grants: done with no grant exits 1" $? 1
./bouncer-grants add "ABC-1 | push, deploy | yes" 2>/dev/null; ok "grants: unknown action exits 2" $? 2
./bouncer-grants add "ABC-1 | , | yes" 2>/dev/null; ok "grants: no action exits 2" $? 2
./bouncer-grants add "ABC-1 | push" 2>/dev/null; ok "grants: no words exits 2" $? 2
./bouncer-grants has ABC-1 2>/dev/null; ok "grants: has without an action exits 2" $? 2
./bouncer-grants nope 2>/dev/null; ok "grants: bad command exits 2" $? 2
./bouncer-grants add "ABC-1 | comment | post it"
./bouncer-grants add "ABC-2|push,pr ,merge|go | ship it"
./bouncer-grants add "ABC-1 | close, link, comment | yes, close it"
ok "grants: a new grant of the same ticket replaces the old" "$(./bouncer-grants list | tr '\n' ';')" "ABC-2 | push, pr, merge | go | ship it;ABC-1 | close, link, comment | yes, close it;"
./bouncer-grants has ABC-2 merge; ok "grants: has a granted action" $? 0
./bouncer-grants has ABC-2 comment; ok "grants: has an action outside the grant exits 1" $? 1
./bouncer-grants has ABC-2 pu; ok "grants: has matches whole actions only" $? 1
ok "grants: get" "$(./bouncer-grants get ABC-1)" "ABC-1 | close, link, comment | yes, close it"
./bouncer-grants done ABC-2; ok "grants: done removes only that ticket" "$(cat "$tmp/q/grants.md")" "ABC-1 | close, link, comment | yes, close it"

# bouncer-ledger (LEDGER sections in the records; a fake gh answers PR states)
mkdir -p "$tmp/bin"; printf '#!/bin/sh\ncase "$3" in *merged*) echo MERGED;; *open*) echo OPEN;; *) exit 1;; esac\n' > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
export BOUNCER_TODAY=2026-11-26 BOUNCER_RECORDS="$tmp/rec"
lg() { PATH="$tmp/bin:$PATH" ./bouncer-ledger "$@"; }
ok "ledger: due with no records prints nothing" "$(lg due)" ""
lg add K-1 memo k t "" n 2>/dev/null; ok "ledger: unknown kind exits 2" $? 2
lg add ../x pr k "" "" n 2>/dev/null; ok "ledger: a bad record name exits 2" $? 2
lg add K-1 follow-up "a | b" t "" n 2>/dev/null; ok "ledger: | in the key exits 2" $? 2
lg done K-1 k 2>/dev/null; ok "ledger: done with no item exits 1" $? 1
lg nope 2>/dev/null; ok "ledger: bad command exits 2" $? 2
mkdir -p "$tmp/rec"; printf 'GOAL\nFix it.\n\nLEDGER\n- [done] verify | K-0 | trigger: x | check: true | next: y | 2026-11-01\n\nLINKS\nx\n' > "$tmp/rec/K-1.md"
lg add K-1 pr https://x/pull/1-merged "" "" "close the ticket" >/dev/null
lg add K-1 held-message K-1 "PR 2 merged" 's=$(echo a | tr a b); [ "$s" = b ]' "post the QA reply" >/dev/null
lg add K-2 follow-up K-2 "K-1 accepted" false "start K-2" >/dev/null
lg add rounds-main verify rounds "staging" "exit 3" "check it" >/dev/null
lg add rounds-main pr https://x/pull/2-open "" "" "merge" >/dev/null
ok "ledger: add goes under the LEDGER header, before other sections" "$(sed -n 6,7p "$tmp/rec/K-1.md" | cut -c1-24 | tr '\n' ';')" "- [open] pr | https://x/;- [open] held-message | ;"
ok "ledger: other sections stay" "$(tail -2 "$tmp/rec/K-1.md" | tr '\n' ';')" "LINKS;x;"
ok "ledger: a record with no section gets one at the end" "$(sed -n 1p "$tmp/rec/K-2.md")" "LEDGER"
ok "ledger: a pr line gets the default trigger" "$(sed -n 6p "$tmp/rec/K-1.md")" "- [open] pr | https://x/pull/1-merged | trigger: merged or closed | check:  | next: close the ticket | 2026-11-26"
ok "ledger: list prints open items with their record" "$(lg list | sed "s#$tmp/rec/##" | cut -d: -f1 | tr '\n' ' ')" "K-1.md K-1.md K-2.md rounds-main.md rounds-main.md "
ok "ledger: due prints merged PRs and fired checks (a | in a check is kept)" "$(lg due 2>/dev/null | sed "s#$tmp/rec/##" | cut -d' ' -f1,4 | tr '\n' ';')" "K-1.md: pr;K-1.md: held-message;"
ok "ledger: a check with another exit code is unsure" "$(lg due 2>&1 >/dev/null | cut -d' ' -f1)" "unsure"
lg done K-1 https://x/pull/1-merged; ok "ledger: done marks only that item" "$(/usr/bin/grep -c '^- \[done\]' "$tmp/rec/K-1.md") $(lg list | /usr/bin/grep -c K-1.md)" "2 1"
touch -t 202611010000 "$tmp/rec/K-2.md"
ok "ledger: stale by age" "$(BOUNCER_NOW=$(date -j -f %Y%m%d%H%M 202611260000 +%s) lg stale | sed "s#$tmp/rec/##")" "K-2.md: older than 7 days"
ok "ledger: stale by the Bartender's last turn" "$(BOUNCER_NOW=$(date -j -f %Y%m%d%H%M 202611260000 +%s) lg stale --days 30 --turn K-2=2026-11-02T00:00:00 | sed "s#$tmp/rec/##")" "K-2.md: older than its Bartender's last turn"
ok "ledger: a fresh record is not stale" "$(lg stale --turn K-1=2020-01-01T00:00:00 | /usr/bin/grep -c K-1.md)" 0
lg stale --turn K-1 2>/dev/null; ok "ledger: stale --turn without a time exits 2" $? 2
unset BOUNCER_TODAY BOUNCER_RECORDS
mkdir -p "$tmp/optcfg"; echo "{\"pluginConfigs\": {\"bouncer@rounds\": {\"options\": {\"records_dir\": \"$tmp/rec\"}}}}" > "$tmp/optcfg/settings.json"
ok "ledger: the records_dir option names the folder" "$(CLAUDE_CONFIG_DIR="$tmp/optcfg" ./bouncer-ledger list | /usr/bin/grep -c "$tmp/rec/")" 4
unset BOUNCER_DATA BOUNCER_REPO

# SKILL.md: the Barback brief line that stops a double delivery of its result (each delivery starts a Bartender turn)
grep -qF 'End your turn with the report as your final text. Never also send it' ../SKILL.md; ok "skill: Barback brief ends its turn with the report and never also sends it" $? 0
grep -qF 'same agent id' ../SKILL.md; ok "skill: a second delivery of a Barback result gets no work" $? 0

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

# fakes for gh and curl (no network)
fb="$tmp/fake"; mkdir -p "$fb"; S=$(pwd)
cat > "$fb/gh" <<'SH'
#!/bin/sh
case "$1 $2" in
  "pr list") printf '5 alice\n6 bob\n' ;;
  "pr diff") [ "$3" = 5 ] && printf 'a.txt\nb.txt\n'; [ "$3" = 6 ] && printf 'c.txt\n'; true ;;
  "pr view") case "$3" in */pull/1) echo MERGED;; */pull/2) echo CLOSED;; */pull/4) echo OPEN;; *) echo "not found" >&2; exit 1;; esac ;;
esac
SH
printf '#!/bin/sh\ncase "$*" in *ABC-1*) echo %s;; *) echo %s;; esac\n' "'{\"data\":{\"issue\":{\"identifier\":\"ABC-1\"}}}'" "'{\"data\":{\"issue\":null}}'" > "$fb/curl"
chmod +x "$fb/gh" "$fb/curl"

# bouncer-accept
acc() { env -u LINEAR_API_KEY PATH="$fb:$PATH" ./bouncer-accept "$@"; }
./bouncer-accept 'nope' 2>/dev/null; ok "accept: bad json exits 2" $? 2
acc '{"status":"WORKING","ticket":"ABC-1"}' >/dev/null; ok "accept: not DONE is a gap" $? 1
ok "accept: merged and open PRs pass, no token is a note" "$(acc '{"status":"DONE","ticket":"ABC-1","result":"https://github.com/o/r/pull/1","evidence":"https://github.com/o/r/pull/4"}' | tr '\n' ';')" "note: https://github.com/o/r/pull/1 is MERGED;note: https://github.com/o/r/pull/4 is OPEN;note: ABC-1 not checked: LINEAR_API_KEY is unset;pass;"
ok "accept: closed and missing PRs are gaps" "$(acc '{"status":"DONE","ticket":"12","evidence":"https://github.com/o/r/pull/2 https://github.com/o/r/pull/3"}' | /usr/bin/grep -c '^gap')" 2
ok "accept: a resolving key passes" "$(echo '{"status":"DONE","ticket":"ABC-1"}' | LINEAR_API_KEY=k PATH="$fb:$PATH" ./bouncer-accept - | tail -1)" pass
echo '{"status":"DONE","ticket":"ABC-2"}' | LINEAR_API_KEY=k PATH="$fb:$PATH" ./bouncer-accept - >/dev/null; ok "accept: an unknown key is a gap" $? 1

# bouncer-overlap
o="$tmp/o"; git init -q -b main "$o"; echo x > "$o/a.txt"; git -C "$o" add a.txt; git -C "$o" -c user.name=carol -c user.email=c@c commit -q -m a
ov() { (cd "$o" && PATH="$fb:$PATH" "$S/bouncer-overlap" "$@"); }
ov o/r 2>/dev/null; ok "overlap: no file exits 2" $? 2
ov --branch 2>/dev/null; ok "overlap: --branch without a ref exits 2" $? 2
ok "overlap: open PRs and recent commits per file" "$(ov --branch main o/r a.txt c.txt d.txt | sed 1,2d | sed 's/ [0-9a-f]\{7\} [0-9-]* / X /' | tr '\n' ';')" "| open PR | #5 | alice | a.txt |;| open PR | #6 | bob | c.txt |;| commit on main | X | carol | a.txt |;"

# bouncer-preflight
pf="$tmp/pf"; git init -q -b main "$pf"; git -C "$pf" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
mkdir -p "$pf/.claude" "$tmp/pfcfg"; touch "$pf/hook.sh"
echo '{"hooks":{"PreToolUse":[{"hooks":[{"command":"$CLAUDE_PROJECT_DIR/hook.sh"},{"command":"python3 /gone/x.py --a"}]}]}}' > "$pf/.claude/settings.json"
pre() { (cd "$1" && CLAUDE_CONFIG_DIR="$tmp/pfcfg" "${2:-$S/bouncer-preflight}"); }
pre "$pf" >/dev/null; ok "preflight: a missing hook script needs a fix" $? 1
ok "preflight: names the missing script only" "$(pre "$pf" | /usr/bin/grep -c '/gone/x.py')" 1
ok "preflight: main checkout ok" "$(pre "$pf" | /usr/bin/grep -c '^ok main-checkout')" 1
echo '{"permissions":{"allow":["mcp__ccd_session_mgmt__clear_session"]}}' > "$tmp/pfcfg/settings.json"; echo '{}' > "$pf/.claude/settings.json"
ok "preflight: all pass" "$(pre "$pf" | tr '\n' ';')" "ok main-checkout;ok hook-paths;ok plugin-version (not a cached install, skipped);ok clear-allowed;"
git -C "$pf" worktree add -q "$tmp/pfwt" 2>/dev/null
ok "preflight: a worktree needs a fix" "$(pre "$tmp/pfwt" | /usr/bin/grep -c '^fix main-checkout')" 1
mkdir -p "$pf/sub"; ok "preflight: a subfolder needs a fix" "$(pre "$pf/sub" | /usr/bin/grep -c '^fix main-checkout')" 1
echo '{}' > "$tmp/pfcfg/settings.json"; ok "preflight: clear_session not allowed needs a fix" "$(pre "$pf" | /usr/bin/grep -c '^fix clear-allowed')" 1
for v in 1.0.0 1.10.0; do c="$tmp/cache/plugins/cache/m/bouncer/$v/skills/bouncer/scripts"; mkdir -p "$c"; cp bouncer-preflight "$c/"; done
ok "preflight: an old cached version needs a fix" "$(pre "$pf" "$tmp/cache/plugins/cache/m/bouncer/1.0.0/skills/bouncer/scripts/bouncer-preflight" | /usr/bin/grep -c 'runs 1.0.0 but 1.10.0')" 1
ok "preflight: the newest cached version is ok" "$(pre "$pf" "$tmp/cache/plugins/cache/m/bouncer/1.10.0/skills/bouncer/scripts/bouncer-preflight" | /usr/bin/grep -c '^ok plugin-version')" 1

exit $fail
