---
title: Sources
description: "The tools Rounds reads: Claude Code, Codex, pi agents on any model, and herdr."
---

A source is the tool that runs a session and reports its state. Rounds reads Claude Code, Codex and pi directly, and the agents that herdr runs. pi can run almost any model (Claude, GPT, Gemini, DeepSeek, Qwen, local models and more), so Rounds shows your sessions on all of them in one list. A source is On or Off. The session window shows only sessions of sources that are On.

| Source | On when | Off when |
| --- | --- | --- |
| Claude Code | Its hooks are installed. | Its hooks are not installed. |
| Codex | Its hooks are installed. | Its hooks are not installed. |
| pi | Its extension is installed. | Its extension is not installed. |
| herdr | herdr runs and Rounds is connected to it. | herdr does not run, or is not found. |

## Claude Code

Rounds reads the session files of the Claude desktop app, and the hook state that the hooks write. Open a session from Rounds with a click on its row. Claude must be allowed to open links.

## Codex

Rounds reads the Codex threads on this Mac, with hooks for live state. Codex has no link for a new thread, so Another round? only opens the Codex app.

## pi

Rounds shows each pi session on this Mac, in any terminal, on any model that pi runs: Claude, GPT, Gemini, DeepSeek, Qwen, local models and more. It reads the session files in `~/.pi/agent/sessions`. For live state, Rounds installs a small pi extension, `~/.pi/agent/extensions/rounds.ts`. The extension writes the state of each session (working, a dialog that waits for you, done, failed, stopped) to a local file. It writes no prompt and no model text. pi loads the extension when a session starts, so restart a pi that already runs.

A click on a pi row brings its terminal to the front. If pi no longer runs, Rounds resumes the session (`pi --session`) in a new tab of rootshell, or in a new terminal window. A forked pi session shows under the session it came from.

## herdr

Rounds shows each agent that runs in herdr (pi, Claude, droid and more), from your local herdr server, through herdr's socket. A click on an agent row brings its pane to the front. A pi session in herdr shows once, as the herdr agent; when herdr does not run, it shows as a pi session.

Rounds works best with [Henry Pi Harness](https://pi.henry.wang). One script installs pi, herdr and the harness, so the pi agents show in Rounds with their states.

To turn a source Off, click Remove Hooks or Remove Extension in Settings, on the Sources page.
