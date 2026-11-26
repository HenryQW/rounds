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
| `status_codes` | `Backlog=Bklog; Todo=Todo; In Progress=Dev; In Review=CR; Done=Done; Canceled=Cxl; Duplicate=Dup; Open=Open; Closed=Done` | Maps each tracker status to the short code in a Bartender title, for example `[Dev] ABC-123 - Bartender - my-repo`. Use `Name=Code` pairs with `;` between them. |

Set it with `/plugin configure bouncer@rounds`, then start a new session.

Models for Barbacks and the place of decision records come from your own rules (`CLAUDE.md`).

## Questions and approvals
The Bouncer asks you only before an outward action (a message other people read, a push, PR or merge, a delete that cannot be undone, money or access) or when no rule or default covers a choice. Your own rules can add actions. It does reversible steps, such as starting a Bartender or a spike, with no question and reports them in one line.

- **One yes for each ticket.** At routing, the Bouncer asks once for the ticket's closing chain, for example `push, pr, merge`. A request that already says it ("fix it and merge") is the yes. The grant is a line in `grants.md`. The chain stops and asks again when a check fails, the scope changes, an action is outside the grant, or an approved text changed.
- **The Bouncer runs outward actions.** Bartenders only prepare them: a committed branch, and the PR text and comment drafts in the ticket record. Auto mode refuses an approval that one session relays to another, so the session where you said yes runs the push, the PR, the merge and the comment.
- **"What should I work on"** names only tickets that can be worked now, and lists the others with a one-line reason (blocked, waiting for a release or another ticket).
- If a hook rewrites Bash commands (rtk runs `git push` as `rtk git push`), an allow rule must name the rewritten form.

## Band
A Bouncer session shows a band above the prompt: each Bartender with its status code, ticket and repo, the number of questions that wait on you, and the queue length. A Bartender with `!` waits on you. The band appears once the session loads the `bouncer` skill or sets a Bouncer title, and only in that session. It learns the pool from the Bouncer's own `start_session`, `set_session_title` and `archive_session` calls, so a Bartender renamed elsewhere shows its old title until the Bouncer renames it again.

The band also lets you act:
- A ticket key opens the ticket in Linear when you set the `linear_workspace_url` plugin option (for example `https://linear.app/<workspace>`). Unset, keys are plain text.
- The menu on each Bartender (Status, Stop, Reset) sends the Bouncer a prompt such as `ABC-123: stop`. The band never talks to a Bartender.
- The band sends one prompt at a time: none while a question waits on you or while the Bouncer works. Open still works then.
- When the number of questions that wait on you goes up, you get a notification.
- A Bartender that waits on you (`!`) shows its question under the band, from `questions.md` in the plugin data folder. Open shows that Bartender's conversation in split view beside the Bouncer; if the app refuses, the band asks the Bouncer to open it. You still answer the Bouncer.
- Click the queue length to show the queued tickets. Pop and Remove send the Bouncer `queue: pop` or `queue: remove ABC-123`; the Bouncer runs `bouncer-queue`.

## Data
The plugin keeps its state in the data folder that Claude Code gives it: `~/.claude/plugins/data/bouncer-rounds/` (`bouncer-inline` for a `--plugin-dir` checkout). `skills/bouncer/scripts/bouncer-data` prints the path.

| File | Holds |
|---|---|
| `queue.md` | Tickets above the Bartender cap, one line each |
| `questions.md` | Bartender questions that wait on you, one line each |
| `grants.md` | Your one yes for each ticket's closing chain, one line each |
| `tickets/<TICKET>.md` | Ticket records, unless your rules name another place |

The pool is in the session titles, so it needs no file. Every Bouncer session sees the same folder, whatever folder it runs in. Plugin updates keep the folder. `claude plugin uninstall bouncer@rounds` deletes it unless you add `--keep-data`.

## Known limits

- The Bouncer must be a session that you open. With Remote Control on, a session that another session started cannot start Bartenders.
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
