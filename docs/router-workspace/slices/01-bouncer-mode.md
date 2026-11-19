# 01 Bouncer mode

## Goal

Rounds gets a Bouncer mode. The pill is the Bouncer, and a click on it opens the Bouncer Window, where the user talks to the Bouncer.

## State

Brief, 2026-11-19. No open owner decision. Next step: details before code.

## Depends

None. Organization rules and workspace setup are built ([overview](../overview.md#built-so-far)).

## Builds

- The mode switch.
- The pill as the Bouncer: it stays still while nothing waits, and bounces only when the Bouncer asks for an approval or an answer.
- The Bouncer Window: the conversation, results and decisions. Approvals show as inline cards that host code draws, never as model text.
- The window drives Pi with `pi --mode rpc` through one adapter. Demo data until dispatch exists ([slice 03](03-dispatch-and-results.md)).

## Decided

- Decision "Bouncer mode in Rounds" ([decisions.md](../decisions.md)).
- Decision "Bouncer Window has a task sidebar" ([decisions.md](../decisions.md)). Patterns to take from the Claude desktop app Code tab ([its docs](https://code.claude.com/docs/en/desktop)): **+ New** at the top of the sidebar; group and sort on hover; archive from a hover menu; a details panel of cards beside the chat; one view only (owner, 2026-11-19), where each agent report shows its tool steps collapsed and a click opens them; a control row under the prompt box; a stop button; Cmd+N and Ctrl+Tab; reports from other agents labeled with their task and a link back.
- Decision "Approvals as inline cards" ([decisions.md](../decisions.md)).
- Decisions "No shared theme in version one" and "Set Up row in the Bouncer Window" ([decisions.md](../decisions.md)).
- Design reference: [bouncer-mockups.html](../bouncer-mockups.html), the mockup the owner picked (layout C, inline approval cards). It covers the task, approval, error and accessibility states that the attention review asked for.
- Rounds still watches all sessions. The session list stays on the global shortcut.
- *Default* (agent, 2026-11-19, reversible): the Bouncer agent sees nothing of the sessions that it does not manage. On user request it reads metadata only (title, state, project, organization), never transcript text, and never sends them input. Organization rules decide what goes to the model.

## Open

None.
