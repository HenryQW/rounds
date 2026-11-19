# Bouncer mode docs

This folder holds the design of Bouncer mode: one user-facing Bouncer in Rounds that coordinates Bartenders and their Barbacks across repositories. It is a plan. Only organization rules, outbound checks and workspace setup are built (see [overview](overview.md#built-so-far)). Do not treat a router doc as proof that the app has a capability.

The [Rounds specification](../spec.md), [glossary](../../GLOSSARY.md) and [design](../../DESIGN.md) describe the current app. Update them when the corresponding behavior or product terms are agreed and built.

| Doc | Holds | Read when |
|---|---|---|
| [overview.md](overview.md) | What Bouncer mode is, goals, agreed scope, parts, acceptance scenarios, build order, open points for the whole project | You start any work on Bouncer mode |
| [CONTEXT.md](CONTEXT.md) | Names of this context: `Name`, `Means`, `Not` (rejected and old names) | You use or add a term, or read an archived doc with old names |
| [decisions.md](decisions.md) | Owner decisions, newest last | You need to know what the owner decided and why, or you record a new decision |
| [bouncer-mockups.html](bouncer-mockups.html) | The picked design of the Bouncer Window and pill: layout C, inline approval cards, demo data only | You build or review slice 01 |
| [decisions/repository-visibility.md](decisions/repository-visibility.md) | Record of the workspace repository and visibility decision: context, decision, consequences | You work on the workspace repository, remotes or task detail storage |
| [decisions/authority.md](decisions/authority.md) | Record of the authority and approval enforcement decision: context, decision, consequences | You work on approvals, protected actions or the authority chain |
| [slices/README.md](slices/README.md) | Build slices in order, with their briefs and state | You plan, start or finish a slice |
| [archive/README.md](archive/README.md) | Reviews and research that led to the design | You need the evidence or the history behind a decision |

## Rules

- A doc is current, or it is in `archive/`. A change that makes a doc wrong fixes that doc in the same commit.
- Record each owner decision in [decisions.md](decisions.md) when the owner makes it. Supersede an old entry; do not delete it.
- Add a name to [CONTEXT.md](CONTEXT.md) before you use it. Current docs use no name from its `Not` column.
- Precedence: decisions and slice briefs win over the archive. When two current docs disagree, the newer dated decision wins.
- This README and [slices/README.md](slices/README.md) list every tracked file in their folders.
