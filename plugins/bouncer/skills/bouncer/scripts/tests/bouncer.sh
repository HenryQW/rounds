#!/usr/bin/env bash
# Fixture test for bouncer-data, bouncer-title, bouncer-route, bouncer-queue, bouncer-questions, bouncer-grants, bouncer-decisions, bouncer-ledger, bouncer-report, bouncer-accept, bouncer-overlap, bouncer-preflight, bouncer-session, bouncer-note, bouncer-start, bouncer-assign and bartender-branch. Boundary cases first. No network.
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
./bouncer-title "In Progress" ABC-1 2>/dev/null; ok "title: missing ticket title exits 2" $? 2
./bouncer-title "In Progress" "ABC 1" t 2>/dev/null; ok "title: a ticket with a space exits 2" $? 2
ok "title: idle" "$(./bouncer-title --idle my-repo)" "🍸 [Idle] my-repo"
ok "title: idle skill type" "$(./bouncer-title --idle my-repo --type Skill)" "🔧 [Idle] my-repo"
ok "title: cleanup type with cta" "$(./bouncer-title --type Cleanup "In Progress" old-sessions my-repo --cta)" "!🧹 [old-sessions] [Dev] my-repo"
ok "title: ticket type is the default" "$(./bouncer-title --type Ticket Todo ABC-1 r)" "🍸 [ABC-1] [Todo] r"
./bouncer-title --type Draft Todo ABC-1 r 2>/dev/null; ok "title: unknown type exits 2" $? 2
./bouncer-title Todo ABC-1 r --type 2>/dev/null; ok "title: --type without a value exits 2" $? 2
ok "title: bartender (default codes)" "$(./bouncer-title "In Progress" ABC-1234 "Fix the  login page")" "🍸 [ABC-1234] [Dev] Fix the login page"
ok "title: a long ticket title is cut to 40" "$(./bouncer-title "In QA" ABC-1 "Broadcast channel switch skips low bandwidth mode")" "🍸 [ABC-1] [QA] Broadcast channel switch skips low band…"
ok "title: github closed (default codes)" "$(./bouncer-title Closed 12 my-repo)" "🍸 [12] [Done] my-repo"
ok "title: empty option uses the default" "$(BOUNCER_STATUS_CODES=" " ./bouncer-title Todo T r)" "🍸 [T] [Todo] r"
BOUNCER_STATUS_CODES="Todo=Todo" ./bouncer-title Closed T r 2>/dev/null; ok "title: a set option replaces the default" $? 2
BOUNCER_STATUS_CODES="Todo" ./bouncer-title Todo T r 2>/dev/null; ok "title: pair without = exits 2" $? 2
mkdir -p "$tmp/config"; echo '{"pluginConfigs": {"bouncer@rounds": {"options": {"status_codes": "Won'"'"'t Do=Wont"}}}}' > "$tmp/config/settings.json"
ok "title: the stored option without the env var" "$(./bouncer-title "Won't Do" ABC-9 web)" "🍸 [ABC-9] [Wont] web"
ok "title: the env var wins over the stored option" "$(BOUNCER_STATUS_CODES="Won't Do=WD" ./bouncer-title "Won't Do" ABC-9 web)" "🍸 [ABC-9] [WD] web"
rm "$tmp/config/settings.json"
ok "title: custom codes, apostrophe, cta, spaces" "$(BOUNCER_STATUS_CODES=" Won't Do = Wont ;; Code Review=CR; " ./bouncer-title "Won't Do" ABC-9 web --cta)" "!🍸 [ABC-9] [Wont] web"

# bouncer-route
route() { echo "$1" | ./bouncer-route | jq -r "$2"; }
echo '{"sessions": []}' | ./bouncer-route >/dev/null; ok "route: no request exits 2" $? 2
echo '{"sessions": [], "request": {"ticket": "ABC-1", "repo": ""}}' | ./bouncer-route >/dev/null; ok "route: empty repo exits 2" $? 2
ok "route: empty pool starts" "$(route '{"sessions": [], "request": {"ticket": "ABC-1", "repo": "a"}}' .action)" start
S='[{"sessionId":"s1","title":"[Dev] 🍸 ABC-1 a","isRunning":true},
    {"sessionId":"s2","title":"[Idle] 🍸 b","isRunning":false},
    {"sessionId":"s3","title":"!🍸 [ABC-3] [CR] Fix c"},
    {"sessionId":"s4","title":"[Spec] 🍸 ABC-4 d"},
    {"sessionId":"s5","title":"[Idle] 🍸 e","isRunning":true},
    {"sessionId":"s6","title":"[Dev][ABC-7] Reply button"},
    {"sessionId":"s7","title":"[Idle] 🍸 f","isArchived":true},
    {"sessionId":"s8","title":"[Idle] 🔧 g"},
    {"sessionId":"s9","title":"🍸 [Idle] h","isRunning":false},
    {"sessionId":"s10","title":"!🍸 [Idle] k","isRunning":false}]'
