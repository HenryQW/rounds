---
name: watching-window-frames
description: Use when the Rounds session window changes size by itself (it jumps, shrinks and grows back, flickers, or resizes in a loop), when the user reports "the window size is wrong again", or after a change to the window fit, the list layout, the filter bar or any row height.
---

# Watching window frames

REQUIRED BACKGROUND: `window-resizes.md` in the `macos-app` skill (method, flags, fixes).

The session window fits its content height (spec 5.7). Each size change is in the debug log `com.henryqw.rounds`, category `frame`. Run the watch with `bash scripts/watch-frames.sh 10m` (Rounds' copy has the subsystem built in).

## Log lines

| Line | Written by | Means |
|---|---|---|
| `content A -> B rows= yourTurn= filter= query=` | PanelView `onScrollGeometryChange` | SwiftUI's content height changed, with the visible row count, the Your Turn count (0 under Last Call shows the Another round? banner in the list), the filter and the search length |
| `fit h=A -> B sliding=…` | `EdgeDrawer.fit()` | the fit asks for height B |
| `slideIn h=A -> B visible=…` | `EdgeDrawer.slideIn` | the slide asks for height B |
| `resized h=… live=…` | `PanelController.windowDidResize` | the window really changed size; `live=true` is a resize by hand |

## Steps

Run `scripts/bundle.sh --install`, then `pkill -x Rounds; open /Applications/Rounds.app`, then follow the Steps of the background skill.

## Demo check (no user needed)

`scripts/check-frames.sh [scene]` runs one demo scene under the watch and exits 1 when a flag is on a `resized` line (a fault the user sees). It waits until the user is idle for 10 s, quits the installed app for the run (they share the global shortcut) and opens it again. Run `scripts/bundle.sh` first. Scenes: `window-turn` (default: opens on Last Call; after 2 s sessions come into Your Turn and the Another round? banner goes), `window-slide` (the same, 0.1 s into the opening slide), `window`, `window-children`, `window-quiet`.

Trap: the demo window takes keyboard focus with its search field active. If the user types while it shows, the keys filter the list, and the watch shows a false `FLIP`. A check that is red once and then green with the idle check was this.

## Causes found so far

- First opening after launch grew in three steps (`slideIn ... content=0`, then `top=` and `bottom=` arrive): the window was made at the first hover, so SwiftUI had not laid out the bars. Fixed by `PanelController.prepare()` at launch.
- A slide started again with no height change (`RESTART`): a fit (the pill's alert state changed) or a second hover on the fading pill aimed the slide again, and a fractional height (736.5 against AppKit's 737) never compared equal. Fixed in `EdgeDrawer.slideIn`: a slide on its way to the same size goes on; the fitted height is rounded. Later a click 0.9 s after the hover, when the slide had ended, started it again: an open window of the same size now always stays. The demo cannot trigger it (its height changes in the same turn), so check it with the watch on the real app.
- A session coming into Your Turn resized twice (`TWICE`): the list got the new rows one pass before the bars above it lost the banner (the banner was in the filter bar until 2026-10-30). Fixed by `EdgeDrawer.fitSoon()`, one fit per main-loop turn.
