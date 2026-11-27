# Bouncer plugin

Bouncer mode for the Code tab of the Claude desktop app. You talk to one session, the Bouncer. It routes ticket work to a Bartender: a linked Code session in its own worktree, one ticket at a time. A Bartender runs bounded parts of its ticket in Barbacks (Agent subagents with worktree isolation). Rounds shows each Bartender as a subagent of its Bouncer ([spec 2.1](../../docs/spec.md#21-desktop-session-files-read-only)). The names are in [GLOSSARY.md](../../GLOSSARY.md#bouncer-mode-roles).

## Install

```
/plugin marketplace add HenryQW/rounds
/plugin install bouncer@rounds
```

Start a new session that you open yourself, then say "bouncer mode" or run `/bouncer:bouncer`.

## Configure

| Option | Default | What it does |
|---|---|---|
| `status_codes` | `Backlog=Bklog; Todo=Todo; In Progress=Dev; In Review=CR; In QA=QA; Done=Done; Canceled=Cxl; Duplicate=Dup; Open=Open; Closed=Done` | Maps each tracker status to the short code in a Bartender title, for example `🍸 [ABC-123] [Dev] Fix the login loop`. Use `Name=Code` pairs with `;` between them. |
| `records_dir` | blank | The folder of the ticket records, for example `~/.tickets`. Blank: `tickets/` in the plugin data folder. |
| `bartender_skill` | blank | A skill with your own routing and gates, for example post-merge checks and approvals. The Bouncer loads it, and each Ticket Bartender brief starts with a line to load it. |
| `ticket_effort` | `medium` | The effort of a Code or Spike Ticket Bartender. |

Set it with `/plugin configure bouncer@rounds`, then start a new session.

The plugin manifest defines the defaults. The title, assignment and ledger scripts use `bouncer_config.py` to read stored options and manifest defaults. The band gets its options from Claude Code.

Models for Barbacks and the place of decision records come from your own rules (`CLAUDE.md`).

## On-call triage

Send `oncall ticket <KEY>, triage now` to the Bouncer. Set `bartender_skill` to a skill that handles this prompt. The Bouncer runs triage in its own session and requests each approval there.

## Questions and approvals
The Bouncer asks you only before an outward action (a message other people read, a push, PR or merge, a delete that cannot be undone, money or access) or when no rule or default covers a choice. Your own rules can add actions. It does reversible steps, such as starting a Bartender or a spike, with no question and reports them in one line.

- **One yes for each Bartender ticket.** At routing, the Bouncer asks once for the ticket's closing chain, for example `push, pr, merge`. A request that already says it ("fix it and merge") is the yes. The grant is a line in `grants.md`. The chain stops and asks again when a check fails, the scope changes, an action is outside the grant, or an approved text changed.
- **The Bouncer runs outward actions.** Bartenders only prepare them: a committed branch, and the PR text and comment drafts in the ticket record. Auto mode refuses an approval that one session relays to another, so the session where you said yes runs the push, the PR, the merge and the comment.
- **Decisions are kept.** The Bouncer records each of your decisions in `memory.md` (one short line) and in a domain file under `decisions/` (the decision and why). It reads the memory in each new session, and a domain file only when it needs the reason. When a request, a Bartender or a ticket conflicts with a recorded decision, it asks you to keep or replace that decision. It does not pick one itself. The plugin also attaches the memory to the first prompt of each Bouncer session, so a cleared or restarted Bouncer has it at once. The Bouncer closes a question only with the id of the decision that records your answer, or with `--none` for a one-off answer.
- **"What should I work on"** names only tickets that can be worked now, and lists the others with a one-line reason (blocked, waiting for a release or another ticket).
- If a hook rewrites Bash commands (rtk runs `git push` as `rtk git push`), an allow rule must name the rewritten form.

## Band
A Bouncer session shows a band above the prompt. The band is always one line: the Bartenders that fit, each one pill (its traffic-light dot (🔴 needs you, 🟡 a turn runs, ⚪ no turn runs but it still holds its ticket, 🟢 idle and free; the mapping is in the skill's "Band" section), its key, the status chip and the PR (linked to GitHub)), then `+N` for the rest. A click on a pill's dot and key opens that Bartender's session in split view. When the pills do not all fit, they drop their PR links first, so more of them show; at the right end `N waits on you` and `N to act` in red (each only above zero) and Open Pane. Open Pane, `+N` and `N to act` open the Bouncer pane beside the chat (or bring it to the front); where the pane cannot show yet, a toast says why. The pane, in Linear's design tokens (dark or light, as the system appearance): a header row (**Bouncer**, the repo; on the right `Queue N`; each card shows its own dot), a red row with the oldest waiting question (click opens that Bartender), the `N to act` list, then `Bartenders N` and one card a Bartender, two a row, all of equal width. Each active Bartender has a card. Row 1 is its dot and session title, such as `🟡 Fix the login loop`, one button that opens that Bartender's session, and `⋯`. Row 2 holds the facts in quiet text: `MIDI-123` linked to Linear, the status chip and `28m` at the right end. Row 3 has every open PR of the ticket, each linked to GitHub in its state colour with its base while open (`⑂ #17860 → dev  ⑂ #17863 → staging`). Row 4 is the ledger's next step (never a merged or closed PR's), or the last RESULT or wait reason, else nothing. All idle ones share one `🟢 N idle` card; every Bartender has a card. A click on a card's dot and session title opens that Bartender's session in split view (the key stays the Linear link). A click on a card's `⋯` shows Status, Stop and Reset on one row under its next step, as three buttons of equal width; Reset is red, and Stop and Reset send only after a second click on `Confirm Stop?` or `Confirm Reset?` (Cancel, or 5 seconds with no click, goes back). The band appears once the session loads the `bouncer` skill or sets a Bouncer title, and only in that session. It learns the pool from the Bouncer's linked sessions (`list_sessions`: titles, last activity, PRs, whether a turn runs) and from the Bouncer's own `start_session`, `set_session_title` and `archive_session` calls. It reads the queue, the questions and the ledger again at session start and after each of the Bouncer's turns. `N to act` counts only the ledger items that are due (`bouncer-ledger due`, run once a turn); a click lists each one under the header as its key (a link to the PR or the Linear issue), its next step and Ask Bouncer. An open item that is not due shows only as its card's next step.

The band also lets you act:
- In the pane, a click on a card's `⋯` opens its menu: Status, Stop and Reset send the Bouncer a prompt such as `ABC-123: stop` (Stop and Reset after `Confirm Stop?` or `Confirm Reset?`). On the idle card, each session has its own menu row, each action names one session (`Reset 01585d74`) and the prompt names its session id (`local_…: reset`). The band never talks to a Bartender.
- With the `linear_workspace_url` plugin option set (for example `https://linear.app/<workspace>`), a ticket key is a link to its Linear issue.
- The band sends one prompt at a time: none while a question waits on you or while the Bouncer works. Open still works then.
- When the number of questions that wait on you goes up, you get a notification. The plugin sets the `!` and the count itself from `questions.md`, and each Bartender's status code from its turn-end report.
- The pane's `N to act` list shows the ledger items that are due (`bouncer-ledger due`), one row each: the key, linked to the PR or the Linear issue, its next step and Ask Bouncer. Open items that are not due show as their card's next step.
- Questions block in order. The red row in the pane shows only the oldest question (the head of `questions.md` in the plugin data folder); click it to open that Bartender. The next one shows after you answer it. The head row of the pane's Undecided list has Pick and Default buttons: a click sends that answer to the Bouncer, as if you typed it. Other Bartenders that wait keep their 🔴 dot. The click shows that Bartender's conversation in split view beside the Bouncer; if the app refuses, the band asks the Bouncer to open it. You still answer the Bouncer.
- In the pane, click `Queue N` to list the queued tickets, one line each (`KEY · repo · mode`). Pop and Remove send the Bouncer `queue: pop` or `queue: remove ABC-123`; the Bouncer runs `bouncer-queue`.

- One Bouncer a repo: a Bouncer runs in a repo's main checkout and routes only that repo; Bouncers of other repos run beside it. Its title is `🚪 Bouncer <repo>`. The first Bouncer of a repo claims `<repo>/bouncer` in the plugin data folder and frees it when its session ends. The band of a second Bouncer of the same repo shows only "another session is the Bouncer of <repo>" and Take Over.

## Data
The plugin keeps its state in the data folder that Claude Code gives it: `~/.claude/plugins/data/bouncer-rounds/` (`bouncer-inline` for a `--plugin-dir` checkout). `skills/bouncer/scripts/bouncer-data` prints the path.

| File | Holds |
|---|---|
| `<repo>/queue.md` | One Bouncer's tickets above the Bartender cap, one line each |
| `<repo>/questions.md` | One Bouncer's questions that wait on you, one line each, oldest first |
| `grants.md` | Your one yes for each ticket's closing chain, one line each |
| `memory.md` | The decision memory, read whole in each new session: one short line a decision (`D<n> \| date \| scope \| domain \| decision`). The Bouncer adds each decision of yours and each default that a later session must follow, and asks you when new information conflicts with a decision. The decisions in force have a cap of 8000 characters, so the whole list fits in context; a replaced decision stays as history, marked `superseded by`, and does not count |
| `decisions/<domain>.md` | One record a decision of that domain: the decision, why, and the source (your words or the default's reason). Read only on demand |
| `decisions/INDEX.md` | The router: one line a domain, with what it covers, its active count and its file, so the Bouncer opens only the domain it needs |
| `decision-table.md` | Rows that the Bouncer adds to its decision table when you answer a question that no row covered |
| `tickets/<TICKET>.md` | Ticket records, unless the `records_dir` option names another folder. Each record's `LEDGER` section holds its work to revisit (an open PR, a held message, a follow-up, a staging check); `bouncer-ledger due` lists what is due |

The pool is in the session titles, so it needs no file. Every Bouncer sees the same folder; the queue and the questions are per repo, in `<repo>/`. The first run of 0.10.4 moves an older `queue.md` and `questions.md` into the first Bouncer's repo folder, once. Plugin updates keep the folder. `claude plugin uninstall bouncer@rounds` deletes it unless you add `--keep-data`.

## Token use
Each model call of the Bouncer reads its whole context again, so a call costs more than the text it writes. The plugin does in a script each step that needs no judgment, and one script covers one event:

| Event | One call | It prints |
|---|---|---|
| Bouncer start, and after a clear | `bouncer-start` | The preflight checks, the decisions, the due and stale ledger items, the questions, the queue, the grants and the context size |
| Before an assigned Bartender ends its turn | `bouncer-report --stop` | One correction request if the report has the wrong fields, ticket, status or length |
| A Bartender's turn-end note | `bouncer-note` | The report (from the Bartender's last answer when the note's 400 characters lost it), the acceptance check, the grant, the record's drafts and open ledger items |
| An assignment | `bouncer-assign` | The title, the model, the effort and the filled brief |

The plugin hook runs `bouncer-note` on a turn-end note and attaches the result to the prompt, so the Bouncer spends no call on it. In the same way it attaches the due ledger items when they change, and one line when the Bouncer's context is past 150K and no Bartender works (`bouncer-session context`); the Bouncer then clears itself.

## Known limits

- The Bouncer must be a session that you open, in the main checkout of the repo it routes. Do not move it with `change_directory`: hook paths stay on the old folder and Bash breaks. `bouncer-preflight` checks the folder, the hook paths, the plugin version and the `clear_session` allow rule. With Remote Control on, a session that another session started cannot start Bartenders. A request for another repo goes to that repo's Bouncer.
- Never detach a Bartender: its reports then do not reach the Bouncer.
- `bouncer-session` reads the Claude desktop app's session files (`~/Library/Application Support/Claude/claude-code-sessions`, macOS) and the transcripts in `~/.claude/projects`. If the app changes them, `bouncer-note` prints `report: none` for a note that lost its report, and the Bouncer checks the evidence itself.
- Outside `bypassPermissions` mode, the app asks you before each Bartender reset (`clear_session`) and before a model or effort above the Bouncer's own.

## Develop and test

1. Add your checkout as a local marketplace and install from it. Claude Code then reads the plugin from your folder, so edits apply with no copy and no version change:
   ```
   claude plugin marketplace add <path to your Rounds checkout>
   claude plugin install bouncer@rounds
   ```
2. After each change, run the fixture test and the validator from the checkout. The test needs `python3`, `jq` and `git`. It uses no network.
   ```
   bash plugins/bouncer/skills/bouncer/scripts/tests/bouncer.sh
   claude plugin test plugins/bouncer
   claude plugin validate plugins/bouncer
   ```
3. Open a new session to try a change to `SKILL.md` or `references/`. The Bouncer reads a file in `references/` only when the router table in `SKILL.md` names its trigger. A running session keeps the skill text that it loaded first. A script change applies at once.
4. For a full run, open the Bouncer session yourself and point it at a test repo, so that the Bartender branches go there. Start it with `/bouncer:bouncer`, so that no other skill with Bouncer text answers instead.
5. To test the option, set it, then open a new session:
   ```
   echo '{"status_codes":"Todo=Todo; Doing=Dev"}' | claude plugin configure bouncer@rounds --values-stdin
   ```
   While the option is unset, Claude Code shows `${user_config.status_codes}` as plain text in the skill, so `bouncer-title` reads the default from `.claude-plugin/plugin.json`.
6. To remove the local install:
   ```
   claude plugin uninstall bouncer@rounds
   claude plugin marketplace remove rounds
   ```
