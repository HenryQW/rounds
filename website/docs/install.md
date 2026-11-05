---
title: Install
description: Install Rounds with one line in Terminal, with Homebrew or from the disk image on macOS 27, open it the first time, and connect Claude Code, Codex and pi with hooks.
---

## Requirements

- macOS 27 on a Mac with Apple silicon.
- At least one agent: Claude Code in the Claude desktop app (the Code tab), Codex, pi, or herdr. Rounds does not read Claude Code sessions started in a terminal, except inside herdr.

## Install with one line

Open Terminal (press ⌘ Space, type Terminal, press Return), paste this line and press Return:

```sh
curl -fsSL https://rounds.henry.wang/install.sh | sh
```

The script downloads the latest release, checks that the release certificate signed it, copies Rounds to `/Applications` and opens it. macOS does not block a copy that `curl` downloads, so you need no other step. Read the script first at [install.sh](/install.sh) if you like.

## Download

Download [Rounds.dmg](https://github.com/HenryQW/rounds/releases/latest/download/Rounds.dmg), the latest release. Open it and drag Rounds to Applications, then do the step in [Open Rounds the first time](#open-rounds-the-first-time). Each release, with its notes, is on the [releases page](https://github.com/HenryQW/rounds/releases).

## Homebrew

```sh
brew trust --tap henryqw/tap && brew install --cask henryqw/tap/rounds
```

Homebrew loads a cask from a tap that is not official only after you trust the tap. The first part of the command does that. The cask removes the quarantine flag, so Rounds opens at once.

## Updates

Rounds looks for a new version once a day and asks before it installs one. To look now, right-click the pill and choose Check for Updates…. To stop the daily check, turn off "Check for updates automatically" in Settings > General.

Rounds 0.1.1 and earlier cannot update themselves: download the next release, or run `brew upgrade --cask rounds`, one time.

## Build from source

See [Build from source](/build).

## Open Rounds the first time

This step is only for a copy from the disk image. Rounds has no Developer ID signature and Apple does not notarize it. So macOS says "Rounds is damaged and can't be opened" at the first launch. Rounds is not damaged: the browser added a quarantine flag, and macOS does not trust the Rounds certificate. Click Cancel, not Move to Trash.

In Terminal, remove the quarantine flag and open Rounds:

```sh
xattr -dr com.apple.quarantine /Applications/Rounds.app && open /Applications/Rounds.app
```

The disk image has the same steps in "Read me if Rounds is damaged.txt". The one-line install, Homebrew, a build from source and an update from Rounds itself need no step.

## First launch

Open Rounds from `/Applications`. A pill shows at the right edge of your screen. Rounds has no Dock icon and no menu bar item.

## Install the hooks

A hook is a command that Claude Code or Codex runs at each turn event. Rounds needs hooks to know the live state of those sessions.

1. Right-click the pill and choose Settings, or press ⌘, in the session window.
2. Open the Agents page.
3. Click Install… in the Claude Code row and in the Codex row.
4. Check the entries in the preview, then confirm.

Rounds keeps a backup of each file it changes. herdr needs no hooks. Rounds connects to it while it runs.

## Install the pi extension

pi has no hooks. Rounds gets the live state of pi sessions from a small pi extension.

1. On the Agents page, click Install… in the pi row.
2. Check the preview, then confirm. Rounds copies `rounds.ts` to `~/.pi/agent/extensions`.
3. Restart the pi sessions that run. pi loads the extension when a session starts.

## After a rename or a move

If the Claude Code or Codex row says "Needs repair", the hook command points to a path that is not valid now. Open the status menu of that row and choose Repair Hooks.
