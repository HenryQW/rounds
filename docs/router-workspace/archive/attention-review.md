# Attention review

Goal: the user gives goals in the Bouncer conversation, makes decisions, and reviews results. Every other screen is monitoring, and the design must make it unnecessary. This review checks the selected design against that goal. The user decided every row on 2026-11-19; see Decided.

| Area | Selected design | Cost to attention | Proposal |
|---|---|---|---|
| Surface | A separate window with a sidebar: Sessions, Tasks, Decision Log | A second place to check. The pill does not count task decisions. | Put a Tasks section in the existing session window, like Starred. Task decisions join Your Turn and the pill count. |
| Board | Three columns with a card for each task | Repeats the existing tiles and needs a wide window | Use the existing tiles as filters. A task is a row; its agents are child rows, one level deeper than today. |
| Approval | A separate page for each protected action | One visit for each push | Open the request in place. Group the exact actions of one milestone into one request. Each action stays listed, and the guard checks each one. |
| Choice | Not in the task area | The user must notice the Bouncer question in Pi | Show a Choose row in Your Turn that opens the Bouncer session. |
| Result | Task detail page with activity and context | The user reads the activity to find the outcome | Show a result card: outcome, checks for each repository, risks. Mark as Reviewed moves the task to Served. |
| Decision log | A sortable top-level table | Audit data in the main navigation | Show decisions in a hover card on the task (⌘I), as Why This State does. Keep the full log in the task record. |
| Agent chart | An animated flow chart on board, detail, approval and recovery | Motion and space that ask for no action | Use child rows and a short chain in the subtitle. Animate only the running dots. |
| Interrupted approval | Stays visible as Interrupted until the user rechecks it | The user checks facts that Rounds can check | Withdraw the request and record it. The agent asks again after it resumes, as a new request. |
| Recovery | A page with an evidence timeline | The user reads evidence for facts that Rounds proved | Rounds rechecks agents and checkouts itself. Show one row only for a fact it cannot prove, with one safe action. |
| Backup note | A footer on every view | Banner blindness | Show it once in Settings > Workspace and on the setup row. |
| Root records | Commit at milestones; each push needs approval | One approval request for each push of records | Commit locally. Push the records only when the user asks; version one runs on one machine. |
| Setup | Settings page before first use | The user must find the page | Show a Set Up row in Your Turn when a task needs a missing approval. |

## Decided

- 2026-11-18: keep the pill and its layout. It counts all of Your Turn, task rows included.
- 2026-11-19: approved Surface, Board, Approval, Choice, Result, Decision log, Agent chart, Backup note, Root records and Setup as proposed. Approval groups the exact push and draft pull request actions of one result.
- 2026-11-19: Interrupted approval and Recovery are superseded by the [Bouncer review](bouncer-review.md). A pi-durable gate keeps a request parked across restarts, and Rounds rechecks the revision, remote URL, agents and checkouts itself.
