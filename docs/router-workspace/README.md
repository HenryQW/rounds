# Router Workspace in Rounds

This is the design for extending Rounds with cross-repository coordination. Organization rules and outbound checks are implemented in the source. The task stores are not integrated into the app, and agent dispatch is not implemented. Rounds is the product home; the user's Router Workspace is a separate coordination directory.

| Document | Purpose |
|---|---|
| [Plan](plan.md) | Scope, acceptance criteria, and remaining decisions |
| [Context](CONTEXT.md) | Coordination terms and accepted constraints |
| [Repository visibility](decisions/repository-visibility.md) | Storage, Git, and visibility decision |
| [Authority](decisions/authority.md) | Delegation authority and protected-action decision |
| [Reuse review](reuse-review.md) | Existing resources and checks still needed |
| [Feasibility check](feasibility-check.md) | Delegate cancellation, recovery, and sandbox evidence |
| [Attention review](attention-review.md) | Simplification of the task area, approved 2026-11-19 |
| [Bouncer review](bouncer-review.md) | Simplification of agents, approvals and recovery; see its Decided section |

The [Rounds specification](../spec.md), [glossary](../../GLOSSARY.md), and [design](../../DESIGN.md) describe the current app. Update them when the corresponding behavior or product terms are agreed and implemented. Do not treat a proposed router document as proof that the app has a capability.
