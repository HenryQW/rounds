# Slices

Build slices of Bouncer mode, in build order. Each slice has its own tests and spec update. The order comes from the plan of 2026-11-19 ([archive/plan.md](../plan.md)); the approval gate and publication follow slice 3 (decision "Build on unreleased pi-durable" in [decisions.md](../../decisions.md)).

| # | Slice | Brief | State |
|---|---|---|---|
| 01 | Bouncer mode | [01-bouncer-mode.md](01-bouncer-mode.md) | Details |
| 02 | Node Harness host | [02-node-harness-host.md](02-node-harness-host.md) | Lifecycle, Bouncer and local container bridge built. Production tool registration remains open. |
| 03 | Dispatch and results | [03-dispatch-and-results.md](03-dispatch-and-results.md) | Local workflow verified across two repositories. App integration remains open. |
| 04 | Approval gate and publication | [04-approval-and-publication.md](04-approval-and-publication.md) | App replay and local decisions for registered tasks. Fixtures verify signal delivery and the action guard. Live dispatch and publication remain open. |

## Carry-over

| From | Work | Takes it |
|---|---|---|
| 02a | Pinned container tool bridge and unresolved execution requirements | 02c, in [slice 02](02-node-harness-host.md) |
