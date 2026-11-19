# 03 Dispatch and results

## Goal

The Bouncer gives a task to a Bartender and gets its result back. The result arrives as branch `container-use/<env>` with a Blocked or Done record. No protected action runs in this slice.

## State

Brief, 2026-11-19. Open decisions: see Open.

## Depends

[Slice 01](01-bouncer-mode.md) (the Bouncer conversation) and [slice 02](02-node-harness-host.md) (the Node Host).

## Builds

- Dispatch and result tools for the Bouncer.
- A Bartender that needs input ends its run as Blocked, with up to 3 options. The Bouncer answers or asks the user, then resumes the run from the same clone.
- Rounds fetches the result branch into the real repository. container-use also adds a local remote `container-use` to the repository, but it does not write the working tree.
- The task interface on the versioned task graph and task detail store. The graph holds task identifiers, links, states, timestamps and detail revision IDs. The detail store holds assignments, progress, results and decisions in immutable revisions. The caller must authorize each storage destination.
- The first caller of `mayStoreTaskDetails(for:)` ([spec 2.7.2](../../spec.md#272-workspace-setup)).
- The acceptance scenario "Initial workflow": register two repositories and complete one cross-repository workflow ([overview](../overview.md#acceptance-scenarios)).

## Decided

- Decision "Option 3: container-use for all agent work" ([decisions.md](../decisions.md)).
- Handoff and result contents: the Handoff row of the [agreed scope](../overview.md#agreed-scope).

## Open

- Define repository enrollment and explicit instruction loading.
- Define task-state transitions and task-to-session identity.
- Checkpoints and safe retention. The [bouncer review](../archive/bouncer-review.md#changes) proposes that the clone is the checkpoint and that the separate Git Checkpoint goes; the owner has not decided it.
- The scope of the Decision Record. The bouncer review proposes to record the decisions in each result and every approval, not every routine agent decision; the owner has not decided it.
- How a Bartender takes in the changes of its Barback is not checked.
- Resolve cross-organization links and separate local-only records before integration.
- Before dispatch, check agent transcripts, output, logs and temporary files against organization storage rules.
