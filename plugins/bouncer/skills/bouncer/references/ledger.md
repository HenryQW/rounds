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
- An item with no check is never due by itself: run `bouncer-ledger list` when the user asks what is open.
- The band shows the open count.
