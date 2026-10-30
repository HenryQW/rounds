---
title: Sources
description: "The tools Rounds reads: Claude Code, Codex and herdr."
---

A source is the tool that runs a session and reports its state. Rounds reads three sources directly: Claude Code, Codex and herdr. Other agents, such as pi, show through herdr, with each model that the agent uses. A source is On or Off. The session window shows only sessions of sources that are On.

| Source | On when | Off when |
| --- | --- | --- |
| Claude Code | Its hooks are installed. | Its hooks are not installed. |
| Codex | Its hooks are installed. | Its hooks are not installed. |
| herdr | herdr runs and Rounds is connected to it. | herdr does not run, or is not found. |

## Claude Code

Rounds reads the session files of the Claude desktop app, and the hook state that the hooks write. Open a session from Rounds with a click on its row. Claude must be allowed to open links.

## Codex

Rounds reads the Codex threads on this Mac, with hooks for live state. Codex has no link for a new thread, so Another round? only opens the Codex app.

## herdr

Rounds reads the agents that your local herdr server runs, such as pi, through herdr's socket. A click on an agent row brings its pane to the front.

Rounds works best with [Henry Pi Harness](https://pi.henry.wang). One script installs pi, herdr and the harness, so the pi agents show in Rounds with their states.

To turn a source Off, click Remove Hooks in Settings, on the Sources page.
