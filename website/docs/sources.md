---
title: Sources
description: "The tools Rounds reads: Claude Code, Codex, and pi agents on any model through herdr."
---

A source is the tool that runs a session and reports its state. Rounds reads Claude Code and Codex directly, and pi agents through herdr. pi can run almost any model (Claude, GPT, Gemini, DeepSeek, Qwen, local models and more), so Rounds shows your sessions on all of them in one list. A source is On or Off. The session window shows only sessions of sources that are On.

| Source | On when | Off when |
| --- | --- | --- |
| Claude Code | Its hooks are installed. | Its hooks are not installed. |
| Codex | Its hooks are installed. | Its hooks are not installed. |
| herdr | herdr runs and Rounds is connected to it. | herdr does not run, or is not found. |

## Claude Code

Rounds reads the session files of the Claude desktop app, and the hook state that the hooks write. Open a session from Rounds with a click on its row. Claude must be allowed to open links.

## Codex

Rounds reads the Codex threads on this Mac, with hooks for live state. Codex has no link for a new thread, so Another round? only opens the Codex app.

## pi agents (through herdr)

Rounds shows each pi agent that runs in herdr, on any model that pi runs: Claude, GPT, Gemini, DeepSeek, Qwen, local models and more. Rounds reads them from your local herdr server, through herdr's socket, so pi must run in herdr; a pi session outside herdr does not show. herdr's other agents show too. A click on an agent row brings its pane to the front. In Settings and in the window, this source is named herdr.

Rounds works best with [Henry Pi Harness](https://pi.henry.wang). One script installs pi, herdr and the harness, so the pi agents show in Rounds with their states.

To turn a source Off, click Remove Hooks in Settings, on the Sources page.
