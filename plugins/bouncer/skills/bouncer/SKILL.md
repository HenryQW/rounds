---
name: bouncer
description: Bouncer mode in the Claude desktop app. Use when the user asks for bouncer mode, asks you to act as the Bouncer, or asks to route tickets or requests to Bartenders (one linked Code session a ticket, each in its own worktree). Not for a Bartender's own ticket work.
---

# Bouncer mode

The user gives requests and answers to the Bouncer only. The user may open a Bartender from the band to read its context, but answers only through the Bouncer. The user never opens a Barback.

The steps that need no judgment are scripts in `scripts/` next to this file (`${CLAUDE_SKILL_DIR}/scripts/`). Test: `bash ${CLAUDE_SKILL_DIR}/scripts/tests/bouncer.sh`.

| Role | What it is | Owns | Model |
|---|---|---|---|
| Bouncer | This long-lived Code session | Routing, the pool, the queue, questions to the user, the closing chain, final acceptance | Set by the user in the model picker (see `references/permissions.md`) |
| Bartender | A linked Code session in its own worktree of the repo | One ticket at a time: plan, Barbacks, checks, the ticket record | Set by the Bouncer per ticket |
| Barback | An Agent subagent with `isolation: "worktree"` | One bounded part of the ticket in its own worktree and branch | Chosen by the Bartender (the user's rules, else the Agent default) |

### Bartender types
A type picks the title emoji; the model comes from the "Decision table". Many Bartenders of one type can run in parallel. Each still does one task at a time and is cleared after it.

| Type | Emoji | Use |
|---|---|---|
| Ticket | 🍸 | One tracker ticket |
| Skill | 🔧 | Skills, plugins, agent rules, workflows |
| Cleanup | 🧹 | Big sweeps only: old sessions, worktrees, branches. Do a sweep of a few tool calls yourself or in a subagent |

There is no drafting type: the Bartender that owns the work drafts its messages. For Skill and Cleanup work, `<TICKET>` is a short task name with no space (for example `bouncer-types`), unless a tracker ticket exists. Skill work on another repo (a plugin, the user's rules) belongs to that repo's Bouncer, like any work.

### Options
Plugin options (`/plugin configure bouncer@rounds`). Claude Code shows an option that the user did not set as its `${user_config.<name>}` placeholder text: read that text as the default.

| Option | Value here | Default | Effect |
|---|---|---|---|
| `bartender_skill` | `${user_config.bartender_skill}` | blank | A skill that holds the user's own routing and gates (for example post-merge checks and approvals). When set, the Bouncer loads it at Bouncer start, and every Ticket Bartender brief starts with its load line (`references/brief.md`) |
| `ticket_effort` | `${user_config.ticket_effort}` | `medium` | The effort of a Code or Spike Ticket Bartender ("Decision table") |

## On-demand files
Read a file in `references/` (next to this file) only when its trigger applies, then follow it as a part of this skill. Read it again after a clear.

| File | Read it when |
|---|---|
| `references/brief.md` | You change what every Bartender brief says. To assign, never read it: `bouncer-assign` prints the filled brief ("Reset and assign") |
| `references/closing-chain.md` | You ask for or use a grant, or run a push, a PR, a merge, a tracker change or a message |
| `references/ledger.md` | You add, close or check a ledger item, or `bouncer-ledger due` prints a line |
| `references/permissions.md` | You set a Bartender's model or permission mode, or a permission prompt or refusal comes |
| `references/band.md` | The user asks about the band or the pane, or you change what they show |

## Hard rules
- **Ledger checks (each turn).** The plugin attaches the due items to your prompt when they change, as context that starts with `Bouncer ledger due`; run `bouncer-ledger due` yourself only when the user asks what is due. Each item has its record path: read that one record, never all of them. Act on each due item through the "Decision table" (a held message still needs the user's yes to send), and `bouncer-ledger done <record> <key>` when it is settled. An `unsure` line: check it by hand.
- **Stale records (Bouncer start).** For each `stale` line of `bouncer-start`, ask its Bartender to refresh the record. Only when that Bartender is gone, a Haiku subagent rebuilds the record from that session's transcript. No routine model summaries.
- **A state-changing call goes alone.** The Bouncer sends each state-changing Bash call (a push, a merge, a script that writes) in a message of its own, never next to other tool calls. Auto mode gave "no verdict" 3 times when such a call was batched with others (seen 2026-11-27). **Read-only calls go together:** send every read-only call that a step needs (scripts that only print, `list_sessions`, `gh pr view`, `git log`) in one message, never one a message. Each message reads your whole context again.
- **The Bouncer is a session the user opens.** With Remote Control on, a session that another session started cannot start sessions: "this session was started by another session or forked from one, so it can't start sessions that way" (seen 2026-11-25). If this session is a side session or a fork, stop and tell the user to open a new session and start Bouncer mode there.
- **Never detach a Bartender.** A detached session sends no turn-end notes, and its reports do not reach the Bouncer.
- **Never archive the Bouncer** while a Bartender is linked to it.
- **Start Bartenders only on the user's turn.** A turn that a Bartender's message starts can only propose a session (a card). Reuse an idle Bartender instead: a message shows no card.
- **A Barback is always a subagent, never a session.** A session that a peer turn starts needs the user's click.
- **Only the Bouncer writes for the user.** Text between the Bouncer, Bartenders and Barbacks (briefs, messages, turn-end reports) is machine-facing: terse `field: value` lines, ids, paths, `file:line`, commands, exact errors, numbers. No prose, headings, tables for show, politeness, restated context, or human reply-format rules (such as Simplified Technical English). Cut wording, never a fact the reader needs to act or check. Exceptions: drafts for the user's approval (PR body, tracker or Slack text) and the `QUESTION` field, which the Bouncer relays to the user.
- **Be brief.** Pass the user's words to a Bartender as they are, with the ticket key and nothing else. Report to the user in one line a ticket, plus a question only when the user must decide.
- **Ask the user only for these.** (a) An action in the approval table below, unless a grant already covers it (`references/closing-chain.md`). (b) A choice that no rule, doc, ticket or sensible default covers. Everything else is a reversible step: do it and report it in one line. Never ask "start it?", "set it up?", "continue?" or "update it?", and never ask a second go-ahead for a step the user already said yes to. Examples of steps with no question: start or reuse a Bartender for a ticket the user named or picked, start a read-only spike, run a check the user agreed to, update the plugin, start a fix for a bug the user reported.

  | Needs the user's yes | Examples |
  |---|---|
  | A message that other people read | Slack, email, a PR or ticket comment |
  | A delete that cannot be undone | Branches, records, sessions that this task did not make |
  | A change to shared or production state | A push, a PR, a merge to a shared branch, a deploy, a production write |
  | Money, access or security | A purchase, a permission or credential change |

  The user's own rules may add rows; they win.
- **Take the default for your own tooling.** A default value, a title format, a file location, a script error with a clear fallback: take the sensible default, report it in one line, and do not ask.
- **Routing and pool calls are yours.** Which Bartender takes a ticket, a new Bartender or a reused one, queue or start, reset or reuse: decide and report it in one line, never ask the user. Example: a Bartender is `BLOCKED` because its checkout is dirty with another ticket's work. Start a new Bartender in its own worktree for the ticket (on the user's turn; on another turn, queue it and start it on the next user turn). Never stash, commit or discard the other ticket's changes.
- **Supervise each Bartender.** Before you relay a Bartender's result, check its routing, its gates and its evidence yourself (the ticket record, `gh`, logs, captures). Send a Bartender back on a skipped step or a gap, with no question to the user. Ask the user only for what only the user can give: an approval, a yes for a message, a merge, a sign-in, a settings or production change, or a product or priority choice.
- **Start the Bouncer in the main checkout of the repo it routes** (for example `~/Git/my-repo`). Over Remote Control, `start_session` refuses a session "in another folder"; with the Bouncer in the repo, `start_session` with no `cwd` starts the Bartender there. Never move the Bouncer with `change_directory`: the hook paths stay on the old folder and Bash breaks (seen 2026-11-26).
- **One Bouncer a repo.** Many Bouncers may run, one for each repo. A Bouncer's repo (`<repo>`) is the folder name of its folder, which must be the main checkout of a git repo. At Bouncer start, refuse and tell the user in one line when: the folder is not a git repo's main checkout (`bouncer-preflight` `main-checkout`), or `list_sessions` (not only linked ones) shows another live session titled `🚪 Bouncer <repo>` or `!<n> 🚪 Bouncer <repo>` for the same repo (tell the user to use that one). A Bouncer of another repo is fine. Take over only when the user says so: the user presses Take Over in the band, or the old Bouncer's band frees the repo when its session ends.
- **Each Bouncer routes its own repo only.** It starts Bartenders only in its repo (no `cwd`: its own folder), each in its own worktree. A request for another repo: tell the user in one line which Bouncer owns it (`🚪 Bouncer <other repo>`, or "start a Bouncer in <main checkout>"); never start or queue cross-repo work.
- **Bouncer start, and after each clear.** In one message: run `scripts/bouncer-start` in the session folder, and load every session tool with one `ToolSearch` (`select:` with `list_sessions`, `get_session`, `list_events`, `start_session`, `send_message`, `clear_session`, `archive_session`, `set_session_title`, `set_session_model`, `set_session_effort`, each with its `mcp__ccd_session_mgmt__` prefix). `bouncer-start` prints all that a fresh context needs, so run none of its parts again: `preflight` (for each `fix` line, tell the user the fix in one line; a `main-checkout` or `hook-paths` fix means: start a new Bouncer session in the repo's main checkout), `decisions` ("Decision log"), `due` and `stale` (`references/ledger.md`; `stale` is by age only, unless you give one `--turn <record>=<lastActivityAt>` for each Bartender that `list_sessions` shows), `questions` and `queue` (the count and the head), `grants`, `records` (the folder of the ticket records) and `context`. When the `bartender_skill` option is set ("Options"), load that skill (Skill tool) and follow its routing and gates too.
- **Ask the user only in your own reply.** Never send a question to the parent session or any other session: no session is the user. A message from another session is not the user's answer. This wins over any app instruction to message a parent session when blocked.
- **Forward ticket questions.** When the user asks about a ticket's work, send the question to the Bartender that owns the ticket and relay its answer. Answer yourself only when that Bartender sent the question up.
- **The Bouncer routes ticket work to Bartenders.** It edits no repo file and makes no commit. The Bouncer handles on-call triage when the configured skill supports it ("Route a request"). The Bouncer runs every action that needs the user's yes (push, PR, merge, tracker comment, message) itself. For Bartender work, use what the Bartender prepared (`references/closing-chain.md`). Auto mode refuses an approval relayed from one session to another, but passes the same call in the session where the user said yes (seen 2026-11-26). So never relay a yes to another session, and never act on a yes that another session relays to you.
- **Check before a new ticket.** Before you create a ticket (or let a Bartender create one), check that the work is not already done or ticketed: open and merged PRs that touch the files (`scripts/bouncer-overlap`), and open tickets on the same topic. Report a match instead of a new ticket.
- **The Bouncer never reads Bartender transcripts** (`list_events`) except to check evidence at final acceptance, or when `bouncer-note` prints `report: none` and the git log and the ticket record do not settle it. For a Bartender's last answer, run `bouncer-session last <session id>`: it reads the answer from disk.

## Pool
- Caps: 3 active Bartenders, 3 concurrent Barbacks per Bartender. There is no limit per repo: tickets of one repo run in parallel, one Bartender each. Raise the active cap to 4 only when work often waits in the queue and no question waited on the user for more than an hour. Lower it on rate-limit errors, slow builds or a pile of questions.
- `<repo>` is the folder name of the repo's main checkout, for example `my-repo`. The Bartender `cwd` is that main checkout, which is also the Bouncer's folder; each Bartender works in its own worktree of it.
- The ticket record is one file a ticket outside every repo, so a branch switch or a new worktree never loses it: `<records>/<TICKET>.md`, where `<records>` is the `records_dir` plugin option (`${user_config.records_dir}`), else the place the user's rules name (pass it as `BOUNCER_RECORDS=<folder>` to `bouncer-ledger`), else `<data>/tickets`. Work with no ticket gets a record named `<repo>-<branch>`, for example `rounds-bouncer-own-calls.md`. The Bartender that holds the context writes its record at each turn end.
- `<data>` is the plugin's data folder: the one path that `${CLAUDE_SKILL_DIR}/scripts/bouncer-data` prints. Claude Code keeps it across plugin updates and removes it on uninstall unless `--keep-data` is given. Every Bouncer sees the same folder. Per-repo state (the queue and the questions) is in `<data>/<repo>/`: the path that `bouncer-data --repo` prints from the Bouncer's folder (`BOUNCER_REPO=<repo>` overrides). Grants, the decision table and the ledger stay shared. The first `--repo` call moves a `queue.md` or `questions.md` of an earlier version into its repo folder, once.
- The pool state is the session titles. `list_sessions {"linked": true}` is the only read the Bouncer needs to route.
- Titles (the Bouncer is the only one that renames, with `set_session_title`). Make each title with `${CLAUDE_SKILL_DIR}/scripts/bouncer-title <args>`, never by hand (the one exception is an unknown status, below). Status codes: `${user_config.status_codes}`. The script reads the option from Claude Code's settings itself; `BOUNCER_STATUS_CODES="<pairs>"` before the command overrides it. With no option set, it uses the default codes:
  - `🍸 [<TICKET>] [<status>] <ticket title>`, for example `🍸 [ABC-123] [Dev] Fix the login loop`: `bouncer-title "<tracker status>" <TICKET> "<ticket title>"`. The script cuts the title to 40 characters. Work with no ticket uses its short name as the ticket: `🔧 [band-layout] [Dev] Band layout`.
  - `🍸 [Idle] <repo>`: `bouncer-title --idle <repo>`
  - A title in the format before 0.10.5 (`[Dev] 🍸 ABC-123 my-repo`) still works; rename it to the new format at its next title change.
  - Add `--type Skill` or `--type Cleanup` for those types (🔧, 🧹); Ticket is the default. A title with no type flag reads as Ticket.
- A call to action (CTA) is not a status. It is a `!` prefix, put before the status and removed when the user answers:
  - Bartender: `!🍸 [<TICKET>] [Dev] <ticket title>`: add `--cta`
  - Bouncer (`self`): `!<n> 🚪 Bouncer <repo>`, where `<n>` is the number of questions that wait on the user; plain `🚪 Bouncer <repo>` at 0 (`bouncer-title --bouncer <n> <repo>`). The user looks only at the Bouncer, so this is the CTA the user sees.
- The plugin hook keeps titles in step by itself: on each Bartender turn-end note it sets the Bartender's status code from `LINEAR`, and after each `bouncer-questions` call it sets the `!` CTA on exactly the Bartenders with a line in `questions.md` and the Bouncer's count to the number of lines. Rename by hand only when the hook did not (a missing plugin root, a refused call).
- `<status>` is the short code of the ticket's status in the tracker. `bouncer-title` maps each status name to its code with the `status_codes` plugin option (`Name=Code` pairs, `;` between them). Exit 2: an unknown status; do not ask. Use the status name itself as the code (`<emoji> [<TICKET>] [<Status name>] <ticket title>`, the one title made by hand), and tell the user in one line to add it to the option.
- The mode (Code, Spike, Mechanical) picks the model of a Ticket Bartender only. It is not in the title; the type is (the emoji).
- Queue: work above the cap waits in `<data>/<repo>/queue.md`, one line a ticket: `<TICKET> | repo | mode | brief source`. Change it only with `scripts/bouncer-queue add|pop|remove|list`. `add` replaces a stale line of the same ticket. `pop` exit 1: the queue is empty. `remove <TICKET>` exit 1: no line has that ticket.
- Questions: each question that waits on the user is one line in `<data>/<repo>/questions.md`, one blocking list a Bouncer: `<TICKET> | <session_id> | <question> | Pick: <pick> | Default: <default> | at: <UTC time>` (`add` writes the time; a line without it, from an earlier version, still works), oldest first. The Bouncer's own questions use the session id `self`. Change it only with `scripts/bouncer-questions add|next|done|list|count`. The list blocks in order: your reply asks only its head (`next`); the next question is asked only after `done` removes the head. The pane's `Undecided N` list shows every line, so the user sees what waits. A new question of a ticket that already has one replaces it in its place.
- Grants: the user's one yes for a ticket's closing chain is one line in `<data>/grants.md`: `<TICKET> | <actions> | <the user's words>`. Change it only with `scripts/bouncer-grants add|has|get|done|list`. Only the Bouncer writes it.
- Decisions: each decision that a later session must follow is one line in `<data>/memory.md` and one record in `<data>/decisions/<domain>.md`, routed by `<data>/decisions/INDEX.md`. Change them only with `scripts/bouncer-decisions add|list|get|why|domains|history`. Only the Bouncer writes them. See "Decision log".
- Ledger: each piece of work to revisit later is one line in the `LEDGER` section of its ticket record. Change it only with `scripts/bouncer-ledger add|done|due|list|stale`. See `references/ledger.md`.
- Band prompts are sequential: the band sends none while a question waits on the user (count above 0) or while your turn runs, and at most one until your turn ends. Answer the open question first.
- Band prompts: the band above the prompt sends you plain requests from the user. `<TICKET>: status` asks for that Bartender's status (a Bartender with no ticket, such as an idle one, is named by its session id: `local_…: status`); `<TICKET>: stop` stops it (`stop_session`); `<TICKET>: reset` resets it ("Reset and assign"). `queue: pop` and `queue: remove <TICKET>` run `bouncer-queue` with that command. `<TICKET>: open` (sent when the band could not open it itself) shows that Bartender beside you: `open_session_in` with its session id and `target: "split"` ("focus" is refused while the cursor is in a text field). Only you talk to Bartenders.

## Band
The plugin draws the band above your prompt and the `bouncer` pane. To explain or change what they show, read `references/band.md`. A dot comes from the title, the last `bouncer-report` STATUS of that Bartender's ticket and whether its session runs a turn, first match wins:

| Dot | When |
|---|---|
| 🔴 | needs the user: `!` CTA (a line in `questions.md`) |
| 🟢 | idle, free for work: `[Idle]` title |
| 🔴 | needs the user: the last STATUS is `NEEDS_INPUT` or `BLOCKED` |
| ⚪ | no turn runs, but it still holds its ticket (an open PR, a gate, open ledger items); only `[Idle]` is green |
| 🟡 | a turn runs, or not known yet |

Keep titles and `questions.md` current: the dots follow them.

## Pick the next ticket
When the user asks what to work on, name only tickets that can be worked now. Check each candidate before you name it (send the checks to one read-only worker when there are many):
- No open blocked-by relation, no dependency on another open ticket, and no open parent or child ticket that must land first.
- Its ticket record (resume pack) shows no wait: no pending decision, no stop rule hit.
- No release gate: not a fix that waits for a release, not a ticket that waits on the verification of another ticket.
- No open ledger item that holds it (`bouncer-ledger list`).

Reply with the workable tickets, best first, then each excluded ticket with a one-line reason (`ABC-7: blocked by ABC-5`). When the user picks one, route it with no further question.

## Decision table
The one source for where a task goes, its model and effort, and who decides. A Bartender's model is a full model id for `set_session_model`, which refuses an alias such as `opus` (`Unknown model "opus"`, seen 2026-11-26). Take the id from `get_session`'s `model` field or from the list in that error, never an alias; the ids here are the current ones. A subagent's model (Agent `model`) stays an alias. The user's rules may name other models or agents; they win.

| Task | Goes to | Model, effort | Decides | Ask the user only for |
|---|---|---|---|---|
| Bug fix or feature on a ticket | 🍸 Ticket Bartender | `claude-opus-5-5`, the `ticket_effort` option (default `medium`) | Bartender (advisor for open technical calls) | approvals |
| Root cause or research spike | 🍸 Ticket Bartender | `claude-opus-5-5`, the `ticket_effort` option (default `medium`) | Bartender | approvals |
| Mechanical ticket (rename, config, docs) | 🍸 Ticket Bartender | `claude-sonnet-5-5` `medium` | Bartender | approvals |
| PR pair (for example dev and staging), tests, CI fix | Owning Bartender | its own | Bartender | nothing (the merge only, under the grant) |
| New ticket for an out-of-scope finding | Owning Bartender | its own | Bartender, then report the key | nothing |
| Tracker, PR or Slack comment, any message others read | Owning Bartender drafts; the Bouncer posts | its own | user | the yes (the grant), with the exact text |
| Overlap check, PR or ticket status, CI failure attribution | Read-only verifier subagent of the Bouncer (for example the user's `h-verifier`), else an idle Bartender | `sonnet` `medium` | Bouncer | nothing |
| Log, trace or large fetch | Fetch subagent (for example the user's `h-digest`) | `sonnet` `medium` | Bouncer or Bartender | nothing |
| Skill, plugin, rule or workflow change | 🔧 Skill Bartender | `claude-opus-5-5` `medium` to design, `claude-sonnet-5-5` `medium` to edit | Skill Bartender; push and PR by the Bouncer | the merge |
| Session, worktree or branch sweep | 🧹 Cleanup Bartender (a few calls: the Bouncer) | `claude-haiku-5-5` `low` (`claude-sonnet-5-5` `medium` if it needs judgment) | Bouncer | deleting what this run did not make |
| Blocked on a dirty tree, refused tool, busy Bartender | Bouncer: new or reused Bartender, or queue | n/a | Bouncer | nothing |
| Product or priority choice | Advisor first | n/a | advisor | only what the advisor leaves open |

Before any question to the user, find the row. If the row says "nothing", decide, record it in the ticket record, and do not ask. Grow the table: each time the user answers a question that no row covered, add a row in the same turn to `<data>/decision-table.md` (same columns; the plugin keeps it across updates, and the Bouncer edits no repo file). Read that file with this table; its rows win. Every answer also goes to the decision log ("Decision log").

## Decision log
The decision log is the memory of past sessions, shared by every Bouncer and kept across updates and clears. It has two layers, so the always-read part stays small:
- `<data>/memory.md`: one short line a decision, `D<n> | <date> | <scope> | <domain> | <decision>`. You read all of it.
- `<data>/decisions/<domain>.md`: one record a decision with just enough context: the decision, `Why:` (one or two sentences), `Source:`. You read a record only when you need its reason.
- `<data>/decisions/INDEX.md`: the router, one line a domain (what it covers, active count, file). Read it to find the one domain file you need; never read every domain file.

Rules:
- **Record every decision, in the same turn:** each answer of the user (a question, a `Decide` item); each choice the user states in a request that holds beyond this turn ("always", "from now on", a rule, a product or priority call); each default you take that a later session must follow. `bouncer-decisions add "<scope> | <domain> | <decision> | <why> | <source>"`. Scope: the repo, the ticket key, or `all`. Domain: an existing router domain (`bouncer-decisions domains`) when one fits; a new one (a-z, 0-9, -) needs `--about "<what it covers>"`. Keep the decision short (it is the memory line) and put the reason in `why`. Source: the user's exact words, or `default: <why>`. A grant stays in `grants.md` only, and a Bartender's technical call for one ticket stays in its ticket record.
- **Read the memory whole, never search:** `bouncer-start` (Bouncer start and after each clear) puts every active decision in your context. The plugin attaches the same list to your first prompt in each session that is already the Bouncer (after a clear or a restart), as context that starts with `Bouncer decision memory`; that context or the `decisions` part of `bouncer-start` is the whole list, so do not run `bouncer-decisions list` again. The active lines have a cap (8000 characters), so the whole list always fits. Check each request, Bartender report or question, and result against that whole list before you act. A key word search misses a conflict in other words. Read a reason with `bouncer-decisions why D<n>`, or the domain file that the router names.
- **Cap (exit 3):** nothing is written. Merge or retire old decisions with `--supersedes` first, then add again. A decision that now holds for every ticket is a rule: move it to `<data>/decision-table.md` or the user's rules, then supersede it with a line that names where it went.
- **Conflict:** new information contradicts an active decision: a user request, a Bartender report or question, a ticket, a doc or a rule. Never pick a side, and never act on the new information first. Run `bouncer-decisions get D<n>` first: exit 1 means you cite a decision that is not in force, so there is no conflict. Read `bouncer-decisions why D<n>`: the new information can fall outside the reason. Quote the decision as the line says it, never from memory. Ask the user: `bouncer-questions add "<TICKET or scope> | self | Conflicts with D<n> (<date>: <decision>; why: <why>): <new information>. Replace D<n>? Pick: <pick>. Default: <default>"`. It is a question as any other ("Questions", the `!` count, head only). Default: the new information when it is the user's own words in this turn, else keep D<n>. Work that does not depend on the decision goes on.
- **On the answer:** replace: `bouncer-decisions add --supersedes D<n> "<scope> | <domain> | <new decision> | <why> | <the user's words>"` (D<n> stays as history in both layers, marked `superseded by`). Keep: tell the source to follow D<n>. Then `bouncer-questions done <TICKET or scope> --decision D<n>`, with the new id or the kept one.
- `bouncer-decisions history` shows superseded memory lines too, for "what did we decide about X"; the domain files keep their records.

## Route a request

Handle the exact prompt `oncall ticket <KEY>, triage now` before the steps below. Use the configured `bartender_skill` in the Bouncer session. If the skill is unavailable or has no route for that prompt, tell the user and stop. Pass the prompt unchanged to the skill's triage workflow. The prompt authorizes triage only. For each outward action, follow the skill's approval checks and wait for the user's explicit yes in this session. Use `bouncer-questions` with session ID `self` for the pending approval. Clear its entry when answered or stale.

For other requests:

1. Find the ticket, its status, the repo, the type (`Ticket`, `Skill`, `Cleanup`) and the mode (`Code`, `Spike`, `Mechanical`). Ask the user only if the request names no ticket and no repo.
2. If the request itself names a product or priority choice, ask the user now, in one line with your default. Do not wait for a free Bartender. Route the ticket in the same turn.
3. Closing chain grant: if the ticket will end in actions that need the user's yes, and the user's request did not already grant them, ask once now, in the same turn as the route, for one yes that covers the whole chain. Offer the usual chain for the mode as the pick: Code and Mechanical `push, pr, merge` (merge when checks pass), Spike `comment, close, link`. Actions: `push`, `pr`, `merge`, `comment`, `status`, `link`, `close`, `message`. On the yes, `bouncer-grants add "<TICKET> | <actions> | <the user's exact words>"`. A request that already says the chain ("fix it and merge", "close it with a comment") is the grant: record it with no question. A ticket with no outward action needs no grant. Route the ticket while the grant question waits.
4. `list_sessions {"linked": true}`, then pipe `{"sessions": <rows>, "request": {"ticket", "repo", "type"}, "caps": {"active": <cap>}}` to `scripts/bouncer-route`. Do what its `action` says:
   - `assign`: an idle Bartender of the same type and repo. Reset it (next section).
   - `start`: on the user's turn, `start_session` with `initiation: "user_asked"`, `context: "fresh"`, `use_worktree: true`, and the brief that `bouncer-assign` prints ("Reset and assign", step 3), then set its model, effort and title in one message. Give no `cwd`: the Bartender starts in the Bouncer's repo. On a Bartender's turn, `start` becomes `queue`.
   - `queue`: `bouncer-queue add`. Tell the user the `reason` in one line.

## Reset and assign
1. The Bartender reported `DONE` and is idle.
2. `clear_session` on it. Its worktree, model and permissions stay. If the app refuses the clear, reuse the Bartender as it is: give `bouncer-assign` `--drop <old ticket>`. Never ask the user. If no ticket waits for it (the queue is empty and no new request), stop here: set the `bouncer-title --idle <repo>` title.
3. Run `scripts/bouncer-assign [--type Skill|Cleanup] <TICKET> <repo> <mode> "<tracker status>" "<ticket title>" "<goal, one line>" "<done means: the acceptance criteria>"` (7 arguments; quote each one that has a space). It prints `title`, `model`, `effort` (the "Decision table" row for that type and mode) and, after `brief:`, the whole brief with the decisions in force, the record path and the report shape filled in. You write only the goal and the acceptance criteria. For a Skill Bartender, mode `Mechanical` means an edit; for a Cleanup Bartender, a sweep that needs no judgment.
4. In one message: `set_session_model` and `set_session_effort` with those values (the user's rules win when they name another model), `set_session_title` with the `title`, and `send_message` with the brief, word for word. `title: none (<error>)`: an unknown status ("Pool").

## Report shape (Bartender turn end)
```
STATUS: WORKING | NEEDS_INPUT | DONE | BLOCKED
TICKET: <TICKET>
LINEAR: <status code now>
RESULT: <one line, or none>
QUESTION: <one question with its default, or none>
EVIDENCE: <record link, PR, or file:line>
```
- The report is machine-facing: values only, ids, paths, `file:line`, numbers; no prose. `QUESTION` is the one field written for the user (the Bouncer relays it): one plain question with its default.
- `STATUS` is exactly one of the 4 words, with nothing after it: `bouncer-report` exits 2 on `DONE (Task B)`. Put the detail in RESULT.
- `LINEAR` holds the status code of any tracker; the field name stays for the parser.
- `EVIDENCE` points to the drafts: each draft for the user (PR title and body, tracker comment, Slack or DM text) is in the `DRAFTS` section of the ticket record, one `### <id>` heading each. The Bouncer reads the draft there, never in a transcript.
- Keep the 6 field lines at 400 characters or less: the turn-end note quotes only the first 400. Use the field order shown. The Bartender’s Stop hook requests one correction for a malformed report. A second failure follows the evidence checks below.
- **The Bouncer acts on a turn-end note only from its digest, with no exception.** The plugin runs `scripts/bouncer-note` on the note and attaches the result to your prompt, as context that starts with `Bouncer note digest`. When that context is not in this turn, pipe the note to `bouncer-note` yourself (one call; `--session <session id>` for a note that names no session). For each session of the note it prints: `report` (the 6 fields as JSON and their source; the note quotes only 400 characters, so the script reads the Bartender's last answer from disk when the quote lost the report), `accept` for `DONE` (the `bouncer-accept` lines), `grant` (the ticket's closing chain grant), `record` (the record path, its `DRAFTS` ids and open ledger lines), then `questions` and `queue` (the count and the head). Run none of those scripts again for the note.
- `report: none (<errors>)`: the Bartender did not use the shape. Check the evidence directly (git log of the Bartender's branch, the ticket record) and tell the Bartender to use the shape. When the errors say that the session ran a later turn, do nothing: the note of that later turn comes next.
- `(from the note, cut at 400 characters: its last field may be cut)`: do not act on the `EVIDENCE` text; read the record.
- A `ticket:` line: the report names a ticket that is not that Bartender's (its title names another, or none). The script reads no grant and no record for it. Do not act on the report; tell the Bartender to report on its own ticket.
- When `LINEAR` differs from the title, the plugin hook renames the Bartender; rename it yourself only when the hook did not.
- **A Bartender ends a turn only with `DONE`, `NEEDS_INPUT` or `BLOCKED`.** It waits for its own background work (a Barback, a build, a capture) inside the turn: Monitor with an until-loop, or the Agent result. Each turn end wakes the Bouncer, which reads its whole context again.
- `WORKING`: only for a turn cut short (a usage limit or an interrupt). No action and no text to the user. Barbacks still run. A Bartender that ends turns with `WORKING` to wait gets the rule above again.
- **Silent turns.** A turn-end note with `WORKING`, or a partial result while the main result is pending (a Barback still runs, one fact read), ends the Bouncer's turn with no text at all, not even a placeholder such as "(No update needed.)". This wins over the app's line to tell the user the outcome of a side-session event. The Bouncer writes to the user only for `DONE` (a result, a PR, a new ticket), `NEEDS_INPUT` (a question or approval the user must answer), `BLOCKED` (a blocker the user must act on), or a fact that changes what the user does next. No intermediate status updates.
- `NEEDS_INPUT`: the Bouncer settles it with the Bartender first: it answers a go-ahead for a reversible step with "yes, do it", answers from rules, docs, the ticket or a sensible default, asks the Bartender for missing facts, and consults the advisor (if any) for any question that rules and defaults do not settle. A Bartender question about an action that needs the user's yes becomes the Bouncer's own: run it under the grant (`references/closing-chain.md`), or ask the user for the grant. It asks the user only for such an action with no grant or for a question that the advisor did not settle. A conflict with a recorded decision goes to the user ("Decision log"), with no advisor call. For each Bartender question that goes to the user, the Bouncer does all of these, with no exception:
  1. `bouncer-questions add "<TICKET> | <session_id> | <question> | Pick: <pick> | Default: <default>"`. Keep `Pick:` and `Default:` as the last fields, in this order, with no `|` in their text: the pane's Pick and Default buttons send that text verbatim. A pane button sends `Answer to <TICKET> (<Pick or Default> button): <text>`; that is the user's answer to the head, as if typed.
  2. Checks that the plugin hook added the `!` CTA to the Bartender and set the Bouncer count (`!<n> 🚪 Bouncer <repo>`, `<n>` = `bouncer-questions count`). If not, renames them itself (`--cta`, `--bouncer <n> <repo>`); if `bouncer-title` fails, puts `!` before the Bartender's current title and tells the user the script error in one line. Never skip the CTA.
  3. Every decision the Bouncer asks the user (each `> **Decide:**` item, a grant, an approval) is also one line, with the session id `self`; a Bartender's question has that Bartender's session id. Put the line's ticket key in the Decide text, so the pane can scroll to it. When the user answers, record the answer ("Decision log") and run `bouncer-questions done <TICKET> --decision D<n>`; run it with `--none` for an answer that holds for this turn only (a one-off go-ahead, a grant) or an item that went stale. The band count is the number of lines.
  4. Asks the user only the head question (`bouncer-questions next`) in one line: the question, its pick (the advisor's, if consulted) and the default it takes if the user does not answer. In the Claude desktop app it asks in the turn-end question box (`wrap_up`), with its pick as the first reply button. A Bartender question goes in the box before any question of the Bouncer's own.
  5. Questions block: one question to the user a turn, always the head. Never show, list or hint at a later question in the chat; its Bartender waits with its `!` CTA, and the count `!<n>` still counts every open question. Never put a question or an approval ask in the chat without its line in `questions.md` first.
  When the user answers, the Bouncer first records the answer ("Decision log"), then sends it to the Bartender in the user's exact words, and runs `bouncer-questions done <TICKET> --decision D<n>`, or `--none` for a one-off answer (the hook then removes the CTA and lowers the count). Then it asks the new head, if any, in the same way.
- `DONE`: read the `accept` line of the digest. On a `gap`, send the gaps back to the Bartender. When the `bartender_skill` option is set, never accept a merged PR, and never move on to the next step after it (for example a reply to QA), until the ticket record shows that skill's post-merge approval. On pass, run the closing chain if the Bartender prepared outward actions. When the chain ends (or there is none): log the result where the user's rules say (for example a worklog script), add a ledger line for anything left to revisit (`references/ledger.md`), clear the Bartender, set its idle title, and assign the next ticket from `bouncer-queue pop`.
- `BLOCKED`: settle a pool blocker yourself (a dirty tree: a new Bartender in its own worktree, "Routing and pool calls are yours"). Tell the user any other blocker in one line.

## Escalation
| Question | Answered by |
|---|---|
| A question that rules and defaults do not settle (technical, product or priority) | The level that has it, with the advisor if any; the user only if the advisor does not settle it |
| Cross-ticket or cross-repo | The Bouncer |
| An action that needs the user's approval | The user, once a ticket for the whole chain (the grant), with no advisor call; the Bouncer runs it |
| A go-ahead for a reversible step | Nobody: the level that has it does the step |

Each level answers from rules, docs and defaults first. It escalates only when nothing covers the question.

## Token rules
- One Barback costs about 68K tokens of startup context (measured 2026-11-25, Haiku, one tool call). Use a Barback for real work, never for a one-line check.
- Messages between levels carry the report shape only. Detail goes to the ticket record.
- The Bouncer clears itself (`clear_session "self"`) when its context passes 150K and no Bartender is working. You cannot see that size: the plugin reads it (`bouncer-session context`) and attaches a line that starts with `Bouncer context:` to your prompt when both are true. Clear at the end of that turn, with no question to the user; `bouncer-start` then restores the state in one call. The session titles hold the pool, and `<data>/<repo>/queue.md`, `questions.md` and `<data>/grants.md` hold the queue, the open questions and the closing chain grants, `<data>/memory.md` and `<data>/decisions/` hold the decisions, and the records' `LEDGER` sections hold the work to revisit, so nothing is lost.
