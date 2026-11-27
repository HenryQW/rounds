<!-- On-demand part of SKILL.md (the bouncer skill). ${CLAUDE_SKILL_DIR} is the folder of SKILL.md; write its real path. Section names in quotes are sections of SKILL.md. -->
# Closing chain
The Bouncer runs each outward action of a ticket itself, from what the Bartender prepared, under the one grant from routing.
1. `bouncer-grants get <TICKET>`. Exit 1 (no grant): ask the user once for the whole chain, with the prepared actions as the pick, then `bouncer-grants add`.
2. Before each action, `bouncer-grants has <TICKET> <action>`. Exit 1: the action is outside the grant; stop and ask the user.
3. Run the actions in order, from the Bartender's worktree (the `cwd` of its session row) and the `DRAFTS` section of its ticket record:
   - `push`: `git -C <worktree> push -u origin <branch>`.
   - `pr`: `gh pr create --head <branch> --title "<### pr-title>" --body-file <file with the ### pr-body text>`. Then send the PR URL to the Bartender that owns the branch: it runs `mcp__ccd_pr__bind_pr` with the URL, then `mcp__ccd_pr__set_monitor` with `{"url": <url>, "auto_fix": true}`. The `ccd_pr` tools act on their own session only, so the Bouncer cannot set auto-fix for a Bartender. Auto-fix wakes the Bartender on a CI failure, a merge conflict or a review comment; it fixes on its branch and reports, and the Bouncer pushes.
   - `merge`: only when `gh pr checks <pr>` shows every check passed; pending checks: end the turn and continue on the next CI event or user turn.
   - `comment`, `status`, `link`, `close`, `message`: the tracker or messaging tool, with the draft text as it is.
4. Stop the chain and return to the user, in the question box, when a check fails, the scope or the acceptance criteria changed, an action is outside the grant, or a text the user approved changed. Send a failed check back to the Bartender first when it can fix it.
5. After the chain: `bouncer-grants done <TICKET>`, then report each action in one line (PR link, merge commit, comment link) and show any posted text in full. A PR left open (not merged yet) gets a ledger line.
