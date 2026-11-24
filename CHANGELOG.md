# Changelog

The release notes of each version: the release page and Sparkle's update window show its section. Write one short
line for each change a user can see, in words a user knows, grouped under Breaking changes, Features and Fixes. Put
the commits of one feature on one line. Leave out commits that undo each other, fixes to work that was not released,
and changes only to code, tests, docs or the build.

## 0.1.5

### Features

- A history page in Settings that shows how long agents waited for you.
- A mark on sessions that a scheduled task started.
- A "Why This State" view on a row that shows why the row has its state. You can save a report when the state is wrong.
- The hover card lists every item, scrolls a long list, and shows each item's state symbol.
- A click on a mark with several items opens the hover card.
- Pi `acp_delegate` runs show as subagents.

### Fixes

- A herdr turn keeps its time after you open it.
- Hover hints show after 0.5 s.
- The hover card stays on the screen when its size is not ready.
- A Claude session that ended before Claude Code started no longer shows as unreadable.
- A herdr check stops waiting for an answer after 5 s.

## 0.1.4

### Features

- Push notifications to Telegram and Bark when you are away from your Mac.
- Sounds on your Mac when a session needs you, fails or is ready.
- A beta update channel, and automatic install of updates.
- Install with one command.

### Fixes

- A click on a herdr session opens the terminal tab that runs herdr, also after rootshell restarts.
- A session that only passes on a question from a side session no longer waits for you.
