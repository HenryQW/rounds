# Router Workspace

The Router Workspace coordinates work across independent repositories through one user-facing Bouncer. This is a planned extension of Rounds, not a description of its current behavior. The workspace is separate from the Rounds source repository unless the user chooses otherwise.

Rounds owns its existing session language in [GLOSSARY.md](../../GLOSSARY.md). A Task Record is not a session: a task can outlive a session or span several sessions.

## Language

**Router Workspace**:
The coordination directory that holds repository records and task records, not copies of application code.

**Root Repository**:
The Git repository that holds the Router Workspace and its configuration. It can be public or private and can hold records for more than one organization.
_Avoid_: Git superproject, monorepo

**Bouncer**, **Bartender**, and **Barback**:
The planned coordination roles defined in [GLOSSARY.md](../../GLOSSARY.md#planned-coordination-roles).

**Bouncer Session**:
The local Pi session that runs the Bouncer and holds the user's conversation. Rounds brings a running session forward. When the user opens a closed Bouncer session, reopen its recorded Pi session if it is available. If the session is missing, start a clearly marked new conversation from durable task records. Report other session access errors without replacing the conversation. Reconcile Bartenders, Barbacks, and checkouts before any work resumes. Bartenders and Barbacks must stop when the Bouncer session ends. An uncertain agent must not be restarted until its previous run is proven stopped.

**Authority Chain**:
The order of decision authority: user, Bouncer, Bartender, then Barback. A Barback sends every request for input to its Bartender and never asks the user directly. The Bartender decides within its authority and asks the Bouncer when unsure. If the Bouncer cannot guide the Bartender without user input, it presents up to three options and recommends one. The user's direct instruction takes precedence over agent decisions and workspace policy, within applicable platform and external constraints.

**Approval Boundary**:
The user's rules for actions that require explicit consent. Agents cannot delegate more authority than the user grants. When the Bouncer cannot determine whether an action needs approval, it prepares the action and asks.

**Approval Request**:
A request for the user's consent to one protected action. A Bartender reviews a Barback's request before it reaches the user. The coordination runtime records the parent chain and can send a known approval request to the Task View after Bartender review without a Bouncer model turn. A Bartender asks the Bouncer first when uncertain. The requesting agent waits for the answer; unrelated work can continue. Rounds shows the request as Needs input and uses its configured remote alerts only when the organization permits the information to leave the machine. If permission is unknown, keep the alert local. A pending request survives a restart. Rounds rechecks the revision and remote URL itself; if they changed, it drops the request and asks again for the changed action. The user can approve or reject a request. A rejection stops the requested action, records the reason, and returns it to the requesting agent.

**Repository Task**:
A task assigned to one Bartender for work in one repository and an assigned checkout or worktree. Several repository tasks can target the same repository on separate worktrees. A repository task can be part of a cross-repository task.

**Task Record**:
The durable record of a task's scope, state, relationships, and results. When organization rules permit, the Router Workspace commits Task Records to the Root Repository's branch locally and pushes them only when the user asks. Otherwise, keep the detailed record in an approved local location, put only permitted metadata in the Root Repository, and show that the detail is not remotely backed up there. If unrelated changes exist, it asks before committing.

**Git Checkpoint**:
A Git-backed snapshot used for local recovery. It is separate from the branch history that holds Task Records. Its retention and restore behavior must protect durable records and unrelated work.

**Decision Record**:
A durable record of a task decision, including the decision, its reason, the responsible user or agent, its time, and its task. Records include routine agent decisions and approval outcomes. The log records decisions rather than private model reasoning.

**Task Group**:
A task's group in the Tasks section, derived from its durable state and whether the user has opened its result. Last Call holds approval requests, interruptions, failures that need attention, and unopened results. On Tap holds queued or running work and tasks waiting for dependencies. Served holds finished or cancelled tasks after the user opens their results. Show the actual task state on every task row. A group does not prove completion. Apply the existing Aged threshold as a filter to inactive Served tasks; do not age out pending work or user decisions.
**Task View**:
The planned Rounds area for task state and Decision Records. It is a Tasks section of the existing session window, like Starred, and links tasks to their session rows. Task decisions join Your Turn and the pill count. A task is one row and its agents are child rows. Reuse the existing Last Call, On Tap, and Served groups and their controls where they fit. Use the Task Group mapping above. Show the Bouncer, Bartender, and Barback chain as child rows and a short subtitle, with an accessible description of relationships and states. Animate only the running dots; motion must respect Reduce Motion. Decision Records open in a hover card (⌘I). The existing session list keeps its current flattened layout. Its initial task-specific actions are approving or rejecting requests; a rejection includes a reason. It does not accept instructions. This limit does not remove existing Rounds session actions. The user chose the shared Henry design and Linear restraint for the earlier web concept. The native design must reconcile that direction with [Rounds design](../../DESIGN.md), its state colors, and system controls. Support light and dark appearances and follow the system setting by default. Define task, approval, error, and accessible interaction states before implementation.

**Organization Boundary**:
A user-defined boundary that governs which organization context a task can load and where its information can be stored or sent. Apply these boundaries to Rounds alerts and ticket lookups for every session, including sessions outside the Router Workspace. Match registered repositories to organizations using directory or Git remote rules defined by the user. Keep alerts and ticket lookups local for unmatched or conflicting matches until the user classifies them. Remote transmission also requires permission under the applicable organization rules.
