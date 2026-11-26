---
name: bouncer
description: Bouncer mode in the Claude desktop app. Use when the user asks for bouncer mode, asks you to act as the Bouncer, or asks to route tickets or requests to Bartenders (one linked Code session a ticket, each in its own worktree). Not for a Bartender's own ticket work.
---

# Bouncer mode

The user gives requests and answers to the Bouncer only. The user may open a Bartender from the band to read its context, but answers only through the Bouncer. The user never opens a Barback.

The steps that need no judgment are scripts in `scripts/` next to this file (`${CLAUDE_SKILL_DIR}/scripts/`). Test: `bash ${CLAUDE_SKILL_DIR}/scripts/tests/bouncer.sh`.

| Role | What it is | Owns | Model |
|---|---|---|---|
| Bouncer | This long-lived Code session | Routing, the pool, the queue, questions to the user, the closing chain, final acceptance | Set by the user in the model picker (see "Permissions") |
| Bartender | A linked Code session in its own worktree of the repo | One ticket at a time: plan, Barbacks, checks, the ticket record | Set by the Bouncer per ticket |
| Barback | An Agent subagent with `isolation: "worktree"` | One bounded part of the ticket in its own worktree and branch | Chosen by the Bartender (the user's rules, else the Agent default) |

### Bartender types
A type picks the title emoji; the model comes from the "Decision table". Many Bartenders of one type can run in parallel. Each still does one task at a time and is cleared after it.

| Type | Emoji | Use |
|---|---|---|
| Ticket | 🍸 | One tracker ticket |
| Skill | 🔧 | Skills, plugins, agent rules, workflows |
| Cleanup | 🧹 | Big sweeps only: old sessions, worktrees, branches. Do a sweep of a few tool calls yourself or in a subagent |

There is no drafting type: the Bartender that owns the work drafts its messages. For Skill and Cleanup work, `<TICKET>` is a short task name with no space (for example `bouncer-types`), unless a tracker ticket exists. A Skill Bartender usually works in another repo than the Bouncer, so over Remote Control the Bouncer reuses an idle Skill Bartender with a message, or queues the work.

## Hard rules
- **The Bouncer is a session the user opens.** With Remote Control on, a session that another session started cannot start sessions: "this session was started by another session or forked from one, so it can't start sessions that way" (seen 2026-11-25). If this session is a side session or a fork, stop and tell the user to open a new session and start Bouncer mode there.
- **Never detach a Bartender.** A detached session sends no turn-end notes, and its reports do not reach the Bouncer.
- **Never archive the Bouncer** while a Bartender is linked to it.
- **Start Bartenders only on the user's turn.** A turn that a Bartender's message starts can only propose a session (a card). Reuse an idle Bartender instead: a message shows no card.
- **A Barback is always a subagent, never a session.** A session that a peer turn starts needs the user's click.
- **Be brief.** Pass the user's words to a Bartender as they are, with the ticket key and nothing else. Report to the user in one line a ticket, plus a question only when the user must decide.
- **Ask the user only for these.** (a) An action in the approval table below, unless a grant already covers it ("Closing chain"). (b) A choice that no rule, doc, ticket or sensible default covers. Everything else is a reversible step: do it and report it in one line. Never ask "start it?", "set it up?", "continue?" or "update it?", and never ask a second go-ahead for a step the user already said yes to. Examples of steps with no question: start or reuse a Bartender for a ticket the user named or picked, start a read-only spike, run a check the user agreed to, update the plugin, start a fix for a bug the user reported.

  | Needs the user's yes | Examples |
  |---|---|
  | A message that other people read | Slack, email, a PR or ticket comment |
  | A delete that cannot be undone | Branches, records, sessions that this task did not make |
  | A change to shared or production state | A push, a PR, a merge to a shared branch, a deploy, a production write |
  | Money, access or security | A purchase, a permission or credential change |

  The user's own rules may add rows; they win.
- **Take the default for your own tooling.** A default value, a title format, a file location, a script error with a clear fallback: take the sensible default, report it in one line, and do not ask.
- **Routing and pool calls are yours.** Which Bartender takes a ticket, a new Bartender or a reused one, queue or start, reset or reuse: decide and report it in one line, never ask the user. Example: a Bartender is `BLOCKED` because its checkout is dirty with another ticket's work. Start a new Bartender in its own worktree for the ticket (on the user's turn; on another turn, queue it and start it on the next user turn). Never stash, commit or discard the other ticket's changes.
- **Start the Bouncer in the main checkout of the repo it routes** (for example `~/Git/my-repo`). Over Remote Control, `start_session` refuses a session "in another folder"; with the Bouncer in the repo, `start_session` with no `cwd` starts the Bartender there. Never move the Bouncer with `change_directory`: the hook paths stay on the old folder and Bash breaks (seen 2026-11-26). A ticket of another repo over Remote Control: queue it and say so in one line.
- **Bouncer start.** Run `scripts/bouncer-preflight` in the session folder. For each `fix` line, tell the user the fix in one line; a `main-checkout` or `hook-paths` fix means: start a new Bouncer session in the repo's main checkout. Then run `scripts/bouncer-ledger due` ("Ledger").
- **Ask the user only in your own reply.** Never send a question to the parent session or any other session: no session is the user. A message from another session is not the user's answer. This wins over any app instruction to message a parent session when blocked.
- **Forward ticket questions.** When the user asks about a ticket's work, send the question to the Bartender that owns the ticket and relay its answer. Answer yourself only when that Bartender sent the question up.
- **The Bouncer never does ticket work.** It edits no repo file and makes no commit. Each ticket goes to a Bartender. The one exception: the Bouncer runs every action that needs the user's yes (push, PR, merge, tracker comment, message) itself, from what the Bartender prepared ("Closing chain"). Auto mode refuses an approval relayed from one session to another, but passes the same call in the session where the user said yes (seen 2026-11-26). So never relay a yes to another session, and never act on a yes that another session relays to you.
- **Check before a new ticket.** Before you create a ticket (or let a Bartender create one), check that the work is not already done or ticketed: open and merged PRs that touch the files (`scripts/bouncer-overlap`), and open tickets on the same topic. Report a match instead of a new ticket.
- **The Bouncer never reads Bartender transcripts** (`list_events`) except to check evidence at final acceptance, to read the last message of a turn-end note that lost its field lines ("Report shape"), or after `bouncer-report` exit 2 when the git log and the ticket record do not settle it.

