# Rounds: design spec

The app was named AI ECG until 2026-10-29. On 2026-10-30 the internal names changed too: bundle id `com.henryqw.rounds`, executable `Rounds`, helper `rounds-hook`, state folder `Rounds`. On its first launch under the new id, the app copies the settings of `com.henryqw.aiecg` (window frame names with Rounds in place of AIECG) and moves `~/Library/Application Support/AI ECG` to `Rounds`. The Claude Code and Codex hooks show "Needs repair" once, because they still run `aiecg-hook`; Repair Hooks replaces those entries.

Date: 2026-10-26. Status: draft for review.

## 1. Goal

Rounds is a macOS background app (no Dock icon, no menu bar item). It shows the live state of Claude desktop Code-tab sessions in three groups:

1. Needs your input
2. Running
3. Quiet

It works like a drawer: a small pill at a screen edge, and a session window that slides out from it (hover, click, or a global shortcut).

### Scope

- In scope: local Claude desktop Code-tab sessions on this Mac, the agents a local herdr server runs (pi and any agent herdr detects; section 2.5), local Codex threads (section 2.6), and local pi sessions in any terminal (section 2.7).
- Out of scope (v1): terminal `claude` CLI sessions, cloud sessions, the desktop "unread" dot, own notifications, App Store.
- Platform: macOS 27 or later, Apple silicon. Swift 6.4, SwiftUI. Not sandboxed. Ad-hoc signed, also a release (no Developer ID, not notarized: a downloaded copy needs its quarantine flag removed, or Open Anyway). Installed in `/Applications`, from the release disk image, the Homebrew tap (`henryqw/tap/rounds`) or a local build.

### Success criteria

- Each local session is in the same group as the desktop sidebar shows, within 2 s of a change.
- The hotkey opens the panel in less than 200 ms.
- Return opens the selected session in Claude desktop.
- Rounds adds no delay to a Claude session (all hooks are async).

## 2. Data sources

Two sources, joined by `cliSessionId` (desktop JSON) = `session_id` (hook payload).

### 2.1 Desktop session files (read only)

Path: `~/Library/Application Support/Claude/claude-code-sessions/*/*/local_*.json`. Watched with FSEvents.

| Field | Use |
|---|---|
| `sessionId` | Row id and deep link (`local_<uuid>`) |
| `cliSessionId` | Join key to hook state and transcript |
| `title`, `cwd`, `branch` | Row text, search |
| `isArchived` | Hide |
| `lastActivityAt` | Sort, the Aged time (3.2) |
| `lastTurnEdgeAt` | Detects a turn edge with no hook (interrupt, wakeup) |
| `lastAssistantUuid` | Freshness check for `postTurnSummary` |
| `turnWrapUp` `{description, needsUser?}` | Turn ended with a question |
| `postTurnSummary` `{status_category, needs_action, status_detail, summarizes_uuid}` | Desktop end-of-turn status: `completed`, `review_ready`, `blocked`, `failed`, `need_input` |
| `error`, `errorAt` | Failed, if `errorAt` is less than 7 days old |
| `interruptedAwaitingPerson` | App quit while a prompt was pending |
| `sshConfig`, `remoteTarget` | No live state (hooks run on the remote host) |
| `spawnedFrom` `{sessionId, taskId, title, sideSession?, userFork?, btw?}` | Side session or fork: a child session of the session with that `sessionId` (5.2). `userFork` true: a fork the user made |

Required keys: `sessionId`, `cliSessionId`, `cwd`, `title`, `isArchived`, `lastActivityAt`. All other keys are optional.

### 2.2 Transcript tail (read only)

Path: `~/.claude/projects/<cwd with "/" and "." replaced by "-">/<cliSessionId>.jsonl`. Read the last 64 KiB only. Used for:

- Reconcile when `lastTurnEdgeAt` is later than the last hook event, or when the session has no hook state (it started before hook install; Claude Code reads changed hooks with its settings file watcher, so its next hook event writes a line). Skip non-message entries (`attachment`, `api-request`, `cost-state`, ...). The interrupt marker is a `user` message that starts with `[Request interrupted by user`.
- Wrap-up question: the desktop keeps `turnWrapUp.needsUser` only when the turn is marked as blocked. So when `turnWrapUp` has no `needsUser`, read the tail too: an `mcp__ccd_turn__wrap_up` tool call with a non-empty `ask`, with no user prompt after it, in a turn that ended, is a question (rule 9).

### 2.3 Hook state (written by `rounds-hook`)

Path: `~/Library/Application Support/Rounds/state/<session_id>`. One line per event, appended with `O_APPEND`:

```
<unix-ms>\t<event>\t<tool_name or notification_type or error>\t<bg_tasks>\t<cron_schedules>\t<task_list>
```

- `bg_tasks`: count of `background_tasks[]` entries whose `type` is not `monitor` (Stop only, else empty). Monitors, such as an artifact watch, stay open after the turn and are not work.
- `task_list`: the same entries (items are `{id, type, status, description}`) as `<type>:<description>`, joined with `;` (Stop only, else empty). The description loses tabs, line breaks and `;`, and is cut to 120 characters. Lines from an older helper have no sixth field: the app then knows the count only.
- `cron_schedules`: the `schedule` cron expressions of `session_crons[]` (items are `{id, schedule, recurring, prompt}`), joined with `;` (Stop only, else empty). The app checks if one fires in the next 15 min, in local time.
- The app uses the line with the highest time, plus the last `Stop` line for background and cron data.
- No prompt text, tool input or message text is written, except the short task descriptions of `task_list` (the row shows them).
- A "New session" offer card (`PreToolUse` for `mcp__ccd_session__start_session` with `initiation` `offer`) waits until the user answers it; the helper writes its tool name with `:offer` added. `initiation` is the only tool input field the helper reads. Other `start_session` calls do not wait for the user, except on a permission prompt (`PermissionRequest`).
- When the file is larger than 64 KiB, the app rewrites it with the last line only.

### 2.4 Hook entries

`HookInstaller` adds these to `~/.claude/settings.json`. Each runs the quoted absolute path of `Contents/Helpers/rounds-hook` inside the running app bundle, with `"async": true`. If the app moves, Settings shows "Wrong path".

| Event | Matcher |
|---|---|
| `UserPromptSubmit` | none |
| `PreToolUse` | `*` |
| `PostToolUse` | `*` |
| `PostToolUseFailure` | `*` |
| `PermissionRequest` | `*` |
| `Notification` | `permission_prompt\|elicitation_dialog\|elicitation_url_dialog` |
| `Elicitation` | `*` |
| `ElicitationResult` | `*` |
| `PreCompact` | `*` |
| `Stop` | none |
| `StopFailure` | `*` |
| `SessionEnd` | `*` |

Facts this relies on (checked in Claude Code 2.1.308, bundled with the desktop app):

- The desktop starts the CLI with `--setting-sources=user,project,local`, so user hooks run.
- `UserPromptSubmit` is skipped for wakeup turns (task notification, loop, cron, side session). `PreToolUse` is the running signal for those.
- `Stop` does not fire on user interrupt or API error. `StopFailure` fires on API error, with `error` in: `authentication_failed`, `oauth_org_not_allowed`, `account_on_hold`, `verification_required`, `billing_error`, `rate_limit`, `overloaded`, `invalid_request`, `model_not_found`, `server_error`, `unknown`, `max_output_tokens`, `cloud_credential_error`.
- `PermissionRequest` fires only on the "ask" path. A denial in the dialog sends no hook (`PostToolUseFailure` and `PermissionDenied` do not fire for it), but it ends the turn: the transcript gets the interrupt marker (2.2), and the desktop sets `lastTurnEdgeAt`. An approval sends no hook either.

### 2.5 herdr agents (socket API, read only except focus)

herdr is a terminal workspace manager for coding agents. Its own integrations (for pi: `herdr integration install pi`) report each agent's state, so Rounds installs nothing for it.