ok "route: idle Bartender in repo is assigned" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"ABC-9\", \"repo\": \"b\"}}" '.action+" "+.sessionId')" "assign s2"
ok "route: an idle Bartender in the new title format is assigned" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"ABC-9\", \"repo\": \"h\"}}" '.action+" "+.sessionId')" "assign s9"
ok "route: an idle Bartender with a question waiting (!) is not reassigned" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"ABC-9\", \"repo\": \"k\"}, \"caps\": {\"active\": 9}}" .action)" start
ok "route: idle title but running is busy" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"ABC-9\", \"repo\": \"e\"}}" .action)" queue
ok "route: busy repo under cap starts (one per ticket)" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"ABC-9\", \"repo\": \"a\"}, \"caps\": {\"active\": 9}}" .action)" start
ok "route: 5 active at cap 3 queues" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"ABC-9\", \"repo\": \"z\"}}" .action)" queue
ok "route: under cap starts" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"ABC-9\", \"repo\": \"z\"}, \"caps\": {\"active\": 6}}" .action)" start
ok "route: idle Skill Bartender gets Skill work" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"x\", \"repo\": \"g\", \"type\": \"Skill\"}}" '.action+" "+.sessionId')" "assign s8"
ok "route: an idle Skill Bartender does not take a ticket" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"ABC-9\", \"repo\": \"g\"}, \"caps\": {\"active\": 9}}" .action)" start
ok "route: an idle Ticket Bartender does not take Cleanup work" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"x\", \"repo\": \"b\", \"type\": \"Cleanup\"}, \"caps\": {\"active\": 9}}" .action)" start
echo '{"sessions": [], "request": {"ticket": "x", "repo": "a", "type": "Draft"}}' | ./bouncer-route >/dev/null; ok "route: unknown type exits 2" $? 2
ok "route: archived Bartender is ignored" "$(route "{\"sessions\": $S, \"request\": {\"ticket\": \"ABC-9\", \"repo\": \"f\"}, \"caps\": {\"active\": 6}}" .action)" start

# bouncer-data
fake="$tmp/home/.claude/plugins/cache/mkt/bouncer/9.9.9/skills/bouncer/scripts"; mkdir -p "$fake"; cp bouncer-data "$fake/"
ok "data: a marketplace install uses <name>-<marketplace>" "$(env -u BOUNCER_DATA -u CLAUDE_PLUGIN_DATA CLAUDE_CONFIG_DIR="$tmp/cfg" "$fake/bouncer-data")" "$tmp/cfg/plugins/data/bouncer-mkt"
ok "data: the folder and tickets/ are made" "$([ -d "$tmp/cfg/plugins/data/bouncer-mkt/tickets" ] && echo yes)" yes
ok "data: CLAUDE_PLUGIN_DATA wins over the path" "$(env -u BOUNCER_DATA CLAUDE_PLUGIN_DATA="$tmp/pd" "$fake/bouncer-data")" "$tmp/pd"
dev="$tmp/checkout/plugins/bouncer/skills/bouncer/scripts"; mkdir -p "$dev"; cp bouncer-data "$dev/"   # not ./: the installed copy runs from plugins/cache
ok "data: a --plugin-dir checkout uses bouncer-inline" "$(env -u BOUNCER_DATA -u CLAUDE_PLUGIN_DATA CLAUDE_CONFIG_DIR="$tmp/cfg" "$dev/bouncer-data")" "$tmp/cfg/plugins/data/bouncer-inline"

# bouncer-queue (in the data folder)
# bouncer-data --repo: one folder a Bouncer repo
git init -q "$tmp/main-repo" && git -C "$tmp/main-repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m i && git -C "$tmp/main-repo" worktree add -q "$tmp/wt" 2>/dev/null
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
./bouncer-questions done ABC-9 --none 2>/dev/null; ok "questions: done of a missing ticket exits 1" $? 1
./bouncer-questions nope 2>/dev/null; ok "questions: bad command exits 2" $? 2
noat() { sed -E 's/ \| at: [0-9T:Z-]+$//'; }
./bouncer-questions add "ABC-1 | local_a | Will Henry post it himself, or allow save_comment? Default: post"
./bouncer-questions add "ABC-2|local_b|Ship A | or B?"
./bouncer-questions add "ABC-1 | local_a | Post it or not?"
ok "questions: a reworded head stays the head" "$(./bouncer-questions next | noat)" "ABC-1 | local_a | Post it or not?"
ok "questions: a new question of the same ticket replaces the old in its place" "$(./bouncer-questions list | noat | tr '\n' ';')" "ABC-1 | local_a | Post it or not?;ABC-2 | local_b | Ship A | or B?;"
ok "questions: count" "$(./bouncer-questions count)" 2
./bouncer-questions next | grep -qE ' \| at: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$'; ok "questions: a line ends with the UTC time it was added" $? 0
./bouncer-questions add "ABC-3 | self | Merge? | at: 1999-01-01T00:00:00Z"; ok "questions: a given at: is replaced, not doubled" "$(./bouncer-questions list | grep -c 'at: ')" 3
./bouncer-questions list | grep -q 1999; ok "questions: the old at: is gone" $? 1
./bouncer-questions done ABC-3 --none
./bouncer-questions done ABC-2 --none; ok "questions: done removes only that ticket" "$(./bouncer-questions list | noat)" "ABC-1 | local_a | Post it or not?"
ok "questions: the file is questions.md in the repo folder" "$(noat < "$tmp/q/r/questions.md")" "ABC-1 | local_a | Post it or not?"
./bouncer-questions add "cleanup-old | local_c | Keep A?"; ./bouncer-questions add "cleanup.old | local_d | Keep B?"
ok "questions: a key matches literally, not as a regex" "$(./bouncer-questions count)" 3
./bouncer-questions done cleanup.old --none; ok "questions: done matches the key literally" "$(./bouncer-questions list | noat | tr '\n' ';')" "ABC-1 | local_a | Post it or not?;cleanup-old | local_c | Keep A?;"
./bouncer-questions done cleanup-old --none
./bouncer-questions add "ABC-4 | self | Pin Node 24? Default: yes"
./bouncer-questions done ABC-4 2>/dev/null; ok "questions: done without --decision or --none exits 2" $? 2
./bouncer-questions done ABC-4 --decision D99 2>/dev/null; ok "questions: done with an unknown decision exits 2" $? 2
ok "questions: a refused done keeps the question" "$(./bouncer-questions list | noat | grep -c ABC-4)" 1
BOUNCER_TODAY=2026-11-28 ./bouncer-decisions add --about "Toolchain" "web | build | Pin Node 24 | CI image moved | Henry: yes" >/dev/null
./bouncer-questions done ABC-4 --decision D1; ok "questions: done with an active decision removes the question" "$(./bouncer-questions list | noat | grep -c ABC-4)" 0
chmod 000 "$tmp/q/memory.md"; ./bouncer-decisions list >/dev/null 2>&1; ok "decisions: list of an unreadable memory exits 2, not 1" $? 2; chmod 644 "$tmp/q/memory.md"
rm -rf "$tmp/q/memory.md" "$tmp/q/decisions"

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