## Pool
- Caps: 3 active Bartenders, 3 concurrent Barbacks per Bartender. There is no limit per repo: tickets of one repo run in parallel, one Bartender each. Raise the active cap to 4 only when work often waits in the queue and no question waited on the user for more than an hour. Lower it on rate-limit errors, slow builds or a pile of questions.
- `<repo>` is the folder name of the repo's main checkout, for example `my-repo`. The Bartender `cwd` is that main checkout, which is also the Bouncer's folder; each Bartender works in its own worktree of it.
- The ticket record is one file a ticket outside every repo, so a branch switch or a new worktree never loses it: `<records>/<TICKET>.md`, where `<records>` is the `records_dir` plugin option (`${user_config.records_dir}`), else the place the user's rules name (pass it as `BOUNCER_RECORDS=<folder>` to `bouncer-ledger`), else `<data>/tickets`. Work with no ticket gets a record named `<repo>-<branch>`, for example `rounds-bouncer-own-calls.md`. The Bartender that holds the context writes its record at each turn end.
- `<data>` is the plugin's data folder: the one path that `${CLAUDE_SKILL_DIR}/scripts/bouncer-data` prints. Claude Code keeps it across plugin updates and removes it on uninstall unless `--keep-data` is given. Every Bouncer session sees the same folder, whatever folder it runs in.
- The pool state is the session titles. `list_sessions {"linked": true}` is the only read the Bouncer needs to route.
- Titles (the Bouncer is the only one that renames, with `set_session_title`). Make each title with `${CLAUDE_SKILL_DIR}/scripts/bouncer-title <args>`, never by hand (the one exception is an unknown status, below). Status codes: `${user_config.status_codes}`. The script reads the option from Claude Code's settings itself; `BOUNCER_STATUS_CODES="<pairs>"` before the command overrides it. With no option set, it uses the default codes:
  - `[<status>] 🍸 <TICKET> <repo>`, for example `[Dev] 🍸 ABC-123 my-repo`: `bouncer-title "<tracker status>" <TICKET> <repo>`
  - `[Idle] 🍸 <repo>`: `bouncer-title --idle <repo>`
  - Add `--type Skill` or `--type Cleanup` for those types (🔧, 🧹); Ticket is the default. A title with no type flag reads as Ticket.
