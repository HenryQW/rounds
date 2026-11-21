# 03 Dispatch and results

## Goal

The Bouncer gives a task to a Bartender and gets its result back. The result arrives as branch `container-use/<env>` with a Blocked or Done record. No protected action runs in this slice.

## State

Details, 2026-11-22. Open decisions: see Open. This brief specifies future work; dispatch is not built.

## Read first, in full

| Read | Purpose |
|---|---|
| [AGENTS.md](../../../AGENTS.md), [DESIGN.md](../../../DESIGN.md), [GLOSSARY.md](../../../GLOSSARY.md) | Project rules, existing components and product terms |
| [Spec 2.7](../../spec.md#27-pi-sessions), [2.8](../../spec.md#28-tickets), [3](../../spec.md#3-classification) | Organization checks, workspace setup and session classification; include every subsection |
| This brief, [01](01-bouncer-mode.md), [02](02-node-harness-host.md), [slice index](README.md) | Scope, adapter boundary and Node Host prerequisites |
| [Overview](../overview.md), [decisions](../decisions.md), [context](../CONTEXT.md) | Agreed behavior, owner decisions and task/session distinction |
| [Bouncer review](../archive/bouncer-review.md), [plan](../archive/plan.md) | Evidence and proposals; proposals do not replace owner decisions |
| [Workspace.swift](../../../Sources/RoundsCore/Workspace.swift), [TaskGraph.swift](../../../Sources/RoundsCore/TaskGraph.swift), [TaskDetailStore.swift](../../../Sources/RoundsCore/TaskDetailStore.swift), [TaskRecordStore.swift](../../../Sources/RoundsCore/TaskRecordStore.swift) | Actual setup checks, graph validation and detail publication contracts |
| [Workspace tests](../../../Tests/RoundsCoreTests/WorkspaceTests.swift), [graph tests](../../../Tests/RoundsCoreTests/TaskGraphTests.swift), [detail tests](../../../Tests/RoundsCoreTests/TaskDetailStoreTests.swift), [record tests](../../../Tests/RoundsCoreTests/TaskRecordStoreTests.swift) | Existing boundaries and regression coverage |
| Pinned Pi source listed under Contracts | Conversation creation, child ownership, tool exposure and scheduling |

Read the living-docs skill, section "Slice brief", before changing this brief. The checked source is `~/.local/share/magpie/shared-skills/skills/living-docs/SKILL.md` on `vps`.

## Depends

[Slice 01](01-bouncer-mode.md) supplies the Bouncer conversation and window. [Slice 02](02-node-harness-host.md) supplies the Node Host, durable adapter, approved storage, models and container-use wrapper.

Sub-step 1 can merge before slice 02. Sub-steps 2 and 3 require its completed host and recovery checks.

## Builds

| Sub-step | Deliverable | Why it can merge alone |
|---|---|---|
| 1 | Task interface over the existing graph and detail stores; first production caller of `mayStoreTaskDetails(for:)` | Local calls and temporary test folders prove storage behavior without a container, model, session mapping or new window |
| 2 | Bouncer dispatch and result tools; Bartender execution and Blocked continuation through the slice 02 host | Depends on 1; proves one repository run and a durable result before any result fetch into the real repository |
| 3 | Result branch intake, result presentation and the two-repository acceptance scenario | Depends on 2; adds verified local fetch and cross-repository coordination without publication |

The split keeps local storage usable while dispatch questions remain open. Each sub-step includes its own tests and the corresponding specification update.

## Files

Paths marked new are proposed files. Existing stores keep their formats unless a later owner decision requires a separate change.

| Path or boundary | Sub-step | Change |
|---|---|---|
| `Sources/RoundsCore/TaskInterface.swift` (new) | 1 | Add the local task interface and call the workspace storage check before writes |
| [Workspace.swift](../../../Sources/RoundsCore/Workspace.swift) | 1 | Reuse `WorkspaceSettingsStore`; do not replace its fresh destination checks |
| [TaskGraph.swift](../../../Sources/RoundsCore/TaskGraph.swift), [TaskDetailStore.swift](../../../Sources/RoundsCore/TaskDetailStore.swift), [TaskRecordStore.swift](../../../Sources/RoundsCore/TaskRecordStore.swift) | 1 | Reuse graph mutations, immutable revisions and detail-first linking |
| `Tests/RoundsCoreTests/TaskInterfaceTests.swift` (new) | 1 | Exercise the caller boundary with real temporary stores and no runtime host |
| Node Host entry, extension registry, wrapper and tests delivered by slice 02 | 2, 3 | Extend those files; record their actual paths here after slice 02, before implementation |
| [BouncerAdapter.swift](../../../Sources/RoundsCore/BouncerAdapter.swift), [Bouncer.swift](../../../Sources/RoundsCore/Bouncer.swift), [BouncerModel.swift](../../../Sources/Rounds/BouncerModel.swift) | 2, 3 | Extend the durable adapter and project records into existing task/report/question events |
| [Bouncer tests](../../../Tests/RoundsCoreTests/BouncerTests.swift) and slice 02 host tests | 2, 3 | Check protocol boundaries and real branch intake; do not restore the removed Pi process adapter |
| [Spec](../../spec.md), this brief, [slice index](README.md) | Each | Record only behavior that the sub-step implements and verifies |

No new window design belongs here. Use the chosen slice 01 components. The Node Host file layout is a dependency of slice 02, not an invented layout in this brief.

## Contracts

### Local task interface

| Boundary | Contract |
|---|---|
| Scope | Each call supplies its organization scope and exact authorized graph/detail destinations. Do not infer authority from assignment text or a Git remote. |
| First check | Call `WorkspaceSettingsStore.mayStoreTaskDetails(for:)` before creating a task or publishing details. False means no graph or detail write. |
| Destination | Reacquire `taskDetailFolder(for:)` for the operation. A previous true result is not a reusable storage grant. |
| Authorization | The setup check establishes folder readiness only. The caller must separately authorize every graph value and detail value for its exact destination. |
| Unclassified input | A nil organization selects the existing unclassified folder. It grants no model transmission. Do not convert a conflicting classification into an unclassified permission. |
| Create | Use `TaskGraphStore.update` and `TaskGraph.createTask`, then `TaskRecordStore.write` with `TaskDetailReference.empty`. New tasks use the existing `queued` state. |
| Read and revise | Read the graph reference and its exact `TaskDetailRevision`. Supply that reference to a revision write. Preserve assignment, result, progress and decisions unless the request changes them. |
| Concurrent change | Return the existing conflict or link error. Do not silently overwrite a newer reference or retry a write with a new reference. |
| Publication | Only `TaskRecordWriteResult.saved` confirms durable detail publication and graph linking. Other results require inspection. |
| Partial write | A graph task without details or an unlinked detail revision can remain after failure. Report it; do not dispatch, delete it or recreate missing data. |
| Viewed result | Only completed or cancelled graph tasks accept acknowledgement. Call `markResultViewed(_:expecting:at:)` with the displayed reference. A stale view cannot acknowledge a newer result. |
| States | Preserve `TaskGraph` validation. Sub-step 1 adds no run-state transition policy or mapping from a Pi conversation to a Rounds task. |

`GraphTask` holds identifiers, parent/dependency links, state, viewed status, timestamps and a detail reference. It has no assignment text or session identifier.

`TaskAssignment` holds `objective`, `scope`, `target`, `constraints` and `acceptanceConditions`. Parent and dependency links belong in the graph.

`TaskResult` holds `changedLocations`, `validationOutcomes`, `checkedRevisionOrWorkingTree`, `risks` and `blockers`. `TaskProgress` and `TaskDecision` remain separate detail arrays.

`TaskRecordStore.write` publishes details before updating the graph. Its error can identify a published orphan. It is not a transaction across both stores.

### Dispatch and results

These boundaries apply after the blocking Open items are resolved. They do not choose the missing identity or transition policy.

| Boundary | Contract |
|---|---|
| Dispatch request | Reference an existing task and detail revision. Supply its target repository, checkout, explicit instructions and the complete agreed handoff. |
| Dispatch permission | Check applicable organization rules for the model, transcript database, logs, output, temporary files and clone before any content reaches them. |
| Rejection | Missing enrollment, instructions, authority, storage approval or current ownership prevents a run. A rejection does not create a replacement clone. |
| Tool exposure | The Bouncer gets orchestration tools. Bartender code/file commands use only the pinned container-use wrapper. No host shell or file tool enters its callable set. |
| Result envelope | Carry Blocked or Done, the task/run correlation, exact detail reference, environment/branch identity and `TaskResult` fields. Validate correlation before accepting content. |
| Blocked | Include a reason and up to 3 options. End that run. The Bouncer answers or asks the user, then continues from the same clone. |
| Done | Supply the checked revision or working-tree identity and validation outcomes. A successful model turn or process exit alone is insufficient. |
| State mapping | Blocked and Done are handoff outcomes. Their mapping to `TaskGraphState` and `BouncerTaskState` remains open; do not equate their names. |
| Intake | Verify the task repository, environment, branch and fetched revision before presenting changes as checked. Preserve the real working tree. |
| Authority | No tool in this slice pushes, opens a pull request, merges, deploys or performs another protected action. Slice 04 supplies that gate. |

A result can arrive before the dependency or required child is complete. Preserve it without bypassing the existing graph completion checks.

### Pinned Pi facts

The source was read at commit `5a14e69c067d40dfbff4f2fff7d3b34c897e2dc9`. The local probe checkout matched that commit before inspection. These are source facts, not claims that Rounds already implements them.

| Verified source | Fact and consequence |
|---|---|
| [harness.ts, Harness.open](https://github.com/earendil-works/pi/blob/5a14e69c067d40dfbff4f2fff7d3b34c897e2dc9/packages/durable/src/harness/harness.ts#L613) | `Harness.open(storage, options, context)` opens the scheduler. `root(context, options)` obtains or creates the reserved root. |
| [harness.ts, conversation methods](https://github.com/earendil-works/pi/blob/5a14e69c067d40dfbff4f2fff7d3b34c897e2dc9/packages/durable/src/harness/harness.ts#L413) | `createConversation(options, context)` creates an independent conversation. `conversation(id, context)` looks up an existing handle. `submit({ type: "input", content, requestId }, context)` admits input. |
| [transaction.ts](https://github.com/earendil-works/pi/blob/5a14e69c067d40dfbff4f2fff7d3b34c897e2dc9/packages/durable/src/session/transaction.ts#L358), [agent.ts](https://github.com/earendil-works/pi/blob/5a14e69c067d40dfbff4f2fff7d3b34c897e2dc9/packages/durable/src/harness/agent.ts#L207) | A tool can create a task-owned conversation in a commit. Its agent initially copies the owning task conversation's stored agent. Configure its role explicitly before input. |
| [21-subagent-foreground.ts](https://github.com/earendil-works/pi/blob/5a14e69c067d40dfbff4f2fff7d3b34c897e2dc9/packages/durable/test/examples/21-subagent-foreground.ts#L41) | The example registers `defineTool` through `defineExtension` and finds an existing child by owner task. It removes the delegation extension and uses a stable input `requestId`. External effects still need separate replay checks. |
| [types.ts, ToolRegistration](https://github.com/earendil-works/pi/blob/5a14e69c067d40dfbff4f2fff7d3b34c897e2dc9/packages/durable/src/harness/types.ts#L416) | The Harness validates tool parameters. Interrupted tool replay defaults to `unsafe`; declare `safe` only after testing every side effect. |
| [scheduler.ts, open and resume](https://github.com/earendil-works/pi/blob/5a14e69c067d40dfbff4f2fff7d3b34c897e2dc9/packages/durable/src/harness/scheduler.ts#L475), [types.ts, Harness](https://github.com/earendil-works/pi/blob/5a14e69c067d40dfbff4f2fff7d3b34c897e2dc9/packages/durable/src/harness/types.ts#L992) | Open reconciles surviving running tasks to pending without dispatching. `resume()` enables scheduling; submit, abort, compact and wait operations can also enable it. Recovery must precede those calls. |

A Pi task identifier, conversation identifier and Rounds graph task identifier are different identities. This brief does not define their durable mapping.

## How it works

```mermaid
flowchart TD
    A[Local task request] --> B[Check workspace and exact storage authority]
    B --> C[Create graph task and publish linked details]
    C --> D{Dispatch prerequisites resolved?}
    D -->|No| E[Keep local task; do not dispatch]
    D -->|Yes| F[Slice 02 host starts Bartender through container-use]
    F --> G[Validate Blocked or Done result and store details]
    G --> H{Result intake prerequisites resolved?}
    H -->|No| I[Keep result; do not integrate]
    H -->|Yes| J[Fetch and verify result branch; show result]
```

### Sub-step 1: local task records

- Check folder readiness and the caller's authority before writing either store.
- Use only explicitly supplied local scope and authorized stores. This step needs no repository registry or conversation identifier.
- Create or load the graph through its existing store. Only an explicit setup action can initialize a missing graph.
- Publish assignment details and link their revision through `TaskRecordStore`. Return partial outcomes with enough identity for inspection.
- Load a task by its graph identifier and current detail reference. Keep the existing graph/detail separation.
- Exercise the interface directly in tests. Do not add a container, model call or user-interface redesign to prove it works.

### Sub-step 2: dispatch and continuation

- Resolve enrollment, instructions, state/identity and storage questions before implementing live dispatch.
- Extend slice 02's registry and Rounds protocol. Keep the task interface as the only record-writing boundary.
- Recheck the target checkout and its single-writer ownership before starting work.
- Create or reacquire the appropriate conversation through the Harness. Apply explicit role tools before submitting the handoff.
- Validate and store the structured result before reporting acceptance to the Bouncer.
- Treat Blocked as an ended run with a retained clone. A later answer must identify that same task and clone.
- After restart, reconcile stored runs, local records, checkout ownership and process identity before any operation enables scheduling.
- Test interrupted external side effects before choosing a replay policy. Pi's stored submissions cannot make container operations exactly once.

### Sub-step 3: branch intake and initial workflow

- Resolve local-only record routing and Barback incorporation before enabling their integration paths.
- Verify the result's repository and environment against the accepted run record. Reject a branch name alone as proof.
- Fetch `container-use/<env>` into the task's real repository through a Rounds-owned fetch operation. Check the fetched revision against the result.
- Expect container-use to add its local `container-use` remote. Recheck remote acknowledgement before further workspace storage operations if the workspace remote set changes.
- Keep the real working tree unchanged during fetch. Do not treat fetch as publication or approval to merge.
- Project accepted records into the existing task sidebar and report/question components. Use the resolved state mapping.
- Register two repositories and complete one dependency workflow across them. Verify every handoff and each repository's result separately.
- Keep unresolved or unauthorized cross-organization links blocked. Do not infer a shared record destination from a shared parent task.

This brief defines no clone deletion schedule, checkpoint replacement or new Decision Record coverage. Preserve existing supplied decisions and recovery evidence.

## Tests

These are implementation cases, not tests run for this documentation change. Run Rounds tests through `scripts/test.sh`. Use the host test tooling delivered by slice 02.

| Sub-step | Case, boundary first | Required observation |
|---|---|---|
| 1 | Missing workspace, malformed settings, unacknowledged changed remotes, or absent approval | The first storage check rejects; neither graph nor details changes |
| 1 | Approved folder disappears, is replaced, becomes a symlink, or loses private ownership/permissions | A fresh operation rejects the destination; no alternate directory receives the data |
| 1 | Organization A is approved; B and unclassified are not | Calls for B and nil fail; A cannot authorize them |
| 1 | Folder readiness succeeds but graph or detail values lack destination authorization | Reject before either write; remote acknowledgement cannot substitute |
| 1 | Missing graph on an ordinary call | Return `missingGraph`; do not initialize or erase recovery evidence |
| 1 | Unknown task or stale detail reference | Reject; preserve the linked revision and report any published orphan |
| 1 | Detail write is not durable, or graph linking fails after detail publication | Surface the exact inspection/link outcome; no success report or dispatch |
| 1 | A new dependency or required-child link would form a cycle or allow premature completion | Existing graph validation rejects the update and preserves the previous graph |
| 1 | Task is nonterminal, or the displayed result reference becomes stale before acknowledgement | `markResultViewed` rejects; a newer terminal result still needs attention |
| 1 | Valid authorized create, revise and reopen | Assignment and current reference survive reopen; graph contains no task text |
| 2 | Missing enrollment, explicit instructions, storage permission or checkout ownership | No model request, conversation input or environment creation occurs |
| 2 | Child inherits the Bouncer's orchestration tools | Role configuration removes forbidden tools before the child's first input |
| 2 | Duplicate dispatch or crash between conversation, submission and environment writes | Reconcile the known operation; never silently start a second clone or writer |
| 2 | Restart leaves an owned wrapper process alive | Verify and stop it before resume, submit, abort, compact or wait can schedule work |
| 2 | Wrong task/run correlation, stale reference, malformed result, or a fourth Blocked option | Reject the result; preserve the current accepted record |
| 2 | One Bartender completes, then a second run reports Blocked and receives an answer | Done records exact checks; Blocked continuation uses its original clone |
| 3 | Wrong repository/environment, missing branch, changed fetched revision, or failed fetch | Keep the working tree intact; do not report verified intake |
| 3 | Result arrives before a dependency or required child completes | Store the result without forcing a graph completion transition |
| 3 | Cross-organization record lacks an authorized destination | No record or link crosses the boundary; integration stays blocked |
| 3 | Bartender consumes Barback output | Test the checked incorporation method after its open question is resolved |
| 3 | Valid local branch intake with unrelated working-tree changes | Verify fetched revision; preserve those changes; no push or protected action occurs |
| 3 | Two enrolled repositories complete one dependency workflow | Both results and checks name the correct repository/revision; parent completion obeys graph validation |

## Numbers

Baseline values below come from source inspection on 2026-11-22. Targets describe future implementation checks, not measured runtime performance.

| Measure | Baseline | Target and method |
|---|---|---|
| Production callers of `mayStoreTaskDetails(for:)` | 0; declaration and tests only | 1 task-interface boundary; inspect `Sources` and exercise both allow and deny paths |
| Graph and detail formats | Graph version 3; detail version 1 | Reuse both formats; reopen written records with the existing stores |
| Encoded detail revision size | Maximum 1,048,576 bytes | Preserve the limit; an oversized assignment fails without a linked replacement |
| Runtime dependencies for sub-step 1 | Existing local stores | 0 containers and 0 model requests; run its fixture tests without a host |
| Blocked options | Agreed maximum 3 | Accept at most 3; reject 4 at the result boundary |
| Concurrent writers per checkout | Agreed maximum 1 | Reject a second writer; assert ownership in dispatch and restart tests |
| Initial workflow repositories | Agreed minimum 2 | Complete one dependency workflow across 2 registered repositories |
| Protected actions in this slice | None permitted | 0; inspect exposed tools and assert no publication calls during acceptance |
| Sub-steps | Not implemented | 3 separately mergeable changes; complete each row's relevant cases before merge |

## Decided

- Decision "Option 3: container-use for all agent work" ([decisions.md](../decisions.md)).
- Handoff and result contents: the Handoff row of the [agreed scope](../overview.md#agreed-scope).
- *default*: Use the three sub-steps above. Local records can proceed while dispatch and integration questions remain open.
- *default*: Add one task-interface file over the existing stores. Keep storage formats and validation in their current owners.
- *default*: Prove sub-step 1 through direct local calls and temporary folders. Add no model, container or new window dependency.
- *default*: Reuse slice 02's host and registry. Configure each role's tools explicitly before input instead of relying on inherited defaults.
- *default*: Stop on uncertain publication, correlation or recovery outcomes. Keep evidence for inspection instead of automatically retrying side effects.

These defaults are implementation proposals. They do not answer Open items or add owner decisions to the decision log.

## Open

Each item remains open. Blockers are direct; later sub-steps also inherit their dependencies' blockers.

| Open item | Effect |
|---|---|
| Define repository enrollment and explicit instruction loading. | blocks sub-step 2 |
| Define task-state transitions and task-to-session identity. | blocks sub-step 2 and sub-step 3 |
| Checkpoints and safe retention remain open. Replacing the Git Checkpoint with the clone is an unapproved proposal in the [bouncer review](../archive/bouncer-review.md#changes). | does not block; the details assume nothing about it |
| Decision Record scope remains open. Recording results and every approval, instead of routine decisions, is an unapproved proposal in the bouncer review. | does not block; the details assume nothing about it |
| How a Bartender takes in the changes of its Barback is not checked. | blocks sub-step 3 |
| Resolve cross-organization links and separate local-only records before integration. | blocks sub-step 3 |
| Before dispatch, check agent transcripts, output, logs and temporary files against organization storage rules. | blocks sub-step 2 |

No item blocks sub-step 1. Do not mark a blocked sub-step ready because its local tests pass.
