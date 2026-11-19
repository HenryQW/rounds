# 01 Bouncer mode

## Goal

Rounds gets a Bouncer mode. The pill is the Bouncer, and a click on it opens the Bouncer Window, where the user talks to the Bouncer.

## State

Brief, 2026-11-19. Open decision: the user picks one of the mockups.

## Depends

None. Organization rules and workspace setup are built ([overview](../overview.md#built-so-far)).

## Builds

- Up to 3 native mockups of the Bouncer Window and the bouncing pill first. The user picks one before the build (design rule in `AGENTS.md`).
- The mode switch.
- The pill as the Bouncer: it stays still while nothing waits, and bounces only when the Bouncer asks for an approval or an answer.
- The Bouncer Window: the conversation, results and decisions. Approvals show as native dialogs from host code, never as model text.
- The window drives Pi with `pi --mode rpc` through one adapter. Demo data until dispatch exists ([slice 03](03-dispatch-and-results.md)).

## Decided

- Decision "Bouncer mode in Rounds" ([decisions.md](../decisions.md)).
- Rounds still watches all sessions. The session list stays on the global shortcut.
- *Default* (agent, 2026-11-19, reversible): the Bouncer agent sees nothing of the sessions that it does not manage. On user request it reads metadata only (title, state, project, organization), never transcript text, and never sends them input. Organization rules decide what goes to the model.

## Open

- Design the native task, approval, error and accessibility states from the [attention review](../archive/attention-review.md), which the user approved on 2026-11-19, as Bouncer mode changed it. Earlier mockups were removed as outdated.
- Decide how the shared theme applies to native Rounds controls without a change to the meaning of the existing state colours. The shared theme draft is a separate local file and is not in the published package.
- In Bouncer mode, where the Set Up row of the attention review shows (it was planned for Your Turn).