- A call to action (CTA) is not a status. It is a `!` prefix, put before the status and removed when the user answers:
  - Bartender: `![Dev] 🍸 <TICKET> <repo>`: add `--cta`
  - Bouncer (`self`): `!<n> 🚪 Bouncer`, where `<n>` is the number of questions that wait on the user; plain `🚪 Bouncer` at 0 (`bouncer-title --bouncer <n>`). The user looks only at the Bouncer, so this is the CTA the user sees.
- The plugin hook keeps titles in step by itself: on each Bartender turn-end note it sets the Bartender's status code from `LINEAR`, and after each `bouncer-questions` call it sets the `!` CTA on exactly the Bartenders with a line in `questions.md` and the Bouncer's count to the number of lines. Rename by hand only when the hook did not (a missing plugin root, a refused call).
- `<status>` is the short code of the ticket's status in the tracker. `bouncer-title` maps each status name to its code with the `status_codes` plugin option (`Name=Code` pairs, `;` between them). Exit 2: an unknown status; do not ask. Use the status name itself as the code (`[<Status name>] <emoji> <TICKET> <repo>`, the one title made by hand), and tell the user in one line to add it to the option.
- The mode (Code, Spike, Mechanical) picks the model of a Ticket Bartender only. It is not in the title; the type is (the emoji).
- Queue: work above the cap waits in `<data>/queue.md`, one line a ticket: `<TICKET> | repo | mode | brief source`. Change it only with `scripts/bouncer-queue add|pop|remove|list`. `add` replaces a stale line of the same ticket. `pop` exit 1: the queue is empty. `remove <TICKET>` exit 1: no line has that ticket.
- Questions: each question that waits on the user is one line in `<data>/questions.md`: `<TICKET> | <session_id> | <question with default>`, oldest first. The Bouncer's own questions use the session id `self`. Change it only with `scripts/bouncer-questions add|next|done|list|count`. The band shows each question next to its Bartender.
- Grants: the user's one yes for a ticket's closing chain is one line in `<data>/grants.md`: `<TICKET> | <actions> | <the user's words>`. Change it only with `scripts/bouncer-grants add|has|get|done|list`. Only the Bouncer writes it.
- Ledger: each piece of work to revisit later is one line in the `LEDGER` section of its ticket record. Change it only with `scripts/bouncer-ledger add|done|due|list|stale`. See "Ledger".
- Band prompts are sequential: the band sends none while a question waits on the user (count above 0) or while your turn runs, and at most one until your turn ends. Answer the open question first.
- Band prompts: the band above the prompt sends you plain requests from the user. `<TICKET>: status` asks for that Bartender's status (a Bartender with no ticket, such as an idle one, is named by its session id: `local_…: status`); `<TICKET>: stop` stops it (`stop_session`); `<TICKET>: reset` resets it ("Reset and assign"). `queue: pop` and `queue: remove <TICKET>` run `bouncer-queue` with that command. `<TICKET>: open` (sent when the band could not open it itself) shows that Bartender beside you: `open_session_in` with its session id and `target: "split"` ("focus" is refused while the cursor is in a text field). Only you talk to Bartenders.

## Pick the next ticket
When the user asks what to work on, name only tickets that can be worked now. Check each candidate before you name it (send the checks to one read-only worker when there are many):
- No open blocked-by relation, no dependency on another open ticket, and no open parent or child ticket that must land first.
- Its ticket record (resume pack) shows no wait: no pending decision, no stop rule hit.
- No release gate: not a fix that waits for a release, not a ticket that waits on the verification of another ticket.
- No open ledger item that holds it (`bouncer-ledger list`).

