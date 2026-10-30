---
title: Glossary
description: The words that Rounds uses, each with one meaning.
---

## States

Each source uses its own words for what a session does. Rounds puts these words into eight states, so a session from Claude, Codex or herdr reads the same. The word of the source shows as the detail on the row, after the state: "Needs input · Permission: Bash".

<div class="states-scroll">
<table class="states-table">
  <thead>
    <tr><th>State</th><th>Tile</th><th>Claude</th><th>Codex</th><th>herdr</th></tr>
  </thead>
  <tbody>
    <tr class="group"><th colspan="5">Waits for you</th></tr>
    <tr>
      <td><span class="state filled" style="--dot: #ff9500">Needs input</span></td>
      <td>Last Call</td>
      <td>A permission request, a question, a plan to approve, an MCP input, an interrupted turn that waits for you, a blocked summary</td>
      <td><code>PermissionRequest</code></td>
      <td><code>blocked</code></td>
    </tr>
    <tr>
      <td><span class="state filled" style="--dot: #ff3b30">Failed</span></td>
      <td>Last Call</td>
      <td><code>StopFailure</code>, an error in the last 7 days, a failed summary</td>
      <td class="none">None</td>
      <td class="none">None</td>
    </tr>
    <tr class="group"><th colspan="5">Runs</th></tr>
    <tr>
      <td><span class="state filled" style="--dot: #007aff">Working</span></td>
      <td>On Tap</td>
      <td>A turn in progress (turn hooks or the transcript)</td>
      <td><code>task_started</code>, turn hooks</td>
      <td><code>working</code></td>
    </tr>
    <tr>
      <td><span class="state" style="--dot: #007aff">Background</span></td>
      <td>On Tap</td>
      <td>A turn that ended with background tasks (for 2 hours at most), a scheduled wake in the next 15 minutes</td>
      <td class="none">None</td>
      <td class="none">None</td>
    </tr>
    <tr class="group"><th colspan="5">Has a result</th></tr>
    <tr>
      <td><span class="state filled" style="--dot: #34c759">Ready</span></td>
      <td>Last Call, then Served</td>
      <td>A summary that says the result is ready for review</td>
      <td class="none">None</td>
      <td><code>done</code> (a turn you did not look at)</td>
    </tr>
    <tr>
      <td><span class="state" style="--dot: #8e8e93">Finished</span></td>
      <td>Last Call, then Served</td>
      <td>A completed turn, a new session</td>
      <td><code>task_complete</code>, <code>Stop</code></td>
      <td><code>idle</code>, <code>unknown</code></td>
    </tr>
    <tr>
      <td><span class="state" style="--dot: #8e8e93">Stopped</span></td>
      <td>Last Call, then Served</td>
      <td>A turn that you interrupted</td>
      <td><code>turn_aborted</code>, <code>Interrupt</code></td>
      <td class="none">None</td>
    </tr>
    <tr class="group"><th colspan="5">Not known</th></tr>
    <tr>
      <td><span class="state dashed" style="--dot: #8e8e93">Offline</span></td>
      <td>Served</td>
      <td>Claude does not run, a hook from before Claude started, a session on another Mac</td>
      <td>Codex does not run</td>
      <td class="none">None</td>
    </tr>
  </tbody>
</table>
</div>
- **Dot:** a filled dot wants you or runs; a ring is quiet or opened; a dashed ring means that the state is not known. A result in Last Call has a filled green dot, the colour of the pill.
- **Finished and Stopped:** both end a turn. Finished means that the agent ended its turn. Stopped means that you ended it while it ran.

## Tiles

Each tile is a filter for one group. A click shows only that group; a click on the selected tile goes back to All. Each group has a plain name, which hints and VoiceOver use, and a tile name, a bar pun.

| Tile | Plain name | What is in it |
| --- | --- | --- |
| Last Call | Your Turn | What needs you: a wait (Needs input, Failed) until the agent goes on, and a result (Ready, Finished, Stopped) until you open it. The pill shows the same count. |
| On Tap | Running | Working and Background sessions. |
| Served | Quiet | Results you opened, and Offline sessions. |
| Aged | Older | Sessions with no activity for a day (you can change the time), unless they run or wait. |

## Words

- **Seen:** You opened the session, in Rounds or in its app, after its current state began. A seen result leaves Last Call. A seen wait stays in Last Call, but the pill no longer rings for it. A new state makes the session unseen again.
- **Pill:** The tab at a screen edge. It shows the Last Call count, or the running count while nothing needs you, and it opens the session window. [How it works](/how-it-works#4-the-pill-shows-the-number) gives its colours.
- **Session window:** The list that slides out from the pill: the tiles, one toggle for each source, and the sessions grouped by project.
- **Source:** The tool that runs a session and reports its state: Claude Code, Codex, or herdr (for pi agents). A source is On or Off. A toggle under the tiles hides the sessions of one source in the window; the pill still counts them.
- **Child session:** A session that another session started. It shows under its parent, after a chevron that folds it. Direct: it works in its parent's folder. Isolated: it works in a folder of its own.
- **Context row:** Under a tile, a parent session that is not in that tile, shown above its children that are. It is grey, has no dot and cannot be selected: it only shows where the children belong. Its chevron folds it. Click All to see the parent as a normal row.
- **Background task:** A shell, sub-agent or workflow that a session runs after its turn. It shows as one grey line under the session, with no dot.
- **Sub-agent:** A session that a Codex or herdr agent started for its own work. It does not count in Last Call, because the agent that started it asks you itself; Settings > Filters can count it.
- **Star, Done, Hide:** Your marks on a session (right-click a row). Star (⌘S) keeps it at the top of its tile and under All. Mark as Done (⌘D) takes it out of the list until it has newer activity. Hide (⌘⌫) shows it only in a search. ⌘Z undoes Done and Hide.
- **Another round?:** What Last Call shows when nothing needs you: one button for each source that is On, to start a new session there.