# bouncer-decisions (memory.md and decisions/ in the data folder)
export BOUNCER_TODAY=2026-11-27
./bouncer-decisions list 2>/dev/null; ok "decisions: list with none exits 1" $? 1
./bouncer-decisions domains 2>/dev/null; ok "decisions: domains with none exits 1" $? 1
./bouncer-decisions add --about x "rounds | tracker | no why or source" 2>/dev/null; ok "decisions: a line without its 5 fields exits 2" $? 2
./bouncer-decisions add --about x "rounds | Tracker! | d | w | s" 2>/dev/null; ok "decisions: a bad domain name exits 2" $? 2
./bouncer-decisions add "rounds | tracker | d | w | s" 2>/dev/null; ok "decisions: a new domain without --about exits 2" $? 2
./bouncer-decisions add --about 2>/dev/null; ok "decisions: --about without a value exits 2" $? 2
./bouncer-decisions add --supersedes D9 --about x "rounds | tracker | d | w | s" 2>/dev/null; ok "decisions: supersede of an unknown id exits 2" $? 2
./bouncer-decisions get 7 2>/dev/null; ok "decisions: get of a bad id exits 2" $? 2
ok "decisions: add prints the id" "$(./bouncer-decisions add --about "Work tracker and ticket states" "rounds | tracker | Use GitHub Issues as the tracker | One tracker for all Bouncer work | user: \"use issues | not Linear\"")" D1
./bouncer-decisions add --about "Merges and releases" "all | release | Merge PRs on a ready verdict | Saves a question for each PR | default: agentMerge rule" >/dev/null
./bouncer-decisions add "web | release | Deploy on Fridays | The team is free then | user: ok" >/dev/null
ok "decisions: a memory line holds no why or source" "$(./bouncer-decisions get D2)" "D2 | 2026-11-27 | all | release | Merge PRs on a ready verdict"
ok "decisions: list of a scope adds the all scope" "$(./bouncer-decisions list rounds | cut -d' ' -f1 | tr '\n' ' ')" "D1 D2 "
ok "decisions: an exact duplicate adds nothing" "$(./bouncer-decisions add "web | release | Deploy on Fridays | again | user: again")" D3
ok "decisions: list of two scopes" "$(./bouncer-decisions list web rounds | cut -d' ' -f1 | tr '\n' ' ')" "D1 D2 D3 "
ok "decisions: the router has one line a domain" "$(./bouncer-decisions domains | grep '^- ' | tr '\n' ';')" "- release: Merges and releases (2 active) decisions/release.md;- tracker: Work tracker and ticket states (1 active) decisions/tracker.md;"
ok "decisions: why prints the record" "$(./bouncer-decisions why D1 | tr '\n' ';')" '## D1 (2026-11-27, rounds);Use GitHub Issues as the tracker;Why: One tracker for all Bouncer work;Source: user: "use issues | not Linear";'
ok "decisions: supersede prints the new id" "$(./bouncer-decisions add --supersedes D1 "rounds | tracker | Use Linear as the tracker | The team moved to Linear | user: switch to Linear")" D4
ok "decisions: the old memory line is marked" "$(./bouncer-decisions history | head -1)" 'D1 | 2026-11-27 | rounds | tracker | Use GitHub Issues as the tracker | superseded by D4'
ok "decisions: the old record is marked" "$(./bouncer-decisions why D1 | head -1)" "## D1 (2026-11-27, rounds) superseded by D4"
ok "decisions: the new record names the old" "$(./bouncer-decisions why D4 | tail -1)" "Supersedes: D1"
ok "decisions: the router counts active records only" "$(./bouncer-decisions domains | grep '^- tracker')" "- tracker: Work tracker and ticket states (1 active) decisions/tracker.md"
ok "decisions: --about rewrites the router line" "$(./bouncer-decisions add --about "Trackers" "rounds | tracker | Close stale issues monthly | Keeps the board short | user: yes" >/dev/null; ./bouncer-decisions domains | grep '^- tracker')" "- tracker: Trackers (2 active) decisions/tracker.md"
ok "decisions: list drops a superseded one" "$(./bouncer-decisions list rounds | cut -d' ' -f1 | tr '\n' ' ')" "D2 D4 D5 "
./bouncer-decisions add --supersedes D1 "rounds | tracker | x | y | z" 2>/dev/null; ok "decisions: supersede of a superseded id exits 2" $? 2
./bouncer-decisions get D1 2>/dev/null; ok "decisions: get of a superseded id exits 1" $? 1
./bouncer-decisions why D9 2>/dev/null; ok "decisions: why of an unknown id exits 1" $? 1
ok "decisions: ids count superseded lines" "$(./bouncer-decisions add "web | release | Pin Node 22 | CI image | default: CI image")" D6
BOUNCER_DECISIONS_CAP=300 ./bouncer-decisions add "web | release | Pin Node 24 | new CI image | default: new CI image" 2>/dev/null; ok "decisions: an add over the cap exits 3" $? 3
ok "decisions: an add over the cap writes nothing" "$(./bouncer-decisions history | wc -l | tr -d ' ') $(grep -c '^## D' "$tmp/q/decisions/release.md")" "6 3"
ok "decisions: a supersede frees its old line from the cap" "$(BOUNCER_DECISIONS_CAP=300 ./bouncer-decisions add --supersedes D6 "web | release | Pin Node 24 | new CI image | default: new CI image")" D7

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
ok "ledger: list --all also prints done items" "$(CLAUDE_CONFIG_DIR="$tmp/optcfg" ./bouncer-ledger list --all | /usr/bin/grep -c '\[done\]')" "$(cat "$tmp"/rec/*.md | /usr/bin/grep -c '^- \[done\]')"
ok "ledger: the records_dir option names the folder" "$(CLAUDE_CONFIG_DIR="$tmp/optcfg" ./bouncer-ledger list | /usr/bin/grep -c "$tmp/rec/")" 4
unset BOUNCER_DATA BOUNCER_REPO

