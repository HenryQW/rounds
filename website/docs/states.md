---
title: States
description: The eight states of a session, and the words of each source that give them.
---

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

## How to read the table

- **Tile:** Last Call has each session you have not seen since its state changed, in the states that Settings > Filters counts. "Last Call, then Served" means that the session goes to Served when you open it. A session that waits for you stays in Last Call after you open it, until it goes on.
- **Dot:** a filled dot wants you or runs; a ring is quiet; a dashed ring means that the state is not known. When you open a session that waits for you, its filled dot becomes a ring.
- **Finished and Stopped:** both end a turn. Finished means that the agent ended its turn. Stopped means that you ended it while it ran.
- **Sub-agents:** a Codex or herdr sub-agent does not go into Last Call, because the agent that started it asks you. Settings > Filters can count them.
- **Aged and hidden:** these are not states. A session with no activity for the Aged time (1 day by default) goes to Aged, unless it runs or waits for you. A session archived in its app is hidden; search finds it.
