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

## Known limits

- The Bouncer must be a session that you open. With Remote Control on, a session that another session started cannot start Bartenders.
- Never detach a Bartender: its reports then do not reach the Bouncer.
- Outside `bypassPermissions` mode, the app asks you before each Bartender reset (`clear_session`) and before a model or effort above the Bouncer's own.

## Test

```
bash plugins/bouncer/skills/bouncer/scripts/tests/bouncer.sh
```

The test needs `python3`, `jq` and `git`. It uses no network.
