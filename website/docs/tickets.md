---
title: Tickets
description: "How a row shows the Linear or GitHub issue of its session, and what Rounds needs to read them."
---

A row shows the ticket its session works on: a Linear issue or a GitHub issue, with its ID and a symbol for its state under the time. Hold the pointer on the ticket or the PR number to see the title, the state and who has it. A click opens it in your browser.

Rounds finds a ticket on the Mac, from three places: the session's branch, the pull requests of a Claude session, and the first prompt: a Linear or GitHub issue link, a GitHub pull request link (the row shows the issues the pull request links), `owner/repo#123` or `#123` after a word such as "fixes" or "issue" (an issue of the repository of the folder's `origin` remote; these two show only when GitHub finds the issue, so they need `gh`), or a Linear ID such as `BBQ-123`.

- Linear: in Settings, on the Tickets page, click Connect… in the Linear row and paste a personal API key. Make it in Linear under Settings, Account, Security and access. Read permission is enough; a key for some teams only shows the issues of other teams as not found. The key stays in your Keychain. Without a key, a Linear link in the prompt shows its ID only.
- Keychain approval. After the first update that adds the Linear helper, macOS can ask for your login password. Choose **Always Allow** to keep the approval across ordinary updates. Use **Try Again** in Tickets if you denied access.
- GitHub: Rounds uses the [gh](https://cli.github.com) command line tool and its sign-in. Install it with Homebrew and run `gh auth login`.

In Settings > Organizations, add an organization and move each project to it. Click Review Permissions… and allow Linear or GitHub for that organization. Rounds keeps unknown and conflicting projects local. A new or changed destination needs permission again.

Privacy: after these checks, only branch names, pull request links, repository names and ticket IDs leave the Mac, to Linear and to GitHub. Rounds never sends prompt text.
