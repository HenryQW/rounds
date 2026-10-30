---
name: watching-window-frames
description: Use when the Rounds session window changes size by itself (it jumps, shrinks and grows back, flickers, or resizes in a loop), when the user reports "the window size is wrong again", or after a change to the window fit, the list layout, the filter bar or any row height.
---

# Watching window frames

The session window fits its content height (spec 5.7). Each size change is in the debug log `com.henryqw.rounds`, category `frame`. `scripts/watch-frames.sh` streams that log and flags abnormal changes while they happen. Debug messages are not saved to disk, so `log show` cannot find them later: the watch must run while the problem happens.

## Log lines

| Line | Written by | Means |
|---|---|---|
| `content A -> B rows= yourTurn= filter= query=` | PanelView `onScrollGeometryChange` | SwiftUI's content height changed, with the visible row count, the Your Turn count (0 under Last Call shows the Another round? banner in the list), the filter and the search length |
| `fit h=A -> B sliding=…` | `EdgeDrawer.fit()` | the fit asks for height B |
| `slideIn h=A -> B visible=…` | `EdgeDrawer.slideIn` | the slide asks for height B |
| `resized h=… live=…` | `PanelController.windowDidResize` | the window really changed size; `live=true` is a resize by hand |

## Flags

- `FLIP A <-> B`: the content height went A, B, A in 5 s. SwiftUI layout swings between two states; find what changes the content (a row, a banner, a filter, a focus state) between the two lines.
- `BOUNCE A -> B -> C`: the content went down then up (or up then down), 20 pt or more each, in 1 s. One layout step showed a wrong height; compare `rows=` and `yourTurn=` on the two lines.
- `FOREIGN h=…`: a size that no fit or slide asked for (1 pt tolerance). Something else resized the window: a `minSize` or content minimum, the frame autosave, or SwiftUI's own window sizing.
- `TWICE in n ms`: one change resized the window twice, which the user sees as a jump. This is the flag to fix first.
- `RESTART`: the slide started again on an open window with no height change, which can make it stutter.
- `BURST n resizes in 1 s`: the fit and AppKit fight. Once this came from a content minimum higher than the fit's minimum (fixed by one `EdgeDrawer.minHeight`).

## Steps

1. `scripts/bundle.sh --install`, then `pkill -x Rounds; open /Applications/Rounds.app`.
2. Start the watch and get only the flags as events. With the Monitor tool: `scripts/watch-frames.sh 30m | tee <scratchpad>/frames.log | grep --line-buffered -E '<<|rror'`. In a terminal: `scripts/watch-frames.sh 10m`.
3. Reproduce: the user uses the app, or an agent runs the demo check below. For each flag, read the 10 lines before it in the log. Say which line started the change.
4. Fix the cause, then repeat steps 1 to 3 on the same scenario until no flag shows.

## Demo check (no user needed)

`scripts/check-frames.sh [scene]` runs one demo scene under the watch and exits 1 when a flag is on a `resized` line (a fault the user sees). It waits until the user is idle for 10 s, quits the installed app for the run (they share the global shortcut) and opens it again. Run `scripts/bundle.sh` first. Scenes: `window-turn` (default: opens on Last Call; after 2 s sessions come into Your Turn and the Another round? banner goes), `window-slide` (the same, 0.1 s into the opening slide), `window`, `window-children`, `window-quiet`.

`BOUNCE` or `FLIP` on a `content` line alone is SwiftUI's own layout passes. It is a fault only when the window follows it with two resizes (`TWICE`).

Trap: the demo window takes keyboard focus with its search field active. If the user types while it shows, the keys filter the list, and the watch shows a false `FLIP`. A check that is red once and then green with the idle check was this.

## Causes found so far

- First opening after launch grew in three steps (`slideIn ... content=0`, then `top=` and `bottom=` arrive): the window was made at the first hover, so SwiftUI had not laid out the bars. Fixed by `PanelController.prepare()` at launch.
- A slide started again with no height change (`RESTART`): a fit (the pill's alert state changed) or a second hover on the fading pill aimed the slide again, and a fractional height (736.5 against AppKit's 737) never compared equal. Fixed in `EdgeDrawer.slideIn`: a slide on its way to the same size goes on; the fitted height is rounded. Later a click 0.9 s after the hover, when the slide had ended, started it again: an open window of the same size now always stays. The demo cannot trigger it (its height changes in the same turn), so check it with the watch on the real app.
- A session coming into Your Turn resized twice (`TWICE`): the list got the new rows one pass before the bars above it lost the banner (the banner was in the filter bar until 2026-10-30). Fixed by `EdgeDrawer.fitSoon()`, one fit per main-loop turn.

## When you add a size change

Every new `setFrame` or `setContentSize` on the session window gets a `frameLog.debug` line with the height it asks for, in the same form as `fit`, so the watch does not flag it as `FOREIGN`.
