<!-- On-demand part of SKILL.md (the bouncer skill). ${CLAUDE_SKILL_DIR} is the folder of SKILL.md; write its real path. Section names in quotes are sections of SKILL.md. -->
# Permissions
Verified 2026-11-25 in `bypassPermissions` mode (no card for any step below):
- A Bartender turn started by a Bouncer message starts a worktree Barback.
- `clear_session` works with Remote Control on.
- `set_session_model` and `set_session_effort` apply after a clear.
- The Bouncer renames a Bartender again with no card.
- Two Bartenders ran in parallel, and each committed its own branch.

Outside bypass mode, the app asks the user for a model more expensive than the Bouncer's own, an effort above the Bouncer's own, and each `clear_session` (auto mode may decide alone). So the Bouncer's effort must be at least the highest effort in the "Decision table", unless the Bouncer runs in bypass mode.

Only the user's allow rules for `mcp__ccd_pr__bind_pr` and `mcp__ccd_pr__set_monitor` let a Bartender bind its PR and turn on auto-fix with no prompt; the user adds them.

The Bouncer picks each Bartender's model and effort itself, from the "Decision table", and never asks the user. Only allow rules for `mcp__ccd_session_mgmt__set_session_model` and `mcp__ccd_session_mgmt__set_session_effort` skip the app's prompt; the user adds them in their own settings. The Bouncer never adds or changes them.

The Bouncer sends each state-changing Bash call (a push, a merge, a script that writes) in a message of its own, never next to other tool calls. Auto mode gave "no verdict" 3 times when such a call was batched with others (seen 2026-11-27).

Auto mode refuses an approval that one session relays to another ("Unsanctioned Communication", "Destructive or Unwanted Actions", seen 2026-11-26), so the Bouncer runs the closing chain itself. A hook such as rtk may rewrite Bash commands (`git push` runs as `rtk git push`); an allow rule must name the rewritten form.