- Socket `~/.config/herdr/herdr.sock`, JSON lines. One request per connection: `{"id", "method", "params"}`, one response line.
- `agent.list` gives per agent: `pane_id`, `agent` (pi, claude, ...), `agent_status` (`idle`, `working`, `blocked`, `done`, `unknown`), `cwd`, `terminal_title_stripped`, and `agent_session` (`kind: path` gives the agent's session file).
- A second connection stays open with `events.subscribe`: `pane.created`, `pane.closed`, `pane.exited`, `pane.agent_detected`, `pane.updated`, and one `pane.agent_status_changed` per agent pane (this type needs a `pane_id`). Any event reads `agent.list` again (once per burst). A changed pane set closes the connection and subscribes again. The 30 s timer also reads the list, so a missed event heals. No socket: retry every 5 s; Settings shows "Not running" or "Not installed". A list and status equal to the last ones are not sent to the app again, except from the 30 s timer (for the time windows).
- Row id: `herdr:` + session file path (stable across herdr restarts), else `herdr:` + pane id. Title: the terminal title without the agent icon part ("π - ") and without a trailing folder name; else the agent name.
- An idle agent with no session file gets no row: it has no conversation (pi writes its session file at the first prompt), and one pane each would show as rows with the same folder-name title. Working, blocked and done agents always show.
- Sub-agents: an agent with no session file and a `name` that starts with `d-` (started by another agent with `herdr agent start`). Its parent is the one agent in the same `workspace_id` that has a session file; it then gets a child row under that agent (5.2), titled with the terminal title (without the icon part and the folder name), else its name. With no such agent, or more than one, the parent is not known and the sub-agent gets a row only while it is blocked.
- herdr reports no times. Rounds keeps the time each status began. At first sight it uses the session file's modification time; a quiet agent with no session file counts as old (Older); a working or blocked one starts now.
- Status: `blocked` → Needs your input "Blocked"; `working` → Running "Working"; `done` → Finished "Done"; `idle` and `unknown` → Finished "Idle". Quiet agents move to Older after the Aged time (3.2), like Claude sessions.
- Open: `agent.focus` with the pane id, then show herdr through AppleScript (`NSAppleEventsUsageDescription`; macOS asks once per app):
  - A local herdr client (a `herdr` process with a regular app above it; parents come from `sysctl` `KERN_PROC_PID`, because `proc_pidinfo` cannot read the root-owned `login` between a terminal and its shell): in rootshell, `focus pane with id` the client's `LC_ROOTSHELL_PANE` (read from the process environment, `KERN_PROCARGS2`), which brings that exact window and tab forward; in other terminals, bring the app forward.
  - No local client (every client is remote, over SSH, `tsshd`): `herdr` in a new tab of a running rootshell (`create tab with command "herdr"`; a new window when that fails), else a new rootshell window (`create window with command "herdr"`), else Ghostty (`new window with configuration {initial input: "herdr"}`). herdr attaches to its session with the agent already selected.
  - rootshell herdr control mode follows herdr focus only inside the selected tab, and has no outside command to select a herdr pane, so an agent on another native tab does not come into view.
- Out of scope: herdr servers on other machines (`--machine`).

### 2.6 Codex threads

- Thread list: table `threads` of `~/.codex/state_5.sqlite`, opened read-only (system `SQLite3`). Rows: not archived, and either `thread_source` `user` (or empty) with a plain `source`, or a sub-agent thread, whose JSON `source` is `{"subagent":{"thread_spawn":{"parent_thread_id", "depth", "agent_path", "agent_nickname", ...}}}`. Review threads (`{"subagent":{"other":"guardian"}}`) stay out. Title: `agent_nickname` (sub-agents), else `name`, else `title`, else `preview`. Time: `updated_at_ms`. Row id: `codex:` + thread id.
- Sub-agent threads are child sessions of `parent_thread_id` (5.2), with the same live state rules as other threads (rollout, hooks by thread id, `codex` process).
- Live state: Codex hooks in `~/.codex/hooks.json` run the same `rounds-hook` (the payload `session_id` is the thread id), with a 10-second timeout (Codex has no async hooks). Entries: UserPromptSubmit, PreToolUse, PermissionRequest, PostToolUse, PreCompact, Stop, Interrupt, SessionEnd. Codex reads `hooks.json` only with `hooks = true` under `[features]` in `config.toml`; install sets it with a line edit (comments and order stay) and drops the old name `codex_hooks`. Codex asks the user to review new hooks before they run; Rounds does not bypass that. Remove takes out the entries and leaves the feature switch.
- Fallback: the newest `task_started` (Running), `task_complete` (Completed) or `turn_aborted` (Stopped by you) event in the last 64 KB of the thread's `rollout_path`, read only for threads updated within the Aged time (3.2). When it is newer than the last hook event it wins (hooks off, or not reviewed yet).
- States: PermissionRequest → Needs input "Permission: <tool>"; UserPromptSubmit, PreToolUse, PostToolUse, PreCompact → Running (idle compaction after a Stop changes nothing, as in 3.2 rule 5); Stop, SessionEnd → Completed; Interrupt → Stopped by you. Running and waiting states need a `codex` process (the Codex app's app-server or the CLI); else "Stale".
- Open: `codex://threads/<id>` (Codex app, bundle `com.openai.codex`).
- Updates: FSEvents on `~/.codex/sessions` (1 s latency), the hook state folder, and the 30 s timer. The thread query runs again only when the modification date or size of `state_5.sqlite` or `state_5.sqlite-wal` changed.
- Known limit: a Codex thread that also runs in a herdr pane shows twice.

### 2.7 pi sessions

pi is a coding agent that can run almost any model. herdr shows the pi agents in its panes (2.5); here Rounds reads pi itself, for every pi session in any terminal. Checked in pi 1.4.0.

- Session files: `~/.pi/agent/sessions/--<cwd>--/<time>_<id>.jsonl` (JSON lines). Line 1 is the header `{"type":"session","id","cwd","parentSession"?}`; `parentSession` (a `/fork` or `/clone`) is the session file of the parent, so the session is a child row of it (5.2, a "fork"). The name is in the last `session_info` entry (`name`). Messages are `{"type":"message","timestamp","message":{"role","stopReason"?,"errorMessage"?}}`. pi writes the file at the first prompt, so a pi that was never prompted has no row (as in 2.5).
- Files are large (the system prompt is one line), so Rounds reads a file of up to 320 KB whole, else its first 256 KB (header, first prompt) and its last 64 KB. Only short lines and lines that start as a prompt, a reply or a name are decoded. Read again when the modification date or size changes.
- Row id: `pi:` + session file path. Title: the session name, else the first line of the first prompt, else the folder. Time: the file's modification time.
- Live state: pi reports its state only to its terminal (OSC 7501 program status), which Rounds cannot read. So Settings installs a pi extension, `Resources/rounds-pi.ts`, as `~/.pi/agent/extensions/rounds.ts` (pi loads every file there when a session starts; herdr's own pi integration works the same way). It follows pi's own status rules (`ProgramStatusReporter`) on `session_start`, `agent_start`, `message_end`, `agent_settled`, `session_before_compact`, `session_compact`, `session_compact_failed`, `ui_prompt_start`, `ui_prompt_end` and `session_shutdown`, and writes one line to `~/Library/Application Support/Rounds/pi/<session id>` (write, then rename): `<unix-ms>\t<state>\t<detail>\t<pid>\t<session file>`. State: `working`, `blocked` (a dialog open; detail: its title), `done`, `error` (detail: the first line of the error), `stopped` (the user stopped the turn) or `idle` (a session that started or resumed, with no turn yet). No prompt, tool input or model text is written. A failed write never stops the session.
- Fallback: the last message in the file, when it is newer than the extension's line (an extension that stopped loading): a prompt, a tool call or a tool result → Working; a reply with `stopReason` `stop` → Finished, `error` → Failed, `aborted` → Stopped.
- States: `blocked` → Needs input; `working` → Working ("Compacting" while it compacts); `done`, `idle` → Finished; `error` → Failed; `stopped` → Stopped. A session needs its pi process: the pid of the extension's newest line that names that pid (after `/new` or `/resume` the process runs another session, and the session it left keeps a line with the same pid). pi runs in Node and sets its process title, so a pi process is a `node` process whose `argv[0]` is `pi` (from `KERN_PROCARGS2`; `proc_name` says node). A session with no pi process is closed (its herdr pane or terminal closed, or pi quit; also a removed worktree) and gets no row, like an archived Claude session (decided 2026-11-03; it replaced the resume of 2026-10-31). So a pi that started before the extension was installed shows only after its next start. A session quiet for the Aged time (3.2) is not Working, and its Needs input or Failed is Offline (a wait never ages, so it would stay in Last Call).
- Once: a session that also runs in herdr shows only as the herdr agent, which can focus its pane. The match is the session file herdr reports in `agent_session`, compared in the letter case on disk: pi names the folder after the cwd as typed, so herdr, the extension and a fork's `parentSession` can spell `--Users-henry-Git-evermark--` a folder that is `Evermark` on disk (the file system ignores case; Rounds resolves each path it reads, with its symlinks, before it compares); herdr reports none for some pi agents, so the `HERDR_PANE_ID` in the environment of the session's running pi process (`KERN_PROCARGS2`) also joins the session to that pane: the herdr agent takes the session file (row id `herdr:` + file, listed like any agent with one). When herdr is not running, the pi row shows.
- Open: the terminal app above the pi process comes forward (parents from `sysctl`, as in 2.5); in rootshell, `focus pane with id` its `LC_ROOTSHELL_PANE`. A pi in a herdr pane has no app above it (it runs under the herdr server), so its `HERDR_PANE_ID` is focused as in 2.5. A closed session has no row, so nothing reopens it.
- Updates: FSEvents on `~/.pi/agent/sessions` and the extension's state folder (1 s latency); an event reads only the changed session files. The 30 s timer lists every session folder again, so a missed event heals. At launch, Rounds deletes the extension's lines of sessions with no session file and no pi process.
- Settings: the pi row's Install… opens the preview (the file and the events); Remove Extension in its status menu deletes the file and turns the agent off. A different file (an older Rounds) shows "Needs update", and the menu adds Update Extension. Install changes no other file. A pi that already runs loads the extension at its next start.
- Known limit: Rounds reads the default folder only, not a `--session-dir`, `PI_CODING_AGENT_SESSION_DIR` or `PI_CODING_AGENT_DIR` folder. A login prompt of pi's own is not an extension dialog, so it does not show as Needs input.

### 2.8 Tickets

A ticket is a Linear issue or a GitHub issue that a session works on. The full design is in [the tickets design](superpowers/specs/2026-11-04-tickets-design.md); this is a summary.

- Discovery, on the Mac: the session's branch (Claude, Codex; pi and herdr: `HEAD` of the session folder), not a default or detached branch; the Claude session's PRs; and the first user prompt, its first 64 KB (Linear and GitHub issue URLs, and bare Linear IDs such as `BBQ-123`, at most 5). A ticket found twice shows once. Only the rows the window lists are looked up. A child row shows only tickets that its parent does not show.
- Linear (`https://api.linear.app/graphql`, with the user's personal API key): the issue of a branch, the issues linked to a PR, and issues by ID. GitHub (`gh api graphql`, with the user's `gh` sign-in): the issues each PR closes, and issues by URL. At most 20 lookups per request, one request at a time per service.
- The key is only in the Keychain (service `com.henryqw.rounds.linear`). The cache is `~/Library/Application Support/Rounds/tickets.json` (0600): a ticket is fetched again after 10 minutes while its row is listed (1 minute when its card opens), and "no ticket" is kept for 1 day.
- Errors: no key, a key that is not valid, an issue of another workspace or not found, a GitHub organization that blocks `gh` (SSO, `FORBIDDEN`), and a missing or signed-out `gh` keep the ID and the link; the card or Settings says why. A PR that GitHub does not know (or not a github.com PR) says "Not found". An error or a bad value for one lookup leaves only that lookup without data, and it is asked again after 10 minutes. Settings checks `gh` again when it opens, so a `gh` installed or signed in after launch works with no relaunch. Offline: cached data stays, and requests try again after 30 s, doubling to 10 minutes. A rate limit waits until Linear's reset time.
- Privacy: only branch names, PR URLs, repository names and issue IDs leave the Mac. Never prompt text. Logs name the service, the request size and the result, never the key, a branch or a title.
- `TicketStore` does the lookups, requests and cache; the row mark and the hover card are in 5.2, the Settings rows in 5.4. Demo mode shows fixed tickets, with no network, Keychain or cache file.

## 3. Classification

`Classifier` is a pure function: `(DesktopSession, HookState?, LastMessage?, claudeRunning: Bool, now) -> Status` (`LastMessage`: what the transcript tail says). It copies the desktop sidebar order (`xS()` in the desktop main process). The first match wins.

| # | Condition | Group | Sub-label |
|---|---|---|---|
| 0 | `isArchived` | hidden | |
| 1 | Claude desktop is not running, or last hook event is `SessionEnd` | Quiet | Stale |
| 2 | `sshConfig` or `remoteTarget` set | Quiet | No live state |
| 3 | Last hook event is `PermissionRequest`, `Notification`, `Elicitation`, or `PreToolUse` for `AskUserQuestion`, `ExitPlanMode` or a `start_session` offer (2.3), and reconcile (3.1) finds no interrupt after it | Needs your input | Permission: `<tool>` / Question / Plan approval / New session / MCP input |
| 4 | `interruptedAwaitingPerson == true` | Needs your input | Interrupted, resume? |
| 5 | Last hook event is a running event (`UserPromptSubmit`, `PreToolUse` other tools, `PostToolUse`, `PostToolUseFailure`, `ElicitationResult`, `PreCompact`). Claude also compacts idle sessions between turns: a `PreCompact`, maybe a `StopFailure`, after a `Stop` and no prompt. Such events change nothing; the `Stop` stays the last event, so a failed idle compaction is not Failed, or reconcile (3.1) says Running | Running | `<tool>` or Thinking or Compacting |
| 6 | Last `Stop` has `bg_tasks > 0` | Running | Background tasks (the `task_list` of that `Stop` shows as lines under the row, 5.2) |
| 7 | Last hook event is `StopFailure`, or `errorAt` less than 7 days old, or fresh summary is `failed` | Needs your input | Failed: `<error>` |
| 8 | A cron in the last `Stop` fires within 15 min | Running | Wakes in `<n>` min |
| 9 | `turnWrapUp.needsUser` set, or a wrap-up question in the transcript tail (2.2), or fresh summary is `blocked` or `need_input` (and not `turnWrapUp` without `needsUser` when `needs_action` is empty) | Needs your input | Question |
| 10 | Otherwise | Quiet | Completed / Review ready / Stopped by you / New |

"Fresh summary" means `postTurnSummary.summarizes_uuid == lastAssistantUuid`, and the last hook event is `Stop` or `StopFailure` (a summary can arrive mid-turn).

Rule 9 follows the desktop summary as it is, also when `needs_action` points to side sessions or the user already opened the session. The user clears these with Mark as Done (decided 2026-10-26).

MCP tool names (`mcp__<server>__<tool>`) show as the tool part in Running and Permission labels.

### 3.0 Standard states

Every agent maps into the standard states of `GLOSSARY.md` (`SessionState`); the agent's own words go in the detail. Rows read "State · detail · folder".

| State | Group | Dot | Claude | Codex | herdr | pi |
|---|---|---|---|---|---|---|
| Needs input | Your Turn (3.2) | orange | permission, question, plan approval, new session offer, MCP input, interrupted, blocked summary | PermissionRequest | blocked | blocked (a dialog) |
| Failed | Your Turn | red | StopFailure, error, failed summary | | | error, a reply that ended in an error |
| Working | Running | blue, pulsing | turn hooks, transcript in progress | task_started, turn hooks | working | working, compacting |
| Background | Running | blue ring | Stop with background tasks (at most 2 h; detail "2 tasks"), cron wake within 15 min | | | |
| Ready | Your Turn | green | review ready (detail "review") | | done (a turn not looked at) | |
| Finished | Quiet | grey ring | completed, new (detail "new") | task_complete, Stop | idle | done, idle |
| Stopped | Quiet | grey ring | interrupted by the user | turn_aborted, Interrupt | | stopped |
| Offline | Quiet | grey dashed ring | Claude not running, hook from before launch, remote (detail "remote") | no codex process | | an aged wait (2.7) |

The labels in the rules below are now details; the state each rule returns is in this table. The group is each state's own; the Last Call rule (3.2) then moves rows by what the user has seen and by time. A herdr agent without a session file (a pi never prompted, or a sub-agent whose parent is not known, 2.5) gets a row only while it is blocked.

### 3.1 Turn edge reconcile

Runs before rule 5 when rules 0 to 4 did not match, and also for rule 3: an interrupt marker after a turn edge that is later than the wait ends the wait (a denied permission). If `lastTurnEdgeAt` is later than the last hook event time + 500 ms, or the session has no hook state, read the transcript tail. The result replaces the last hook event:

- Last message is the interrupt marker: Finished/idle, "Stopped by you" (skip rules 5 to 9).
- Last message is an `assistant` entry with `stop_reason == end_turn`: treat as `Stop`, go on to rule 6.
- A tool call that waits for the user (`AskUserQuestion`, `ExitPlanMode`, a `start_session` offer, 2.3) has no tool result yet, and no prompt came after it: Needs your input, as rule 3 (Question, Plan approval, New session). Only a session with no hook state gets here; with hooks, the tool's `PreToolUse` is later than the turn edge.
- Otherwise: Running, rule 5 (a turn with no prompt hook has started, or a wakeup turn after `Stop`).

### 3.2 Sort and count

- Starred rows (5.2) form their own group before all others, in status order, then by recent activity.

- Needs your input: longest wait first.
- Running and Finished/idle: newest `lastActivityAt` first.
- Last Call (Your Turn; Settings > Filters, decided 2026-10-30): what needs the user, in one of five states (Needs input, Failed, Ready, Finished, Stopped; the setting that chose them was removed on 2026-10-30, as one fixed rule is easier to read): a wait (Needs input, Failed) until the agent goes on, seen or not, and a result (Ready, Finished, Stopped) until the user opens it. Last Call is the panel's value, one place for all that wants the user, and the pill shows its count (one rule, decided 2026-10-30 after the pill and the tiles disagreed). Seen: opened from Rounds (saved with the marks), or a Claude `lastFocusedAt` later than the state began; a new state makes the session unseen again. Codex and herdr record no focus, so only an opening from Rounds makes them seen; Mark All as Seen (the Last Call tile's right-click menu) marks every unseen Last Call session seen at once. Seen changes only the alert for a wait: an opened wait stays in Last Call, and the pill no longer rings for it. Out of Last Call (a state left unchecked), Needs input is in Running (its work waits to go on), and the rest in Quiet. Working and Background are always Running.
- Older: a session with no activity for the Aged time (Move to Aged after, 1 to 99 hours or days, default 1 day) is Older, unless it runs or waits (Needs input, Failed); this comes before Last Call, so an old unseen session does not fill Last Call.
- Pill count: the Last Call sessions, child sessions too: always the Last Call tile's number.
- Child sessions (side sessions, forks, sub-agents; 2.1, 2.5, 2.6) go under their root session when that session is listed: not archived, and without a search also not older, hidden or Marked as Done. Else a child session is a row of its own. The row with its children goes in the most urgent group of all of them, and a Your Turn row waits since its longest wait. A child session marked done or hidden leaves its parent, as a row would leave the list. A Ready or Finished session with a sub-agent (Codex, herdr) that is Working or Background is Background ("1 sub-agent", "2 sub-agents"): it waits for the sub-agent, so it is not in Last Call.
- A sub-agent (a Codex sub-agent thread, a herdr sub-agent) never alerts unless Count sub-agents in Last Call is on (default off; decided 2026-10-29): the agent that started it handles its result and asks the user itself. Its Needs input is in Running (the parent's work goes on), and its other states in Quiet, so it never lifts its parent into Your Turn, never counts in the pill or the Last Call tile, and never hides the Another round? banner. Its dot keeps the state colour, and its row keeps the state word under a filter. Claude forks and side sessions, and pi forks, are the user's own work and alert as other sessions do. Risk: an agent that does not pass a sub-agent's question up to its parent leaves it waiting with no alert.
- Children sort by group, then newest `lastActivityAt` first. A side session or fork with its parent's title shows as "Fork" (`userFork`), else as `spawnedFrom.title`.
- Filter tile and pill counts are of sessions, by each session's own state.

### 3.3 Known limits (v1)

- A session with no hook state (it started before hook install) shows from desktop JSON and the transcript tail until its next hook event. A permission prompt in it does not show as Needs your input, because the transcript has the tool call but not if it waits for approval or runs.
- An approved permission for a long tool stays in Needs your input until the tool ends: no hook fires between the decision and `PostToolUse`, and the transcript has no entry before the tool result.
- A background `Bash` that `Stop.background_tasks` does not list shows as Finished/idle. No signal tells it apart: in local data, every `Stop` during a `run_in_background` Bash listed it, and a process that a command detaches itself (`&`, `nohup`) is not a task, so no hook event or transcript entry follows it.

## 4. Components

One SwiftPM package (this Mac has Command Line Tools only, no Xcode). Targets: `RoundsCore` (Foundation-only logic), `rounds-hook`, `Rounds` (the app), `RoundsCoreTests`. `scripts/bundle.sh` builds `Rounds.app` and signs it with the self-signed identity "Rounds Self-Signed" when a keychain has it (the release), else ad hoc; `scripts/dmg.sh` packs it into `build/Rounds.dmg`. A tag `v<VERSION>` runs `.github/workflows/release.yml`, which publishes the disk image, the signed update and its appcast (5.8), and updates the Homebrew tap (website/docs/release.md). The one package dependency is Sparkle (5.8), pinned to an exact version.

| Unit | Job |
|---|---|
| `rounds-hook` (Foundation only, in `Contents/Helpers/`) | Reads hook JSON from stdin, appends one state line (2.3). Exit 0 on success; non-zero with a stderr message on failure. |
| `HookInstaller` | Reads, checks and changes `settings.json`. Status: Installed / Not installed / Needs repair (a wrong helper path). Install and Remove: backup to `settings.json.rounds-backup`, then atomic replace. Keeps all other hooks. Idempotent. Refuses invalid JSON. |
| `DesktopSessionStore` | FSEvents watch, decode, publish `[DesktopSession]`. |
| `HookStateStore` | FSEvents watch on `state/`, publish `[cliSessionId: HookState]`. Deletes state files of archived or deleted sessions at launch. |
| `TranscriptReader` | Tail read and parse for reconcile. |
| `Classifier` | Section 3. |
| `AppModel` | Joins stores, runs the classifier on each change and every 30 s (for time windows), checks `NSWorkspace` for Claude desktop (`com.anthropic.claudefordesktop`). A change in the Claude, Codex or pi folder reads only that agent; a changed hook state file reads the agent of its session (both when the id is not known). Hook install status (`settings.json`, `hooks.json`, `config.toml`, the pi extension) is read at launch and when Settings opens or changes the hooks; the 30 s timer reads it again only when the modification date or size of one of these files changed. |
| `HotkeyManager` | Carbon `RegisterEventHotKey`. Default ⌥⌘Space. |
| `TicketStore` | Tickets of the listed rows (2.8): lookups, Linear and `gh` requests, the cache, the Linear key in the Keychain. |
| UI | `EdgeDrawer` (pill and slide), `PanelController` (session window), `HoverCard` (the card of a ticket or PR mark), `SettingsView`. |

## 5. UI

### 5.1 No menu bar

There is no menu bar item (removed on 2026-10-27): the edge pill (5.7) does its job, showing the needs-input count and growing to get attention, and the session window shows more than the old menu popover did. Settings opens from the window's gear button, ⌘, and the pill's right-click menu, which also has Check for Updates… and Quit.

### 5.2 Panel

- A normal titled window, 420 x 560 pt at first, upper third of the active screen. The user can move and resize it (minimum 360 x 320); macOS keeps its frame. Normal level; it opens on the active Space and over full-screen apps. It stays open when focus leaves; Esc, the close button, or the hotkey while it is in front closes it.
- The list is a `ScrollView` over a non-lazy `VStack` (at most about 100 rows), drawn like a sidebar list: one section per project, whose header (secondary style) folds or unfolds it with a click (a chevron shows under the pointer; folded state kept across launches). A `List` was used first, but its table guesses the height of rows it has not drawn, so the window could not fit it (5.7). `.searchable` in the toolbar (the toolbar hides the title text, so the search field fits; the window keeps the title "Rounds").
- Project: the main checkout of the session folder's git repository (a worktree's `.git` file points to `<repo>/.git/worktrees/<name>`; subfolders walk up to `.git`), else the folder itself. The header shows the project icon (5.6) or the first letter in a rounded badge, the name and the row count. Projects with waiting work come first, then running, then the most recent. Inside a project: Needs your input, Running, Finished, then Older and Hidden (search only).
- Rows: a grey fill under the pointer (fades in 0.15 s); the selected row has the accent fill of a sidebar selection with white text, so the two never look alike. Rows are buttons for VoiceOver (with the selected trait).
- Pull requests (`prs` in the session file): under the relative time, right-aligned, a symbol and the PR number in grey, in the time's font ("#16338"); with more than one, the newest (highest) number and how many more ("#16340 +1"), without changing the row height. The symbol shows the newest PR's GitHub state (`state` in the session file, as Claude desktop last saw it, so no network call): open is a green `arrow.triangle.pull`, merged a purple `arrow.triangle.merge`, closed a grey `xmark.circle`, and no state a grey `arrow.triangle.pull`; white on a selected row. Closed is grey, not red, because red means Failed. The shape changes with the colour, so colour is not the only cue. A click opens the PR, or with more than one, a menu with "Open PR n" per PR. Child rows show it too. PR numbers show as digits, with no grouping separator. A gear button at the bottom right opens Settings (`SettingsLink`); next to it a red power button asks "Quit Rounds?" in an alert sheet (Quit, Cancel; Return quits, Esc cancels), and the window stays open while it asks.
- Tickets (2.8): before the PR mark, under the time, in the same font, a grey symbol and the first ticket's identifier ("BBQ-123", "#812" for GitHub), and how many more ("BBQ-123 +1"). The symbol gives the state by its shape, as the mark is grey (orange and blue mean session states): Linear `backlog` `circle.dotted`, `unstarted` `circle`, `started` `circle.lefthalf.filled`, `completed` `checkmark.circle`, `canceled` `xmark.circle`, `triage` `circle.dashed`; GitHub open `circle`, closed as completed `checkmark.circle`, closed as not planned `xmark.circle`; no data `circle`. White on a selected row. A click opens the ticket in the default browser; with more than one, a menu with "Open BBQ-123" per ticket. The marks are never cut: the title gives way first. Both marks have the grey hover fill.
- Hover card, for the ticket mark and the PR mark: it shows after 0.6 s on the mark, stays while the pointer is on the mark or the card, and closes 0.2 s after the pointer leaves both, or when the window hides. It is a child panel of the window that never takes focus, so the other app stays in front; while the pointer is on it, the window does not slide back. It hangs under the mark (above it when there is no room below), 280 pt wide, flat with a hairline. Per item, up to 3, then "and 2 more": the identifier and service ("BBQ-123 · Linear", "owner/repo#812 · GitHub", "#42 · GitHub" for a PR), the title (up to 2 lines), then the state, the assignee (a PR: its author) and "updated 2 hr. ago". With no data: "Loading…", or why it cannot load ("gh not found", "gh not signed in", "Linear key not valid"); "Add a Linear API key in Settings to see the title", "Not in your Linear workspace", "Not found", "No access: authorize gh for this organization"; an archived issue adds "Archived", and a service that is offline adds "Not updated: offline" (an item with no data then says only that). A click on an item opens it. A click on a mark, and any menu that opens, closes the card or stops one that waits. A card whose row has no item left closes. Until the first `gh` check answers, a GitHub item with no data says "Loading…"; a PR says "Loading…" only until GitHub's first answer. Opening the card fetches data older than 1 minute again. The marks have no hover hint: the card names the items.
- Children (3.2): a row with child sessions or background tasks has a chevron before its dot (other rows keep that column empty, so titles line up), folded at first; a click on the chevron folds or unfolds it (the unfolded ids stay until the app quits). It shows unfolded while a child session needs input and during a search. Children start under the parent's title, with a thin line on their leading side, under the centre of the parent's origin icon (decided 2026-11-03: 7 pt to the right of it, the line was on no edge). A child row's subtitle ends with its kind (GLOSSARY): `folder` and "Direct" when its folder is the parent's, else `arrow.triangle.branch` and "Isolated: <folder name>". Background task lines have no kind: the Stop hook gives no folder for a task, and a sub-agent can run in a worktree of its own.
  - Under a status filter only the sessions in that group show. A parent that is not in it shows as a grey row (its icon and title, no dot, not selectable) above its matching children, which start under its title; its other children and its tasks stay out. It has the same chevron as other parent rows, but starts unfolded, so the filter's matches show at once, and it folds even while a child needs input (under Last Call every child does), except during a search (decided 2026-10-30; it could not fold before). The folded ids stay until the app quits. Under a filter a subtitle leaves out the state word (the filter names it) and keeps the detail; Failed keeps its word, since it shares the Your Turn group. All shows the full tree.
  - A child session is a full row without the agent icon (its parent shows it): status dot, title, "State · detail", relative time. ↵, double-click and the row menu work as on any row.
  - A background task (rule 6) is one line in the secondary colour: a symbol by type (shell `terminal`, subagent `person.crop.circle`, workflow `flowchart`, others `gearshape`) and the description, in one line. It has no dot and no time, and it cannot be selected. A line from an older helper (count only) shows one line "n background tasks".
  - A folded row adds its child sessions after the state: "Working · Bash · 1 fork · 2 sub-agents · repo" ("fork" for a Claude or pi fork, "session" for another Claude side session, "sub-agent" for Codex and herdr). The task count is already in the Background detail ("2 tasks").
- Filters, under the search field (`FilterBar`):
  - Tiles: Your Turn (orange `exclamationmark.circle.fill`, the count of its sessions, the same number as the pill; right-click: Mark All as Seen), Running (blue `spigot.fill`, a tap: On Tap), Quiet (green `checkmark.circle.fill`, the count of quiet rows: served, the drinks theme; decided 2026-11-03, the one exception to colour as information (DESIGN.md); it replaced a grey symbol (2026-10-30)), Older (grey `clock`, no count). Each tile is a symbol and a count, with its tile name in caption text under them, 44 pt high. Each group has a plain name (used in text, hints and VoiceOver) and a tile name, a drinking pun on the app's name: Your Turn is Last Call, Running is On Tap, Quiet is Served, Older is Aged (GLOSSARY.md). Empty lists say "Nothing Needs You", "Nothing on Tap", "Nothing Served", "Nothing Aged", under an empty tap (`spigot`). The tiles are neutral, with a 0.5 pt hairline and a faint fill; colour is only on the symbol, and the count is in the text colour (colour shows only where it carries a state). The selected tile lifts to the control surface with a stronger hairline, not a coloured fill; the name is in the hint and accessibility label. Hints show after 1 s (`NSInitialToolTipDelay`). A click shows only that status; a click on the selected tile goes back to All. Zero counts are dimmed. The filter stays across openings, but a window that opens while the pill calls (orange, red or green; 5.7) opens on Last Call, where every session the pill counts is (decided 2026-10-30: a green pill opened on a kept Served filter, which showed none of its sessions).
  - Agent toggles: one per agent in the rows (Claude, Codex, pi first, then other herdr agents by name), its icon and count in a capsule with a 0.5 pt hairline and no fill; a click hides or shows that agent; a hidden agent stays in the row, dimmed. Kept across launches.
  - Counts never follow the search; tile counts leave out hidden agents, and agent counts leave out Older sessions (also starred ones), so the agent counts add up to the tile totals. Older shows the sessions quiet for more than 24 h, which All shows only in a search. Row dots follow the states (3.0).
- No detail pane: session details are read in Claude. The list shows status, folder and time only.
- Row: status dot (orange: needs input, red: failed, blue pulse: running, grey: idle), title, sub-label, project folder name, relative time. A Failed row has a red broken glass (a tumbler drawn in code whose rim lost a shard, 12 x 14 pt, white on a selected row; decided 2026-10-30) where a working row has its glass; it does not move, since only live work moves in the list.
- Search: title, project folder, branch, ticket identifiers and titles, also of child sessions: a row that matches shows with all its children, else a row shows with its children that match. Includes older idle sessions in an "Older" section.
- Selection: no row is selected when the window opens or the filter changes; ↓ or ↑ selects the first row (and scrolls the selected row into view), a click selects a row. A selection made for you would look like a second hover.
- Keys: type to filter, ↑/↓ move (through the child sessions of unfolded rows; task lines are skipped), ↵ open (the selected row, else the first row shown) and close the window, ⌘D Mark as Done, ⌘S Star or Unstar (the row under the pointer, else the selected row), ⌘⌫ Hide (only while the search field is empty; with text it edits the text), ⌘1 to ⌘5 pick the tile All, Last Call, On Tap, Served, Aged, ⌘Z/⇧⌘Z undo and redo Mark as Done, Hide and Unhide (undo selects the row again), Esc clears search then closes.
- Right-click on a row: Open in Claude, Mark as Done, Star or Unstar ("Starred in Claude" for a Claude star), Hide or Unhide; then Open PR n (one per linked pull request, from `prs` in the session file), Open BBQ-123 (one per ticket), Reveal in Finder, Copy Branch Name. A double-click opens the session in its app; Settings > General "Clicks to open a session" can make it one click (default: two clicks).
- Mark as Done and Hide are local to Rounds (saved in `UserDefaults`). Claude desktop has no safe way to archive a session from outside: no deep link, and its session files are owned by the running app. Done hides a session until it has newer activity. Hidden sessions show only in search, in a "Hidden" section, with Unhide.
- Starred: a "Starred" section (a yellow star) comes before the projects. Under All it holds every starred session; under a status filter only the starred ones in that group (decided 2026-10-30: under Last Call, starred finished sessions hid what waits). It holds the sessions starred in Claude desktop (`isStarred`, which Rounds never changes) and those the user starred in Rounds (⌘S, any agent, saved with the marks). A starred row shows only there, whatever its state, also when Older; Done and Hide still take it out. Its sessions count in their own state.

### 5.4 Settings window

- Check for Updates… (sidebar foot, above Report a Bug): Sparkle's check now (5.8).
- Report a Bug (sidebar foot, above the signature): opens github.com/HenryQW/rounds/issues/new with the `bug` label and a body that lists the Rounds version and build, macOS, Claude, Codex (app versions, or "not found") and herdr (`~/.local/bin/herdr --version`), then empty "What happened" and "Steps to reproduce" headings.
- The sidebar's head shows the app icon (32 pt), "Rounds" and the version (from the `VERSION` file, which `bundle.sh` writes into the bundle's `CFBundleShortVersionString`; the docs site reads the same file); its foot is the author's signature: the profile picture (24 pt circle, `Resources/henry.png`), and "Made with Henry by AI 🤖.", where only "Henry" is a link to https://henry.wang (no full URL shows). The link is henry.wang's Decisive Cobalt (#1D4ED8), or its Evidence Blue (#8FB3FF) in dark mode for contrast. The session window shows only the icon and "Rounds".
- Six pages in a sidebar (like Linear's settings), each a short grouped form under a 20 pt semibold title (-0.4 pt tracking) and one line on what the page is for: General (Open at login, Open a session with, Session window shortcut, Check for updates automatically), Pill (Screen edge, Close the window after, Stop the alert for opened sessions, Show the pill on), Filters (Count sub-agents in Last Call; Move to Aged after: a number, 1 to 99, and Hours or Days; 3.2), Agents (Claude Code, Codex, pi, herdr; sidebar icon `sparkles`), Tickets (Linear, GitHub), Keys (the cheatsheet). Each setting has a one-line explanation under its name in the secondary colour; longer details are in the row's hover hint, so no explanation wraps (2026-10-30: they wrapped to six lines in the 240 pt label column).
- Stop the alert for opened sessions (default on): a seen session (3.2) gets a ring dot; a seen result leaves Last Call, and a seen wait stays but the pill no longer rings for it. Off: no session is seen, so the pill rings and Last Call keeps each session until its state changes.
- Shortcut recorder: click, press a combination with ⌘, ⌥ or ⌃ (or an F-key). Esc cancels. The field is the Session window shortcut row in General; empty, it shows "Record Shortcut". The clear button (×) in the field, or Delete while recording, removes the shortcut; it stays empty after relaunch (a stored `null`). Saved in `UserDefaults` as key code and modifiers. If registration fails: "Another app uses this shortcut.", keep the old one.
- A normal resizable window: the form scrolls; minimum 560 x 360 pt, first shown at 640 x 560 (frame name `RoundsSettingsSidebar`, so the narrow frame of the old tab window does not come back), then at the size the user gave it; it opens at the centre of the screen each time. While Settings shows, the session window stays open (it does not slide back), so changes show in it at once. SwiftUI gives the Settings window no resizable style, so the view adds `.resizable` to its window.
- Launch at Login (`SMAppService.mainApp`).
- Open a session with: Single Click or Double-Click (default), how a click on a row opens it in its app; with Double-Click, a single click only selects the row.
- An agent is on while it can report live state: Claude Code and Codex while their hooks are installed (a wrong helper path still counts, until Repair Hooks), pi while its extension is installed (an older copy still counts, until Update Extension), herdr while it is connected. The window shows only agents that are on; each agent's row shows whether it is on.
- Integration rows (Agents and Tickets pages; decided 2026-11-04: the status is the control, as on Linear's Connections page, in place of switches, status capsules and link buttons): the logo in a 28 pt tile (the logo at 18 pt, 7 pt corners, a 0.5 pt separator hairline, no fill or shadow); then two lines, 2 pt apart: the name, and one line (callout) on what the row does in the secondary colour, or on what is wrong in orange. That line does not wrap at the first window size (640 x 560); a long workspace or account name ends in "…". At the end of the row, right-aligned and centred, the row's control, one of: a status menu, a native button (Install…, Connect…) while nothing is set up, or the status only while there is no action. The status is a 7 pt dot in the state's colour and the status word: green set up (Installed, Connected, Signed in, n agents), orange needs action (Needs repair, Needs update, Key not valid, Not signed in), grey otherwise (Not found, Not running, Offline, Checking, gh not found). In a status menu the word is the label of a native borderless menu (primary text, the default menu indicator, the grey hover fill); the dot is outside the menu, as a borderless menu drops shapes from its label. Menu items say what they change (Repair Hooks, Update Extension, Remove Hooks, Remove Extension, Change Key…, Remove Key, Check Again). An absent app is "Not found", with no menu. The agents' logos keep their colours; Linear and GitHub (simple-icons, CC0, `Resources/linear.svg`, `Resources/github.svg`) are template images in the label colour. These rows take the full width, with no label column.
- Agents: one section with a row per agent (Claude Code "Sessions in the Code tab.", Codex "Threads, state from hooks.", pi "Sessions, state from an extension.", herdr "Agents from herdr's socket."), and each agent's details in its row's hover hint. The footer shows only errors (how to open a session is in General and Keys).
- pi row: "Installed" (green), menu: Remove Extension, which deletes the extension. "Needs update" (orange; "The extension is out of date.") for a different file from an older Rounds, menu: Update Extension, Remove Extension. Install… while the extension is not there opens the install preview. "Not found" when `~/.pi/agent` is absent (2.7).
- herdr row: the status only, no menu: "1 agent" or "n agents" (green), "Not running" or "Not found" (grey); hint: how agents report state.
- Codex row: "Installed" (green), menu: Remove Hooks. "Needs repair" (orange; "Hooks point to an old path.") for a wrong path, menu: Repair Hooks, Remove Hooks. Install… while the hooks are not there opens the install preview of the entries and the `config.toml` change; each changed file keeps a `.rounds-backup`. "Not found" when Codex is absent.
- Session Window Shortcuts: a read-only cheatsheet of the keys in 5.2 (action on the left, keys on the right, each key in its own keycap with a hairline (6 x 2 pt padding, at least 20 pt wide, 4 pt apart), in the system font, as Linear shows shortcuts; a monospaced ⌘D in one cap ran together). It changes with 5.2.
- Claude Code row: "Installed" (green), menu: Remove Hooks. "Needs repair" (orange; "Hooks point to an old path.") for a wrong path, menu: Repair Hooks, Remove Hooks. Install… while the hooks are not there opens the install preview.
- Tickets page (after Agents; 2.8): one section with no header, as the page title names it. Linear: with no key, Connect… opens a sheet: the Linear logo tile and "Connect Linear", "Make a personal API key in Linear: Settings, Account, Security and access. Read permission is enough. The key stays in your Keychain.", a secure field ("Paste the API key"), Cancel and Save Key (the default button, so Return saves; disabled while the field is empty). Save Key stores the key and closes the sheet; Cancel or any other close clears the typed key, and so does a close of Settings. With a key, the menu has Change Key… (the same sheet) and Remove Key: "Connected" (green; "Issues in <workspace>."), "Key not valid" (orange; "Linear did not accept the key."), "Offline" (grey) or "Checking" (grey, while a new key waits for its first answer), both with "Titles and states of issues.", as is the row with no key. GitHub: the menu has Check Again: "Signed in" (green; "Your gh account is <user>."), "Not signed in" (orange; "Run gh auth login in a shell."), "gh not found" (grey; "Install it with brew install gh."), "Offline" (grey; "Uses the gh command line tool."); "Checking" (grey, no menu; the same line) until the first `gh` check answers. Check Again checks `gh` again; while not signed in, Rounds also checks it when Settings opens. The hints say where to make a Linear key, that Read permission is enough, that the key stays in the Keychain, and what each service gets.
- Install shows the exact entries before it writes. It says that the file is written again with new formatting and that a backup is kept.

### 5.5 Deep link

Claude sessions: `claude://code/continue?session=<sessionId>`. Codex threads: `codex://threads/<id>`. herdr agents: see 2.5 Open. pi sessions: see 2.7 Open. Row menus say "Open in Claude", "Open in Codex", "Open in herdr" or "Open in Terminal". If the desktop "entry points" setting is off, Claude ignores the link; Claude still comes to the front, and the panel shows a hint.

### 5.6 Row icons

- Origin: each agent Rounds supports by name (`KnownAgent`: claude, pi, codex) ships its icon as `Resources/<name>.svg`, copied into the app bundle by `scripts/bundle.sh`. **Adding an agent requires its icon**: a test fails when `Resources/<name>.svg` is missing. Claude rows (desktop, and Claude run by herdr) use the Claude spark (`claude.svg`, from the Claude app's own assets); pi uses `pi.svg`; Codex uses the Codex glyph from the Codex app's assets with the app icon's blue-violet gradient (`codex.svg`), so it shows in light and dark mode. Other herdr agents show the first letter of their name in a rounded badge.
- Project: the first file found in the session folder from a fixed list of common names (`projectIconCandidates`: `Resources/AppIcon.icns`, `apple-touch-icon.png`, `icon.*`, `logo.*`, `assets/icon.*`, `assets/logo.*`, Next.js `app/icon.*` and `app/favicon.ico`, `public/favicon.*`, `favicon.*`, `docs/icon.png`, ...). No match: no project icon. Subfolders of a monorepo are not searched.
- App icon (`Resources/AppIcon.icns`, from `swift scripts/make-icon.swift`): a white glass, the working rows' tumbler, two-thirds full, on a deep blue gradient (#2A86F0 to #0A5CC4), with an orange bubble over the drink: the pill's two state colours, on Apple's 1024 px grid. The 16 and 32 px images use a thicker outline and a larger bubble, with no small white bubble. It replaced a heartbeat line that ended in an orange dot.
- Under the Last Call filter, when no session of a shown agent is in Your Turn (the tile total is 0), the search is empty and an agent is on (decided 2026-10-30), the empty list is the Another round? banner: 🍹, "Another round?" in the Rounds blue (#0A6BDB), and one button per agent that is on (Claude Code, Codex, herdr), with its icon and name and a Rounds-blue hairline. Starred rows stay above it. Other filters show no banner. A click on a button starts a new session there: New Claude Code Session opens `claude://code/new`; Open Codex opens the app, as Codex has no new-thread link; Open herdr brings herdr to the front. With no agent on, the banner has no icons. An empty list says what is missing (5.2).
- Layout grid (Linear's 4 pt scale: 4, 8, 12, 16): three left edges. 16 pt: the filter bar, the section icon, the chevron and the bottom bar. 40 pt: the section name and the row dot under it, so rows start under their section's title. 82 pt: the row title, where child rows start. Hover and selection fills start 8 pt from the window edge; 8 pt between tiles and agent toggles (28 pt high), 16 pt above each section, 4 pt row insets. The bottom bar starts with the app icon (16 pt) and "Rounds" in the secondary colour, and ends with Settings and Quit; it is a safe-area bar with a hard scroll edge, so rows do not show behind its buttons.
- Window rows show the origin icon (18 pt) after the status dot; the project icon is in the section header. A working row has a small glass (12 x 14 pt, a tumbler in a grey outline) before its time: blue drink fills it to 80 % in 70 % of a pour, stays, and empties to 10 % (20 frames a second); white on a selected row; two-thirds full and still with Reduce Motion. Each glass has its own speed (2.4 to 3.2 s a pour) and start from a seed (the row id), so glasses never fill in step. It replaced an ECG trace, to fit the drinks theme of the name. Only Working rows have it, so only live work moves. Section names are small (caption, semibold) with +0.4 pt tracking; row titles are medium weight; times and PR numbers are monospaced. Menu rows show the project icon with a small origin badge at its corner, or the origin icon alone (16 pt after the status symbol); every menu row keeps the same image column so titles line up.
- The project icon is looked up in the project folder (5.2), so worktrees use their repository's icon.
- Icons load once per folder for the life of the app; an icon added later shows after a relaunch.

### 5.7 Pill and session window slide

- Settings: "Screen edge" Left or Right (default); there is no Off, since the pill is the only entry point. "Close the window after": a number field (any value from 0 to 5 s) with a stepper in 0.05 s steps; default 0.25 s.
- Displays: "Show the pill on" has Select All while a display is unchecked; under it, each connected display is a full row with a checkbox and its name. Saved as the unchecked display UUIDs, so a display connected later shows the pill. With no checked display connected, the built-in display (else the first) keeps the pill, since the pill is the only entry point.
- Which display: the window slides out on the display whose pill the user used; the shortcut uses the display under the pointer if it has a pill, else the first display with one. While the window shows, every pill hides. When the Screen edge or the checked displays change while the window is open, it moves at once (one step, no animation) to the new edge, or, when its display has no pill now, to a display with one (the shortcut's rule), at the same fitted height and centring. When another display lies past the drawer's edge, the window slides only 60 pt and fades, so it never shows on the neighbour.
- Pill: an `NSPanel` (borderless, non-activating, status-bar level, all Spaces), 28 x 100 pt, at the chosen edge of each chosen display (visible frame), centred at the middle until the user moves it. ⌘-drag moves it along the edge (a hover with ⌘ down does not open the window); its place is kept as a part of the visible height (`pillPosition`), the same on every display, and the pill stays inside the visible frame. It shows only while the window is hidden. It is an edge tab: square on the screen side, round (12 pt) on the inner side, of clear glass with a 1 pt edge (primary at 25 %), so it reads as part of the screen edge. A full capsule of regular glass looked like a grey slab stuck on the edge. While sessions run, the tab turns opaque deep blue (#0A6BDB, so white text keeps about 5:1; system blue gives about 4:1) with the running count in white semibold digits (-0.2 pt tracking). Over the count is the working rows' tumbler in white (11 x 14 pt, 1.5 pt outline), which fills to 80 %, stays and empties to 10 %, 2.8 s a pour, while two white fizz bubbles (4 and 3 pt) rise 70 pt from the bottom behind it and the count and fade, every 1.9 and 2.6 s, so a live app does not look frozen; with Reduce Motion the tumbler is two-thirds full and still, with no fizz. Each coloured tab has its glass over the count (decided 2026-11-03): the tumbler on blue, the wine glass on green, the shaker on orange and the broken glass on red. It replaced a darker drink in the lower 60 % of the tab under the fizz, which was the only tab without a glass over its count; the fizz stayed (decided 2026-11-03). While a session in Last Call failed, the tab is system red, not orange, with near-black ink and a red ring (red wins over orange: a failed turn stopped and does not go on by itself; decided 2026-10-30); in place of the shaker it has the broken glass (11 x 14 pt, 1.5 pt lines), which each peek makes whole, shakes as the shaker does (0.6 s), then breaks in 0.4 s (a crack runs down from the rim, then the shard tips off); it stays broken until the next peek, and with Reduce Motion it is broken and still. The orange tab has a cocktail shaker (a shape drawn in code, 10 x 16 pt, as no SF Symbol or emoji is a shaker; decided 2026-10-30) over the count that shakes (six tilts of 16 degrees, 0.09 s each, then a spring back) at the start of each peek; only the shaker moves, so the count stays readable. It replaced a bell (`bell.fill`) that rang. A blue dot on clear glass was not visible. The blue and orange tabs are flat colour with a 0.5 pt dark hairline, and no gradient. While Last Call holds only results (Ready, Finished, Stopped; decided 2026-10-29 and 2026-10-30), the tab is opaque system green with the Your Turn count in near-black (#062910) under a still `wineglass.fill` (11 pt): a result waits, nothing is blocked, so nothing moves. While a session that needs input or failed is unseen, the pill keeps its size and its panel grows to 70 x 160 pt (room for the peek and the ring), turns opaque system orange (no glass, so no wallpaper shows through) with the Your Turn count in near-black (about 9:1) under the shaker, in near-black, and every 2 s it peeks: it moves 12 pt out from the edge with a small bounce (0.35 s), stays 0.3 s, and slides back (0.45 s), while an orange ring (3 pt) grows out of it from the edge (to 170 %) and fades in 1.2 s. A 6 pt peek with a 135 % ring was too weak to catch the eye. Colour and ringing are apart (decided 2026-10-30): the colour comes from what Last Call holds (red with a failure, orange with a wait, green with only results), and the panel grows, the pill peeks and the shaker or glass moves only while a wait is unseen; a wait the user opened keeps the colour, still. Only the pill takes the hover and the click. Still with Reduce Motion (no fizz, no ring and no shake). A size beat (to 92 %) did not catch the eye. A brightness pulse and white text made it pale yellow and unreadable on orange wallpapers. Right-click: Settings…, Quit Rounds.
- Open: hover or click the pill (or the global shortcut). The window keeps its width and is as tall as its content, from 300 pt up to the visible frame, and kept inside the visible frame. It slides in centred on the pill; while it is open it keeps its top edge and changes size only at the bottom (decided 2026-10-30: a filter with fewer rows shrank it from the top and the bottom, so the pointer could end up outside the window, which then slid back). The height comes from SwiftUI layout: `onScrollGeometryChange` gives the rows' content height plus the scroll view's insets (toolbar, filters, bottom bar), at the window's real width. The window is made and laid out at launch, while it is hidden, so SwiftUI knows the list and the bars around it before the first opening (made at the first hover, the bars took their height during the slide and the window grew in three steps); before each slide the drawer lays it out again. While it is open, each change of that height (rows come or go, a section or a row folds) fits the window once, in one step, at the end of the main-loop turn: the bars above the list (the filter bar, the Another round? banner) take their height one layout pass after the list, and a fit for each pass resized the window twice. Each content height, fit, slide and resize is in the debug log (category `frame`); `scripts/watch-frames.sh` flags abnormal ones and `scripts/check-frames.sh` checks a demo scene (`.claude/skills/watching-window-frames`). No animation changes the height: an animated height resizes the window on every frame, and each resize draws the toolbar (and the search field's focus ring) again. Below the full height the list shows no scroller. It slides in from the edge with a slightly bouncy SwiftUI spring, `.spring(duration: 0.45, bounce: 0.25)`, run on the window's origin only through `NSAnimationContext.animate(_:changes:completion:)` (the size is set before the slide; a new height that comes during the slide aims it again, and a fit or a second hover on the fading pill with the same size leaves the running slide alone, since starting it again made it stutter; the fitted height is in whole points, as AppKit sets it, so it compares equal to the window's), while the pill fades out over it; sliding back uses `.easeIn(duration: 0.22)` (a spring's slow tail left a strip of window at the edge) with the pill fading in, so the edge is never empty; the app takes focus with `activate(ignoringOtherApps:)`, because a hover on a non-activating panel gives no focus and the cooperative `activate()` leaves the other app in front.
- Close: the window slides off the screen, is ordered out, and the pill shows again, when the pointer has been outside the window for the set time, or the app has been without focus for the set time. The pointer rule starts once the pointer has entered the window (the shortcut can open it with the pointer elsewhere); an open menu of the window counts as inside. Coming back cancels the slide. Esc and the shortcut slide it back at once.

### 5.8 Updates

- Sparkle 2 (decided 2026-11-03), the one package dependency: `bundle.sh` copies `Sparkle.framework` into `Contents/Frameworks` and signs the whole app, with no hardened runtime (library validation would stop a self-signed or ad-hoc app from loading the framework).
- Feed: `SUFeedURL` is the `appcast.xml` of the latest GitHub release. The release workflow signs `Rounds.dmg`, the one release file (the download, the cask and the update; decided 2026-11-03), with the Rounds EdDSA key (`sign_update` from the same Sparkle package) and writes a one-item appcast: version, minimum macOS 27, the DMG, its length and signature, and the release notes (`scripts/release-notes.sh`) as Markdown (`<description sparkle:format="markdown">`), which Sparkle's window shows as text, not as the GitHub release page (decided 2026-11-03).
- Trust: Sparkle accepts an update when its EdDSA signature matches `SUPublicEDKey`, or when its Apple code signature matches the installed app's. Releases are signed with one self-signed certificate (decided 2026-11-03), so every release has the same designated requirement (`identifier "com.henryqw.rounds" and certificate leaf = H"981b67fc…"`): both checks pass, and macOS keeps permissions (Automation) across an update. An ad-hoc build gets a new identity each time, so only the EdDSA signature would decide, and permissions would be asked again. macOS does not trust the certificate; it does not replace a Developer ID. The certificate is in 1Password (35brookroad > Employee > "Rounds code signing certificate") and in the release secrets `SIGNING_CERTIFICATE_P12` and `SIGNING_CERTIFICATE_PASSWORD`. The private key is in 1Password (35brookroad > Employee > "Rounds Sparkle EdDSA key") and in the release secret `SPARKLE_ED_PRIVATE_KEY`; without it no installed copy can update.
- Sparkle removes the quarantine flag from the update, so an update needs no `xattr` step; only the first download does.
- `CFBundleVersion` and `CFBundleShortVersionString` are both the `VERSION` file; Sparkle compares `CFBundleVersion`.
- Checks: once a day by default (`SUEnableAutomaticChecks`), off with "Check for updates automatically" (General); Check for Updates… in the pill's right-click menu and the Settings sidebar. Sparkle's own window shows a new version and asks before it installs; it does not install by itself. Demo runs do not check.
- Not done: Sparkle's gentle reminders for background apps (a scheduled check that finds an update shows Sparkle's window at once).

## 6. Errors

| Failure | Response |
|---|---|
| Sessions folder missing | Banner with path. No groups. |
| Required key missing or decode fails | Read again on next event. If it still fails: leave out the session, banner "N sessions unreadable: Claude desktop format may have changed". Log file path and key. |
| Bad hook line | Ignore, log once. |
| `settings.json` invalid | No install. Show parse error. |
| No transcript | "No messages yet". |

Logs use `os.Logger`. They contain ids and paths only, never prompt or message text.

## 7. Testing

Swift Testing.

- `Classifier`: one case per rule in section 3, plus: permission during background tasks; stale `summarizes_uuid`; turn edge reconcile with interrupt marker, `end_turn`, and running entry; SSH; Claude not running; cron due in 10 min and in 30 min.
- Parsers: desktop JSON, transcript tail, hook lines. Fixtures copy the real structure with placeholder titles, paths and ids.
- `HookInstaller`: keeps an existing `rtk` hook; second install changes nothing; remove deletes only Rounds entries; refuses invalid JSON; detects wrong path.
- `rounds-hook`: 50 parallel runs give 50 complete lines.
- Manual acceptance on the real desktop app: permission prompt (`default` mode), `AskUserQuestion`, plan approval, `sleep 30`, background command, scheduled wakeup, Esc interrupt, quit Claude mid-turn, hotkey, recorder conflict, deep link opens the right session.

### 7.1 Demo mode and the README picture

The docs site explains the motivation, the mechanism and the words (Why Rounds, How It Works, Glossary, then Agents, Tickets, Install, Keys, Build and Release) and has no screenshots: the home page demo shows the app (decided 2026-10-30; 18 screenshots of every page went out of date at each change). The README shows one picture of the session window, and the frame checks (`scripts/check-frames.sh`) run demo scenes. A real picture would show real session titles and folders, so both use fixed placeholder data (`Sources/Rounds/Demo.swift`).

- `--demo`: fixed placeholder sessions in place of Claude, Codex and herdr, and every agent is on. They show each state (Needs input with a Permission detail, Failed, Working, Background with task lines, Ready (one of them seen), Finished, Stopped, Offline), a starred row, a parent with a direct and an isolated child, one PR and two PRs, and rows from Claude, Codex and pi. Demo mode reads no session, hook or settings file, and reads and writes no setting: `appDefaults` is a store that keeps nothing, and window frames are not saved.
- `--demo-scene <name>` opens one window after launch, with no key or pointer events: `window`, `window-quiet` (opens on Last Call with no session in Your Turn: the Another round? banner), `window-children` (parents unfolded), `window-turn` (the same, then after 2 s two sessions need the user), `window-slide` (the same, 0.1 s into the opening slide), `pill-ready` (only results wait: the green pill), `pill-failed` (a failure waits: the red pill), `settings` (the Settings window, through the app menu's Settings… item); `pill-running`, `pill-attention` (a session needs input, none failed) and `pill-failed` show only the pill. `--demo-appearance light|dark` sets the appearance.
- `scripts/screenshots.sh` (after `scripts/bundle.sh`) waits until the user is idle for 20 s, quits the installed app (the same global shortcut), runs the `window` scene in light, captures only its window (`screencapture -x -o -l`) to `website/public/screenshots/window-light.png`, and opens the installed app again.
