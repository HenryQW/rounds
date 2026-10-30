# Rounds

Live state of AI coding sessions on one Mac, from several sources, in one list behind a screen-edge pill. The name is a round of drinks; the four tile names carry the drinks pun.

## Sessions and sources

**Session**:
One unit of agent work the user can open and continue: a Claude Code session, a Codex thread or a herdr agent pane.
_Avoid_: task, activity, conversation, convo, job

**Source**:
The tool that runs a session and reports its state: Claude Code, Codex, or a herdr agent such as pi.
_Avoid_: origin, provider, platform

**On** / **Off**:
Whether a source can report live state. Claude Code and Codex are on while their hooks are installed; herdr is on while it is running. The window shows only the sessions of sources that are on.
_Avoid_: enabled, connected, disabled

**Thread**:
Codex's word for a session; used only when the text is about Codex.

**Agent**:
herdr's word for the coding agent in one pane (pi, Claude, droid); used only when the text is about herdr.

**Child session**:
A session that another session (its parent) started: a fork, a side session or a sub-agent. It shows under its parent while the parent is listed, else on its own.
_Avoid_: subsession, nested session

**Sub-agent**:
A child session that another session started to do part of its work. It never makes the pill alert: the session that started it handles its result and asks the user itself.
_Avoid_: worker

**Fork**:
A child session that the user made from another session.
_Avoid_: copy, branch

**Direct**:
A child session that works in its parent's folder.
_Avoid_: inline, shared

**Isolated**:
A child session that works in a folder of its own. The kind comes from the folder, not from how the child started.
_Avoid_: sandboxed, separate

**Background task**:
Work a session left running after its turn, such as a shell command or a sub-agent inside a Claude session.
_Avoid_: job, child

**Project**:
The repository a session belongs to; worktrees join their repository.
_Avoid_: repo, workspace, folder

## States

**State**:
What a session is doing now, as one of the standard states below; every source maps into them, whatever its own words.
_Avoid_: status (alone), label

**Detail**:
The source's own words next to the state: a tool name, the permission asked for, "review", "Wakes in 5 min".
_Avoid_: sub-label, reason

**Needs input**:
The session is blocked until the user answers a permission, a question, a plan or an input request.
_Avoid_: blocked, waiting, attention required

**Failed**:
The last turn ended in an error.
_Avoid_: error, crashed

**Working**:
The session is in a turn now.
_Avoid_: thinking, busy

**Background**:
The session is between turns but still has work scheduled: background tasks or a timed wake-up.
_Avoid_: waiting, scheduled

**Ready**:
The session finished a turn with a result the user has not looked at yet.
_Avoid_: done, review ready, unread

**Finished**:
The session finished and has nothing new for the user.
_Avoid_: idle, completed, done

**Stopped**:
The user interrupted the last turn.
_Avoid_: aborted, cancelled, interrupted

**Offline**:
The live state is unknown: the source app is not running, or the session runs on another machine.
_Avoid_: stale, unknown

**Seen**:
A session the user opened, in Rounds or in its app, since its current state began. A seen result leaves Last Call; a seen wait stays in Last Call, but the pill no longer rings for it.
_Avoid_: read, clicked, acknowledged

## Groups and tiles

**Group**:
The place of a state in the list and the filters. Each group has a plain name, used in text, and a tile name, shown on its filter tile.
_Avoid_: category, bucket, queue

**Your Turn** (tile name **Last Call**):
The group of sessions that need the user, in a counted state (Needs input, Failed, Ready, Finished, Stopped by default): every wait (Needs input, Failed) until the agent goes on, and every result (Ready, Finished, Stopped) until the user opens it. The pill shows its count.
_Avoid_: Need input, attention required

**Running** (tile name **On Tap**):
The group of sessions at work: Working and Background.
_Avoid_: active, busy

**Quiet** (tile name **Served**):
The group of sessions with nothing to do now: opened results (Ready, Finished, Stopped) and Offline.
_Avoid_: idle, done

**Older** (tile name **Aged**):
Sessions with no activity for the Aged time (1 day by default) that do not run or wait; shown only in a search or under their tile.
_Avoid_: archived, stale

**Another Round?**:
The empty Last Call list while no session is in Your Turn, with one button per source that is on; a click on a button starts a new session there.
_Avoid_: all clear, empty state

## The user's marks

**Mark as Done**:
The user's note that a session needs nothing; the session leaves the list until it has newer activity.
_Avoid_: archive, dismiss

**Starred**:
A session the user starred in Claude or in Rounds; it shows at the top of the list, under a status filter only when it is in that group.
_Avoid_: pinned, flagged, favourite

**Hidden**:
A session the user took out of the list until they unhide it; it shows only in a search.
_Avoid_: muted, archived

## Live state

**Hook**:
A command that Claude Code or Codex runs at each turn event, so Rounds learns state the app keeps only in memory.

**Hook state**:
The last turn events Rounds recorded for one session from its hooks.

**Rollout**:
Codex's record of everything that happened in a thread.
_Avoid_: transcript (that is Claude's record)

**Transcript**:
Claude Code's record of a session's messages.

## Window

**Pill**:
The tab at a screen edge that shows the counts and opens the session window. It shows the Your Turn count: red while a session in it failed, orange while one needs input, and green while it holds only results (Ready, Finished, Stopped); with no Your Turn session it turns blue with the running count while sessions run. It rings (peeks out) only while a wait is not yet seen. It is the app's only entry point.
_Avoid_: handle, badge, edge tab

**Session window**:
The window that slides out from the pill's edge with the filter bar and the list.
_Avoid_: drawer, panel, popover

**Filter bar**:
The tiles and source toggles above the list.

**Tile**:
The filter for one group: a symbol, a count and the group's tile name.
_Avoid_: status tile, segment, chip

**Source toggle**:
A filter that shows or hides all sessions of one source.

**Rounds blue**:
The app's own colour: the icon, the running pill and the Another Round? banner.
_Avoid_: brand blue, accent (that is the system's selection colour)
