# Tickets: Linear issues and GitHub issues on session rows

Status: design, for review (2026-11-04).

## Goal

See which ticket each session works on, and the ticket's state, without leaving Rounds. A ticket is a Linear issue or a
GitHub issue. Pull requests get the same hover card.

Success: a session on a Linear branch, a session whose PR closes a GitHub issue, and a session whose first prompt names
a ticket each show the right ticket; nothing shows a guessed ticket; a click opens the ticket in the default browser.

## Facts this design uses (checked 2026-11-04)

- Linear GraphQL (`https://api.linear.app/graphql`, live schema): `issueVcsBranchSearch(branchName)` returns the Issue
  that Linear links to a branch name; `attachmentsForURL(url)` returns attachments, each with its `issue`, so a PR URL
  gives the Linear issues linked to it; `issue(id)` takes an identifier; Issue has `identifier`, `title`, `url`,
  `state { name type }`, `assignee`, `updatedAt`, `archivedAt`; `organization { urlKey }` names the workspace.
  Not checked yet (needs a key): whether a branch with no issue gives null or an error. Both mean "no issue".
- GitHub GraphQL through `gh api graphql` (the user's `gh` login): `pullRequest.closingIssuesReferences` gives each
  closed issue's `number`, `title`, `state`, `stateReason`, `url` and repository, also in another repository. A missing
  object gives a `NOT_FOUND` error for that field only, and `gh` exits 1 while the other data is good.

## Discovery (local; no prompt text leaves the Mac)

Each row gets tickets from three places, in this order. A ticket found twice shows once (same issue URL).

1. Branch. Claude: the session file's `branch`. Codex: the thread's branch. pi and herdr: `HEAD` of the session folder
   (`.git/HEAD`; in a worktree, `.git` is a file that names the git folder). No branch for a detached `HEAD`, or for
   `main`, `master`, `develop`, `trunk`, or the branch `refs/remotes/origin/HEAD` names. Linear: `issueVcsBranchSearch`.
   GitHub issues are not read from branch names: a leading number (`2024-cleanup`) is a guess.
2. Pull requests (Claude rows, `prs`). Linear: `attachmentsForURL` with the PR URL. GitHub: the PR's
   `closingIssuesReferences`.
3. The first user prompt, its first 64 KB only (Claude: the transcript's first user message; Codex: the first user
   message of the rollout file; pi: the session file's first prompt, which Rounds already reads). It finds:
   - Linear issue URLs `https://linear.app/<workspace>/issue/<ID>[/slug]`;
   - GitHub issue URLs `https://github.com/<owner>/<repo>/issues/<n>` (not `/pull/`, which is a PR);
   - bare Linear identifiers (`BBQ-123`), sent to `issue(id)`: only an identifier that Linear finds counts, so
     `UTF-8` or `GPT-4` gives nothing. At most 5 candidates per prompt.
   URLs lose a trailing `.,;:!?)]>'"`, a query and a fragment; identifiers are upper case. Short GitHub refs (`#123`)
   are not read: the repository is not certain.

Rules:
- Only rows the window lists are looked up (the Older group and hidden rows only when shown or hovered), so a launch
  with hundreds of old pi sessions sends no flood of requests.
- A child row shows only tickets that its parent does not show.
- pi and herdr rows follow the folder's current branch, not the branch the session started on (known limit, as the
  folder has no record of it).

## Data

- Linear key: a personal API key that the user pastes in Settings, kept in the Keychain (service
  `com.henryqw.rounds.linear`). Never in a file, a log or the cache.
- Requests: Linear, aliased queries, at most 20 lookups per request; GitHub, one `gh api graphql` per batch, aliased,
  with each alias's error read on its own. At most one request in flight per service.
- Cache: `~/Library/Application Support/Rounds/tickets.json` (0600): tickets by issue URL, and the lookups (branch, PR
  URL, identifier) that point to them or to "none". A ticket is fetched again after 10 minutes while its row is
  listed, and on hover after 1 minute. A "none" is kept for 1 day. A cache that does not decode is deleted.
- An issue moved to another team gets a new identifier; the row shows the identifier Linear sends now.

## Errors and limits

| Case | Result |
| --- | --- |
| No Linear key | Branch, PR and bare-identifier lookups for Linear do not run. Linear URLs from the prompt show the ID and the link; the card says "Add a Linear API key in Settings to see the title". |
| Key not valid (401) | Linear requests stop until the key changes. Settings shows "Key not valid". |
| Linear URL of another workspace (`urlKey` differs) | ID and link; the card says "Not in your Linear workspace". |
| Issue not found or no access | ID and link; the card says "Not found". |
| Archived issue | Shown with its state; the card adds "Archived". |
| `gh` not installed, not signed in, or blocked by SSO | GitHub tickets show the ID and link; Settings shows why. |
| Host other than github.com | Not read (out of scope). |
| Rate limit (429, Linear `RATELIMITED`) | Wait until the reset time (Linear's `X-RateLimit-Requests-Reset`), else 60 s. |
| Offline | Keep cached data; try again after 30 s, doubling to 10 min. The card says "Updated 25 min ago". |
| Demo run | Fixed demo tickets, no network, no Keychain. |

Logs: the service, the request size and the result; never the key, branch names or titles.

## UI

- Mark (row, under the time, next to the PR mark, same caption font): a grey state symbol and the identifier
  (`BBQ-123`, `#812` for GitHub). Linear state types: `backlog` `circle.dotted`, `unstarted` `circle`, `started`
  `circle.lefthalf.filled`, `completed` `checkmark.circle`, `canceled` `xmark.circle`, `triage` `circle.dashed`; no data
  `circle`. GitHub: open `circle`, closed as completed `checkmark.circle`, closed as not planned `xmark.circle`. Grey,
  because orange and blue mean Needs input and Working; white on a selected row. More than one: the first ticket and a
  count (`BBQ-123 +1`). The title gives way first when the row is narrow; the identifier is not cut.
- Click: one ticket opens in the default browser; more than one, a menu with "Open BBQ-123" per ticket. The right-click
  menu adds the same items. The mark has the grey hover fill.
- Card: after 0.6 s on a ticket or PR mark; it stays while the pointer is on the mark or the card and closes 0.2 s after
  it leaves both, or when the window slides away. It never takes focus (the window is a non-activating panel). Per
  ticket: identifier and service ("BBQ-123 · Linear", "owner/repo#812 · GitHub"), title (up to 2 lines), state name, assignee or author, update
  time; at most 3 tickets, then "and 2 more". A click on a ticket opens it. A PR card has the same layout ("#42 ·
  GitHub", Open, Merged or Closed, author).
- Search also matches ticket identifiers and titles.
- Settings > Sources, a Tickets section: "Linear API key" (secure field) with "Connected: <workspace>", "Key not
  valid" or "Offline", and Remove Key; "GitHub" with "Uses gh, signed in as <user>", "gh not found" or "gh not signed
  in".

## Privacy

Sent to Linear: branch names, PR URLs and identifiers. Sent to GitHub (through `gh`): repository names and PR and issue
numbers. Never prompt text. A local ad-hoc build has a new code identity each time, so the Keychain may ask again after
a rebuild; signed releases keep one identity.

## Tests (RoundsCore)

Default and detached branches give no lookup; `.git` file worktrees resolve `HEAD`; prompt scanning (URL forms,
trailing punctuation, query and fragment, `/pull/` ignored, 5-candidate cap, 64 KB cap); dedupe across the three
places; child rows drop the parent's tickets; Linear and `gh` response decoding, including partial `NOT_FOUND` and
another workspace; cache expiry and "none" lifetime. Then a live check: a Linear branch, a PR that closes a GitHub
issue, a first prompt with a Linear URL and a bare identifier, no key, a bad key, and offline.

## Out of scope

Writing to Linear or GitHub; tickets named only in later prompts or in tool calls; GitHub Enterprise; Linear workspaces
other than the key's.
