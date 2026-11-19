# 04 Approval gate and publication

## Goal

Rounds pushes a branch or opens a draft pull request for a result only after the user approves the exact list of actions. Agents cannot do a protected action.

## State

Brief, 2026-11-19. Open decisions: see Open.

## Depends

[Slice 03](03-dispatch-and-results.md).

## Builds

- The gate extension parks a tool call with `sleep: { signals: [Approval.key(key)] }`. The Node Host shows it to Rounds, and Rounds answers through `harness.signal(taskId, Approval, key, value, context)` (pi `test/examples/44-approval-gate.ts`).
- The example keeps open questions only in memory, so the Node Host stores them itself to show them again after a restart.
- One request groups the exact push and draft pull request actions of one result. Each action stays listed, and the guard checks each one.
- After a restart, Rounds rechecks the revision and remote URL. If they are the same, the request stays. If not, Rounds drops it and asks again.
- A rejection stops the action, records the reason and returns it to the requesting agent.
- Rounds shows the request as Needs input. Remote alerts go out only when the organization permits it; if permission is unknown, the alert stays local.

## Decided

- Decisions "Authority and approval enforcement", "Option 3: container-use for all agent work", "Attention review" (Approval row) and "Restart rechecks replace the Interrupted state" ([decisions.md](../decisions.md)).

## Open

- Validate checkout ownership, recovery proof and the complete approval guard before protected actions use them. An approval must bind the requested action, its target and the current state.
- How a Bartender reviews a Barback's request before it reaches the user, when the request is a pi-durable gate.
