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

Approvals, models for Barbacks and the place of decision records come from your own rules (`CLAUDE.md`). The plugin adds no approval rules of its own.

## Band
A Bouncer session shows a band above the prompt: each Bartender with its status code, ticket and repo, the number of questions that wait on you, and the queue length. A Bartender with `!` waits on you. The band appears once the session loads the `bouncer` skill or sets a Bouncer title, and only in that session. It learns the pool from the Bouncer's own `set_session_title` and `archive_session` calls, so a Bartender renamed elsewhere shows its old title until the Bouncer renames it again.

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
