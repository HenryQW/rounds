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
  `state { name type }`, `assignee`, `updatedAt`, `archivedAt`; `organization { urlKey }` names the workspace, and
  `teams(first: 250) { nodes { key } }` gives its team keys.
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
2. Pull requests (Claude rows, `prs`, then the PR URLs of the first prompt). Linear: `attachmentsForURL` with the PR URL. GitHub: the PR's
   `closingIssuesReferences`.
3. The first user prompt, its first 64 KB only (Claude: the transcript's first user message; Codex: the first user
   message of the rollout file; pi: the session file's first prompt, which Rounds already reads). It finds:
   - Linear issue URLs `https://linear.app/<workspace>/issue/<ID>[/slug]` (the workspace in lower case);
   - GitHub issue URLs `https://github.com/<owner>/<repo>/issues/<n>`, with one `/` at the end or none;
   - GitHub PR URLs `https://github.com/<owner>/<repo>/pull/<n>`, with a subpath (`/files`) or a `/` at the end or
     none: the row adds `https://github.com/<owner>/<repo>/pull/<n>` to its PRs (once), so it shows the issues the PR
     links, not the PR;
   - `owner/repo#<n>`, a guess (owner `[A-Za-z0-9-]{1,39}`, repo `[A-Za-z0-9._-]{1,100}`, no leading zero), with no name
     character (`[A-Za-z0-9_./-]`) before it and no letter, digit or `_` after it; a URL is read first, so the
     fragment of an issue URL is not read again;
   - `#<n>` right after close, closes, closed, fix, fixes, fixed, resolve, resolves, resolved, issue, ref or refs (any
     case, a word of its own, then spaces or a colon): an issue of the repository of the session folder's `origin`
     remote (the `url` of `[remote "origin"]` in `config` of the common git folder; `git@github.com:`,
     `ssh://git@github.com/` or `https://github.com/`, with or without a user, only), a guess. No repository: no ref.
     "#12" alone, "color #fff" and "step #2" give nothing. A guess can also name a PR, so it shows "Loading…" until
     GitHub answers, then nothing when GitHub does not find the issue (a PR number, say), and nothing while `gh` is
     missing or signed out (an issue URL keeps "Not found" and the `gh` note);
   - bare Linear identifiers (`BBQ-123`; not a version such as `ios-1.57` or `v2-1.0`, and no leading zero, so
     `BBQ-0123` gives nothing; `BBQ-123.` at the end of a sentence counts), sent to `issue(id)`: only an identifier whose prefix is a team key of the
     workspace is looked up or shown (each Linear request also asks for the team keys; until they come, only the team
     keys of cached tickets count), and
     only an identifier that Linear finds counts, so `UTF-8` or `GPT-4` gives nothing.
   At most 20 candidates per prompt; a row takes its first 5 after the team filter and the repository of each guess. Scheme
   and host can be in any case.
   A match that ends at the 64 KB cut is dropped, as the cut can shorten it (`BBQ-12` from `BBQ-123`).
   URLs lose a trailing `.,;:!?)]>'"`, a query and a fragment; identifiers are upper case.

Rules:
- Only rows the window lists are looked up (older, done and hidden rows only while a search or the Aged filter shows
  them), so a launch with hundreds of old pi sessions sends no flood of requests.
- A child row shows only tickets that its parent does not show (a grandchild, which shows under the root, compares with its own parent and the root).
- pi and herdr rows follow the folder's current branch, not the branch the session started on (known limit, as the
  folder has no record of it).

## Data

- Linear key: a personal API key that the user pastes in Settings, kept in the Keychain (service
  `com.henryqw.rounds.linear`). Never in a file, a log or the cache.
- Requests: Linear, aliased queries, at most 20 lookups per request; GitHub, one `gh api graphql` per batch, aliased,
  with each alias's error read on its own. At most one request in flight per service.
- Cache: `~/Library/Application Support/Rounds/tickets.json` (0600): tickets by issue URL, and the lookups (branch, PR
  URL, identifier) that point to them or to "none". A ticket is fetched again after 10 minutes while its row is
  listed, and on hover after 1 minute. A "none" is kept for 1 day. A cache that does not decode is deleted; at launch,
  entries not fetched for 30 days are dropped.
- An issue moved to another team gets a new identifier; the row shows the identifier Linear sends now.

## Errors and limits

| Case | Result |
| --- | --- |
| No Linear key | Branch, PR and bare-identifier lookups for Linear do not run. Linear URLs from the prompt show the ID and the link; the card says "Add a Linear API key in Settings to see the title". |
| Key not valid (401) | Linear requests stop until the key changes. Settings shows "Key not valid". |
| Linear URL of another workspace (`urlKey` differs) | ID and link; the card says "Not in your Linear workspace". |
| Issue or PR not found (a PR URL that is not a github.com PR too) | ID and link; the card says "Not found". |
| GitHub organization blocks `gh` (SSO: `FORBIDDEN` or `saml_failure`) | ID and link; the card says "No access: authorize gh for this organization". |
| Error or bad value on one alias (null `data` with alias errors too) | Only that lookup has no data; it is asked again after 10 minutes. |
| Not found deeper than the alias's own field (a null item in a list) | The alias keeps the rest of its result; if it makes `data` null, as any error with null `data`, the lookups have no data and are asked again after 10 minutes. |
| More than 250 teams, or an archived team | Bare IDs of those teams do not show (`teams(first: 250)`, no paging). |
| Archived issue | Shown with its state; the card adds "Archived". |
| `gh` not installed or not signed in | GitHub tickets show the ID and link; Settings shows why, and checks `gh` again when it opens. |
| Host other than github.com | Not read (out of scope). |
| Rate limit (429, Linear `RATELIMITED` as the code or the type, in any case, on any error) | Wait until the reset time (Linear's `X-RateLimit-Requests-Reset`), else 60 s. |
| Offline | Keep cached data; try again after 30 s, doubling to 10 min. The card says "Updated 25 min ago". |
| Demo run | Fixed demo tickets, no network, no Keychain. |

Logs: the service, the request size and the result; never the key, branch names or titles.

## UI

- Mark (row, under the time, next to the PR mark, same caption font): a grey state symbol and the identifier
  (`BBQ-123`, `#812` for GitHub). Linear state types: `backlog` `circle.dotted`, `unstarted` `circle`, `started`
  `circle.lefthalf.filled`, `completed` `checkmark.circle`, `canceled` `xmark.circle`, `triage` `circle.dashed`; no data
  `circle`. GitHub: open `circle`, closed as completed `checkmark.circle`, closed as not planned or as a duplicate
  `xmark.circle`. Grey,
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
trailing punctuation, query and fragment, `/pull/` ignored, 20-candidate cap, 64 KB cap, the team filter and the
5-ref row cap); dedupe across the three
places; child rows drop the parent's tickets; Linear and `gh` response decoding, including partial `NOT_FOUND` and
another workspace; cache expiry and "none" lifetime. Then a live check: a Linear branch, a PR that closes a GitHub
issue, a first prompt with a Linear URL and a bare identifier, no key, a bad key, and offline.

## Out of scope

Writing to Linear or GitHub; tickets named only in later prompts or in tool calls; GitHub Enterprise; Linear workspaces
other than the key's.
