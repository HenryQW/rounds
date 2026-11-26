# Bouncer plugin

Bouncer mode for the Code tab of the Claude desktop app. You talk to one session, the Bouncer. It routes each ticket to a Bartender: a linked Code session in its own worktree, one ticket at a time. A Bartender runs bounded parts of its ticket in Barbacks (Agent subagents with worktree isolation). Rounds shows each Bartender as a subagent of its Bouncer ([spec 2.1](../../docs/spec.md#21-desktop-session-files-read-only)). The names are in [GLOSSARY.md](../../GLOSSARY.md#bouncer-mode-roles).

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

Set it with `/plugin configure bouncer@rounds`, then start a new session.

Models for Barbacks and the place of decision records come from your own rules (`CLAUDE.md`).

## Questions and approvals
The Bouncer asks you only before an outward action (a message other people read, a push, PR or merge, a delete that cannot be undone, money or access) or when no rule or default covers a choice. Your own rules can add actions. It does reversible steps, such as starting a Bartender or a spike, with no question and reports them in one line.

- **One yes for each ticket.** At routing, the Bouncer asks once for the ticket's closing chain, for example `push, pr, merge`. A request that already says it ("fix it and merge") is the yes. The grant is a line in `grants.md`. The chain stops and asks again when a check fails, the scope changes, an action is outside the grant, or an approved text changed.
- **The Bouncer runs outward actions.** Bartenders only prepare them: a committed branch, and the PR text and comment drafts in the ticket record. Auto mode refuses an approval that one session relays to another, so the session where you said yes runs the push, the PR, the merge and the comment.
- **"What should I work on"** names only tickets that can be worked now, and lists the others with a one-line reason (blocked, waiting for a release or another ticket).
- If a hook rewrites Bash commands (rtk runs `git push` as `rtk git push`), an allow rule must name the rewritten form.

## Band
A Bouncer session shows a band above the prompt. Compact, the default, is one row with every Bartender inline (it wraps only when the window is narrow): its traffic-light dot (🔴 needs you, 🟡 a turn runs, 🟢 no turn runs; the mapping is in the skill's "Band" section), its key (linked to Linear), the status chip and the PR (linked to GitHub); at the right end `N waits on you` and `N to act` in red (each only above zero) and Details. Details uses the layout of ponytail's band: a header row (dots, **Bouncer**, the repo; on the right `Queue N`, `N to act` and Compact), a red row with the oldest waiting question (click opens that Bartender), then one card a Bartender in Linear's design tokens, all of equal width (dark or light, as the system appearance); the terminal shows a rule and columns split by `│`. Each active Bartender has a card in two rows, as a Rounds session row (`🟡 MIDI-123` linked to Linear, the status chip, `⑂ #17860 +1` linked to GitHub, `28m`, `⋯`; then the ledger's next step or the last RESULT or wait reason); all idle ones share one `🟢 N idle` column; past 4 columns the rest show as `+N`. A click on a card's `⋯` shows Status, Stop and Reset in place of its sub-line. The band keeps your choice across sessions. The band appears once the session loads the `bouncer` skill or sets a Bouncer title, and only in that session. It learns the pool from the Bouncer's linked sessions (`list_sessions`: titles, last activity, PRs, whether a turn runs) and from the Bouncer's own `start_session`, `set_session_title` and `archive_session` calls. It reads the queue, the questions and the ledger again at session start and after each of the Bouncer's turns. `N to act` counts only the ledger items that are due (`bouncer-ledger due`, run once a turn); a click lists each one as its key (a link to the PR or the Linear issue) and its next step. An open item that is not due shows only as its card's next step.

The band also lets you act:
- A click on a chip opens its action row: Status, Stop and Reset send the Bouncer a prompt such as `ABC-123: stop`. On the idle chip, each action names one session (`Reset 01585d74`) and the prompt names its session id (`local_…: reset`). The band never talks to a Bartender.
- With the `linear_workspace_url` plugin option set (for example `https://linear.app/<workspace>`), the action row of a chip with a ticket key has Open in Linear.
- The band sends one prompt at a time: none while a question waits on you or while the Bouncer works. Open still works then.
- When the number of questions that wait on you goes up, you get a notification. The plugin sets the `!` and the count itself from `questions.md`, and each Bartender's status code from its turn-end report.
- Click `⏰ N open` to list the open items in the records' `LEDGER` sections, one line each (`KEY · kind · next`).
- Questions block in order. The red pill shows only the oldest question (the head of `questions.md` in the plugin data folder); click it to open that Bartender. The next one shows after you answer it. Other Bartenders that wait keep their 🔴 dot. The click shows that Bartender's conversation in split view beside the Bouncer; if the app refuses, the band asks the Bouncer to open it. You still answer the Bouncer.
- Click `📥 N queued` to list the queued tickets, one line each (`KEY · repo · mode`). Pop and Remove send the Bouncer `queue: pop` or `queue: remove ABC-123`; the Bouncer runs `bouncer-queue`.

- One Bouncer a repo: a Bouncer runs in a repo's main checkout and routes only that repo; Bouncers of other repos run beside it. Its title is `🚪 Bouncer <repo>`. The first Bouncer of a repo claims `<repo>/bouncer` in the plugin data folder and frees it when its session ends. The band of a second Bouncer of the same repo shows only "another session is the Bouncer of <repo>" and Take Over.

## Data
The plugin keeps its state in the data folder that Claude Code gives it: `~/.claude/plugins/data/bouncer-rounds/` (`bouncer-inline` for a `--plugin-dir` checkout). `skills/bouncer/scripts/bouncer-data` prints the path.

| File | Holds |
|---|---|
| `<repo>/queue.md` | One Bouncer's tickets above the Bartender cap, one line each |
| `<repo>/questions.md` | One Bouncer's questions that wait on you, one line each, oldest first |
| `grants.md` | Your one yes for each ticket's closing chain, one line each |
| `decision-table.md` | Rows that the Bouncer adds to its decision table when you answer a question that no row covered |
| `tickets/<TICKET>.md` | Ticket records, unless the `records_dir` option names another folder. Each record's `LEDGER` section holds its work to revisit (an open PR, a held message, a follow-up, a staging check); `bouncer-ledger due` lists what is due |

The pool is in the session titles, so it needs no file. Every Bouncer sees the same folder; the queue and the questions are per repo, in `<repo>/`. The first run of 0.10.4 moves an older `queue.md` and `questions.md` into the first Bouncer's repo folder, once. Plugin updates keep the folder. `claude plugin uninstall bouncer@rounds` deletes it unless you add `--keep-data`.

## Known limits

- The Bouncer must be a session that you open, in the main checkout of the repo it routes. Do not move it with `change_directory`: hook paths stay on the old folder and Bash breaks. `bouncer-preflight` checks the folder, the hook paths, the plugin version and the `clear_session` allow rule. With Remote Control on, a session that another session started cannot start Bartenders. A request for another repo goes to that repo's Bouncer.
- Never detach a Bartender: its reports then do not reach the Bouncer.
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
   claude plugin validate plugins/bouncer
   ```
3. Open a new session to try a change to `SKILL.md`. A running session keeps the skill text that it loaded first. A script change applies at once.
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
