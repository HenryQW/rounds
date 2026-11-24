# Archive

The archive records how the design of Bouncer mode came about. [Decisions](../decisions.md) and [slice briefs](../slices/README.md) win over it. Archived docs can use old names; [CONTEXT.md](../CONTEXT.md) maps them to current names in its `Not` column. Do not update archived docs, except to fix links.

| Doc | Holds | Status |
|---|---|---|
| [plan.md](plan.md) | The plan up to 2026-11-19: objective, scope, acceptance scenarios, remaining work and slice order. Its content now lives in the [overview](../overview.md), [decisions](../decisions.md) and [slice briefs](../slices/README.md). | Record only |
| [reuse-review.md](reuse-review.md) | Existing tools checked for reuse, orchestration options for option 3, and the pi-durable probe of 2026-11-19 | Read by [slice 02](../slices/02-node-harness-host.md) (section [pi-durable](reuse-review.md#pi-durable-checked-2026-11-18)) |
| [feasibility-check.md](feasibility-check.md) | Delegate cancellation, recovery, sandbox, container-use, Dagger and egress probes | Read by [slice 02](../slices/02-node-harness-host.md) |
| [attention-review.md](attention-review.md) | The review of the task area for user attention, approved 2026-11-19 | Read by [slice 01](../slices/01-bouncer-mode.md) |
| [bouncer-review.md](bouncer-review.md) | The review of agents, approvals and recovery, and option 3 | Read by [slice 03](../slices/03-dispatch-and-results.md); decision "Option 3" links it |