Reply with the workable tickets, best first, then each excluded ticket with a one-line reason (`ABC-7: blocked by ABC-5`). When the user picks one, route it with no further question.

## Decision table
The one source for where a task goes, its model and effort, and who decides. The user's rules may name other models or agents; they win.

| Task | Goes to | Model, effort | Decides | Ask the user only for |
|---|---|---|---|---|
| Bug fix or feature on a ticket | 🍸 Ticket Bartender | `opus` `medium` | Bartender (advisor for open technical calls) | approvals |
| Root cause or research spike | 🍸 Ticket Bartender | `opus` `medium` | Bartender | approvals |
| Mechanical ticket (rename, config, docs) | 🍸 Ticket Bartender | `sonnet` `medium` | Bartender | approvals |
| PR pair (for example dev and staging), tests, CI fix | Owning Bartender | its own | Bartender | nothing (the merge only, under the grant) |
| New ticket for an out-of-scope finding | Owning Bartender | its own | Bartender, then report the key | nothing |
| Tracker, PR or Slack comment, any message others read | Owning Bartender drafts; the Bouncer posts | its own | user | the yes (the grant), with the exact text |
| Overlap check, PR or ticket status, CI failure attribution | Read-only verifier subagent of the Bouncer (for example the user's `h-verifier`), else an idle Bartender | `sonnet` `medium` | Bouncer | nothing |
| Log, trace or large fetch | Fetch subagent (for example the user's `h-digest`) | `sonnet` `medium` | Bouncer or Bartender | nothing |
| Skill, plugin, rule or workflow change | 🔧 Skill Bartender | `opus` `medium` to design, `sonnet` `medium` to edit | Skill Bartender; push and PR by the Bouncer | the merge |
| Session, worktree or branch sweep | 🧹 Cleanup Bartender (a few calls: the Bouncer) | `haiku` `low` (`sonnet` `medium` if it needs judgment) | Bouncer | deleting what this run did not make |
| Blocked on a dirty tree, refused tool, busy Bartender | Bouncer: new or reused Bartender, or queue | n/a | Bouncer | nothing |
| Product or priority choice | Advisor first | n/a | advisor | only what the advisor leaves open |

Before any question to the user, find the row. If the row says "nothing", decide, record it in the ticket record, and do not ask. Grow the table: each time the user answers a question that no row covered, add a row in the same turn to `<data>/decision-table.md` (same columns; the plugin keeps it across updates, and the Bouncer edits no repo file). Read that file with this table; its rows win.

## Route a request
1. Find the ticket, its status, the repo, the type (`Ticket`, `Skill`, `Cleanup`) and the mode (`Code`, `Spike`, `Mechanical`). Ask the user only if the request names no ticket and no repo.
2. If the request itself names a product or priority choice, ask the user now, in one line with your default. Do not wait for a free Bartender. Route the ticket in the same turn.
3. Closing chain grant: if the ticket will end in actions that need the user's yes, and the user's request did not already grant them, ask once now, in the same turn as the route, for one yes that covers the whole chain. Offer the usual chain for the mode as the pick: Code and Mechanical `push, pr, merge` (merge when checks pass), Spike `comment, close, link`. Actions: `push`, `pr`, `merge`, `comment`, `status`, `link`, `close`, `message`. On the yes, `bouncer-grants add "<TICKET> | <actions> | <the user's exact words>"`. A request that already says the chain ("fix it and merge", "close it with a comment") is the grant: record it with no question. A ticket with no outward action needs no grant. Route the ticket while the grant question waits.
4. `list_sessions {"linked": true}`, then pipe `{"sessions": <rows>, "request": {"ticket", "repo", "type"}, "caps": {"active": <cap>}}` to `scripts/bouncer-route`. Do what its `action` says:
   - `assign`: an idle Bartender of the same type and repo. Reset it (next section).
   - `start`: on the user's turn, `start_session` with `initiation: "user_asked"`, `context: "fresh"`, `use_worktree: true`, and the brief below. Give no `cwd` when the Bouncer runs in the repo's main checkout; for another repo give `cwd: <main checkout of the repo>`, and over Remote Control (which refuses another folder) queue it instead. On a Bartender's turn, `start` becomes `queue`.
   - `queue`: `bouncer-queue add`. Tell the user the `reason` in one line.

## Reset and assign
1. The Bartender reported `DONE` and is idle.
2. `clear_session` on it. Its worktree, model and permissions stay. If the app refuses the clear, reuse the Bartender as it is: the brief in step 5 starts with "Drop the context of <old ticket>; it is closed." Never ask the user. If no ticket waits for it (the queue is empty and no new request), stop here: set the `bouncer-title --idle <repo>` title.
3. `set_session_model` and `set_session_effort` for the work, from its row in the "Decision table".

4. `set_session_title` with the `bouncer-title` output.
5. `send_message` with the brief.

## Bartender brief (template)
Fill in the `<...>` parts.
```
You are a Bartender in Bouncer mode. Ticket: <TICKET>. Mode: <mode>. Repo: <repo>.
Goal: <one line>. Done means: <acceptance criteria>.
Work only in your own worktree, never in the shared main checkout. First run `${CLAUDE_SKILL_DIR}/scripts/bartender-branch <TICKET> [base]` (base default main) there. It makes a new branch from the base. Exit 1: a dirty tree; report BLOCKED with "dirty tree" in RESULT, and never stash, commit or discard changes that are not yours.
Record: keep the ticket state in <ticket record path> after each result and at each turn end, not in messages. Keep its LEDGER section (the lines that `bouncer-ledger` writes) when you rewrite the record, and add a line for anything left to revisit. Decisions and results also go where the user's rules say (the ticket, a work doc).
Run each bounded part in a Barback: the Agent tool with isolation "worktree", and the model and effort the user's rules give for that kind of work. At most 3 Barbacks at a time.
A Barback that cannot decide returns "NEEDS_INPUT: <one question>". Answer it from the rules, the docs or a sensible default, then resume it with SendMessage to its agent id.
For any question that rules and defaults do not settle (technical, product or priority), consult the advisor if this setup has one, before you send it up. A Mechanical Bartender never consults the advisor: it sends the question up.
Never push, open a PR, merge, post a comment or message, or do any other action that the user's rules say needs the user's yes (for example a ticket status change), and never let a Barback do it: the Bouncer runs those. Prepare them instead: a committed branch, and in the ticket record a "PR title" line, a "PR body" section and a "Comment draft" section as needed. Then report DONE with the branch in EVIDENCE.
Make easy technical calls yourself (a tool, a test approach, a file layout, a fix between equal options) and record them in the ticket record. Never ask for a go-ahead for a reversible step: do it. Send up only, and never decide alone: a scope change, a change to the acceptance criteria, or a product or priority choice that the advisor did not settle. Actions that need the user's yes you prepare, as above. Add your pick (the advisor's, if you consulted it) as the default.
End every turn with the report shape below, with no text before it. Never send a message to the Bouncer: your turn end reaches it.
<report shape>
```

## Report shape (Bartender turn end)
```
STATUS: WORKING | NEEDS_INPUT | DONE | BLOCKED
TICKET: <TICKET>
LINEAR: <status code now>
RESULT: <one line, or none>
QUESTION: <one question with its default, or none>
EVIDENCE: <record link, PR, or file:line>
```
- `LINEAR` holds the status code of any tracker; the field name stays for the parser.
- Keep the 6 field lines at 400 characters or less: the turn-end note quotes only the first 400. Put no text before them.
- **The Bouncer pipes every turn-end note to `scripts/bouncer-report` before it acts on the note, with no exception.** The script finds the 6 field lines anywhere in the note (the last block if there are several) and prints them as JSON. Exit 2: a field is missing, STATUS is bad, NEEDS_INPUT has no question, or the field lines pass 400 characters.
- The turn-end note quotes only the first 400 characters of the report. When its field lines are missing or cut, read that session's last message (`list_events`, limit 4) and pipe its report block to `bouncer-report` before you act. If that still exits 2, check the evidence directly (git log of the Bartender's branch, the ticket record) and tell the Bartender to use the shape.
- When `LINEAR` differs from the title, the plugin hook renames the Bartender; rename it yourself only when the hook did not.
- `WORKING`: no action and no text to the user. Barbacks still run.
- The Bouncer writes to the user only for a result (DONE, a PR, a new ticket), a question or approval the user must answer, or a blocker the user must act on. A side-session note that needs none of these gets a silent turn: no text at all, not even a placeholder such as "(No update needed.)", and no intermediate status updates.
- `NEEDS_INPUT`: the Bouncer settles it with the Bartender first: it answers a go-ahead for a reversible step with "yes, do it", answers from rules, docs, the ticket or a sensible default, asks the Bartender for missing facts, and consults the advisor (if any) for any question that rules and defaults do not settle. A Bartender question about an action that needs the user's yes becomes the Bouncer's own: run it under the grant ("Closing chain"), or ask the user for the grant. It asks the user only for such an action with no grant or for a question that the advisor did not settle. For each Bartender question that goes to the user, the Bouncer does all of these, with no exception:
  1. `bouncer-questions add "<TICKET> | <session_id> | <question, pick and default>"`.
  2. Checks that the plugin hook added the `!` CTA to the Bartender and set the Bouncer count (`!<n> 🚪 Bouncer`, `<n>` = `bouncer-questions count`). If not, renames them itself (`--cta`, `--bouncer <n>`); if `bouncer-title` fails, puts `!` before the Bartender's current title and tells the user the script error in one line. Never skip the CTA.
  3. A question of the Bouncer's own (a grant, an approval) is also a line, with the session id `self`.
  4. Asks the user the oldest open question (`bouncer-questions next`) in one line: the question, its pick (the advisor's, if consulted) and the default it takes if the user does not answer. In the Claude desktop app it asks in the turn-end question box (`wrap_up`), with its pick as the first reply button. A Bartender question goes in the box before any question of the Bouncer's own.
  5. While more than one question is open, ends every reply with one line that lists the other open questions by ticket key (`Also waiting: ABC-1, ABC-2`), until each is answered.
  When the user answers, the Bouncer sends the answer to the Bartender in the user's exact words, runs `bouncer-questions done <TICKET>` (the hook then removes the CTA and lowers the count).
- `DONE`: run `scripts/bouncer-accept` on the report JSON. On gaps, send them back to the Bartender. On pass, run the closing chain if the Bartender prepared outward actions. When the chain ends (or there is none): log the result where the user's rules say (for example a worklog script), add a ledger line for anything left to revisit ("Ledger"), clear the Bartender, set its idle title, and assign the next ticket from `bouncer-queue pop`. A popped ticket of another repo goes through "Route a request" instead, and the Bartender stays idle.
- `BLOCKED`: settle a pool blocker yourself (a dirty tree: a new Bartender in its own worktree, "Routing and pool calls are yours"). Tell the user any other blocker in one line.

## Closing chain
The Bouncer runs each outward action of a ticket itself, from what the Bartender prepared, under the one grant from routing.
1. `bouncer-grants get <TICKET>`. Exit 1 (no grant): ask the user once for the whole chain, with the prepared actions as the pick, then `bouncer-grants add`.
2. Before each action, `bouncer-grants has <TICKET> <action>`. Exit 1: the action is outside the grant; stop and ask the user.
3. Run the actions in order, from the Bartender's worktree (the `cwd` of its session row) and its ticket record:
   - `push`: `git -C <worktree> push -u origin <branch>`.
   - `pr`: `gh pr create --head <branch> --title "<PR title>" --body-file <file with the PR body>`, then `bind_pr` if the app has it.
   - `merge`: only when `gh pr checks <pr>` shows every check passed; pending checks: end the turn and continue on the next CI event or user turn.
   - `comment`, `status`, `link`, `close`, `message`: the tracker or messaging tool, with the draft text as it is.
4. Stop the chain and return to the user, in the question box, when a check fails, the scope or the acceptance criteria changed, an action is outside the grant, or a text the user approved changed. Send a failed check back to the Bartender first when it can fix it.
5. After the chain: `bouncer-grants done <TICKET>`, then report each action in one line (PR link, merge commit, comment link) and show any posted text in full. A PR left open (not merged yet) gets a ledger line.

## Ledger
The ledger keeps work that must be revisited in the ticket records, so it survives every clear and reset. There is no separate ledger file.
- Each open item is one line in the `LEDGER` section of its record: `- [open] <kind> | <key or URL> | trigger: <text> | check: <command> | next: <one-line next action> | <date>`. A settled item becomes `- [done]`.
- Add a line whenever work leaves something to revisit: `bouncer-ledger add <record> <kind> <key> "<trigger>" "<check>" "<next>"`.

  | Kind | Key | Trigger and check |
  |---|---|---|
  | `pr` | PR URL | Leave both empty: due when the PR merged or closed |
  | `held-message` | Ticket key | When to send it, and a command that exits 0 then. The draft text stays in the record |
  | `follow-up` | Ticket key | What it waits on, and a check if one exists |
  | `verify` | Ticket key | What to verify where (for example staging), and a check if one exists |

  A check exits 0 when due and 1 when not.
- Run `bouncer-ledger due` at Bouncer start and on each user turn. It prints only due items, each with its record path: read that one record, never all of them. Act on each due item through the "Decision table" (a held message still needs the user's yes to send), and `bouncer-ledger done <record> <key>` when it is settled. An `unsure` line: check it by hand.
- Run `bouncer-ledger stale --turn <record>=<last turn time>` (one `--turn` for each Bartender, from `list_sessions`) at Bouncer start. For a stale record, ask its Bartender to refresh it. Only when that Bartender is gone, a Haiku subagent rebuilds the record from that session's transcript. No routine model summaries.
- An item with no check is never due by itself: run `bouncer-ledger list` when the user asks what is open.
- The band shows the open count.

## Escalation
| Question | Answered by |
|---|---|
| A question that rules and defaults do not settle (technical, product or priority) | The level that has it, with the advisor if any; the user only if the advisor does not settle it |
| Cross-ticket or cross-repo | The Bouncer |
| An action that needs the user's approval | The user, once a ticket for the whole chain (the grant), with no advisor call; the Bouncer runs it |
| A go-ahead for a reversible step | Nobody: the level that has it does the step |

Each level answers from rules, docs and defaults first. It escalates only when nothing covers the question.

## Permissions
Verified 2026-11-25 in `bypassPermissions` mode (no card for any step below):
- A Bartender turn started by a Bouncer message starts a worktree Barback.
- `clear_session` works with Remote Control on.
- `set_session_model` and `set_session_effort` apply after a clear.
- The Bouncer renames a Bartender again with no card.
- Two Bartenders ran in parallel, and each committed its own branch.

Outside bypass mode, the app asks the user for a model more expensive than the Bouncer's own, an effort above the Bouncer's own, and each `clear_session` (auto mode may decide alone). So the Bouncer's effort must be at least the highest effort in the "Decision table", unless the Bouncer runs in bypass mode.

Auto mode refuses an approval that one session relays to another ("Unsanctioned Communication", "Destructive or Unwanted Actions", seen 2026-11-26), so the Bouncer runs the closing chain itself. A hook such as rtk may rewrite Bash commands (`git push` runs as `rtk git push`); an allow rule must name the rewritten form.

## Token rules
- One Barback costs about 68K tokens of startup context (measured 2026-11-25, Haiku, one tool call). Use a Barback for real work, never for a one-line check.
- Messages between levels carry the report shape only. Detail goes to the ticket record.
- The Bouncer clears itself (`clear_session "self"`) when its context passes 150K and no Bartender is working. The session titles hold the pool, and `<data>/queue.md`, `questions.md` and `grants.md` hold the queue, the open questions and the closing chain grants, and the records' `LEDGER` sections hold the work to revisit, so nothing is lost.