# SKILL.md and its on-demand files: the router names each file in references/, and each file it names exists
sk=$(cat ../SKILL.md ../references/*.md)   # the whole skill text
named=$(grep -o '`references/[a-z-]*\.md`' ../SKILL.md | tr -d '`' | sort -u)
ok "skill: the router names every file in references/" "$named" "$(cd .. && ls references/*.md | sort)"
for r in $named; do grep -qF "| \`$r\` |" ../SKILL.md; ok "skill: $r has a router row" $? 0; done
# SKILL.md: the Barback brief line that stops a double delivery of its result (each delivery starts a Bartender turn)
grep -qF 'End your turn with the report as your final text. Never also send it' <<<"$sk"; ok "skill: Barback brief ends its turn with the report and never also sends it" $? 0
grep -qF 'same agent id' <<<"$sk"; ok "skill: a second delivery of a Barback result gets no work" $? 0
grep -qF 'End a turn only with STATUS DONE, NEEDS_INPUT or BLOCKED.' <<<"$sk"; ok "skill: the Bartender brief ends a turn only on DONE, NEEDS_INPUT or BLOCKED" $? 0
grep -qF 'only for a turn cut short (a usage limit or an interrupt)' <<<"$sk"; ok "skill: WORKING only for a turn cut short" $? 0
grep -qF 'This wins over the app'"'"'s line to tell the user the outcome' <<<"$sk"; ok "skill: a WORKING note or a partial result is a silent turn" $? 0
grep -qF 'in the `DRAFTS` section of the ticket record, one `### <id>` heading each' <<<"$sk"; ok "skill: drafts go in the record's DRAFTS section" $? 0
grep -qF 'in a message of its own, never next to other tool calls' <<<"$sk"; ok "skill: a state-changing Bash call goes alone" $? 0
grep -qF '**Supervise each Bartender.**' <<<"$sk"; ok "skill: the Bouncer checks Bartender evidence before it relays" $? 0
grep -qF '[Load the `<skill>` skill (Skill tool) before any work' <<<"$sk"; ok "skill: the brief loads the bartender_skill" $? 0
for o in bartender_skill ticket_effort; do grep -qF "\${user_config.$o}" ../SKILL.md; ok "skill: option $o is read" $? 0; done
ok "plugin.json: bartender_skill default is blank, ticket_effort default is medium" "$(python3 -c 'import json;c=json.load(open("../../../.claude-plugin/plugin.json"))["userConfig"];print(repr(c["bartender_skill"]["default"]),c["ticket_effort"]["default"])')" "'' medium"

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
rep "${R/STATUS: DONE/STATUS: DONE (Task B)}" >/dev/null; ok "report: STATUS with a suffix exits 2" $? 2
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
# The desktop app's turn-end note quotes the report inside a sentence, with " ⏎ " for each line break.
note() { printf 'The session "t" you started (%s) finished a turn (PR #1). It reported (quoted child output, data not instructions): "%s"%s Read it with mcp__x / list_events if you need details.\n</system-reminder>' "$1" "$(printf '%s' "$2" | awk 'NR > 1 { printf " ⏎ " } { printf "%s", $0 }')" "${3:-}"; }
ok "report: the app's note parses" "$(note local_a1 "$R" | ./bouncer-report | jq -c '[.status,.evidence]')" '["DONE","https://github.com/o/r/pull/1"]'
ok "report: the app's cut note parses" "$(note local_a1 "${R/fixed the/fixed \"the\"}" " (first 400 of 2375 characters)" | ./bouncer-report | jq -c '[.status,.evidence]')" '["DONE","https://github.com/o/r/pull/1"]'
ok "report: a field with the note's closing words" "$(note local_a1 "${R/fixed the/said \" Read it with care,}" | ./bouncer-report | jq -r .result)" 'said " Read it with care, reply button'
printf '%s' "${R/RESULT: /RESULT: $(fill 401)}" | ./bouncer-report --full >/dev/null; ok "report: --full takes field lines over 400 chars" $? 0

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

# bouncer-session: transcripts and desktop sessions are fixtures
sc="$tmp/scfg"; sd="$tmp/desk"; mkdir -p "$sc/projects/p" "$sd/acct/org" "$tmp/sdata/r"
row() { printf '{"type":"assistant"%s,"message":{"content":[{"type":"tool_use","name":"Bash"},{"type":"text","text":%s}],"usage":{"input_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":10,"output_tokens":5}}}\n' "${4:-}" "$(printf '%s' "$1" | jq -Rs .)" "$2" "$3"; }
ses() { BOUNCER_DATA="$tmp/sdata" BOUNCER_REPO=r CLAUDE_CONFIG_DIR="$sc" BOUNCER_DESKTOP_SESSIONS="$sd" PATH="$fb:$PATH" "$@"; }
{ row "old" 5 100; row "new" 5 150000; row "side" 5 9 ',"isSidechain":true'; echo '{"type":"user"}'; } > "$sc/projects/p/own.jsonl"
ok "session: context is the last main answer's usage" "$(ses ./bouncer-session context own)" "context: 150020 tok (over 150000)"
ok "session: context at the cap is not over" "$(ses ./bouncer-session context --cap 150020 own)" "context: 150020 tok"
echo own > "$tmp/sdata/r/bouncer"
ok "session: context defaults to this repo's Bouncer" "$(ses ./bouncer-session context --cap 200000)" "context: 150020 tok"
ok "session: no transcript prints unknown" "$(ses ./bouncer-session context nope)" "context: unknown"
ses ./bouncer-session context nope >/dev/null; ok "session: no transcript exits 1" $? 1
ses ./bouncer-session context ../x >/dev/null; ok "session: a path as an id exits 1" $? 1
ses ./bouncer-session >/dev/null 2>&1; ok "session: no command exits 2" $? 2
ses ./bouncer-session last own >/dev/null 2>&1; ok "session: last takes a local id only" $? 2
LONG="Checked the build and the tests first, as the brief says. $(fill 600)

${R/RESULT: /RESULT: $(fill 401)}"
row "$LONG" 1 1 > "$sc/projects/p/cli-a1.jsonl"; row "no report here" 1 1 > "$sc/projects/p/cli-a2.jsonl"
desk() { jq -n --arg t "$2" --arg q "$3" --arg c "$4" '{cliSessionId: $c, lastAssistantCliSessionId: $c, title: $t, lastTurnReport: $q}' > "$sd/acct/org/$1.json"; }
desk local_a1 "🍸 [ABC-1] [Dev] Fix the reply" "Checked the build" cli-a1
desk local_a2 "!🍸 [ABC-9] [CR] Other" "All good" cli-a2
ok "session: title" "$(ses ./bouncer-session title local_a1)" "🍸 [ABC-1] [Dev] Fix the reply"
ok "session: quote" "$(ses ./bouncer-session quote local_a1)" "Checked the build"
ses ./bouncer-session quote local_none >/dev/null; ok "session: quote of an unknown session exits 1" $? 1
ok "session: last prints the last answer's text" "$(ses ./bouncer-session last local_a1 | tail -1)" "EVIDENCE: https://github.com/o/r/pull/1"
ses ./bouncer-session last local_none >/dev/null; ok "session: last of an unknown session exits 1" $? 1

# Exercise the installed Stop command with the desktop id and CLI session id that Claude supplies.
stop_command=$(jq -er '.hooks.Stop[0].hooks[0].command' ../../../hooks/hooks.json)
stop_result() {
    local output
    output=$(jq -n --arg sid "$1" --arg text "$2" --argjson extra "${3:-null}" \
        '{hook_event_name: "Stop", session_id: $sid, stop_hook_active: false, last_assistant_message: $text} + $extra' |
        ses env CLAUDE_PLUGIN_ROOT="$PWD/../../.." CLAUDE_CODE_HOST_SESSION_ID=local_a1 bash -c "$stop_command") || { echo error; return; }
    if [ -z "$output" ]; then echo allow; else jq -er '.decision' <<< "$output"; fi
}
ok "stop: a complete report can end the turn" "$(stop_result cli-a1 "$R")" allow
ok "stop: invalid report requests one correction" "$(stop_result cli-a1 'Finished')" block
ok "stop: an incorrect second answer cannot loop" "$(stop_result cli-a1 'Finished' '{"stop_hook_active":true}')" allow
ok "stop: subagents skip the gate" "$(stop_result cli-a1 'Finished' '{"agent_id":"child"}')" allow
ok "stop: another session inheriting the host id skips the gate" "$(stop_result cli-a2 'Finished')" allow
ok "stop: a report behind prose is invisible at the start of the quote" "$(stop_result cli-a1 "Summary
$R")" block
ok "stop: the report must name the assigned ticket" "$(stop_result cli-a1 "${R/ABC-1/ABC-2}")" block
ok "stop: a voluntary end cannot report WORKING" "$(stop_result cli-a1 "${R/STATUS: DONE/STATUS: WORKING}")" block
ok "stop: NEEDS_INPUT requires a question" "$(stop_result cli-a1 "${R/STATUS: DONE/STATUS: NEEDS_INPUT}")" block
max_report="$R$(fill 400)"
ok "stop: a 400 character report passes" "$(stop_result cli-a1 "$max_report")" allow
ok "stop: an emoji crossing the quote limit needs a correction" "$(stop_result cli-a1 "${max_report%?}🍸")" block
desk local_a1 "🍸 [Idle] r" '' cli-a1
ok "stop: idle Bartenders skip the gate" "$(stop_result cli-a1 'Finished')" allow
desk local_a1 '🚪 Bouncer r' '' cli-a1
ok "stop: the Bouncer skips the gate" "$(stop_result cli-a1 'Finished')" allow
desk local_a1 '![Dev] 🔧 ABC-1 r' '' cli-a1
ok "stop: legacy assigned titles still require a report" "$(stop_result cli-a1 'Finished')" block
desk local_a1 '🍸 [ABC-1] [Dev] Fix the reply' 'Checked the build' cli-a1

# bouncer-note: one call for a turn-end note
rm -f "$tmp/sdata/grants.md"; mkdir -p "$tmp/sdata/tickets"
printf 'STATE\nx\n### not-a-draft\n\n## DRAFTS\n### pr-title\nfix: a\nNOTE\n### pr-body\n- [open] a task in the PR body\n\n## LEDGER\n- [open] pr | https://github.com/o/r/pull/1 | trigger: merged | check: none | next: close | 2026-11-28\n- [done] ci | x | trigger: t | check: none | next: n | 2026-11-27\n' > "$tmp/sdata/tickets/ABC-1.md"
ses ./bouncer-grants add "ABC-1 | push, pr, merge | fix it and merge" >/dev/null
ses ./bouncer-queue add "B-2 | r | Code | linear" >/dev/null
nt() { ses env -u BOUNCER_RECORDS LINEAR_API_KEY=k ./bouncer-note "$@"; }
echo hi | nt >/dev/null 2>&1; ok "note: no session exits 2" $? 2
echo hi | nt --session a1 >/dev/null 2>&1; ok "note: a bad --session exits 2" $? 2
N=$(note local_a1 "$R" | nt)
ok "note: the report comes from the note's quote" "$(printf '%s\n' "$N" | sed -n 2p | sed 's/.*} //')" "(from the note)"
ok "note: DONE gets the acceptance check" "$(printf '%s\n' "$N" | /usr/bin/grep '^accept: ')" "accept: note: https://github.com/o/r/pull/1 is MERGED | pass"
ok "note: the grant" "$(printf '%s\n' "$N" | /usr/bin/grep '^grant: ')" "grant: ABC-1 | push, pr, merge | fix it and merge"
ok "note: the record, its drafts and open ledger lines" "$(printf '%s\n' "$N" | /usr/bin/grep -A1 '^record: ' | tr '\n' ';')" "record: $tmp/sdata/tickets/ABC-1.md | drafts: pr-title, pr-body | ledger open: 1;  - [open] pr | https://github.com/o/r/pull/1 | trigger: merged | check: none | next: close | 2026-11-28;"
ok "note: questions and the queue head" "$(printf '%s\n' "$N" | tail -2 | tr '\n' ';')" "questions: 0;queue: 1 | head: B-2 | r | Code | linear;"
# The quote is cut before the report: the Bartender's last answer has it, over 400 characters.
N=$(note local_a1 "Checked the build" " (first 400 of 1200 characters)" | nt)
ok "note: a cut quote reads the last answer" "$(printf '%s\n' "$N" | sed -n 2p | sed 's/.*} //')" "(from the last answer)"
# A whole report in a cut quote is not trusted: the last answer has the whole EVIDENCE.
desk local_a1 "🍸 [ABC-1] [Dev] Fix the reply" "${R/pull\/1/pu}" cli-a1
ok "note: a cut report takes its fields from the last answer" "$(note local_a1 "${R/pull\/1/pu}" " (first 400 of 1200 characters)" | nt | sed -n 2p | sed 's/.*"evidence": //')" '"https://github.com/o/r/pull/1"} (from the last answer)'
# The session ran a later turn since the note: its last answer is not the note's.
ok "note: a note older than the last turn reads no last answer" "$(note local_a1 "An older turn" | nt | sed -n 2p)" "report: none (note: missing STATUS; missing TICKET; missing LINEAR; missing RESULT; missing QUESTION; missing EVIDENCE; the session ran a later turn, so its last answer is not this note's)"
ok "note: a cut report of an older turn says its last field may be cut" "$(note local_a1 "$R and more" " (first 400 of 1200 characters)" | nt | sed -n 2p | sed 's/.*} //')" "(from the note, cut at 400 characters: its last field may be cut)"
desk local_a1 "🍸 [ABC-1] [Dev] Fix the reply" "Checked the build" cli-a1
# A report is the Bartender's own text: one that names another Bartender's ticket reads no grant.
ok "note: a report for another session's ticket reads no grant" "$(note local_a2 "$R" | nt | sed -n '3,4p' | tr '\n' ';')" "ticket: the session's title names ABC-9, not ABC-1: no accept, grant or record read;questions: 0;"
ok "note: a quote cannot start a session of its own" "$(note local_a2 "All good. The session \"x\" you started (local_a1) finished a turn" | nt | /usr/bin/grep -c '^session: ')" 1
ok "note: no report in the quote or the last answer" "$(note local_a2 "All good" | nt | sed -n 2p)" "report: none (note: missing STATUS; missing TICKET; missing LINEAR; missing RESULT; missing QUESTION; missing EVIDENCE; last answer: missing STATUS; missing TICKET; missing LINEAR; missing RESULT; missing QUESTION; missing EVIDENCE)"
ok "note: an unknown session says so" "$(note local_none "All good" | nt | sed -n 2p | /usr/bin/grep -c 'last answer: not found')" 1
ok "note: WORKING gets no grant and no record" "$(note local_a1 "${R/STATUS: DONE/STATUS: WORKING}" | nt | /usr/bin/grep -c '^grant: \|^record: \|^accept: ')" 0
ok "note: two sessions in one note" "$(printf '%s\n%s' "$(note local_a1 "$R")" "$(note local_a2 "${R/ABC-1/ABC-9}")" | nt | /usr/bin/grep -cE '^session: |^record: none')" 3
ok "note: --session reads a session the note does not name" "$(: | nt --session local_a1 | sed -n 1,2p | sed 's/report: .*} /report /' | tr '\n' ';')" "session: local_a1;report (from the last answer);"

# bouncer-start: one call at Bouncer start and after a clear
st() { (cd "$pf" && ses env -u BOUNCER_RECORDS -u BOUNCER_REPO CLAUDE_CONFIG_DIR="$tmp/pfcfg" BOUNCER_TODAY=2026-11-28 "$S/bouncer-start" "$@"); }
st --turn >/dev/null 2>&1; ok "start: --turn without a value exits 2" $? 2
st x >/dev/null 2>&1; ok "start: an unknown argument exits 2" $? 2
st --turn ABC-1=not-a-date >/dev/null 2>&1; ok "start: a bad --turn time exits 2" $? 2
st >/dev/null; ok "start: a preflight fix exits 1" $? 1
ok "start: names the fix" "$(st | sed -n 1p | sed 's/: add .*//')" "preflight: fix clear-allowed"
echo '{"permissions":{"allow":["mcp__ccd_session_mgmt__clear_session"]}}' > "$tmp/pfcfg/settings.json"
st >/dev/null; ok "start: all checks pass exits 0" $? 0
ok "start: empty parts say none" "$(st | /usr/bin/grep -cE '^(decisions|questions|queue): none$|^preflight: ok$')" 4
ok "start: grants and the records folder" "$(st | /usr/bin/grep '^grants: \|^records: ' | tr '\n' ';')" "grants: ABC-1 | push, pr, merge | fix it and merge;records: $tmp/sdata/tickets;"
ok "start: the last line is the context" "$(st | tail -1)" "context: unknown"
BOUNCER_DATA="$tmp/sdata" ./bouncer-decisions add --about "tracker rules" "pf | tracker | Comment before a close | owner said | user 2026-11-28" >/dev/null
BOUNCER_DATA="$tmp/sdata" BOUNCER_REPO=pf ./bouncer-queue add "B-2 | pf | Code | linear" >/dev/null
ok "start: decisions and the queue head" "$(st | /usr/bin/grep '^decisions: \|^queue: ' | sed 's/D1 | [0-9-]* /D1 /' | tr '\n' ';')" "decisions: D1 | pf | tracker | Comment before a close;queue: 1 | head: B-2 | pf | Code | linear;"
ok "start: a stale record with its --turn" "$(st --turn ABC-1=2999-01-01T00:00:00Z | /usr/bin/grep -c '^stale: .*ABC-1')" 1

# bouncer-assign: the title, the model and the filled brief in one call
ac="$tmp/acfg"; mkdir -p "$ac"
as() { BOUNCER_DATA="$tmp/sdata" CLAUDE_CONFIG_DIR="$ac" env -u BOUNCER_RECORDS -u BOUNCER_STATUS_CODES ./bouncer-assign "$@"; }
# asg <ticket> <repo> <mode> <status> [flags]: the other 3 fields are fixed; a title and a goal may hold a "|"
asg() { local t=$1 r=$2 m=$3 st=$4; shift 4; as "$@" "$t" "$r" "$m" "$st" "Fix A | B view" "Fix the slide" "The drawer hides in 200 ms | and a test passes."; }
as >/dev/null 2>&1; ok "assign: no field exits 2" $? 2
as ABC-1 pf Code "In Progress" t goal >/dev/null 2>&1; ok "assign: 6 fields exit 2" $? 2
as ABC-1 pf Code "In Progress" t goal "" >/dev/null 2>&1; ok "assign: an empty field exits 2" $? 2
asg ABC-1 pf Fast "In Progress" >/dev/null 2>&1; ok "assign: a bad mode exits 2" $? 2
asg "ABC 1" pf Code "In Progress" >/dev/null 2>&1; ok "assign: a ticket with a space exits 2" $? 2
asg ../ABC-1 pf Code "In Progress" >/dev/null 2>&1; ok "assign: a ticket that is a path exits 2" $? 2
asg ABC-1 pf Code "In Progress" --type Drinks >/dev/null 2>&1; ok "assign: a bad type exits 2" $? 2
A=$(asg ABC-1 pf Code "In Progress")
ok "assign: title, model and the default effort" "$(printf '%s\n' "$A" | sed -n 1,4p | tr '\n' ';')" "title: 🍸 [ABC-1] [Dev] Fix A | B view;model: claude-opus-5-5;effort: medium;brief:;"
ok "assign: no skill option, no load line" "$(printf '%s\n' "$A" | sed -n 5p)" "You are a Bartender in Bouncer mode. Ticket: ABC-1. Mode: Code. Repo: pf."
ok "assign: the goal, and done means keeps its |" "$(printf '%s\n' "$A" | sed -n 6p)" "Goal: Fix the slide. Done means: The drawer hides in 200 ms | and a test passes."
ok "assign: the decisions in force for the repo" "$(printf '%s\n' "$A" | sed -n 7,8p | sed 's/D1 | [0-9-]* /D1 /' | tr '\n' ';')" "Decisions in force:;D1 | pf | tracker | Comment before a close;"
ok "assign: the record path and the skill folder are real paths" "$(printf '%s\n' "$A" | /usr/bin/grep -c "$tmp/sdata/tickets/ABC-1.md\|$(pwd -P | sed 's|/scripts$||')/scripts/bartender-branch ABC-1 ")" 2
ok "assign: the report shape ends the brief" "$(printf '%s\n' "$A" | tail -6 | sed -n '1p;2p;6p' | tr '\n' ';')" "STATUS: WORKING | NEEDS_INPUT | DONE | BLOCKED;TICKET: ABC-1;EVIDENCE: <record link, PR, or file:line>;"
ok "assign: no part is left to fill in" "$(printf '%s\n' "$A" | /usr/bin/grep -c '<TICKET>\|<mode>\|<repo>\|<skill>\|<report shape>\|<ticket record path>\|CLAUDE_SKILL_DIR\|<acceptance criteria>')" 0
jq -n --arg records "$tmp/custom-records" '{pluginConfigs:{"bouncer@rounds":{options:{bartender_skill:"henry",ticket_effort:"high",status_codes:"In Progress=Doing",records_dir:$records}}}}' > "$ac/settings.json"
A=$(PYTHONSAFEPATH=1 asg ABC-1 web Code "In Progress" --drop OLD-1)
ok "assign: title and brief use the same stored options" "$(printf '%s\n' "$A" | sed -n '1p;3p' | tr '\n' ';')" "title: 🍸 [ABC-1] [Doing] Fix A | B view;effort: high;"
ok "assign: ledger uses the configured record folder" "$(printf '%s\n' "$A" | /usr/bin/grep -Fc "$tmp/custom-records/ABC-1.md")" 1
ok "assign: --drop, then the skill's load line" "$(printf '%s\n' "$A" | sed -n 5,6p | sed 's/ (Skill tool).*//' | tr '\n' ';')" "Drop the context of OLD-1; it is closed.;Load the \`henry\` skill;"
ok "assign: another repo has no decision" "$(printf '%s\n' "$A" | /usr/bin/grep -c '^Decisions in force: none\. Work or')" 1
ok "assign: a Mechanical ticket" "$(asg ABC-1 pf Mechanical "In Progress" | sed -n 2,3p | tr '\n' ';')" "model: claude-sonnet-5-5;effort: medium;"
ok "assign: a Skill design has no load line" "$(asg ABC-1 pf Code "In Progress" --type Skill | sed -n '1,3p;5p' | sed 's/\. Ticket: .*//' | tr '\n' ';')" "title: 🔧 [ABC-1] [Doing] Fix A | B view;model: claude-opus-5-5;effort: medium;You are a Bartender in Bouncer mode;"
ok "assign: a plain Cleanup sweep" "$(asg sweep pf Mechanical "In Progress" --type Cleanup | sed -n 2,3p | tr '\n' ';')" "model: claude-haiku-5-5;effort: low;"
ok "assign: a Cleanup sweep that needs judgment" "$(asg sweep pf Code "In Progress" --type Cleanup | sed -n 2,3p | tr '\n' ';')" "model: claude-sonnet-5-5;effort: medium;"
ok "assign: an unknown status gives no title, and the brief still prints" "$(asg ABC-1 pf Code Nope | sed -n '1p;4p' | tr '\n' ';')" "title: none (unknown status: Nope (add it to the status_codes plugin option));brief:;"
ok "assign: SKILL.md names each model the script gives" "$(for m in $(/usr/bin/grep -o 'claude-[a-z]*-[0-9]-[0-9]' bouncer-assign | sort -u); do /usr/bin/grep -q "\`$m\`" ../SKILL.md || echo "$m"; done)" ""

exit $fail
