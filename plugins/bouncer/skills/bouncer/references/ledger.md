<!-- On-demand part of SKILL.md (the bouncer skill). ${CLAUDE_SKILL_DIR} is the folder of SKILL.md; write its real path. Section names in quotes are sections of SKILL.md. -->
# Ledger
The ledger keeps work that must be revisited in the ticket records, so it survives every clear and reset. There is no separate ledger file.
- Each open item is one line in the `LEDGER` section of its record: `- [open] <kind> | <key or URL> | trigger: <text> | check: <command> | next: <one-line next action> | <date>`. A settled item becomes `- [done]`.
- Add a line whenever work leaves something to revisit: `bouncer-ledger add <record> <kind> <key> "<trigger>" "<check>" "<next>"`.

  | Kind | Key | Trigger and check |
  |---|---|---|
  | `pr` | PR URL | Leave both empty: due when the PR merged or closed |
  | `held-message` | Ticket key | When to send it, and a command that exits 0 then. The draft text stays in the record |
  | `follow-up` | Ticket key | What it waits on, and a check if one exists |
  | `verify` | Ticket key | What to verify where (for example staging), and a check if one exists |

  A check exits 0 when due and 1 when not.
- Run `bouncer-ledger due` at Bouncer start and on each user turn. It prints only due items, each with its record path: read that one record, never all of them. Act on each due item through the "Decision table" (a held message still needs the user's yes to send), and `bouncer-ledger done <record> <key>` when it is settled. An `unsure` line: check it by hand.
- Run `bouncer-ledger stale --turn <record>=<last turn time>` (one `--turn` for each Bartender, from `list_sessions`) at Bouncer start. For a stale record, ask its Bartender to refresh it. Only when that Bartender is gone, a Haiku subagent rebuilds the record from that session's transcript. No routine model summaries.
- An item with no check is never due by itself: run `bouncer-ledger list` when the user asks what is open.
- The band shows the open count.
