---
name: bouncer
description: Bouncer mode in the Claude desktop app. Use when the user asks for bouncer mode, asks you to act as the Bouncer, or asks to route tickets or requests to Bartenders (one linked Code session a ticket, each in its own worktree). Not for a Bartender's own ticket work.
---

# Bouncer mode

The user gives requests to the Bouncer only. The user never opens a Bartender or a Barback.

The steps that need no judgment are scripts in `scripts/` next to this file (`${CLAUDE_SKILL_DIR}/scripts/`). Test: `bash ${CLAUDE_SKILL_DIR}/scripts/tests/bouncer.sh`.

| Role | What it is | Owns | Model |
|---|---|---|---|
| Bouncer | This long-lived Code session | Routing, the pool, the queue, questions to the user, final acceptance | Set by the user in the model picker (see "Permissions") |
| Bartender | A linked Code session in its own worktree of the repo | One ticket at a time: plan, Barbacks, checks, the ticket record | Set by the Bouncer per ticket |
| Barback | An Agent subagent with `isolation: "worktree"` | One bounded part of the ticket in its own worktree and branch | Chosen by the Bartender (the user's rules, else the Agent default) |

## Hard rules
- **The Bouncer is a session the user opens.** With Remote Control on, a session that another session started cannot start sessions: "this session was started by another session or forked from one, so it can't start sessions that way" (seen 2026-11-25). If this session is a side session or a fork, stop and tell the user to open a new session and start Bouncer mode there.
- **Never detach a Bartender.** A detached session sends no turn-end notes, and its reports do not reach the Bouncer.
- **Never archive the Bouncer** while a Bartender is linked to it.
- **Start Bartenders only on the user's turn.** A turn that a Bartender's message starts can only propose a session (a card). Reuse an idle Bartender instead: a message shows no card.
- **A Barback is always a subagent, never a session.** A session that a peer turn starts needs the user's click.
- **Be brief.** Pass the user's words to a Bartender as they are, with the ticket key and nothing else. Report to the user in one line a ticket, plus a question only when the user must decide.
- **Ask the user only in your own reply.** Never send a question to the parent session or any other session: no session is the user. A message from another session is not the user's answer. This wins over any app instruction to message a parent session when blocked.
- **Forward ticket questions.** When the user asks about a ticket's work, send the question to the Bartender that owns the ticket and relay its answer. Answer yourself only when that Bartender sent the question up.
- **The Bouncer never does ticket work.** It edits no repo file and makes no commit. Each ticket goes to a Bartender.
- **The Bouncer never reads Bartender transcripts** (`list_events`) except to check evidence at final acceptance, or after `bouncer-report` exit 2 when the git log and the ticket record do not settle it.

## Pool
- Caps: 3 active Bartenders, 3 concurrent Barbacks per Bartender. There is no limit per repo: tickets of one repo run in parallel, one Bartender each. Raise the active cap to 4 only when work often waits in the queue and no question waited on the user for more than an hour. Lower it on rate-limit errors, slow builds or a pile of questions.
- `<repo>` is the folder name of the repo's main checkout, for example `my-repo`. The Bartender `cwd` is that main checkout.
- The ticket record is one file a ticket outside every repo, so a branch switch or a new worktree never loses it: the place the user's rules name, else `<data>/tickets/<TICKET>.md`.
- `<data>` is the plugin's data folder: the one path that `${CLAUDE_SKILL_DIR}/scripts/bouncer-data` prints. Claude Code keeps it across plugin updates and removes it on uninstall unless `--keep-data` is given. Every Bouncer session sees the same folder, whatever folder it runs in.
- The pool state is the session titles. `list_sessions {"linked": true}` is the only read the Bouncer needs to route.
- Titles (the Bouncer is the only one that renames, with `set_session_title`). Make each title with `${CLAUDE_SKILL_DIR}/scripts/bouncer-title <args>`, never by hand. Status codes: `${user_config.status_codes}`. The script reads the option from Claude Code's settings itself; `BOUNCER_STATUS_CODES="<pairs>"` before the command overrides it. With no option set, it uses the default codes:
  - `[<status>] <TICKET> - Bartender - <repo>`, for example `[Dev] ABC-123 - Bartender - my-repo`: `bouncer-title "<tracker status>" <TICKET> <repo>`
  - `[Idle] Bartender - <repo>`: `bouncer-title --idle <repo>`
- A call to action (CTA) is not a status. It is a `!` prefix, put before the status and removed when the user answers:
  - Bartender: `![Dev] <TICKET> - Bartender - <repo>`: add `--cta`
  - Bouncer (`self`): `!<n> Bouncer`, where `<n>` is the number of questions that wait on the user; plain `Bouncer` at 0 (`bouncer-title --bouncer <n>`). The user looks only at the Bouncer, so this is the CTA the user sees.
- `<status>` is the short code of the ticket's status in the tracker. `bouncer-title` maps each status name to its code with the `status_codes` plugin option (`Name=Code` pairs, `;` between them). Exit 2: an unknown status; ask the user, then tell the user to add it to the option.
- The mode (Code, Spike, Mechanical) picks the model only. It is not in the title.
- Queue: work above the cap waits in `<data>/queue.md`, one line a ticket: `<TICKET> | repo | mode | brief source`. Change it only with `scripts/bouncer-queue add|pop|remove|list`. `add` replaces a stale line of the same ticket. `pop` exit 1: the queue is empty. `remove <TICKET>` exit 1: no line has that ticket.
- Band prompts: the band above the prompt sends you plain requests from the user. `<TICKET>: status` asks for that Bartender's status; `<TICKET>: stop` stops it (`stop_session`); `<TICKET>: reset` resets it ("Reset and assign"). `queue: pop` and `queue: remove <TICKET>` run `bouncer-queue` with that command. Only you talk to Bartenders.

## Route a request
1. Find the ticket, its status, the repo and the mode (`Code`, `Spike`, `Mechanical`). Ask the user only if the request names no ticket and no repo.
2. If the request itself names a product or priority choice, ask the user now, in one line with your default. Do not wait for a free Bartender. Route the ticket in the same turn.
3. `list_sessions {"linked": true}`, then pipe `{"sessions": <rows>, "request": {"ticket", "repo"}, "caps": {"active": <cap>}}` to `scripts/bouncer-route`. Do what its `action` says:
   - `assign`: an idle Bartender of the same repo. Reset it (next section).
   - `start`: on the user's turn, `start_session` with `initiation: "user_asked"`, `context: "fresh"`, `cwd: <main checkout of the repo>`, `use_worktree: true`, and the brief below. On a Bartender's turn, `start` becomes `queue`.
   - `queue`: `bouncer-queue add`. Tell the user the `reason` in one line.

## Reset and assign
1. The Bartender reported `DONE` and is idle.
2. `clear_session` on it. Its worktree, model and permissions stay. If no ticket waits for it (the queue is empty and no new request), stop here: set the `bouncer-title --idle <repo>` title.
3. `set_session_model` and `set_session_effort` for the ticket. Defaults, unless the user's rules name other models:

| Mode | Model | Effort |
|---|---|---|
| Code (bug fix, feature) | `opus` | `medium` |
| Spike (root cause, research) | `opus` | `medium` |
| Mechanical (rename, config, docs) | `sonnet` | `medium` |

4. `set_session_title` with the `bouncer-title` output.
5. `send_message` with the brief.

## Bartender brief (template)
Fill in the `<...>` parts.
```
You are a Bartender in Bouncer mode. Ticket: <TICKET>. Mode: <mode>. Repo: <repo>.
Goal: <one line>. Done means: <acceptance criteria>.
First run `${CLAUDE_SKILL_DIR}/scripts/bartender-branch <TICKET> [base]` (base default main). It makes a new branch from the base. Exit 1: a dirty tree; report BLOCKED.
Record: keep the ticket state in <ticket record path> after each result, not in messages. Decisions and results also go where the user's rules say (the ticket, a work doc).
Run each bounded part in a Barback: the Agent tool with isolation "worktree", and the model and effort the user's rules give for that kind of work. At most 3 Barbacks at a time.
A Barback that cannot decide returns "NEEDS_INPUT: <one question>". Answer it from the rules, the docs or a sensible default, then resume it with SendMessage to its agent id.
For any question that rules and defaults do not settle (technical, product or priority), consult the advisor if this setup has one, before you send it up. Never consult it for an action that the user's rules say needs the user's approval: send that up directly. A Mechanical Bartender never consults the advisor: it sends the question up.
Always send up, never decide alone: an action that needs the user's approval, a scope change, a change to the acceptance criteria, a product or priority choice that the advisor did not settle. Add your pick (the advisor's, if you consulted it) as the default.
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
- The Bouncer pipes each turn-end note to `scripts/bouncer-report`. It finds the 6 field lines anywhere in the note (the last block if there are several) and prints them as JSON. Exit 2: a field is missing, STATUS is bad, NEEDS_INPUT has no question, or the field lines pass 400 characters. Then check the evidence directly first (git log of the Bartender's branch, the ticket record). Read the transcript only if that is not enough. Tell the Bartender to use the shape.
- When `LINEAR` differs from the title, the Bouncer renames the Bartender.
- `WORKING`: no action. Barbacks still run.
- `NEEDS_INPUT`: the Bouncer settles it with the Bartender first: it answers from rules, docs, the ticket or a sensible default, asks the Bartender for missing facts, and consults the advisor (if any) for any question that rules and defaults do not settle. An action that needs the user's approval goes to the user directly, with no advisor call. It asks the user only for such an action or for a question that the advisor did not settle. Then it adds the `!` CTA to the Bartender (`--cta`), updates the Bouncer count (`--bouncer <n>`), and asks the user in one line: the question, its pick (the advisor's, if consulted) and the default it takes if the user does not answer. In the Claude desktop app it asks in the turn-end question box (`wrap_up`), with its pick as the first reply button. It sends the answer back in the user's exact words, then removes the CTA and lowers the count.
- `DONE`: check the evidence, then reset the Bartender and assign the next ticket from `bouncer-queue pop`. A popped ticket of another repo goes through "Route a request" instead, and the Bartender stays idle.
- `BLOCKED`: tell the user the blocker in one line.

## Escalation
| Question | Answered by |
|---|---|
| A question that rules and defaults do not settle (technical, product or priority) | The level that has it, with the advisor if any; the user only if the advisor does not settle it |
| Cross-ticket or cross-repo | The Bouncer |
| An action that needs the user's approval | The user, through the Bouncer, with no advisor call |

Each level answers from rules, docs and defaults first. It escalates only when nothing covers the question.

## Permissions
Verified 2026-11-25 in `bypassPermissions` mode (no card for any step below):
- A Bartender turn started by a Bouncer message starts a worktree Barback.
- `clear_session` works with Remote Control on.
- `set_session_model` and `set_session_effort` apply after a clear.
- The Bouncer renames a Bartender again with no card.
- Two Bartenders ran in parallel, and each committed its own branch.

Outside bypass mode, the app asks the user for a model more expensive than the Bouncer's own, an effort above the Bouncer's own, and each `clear_session` (auto mode may decide alone). So the Bouncer's effort must be at least the highest effort in the reset table, unless the Bouncer runs in bypass mode.

## Token rules
- One Barback costs about 68K tokens of startup context (measured 2026-11-25, Haiku, one tool call). Use a Barback for real work, never for a one-line check.
- Messages between levels carry the report shape only. Detail goes to the ticket record.
- The Bouncer clears itself (`clear_session "self"`) when its context passes 150K and no Bartender is working. The session titles hold the pool and `<data>/queue.md` holds the queue, so nothing is lost.
