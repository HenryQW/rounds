# Slices

Build slices of Bouncer mode, in build order. Each slice has its own tests and spec update. The order comes from the plan of 2026-11-19 ([archive/plan.md](../archive/plan.md)); the approval gate and publication follow slice 3 (decision "Build on unreleased pi-durable" in [decisions.md](../decisions.md)).

| # | Slice | Brief | State |
|---|---|---|---|
| 01 | Bouncer mode | [01-bouncer-mode.md](01-bouncer-mode.md) | Details |
| 02 | Node Harness host | [02-node-harness-host.md](02-node-harness-host.md) | Built: 02a lifecycle; planned: 02b Bouncer, 02c tool bridge |
| 03 | Dispatch and results | [03-dispatch-and-results.md](03-dispatch-and-results.md) | Brief |
| 04 | Approval gate and publication | [04-approval-and-publication.md](04-approval-and-publication.md) | Brief |

## Carry-over

| From | Work | Takes it |
|---|---|---|
| 02a | Bouncer conversation migration, model resolution and obsolete adapter removal | 02b, in [slice 02](02-node-harness-host.md) |
| 02a | Pinned container tool bridge and unresolved execution requirements | 02c, in [slice 02](02-node-harness-host.md) |
