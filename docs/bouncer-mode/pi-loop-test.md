# Pi Bouncer claim loop: test report (2026-11-26)

This report records the tests of slices 2 to 6 of [the Pi Bouncer claim loop](pi-loop.md). A fixture test is a script test with temporary Git repositories and fake `gh` and `herdr` commands. The live test used a private repository and real Herdr panes.

## What was built

| Part | Where | Commit |
|---|---|---|
| `bouncer-reconcile`, `bouncer-dispatch`, `bouncer-record`, `bouncer-tick`, `bouncer_lib.py`, fixture tests | `henry` skill, `scripts/` | `0f2be59` in the skill repository |
| Skill text for the model items | `henry` skill, `pi-bouncer.md` | `0f2be59` |
| Extension: timer, wake, gate | `HenryQW/pi-harness`, `extensions/pi-herdr-tools/internal/bouncer.ts` | `562f328`, `b84a089` on `feat/bouncer-loop` |
| Design | `docs/bouncer-mode/pi-loop.md` | this branch |

An independent review of the scripts found 7 must-fix and 7 should-fix items. All 14 are fixed. The last one (a changed digest sent all current items again) is fixed in the extension: a wake now sends only the lines that the last accepted result did not have. For each must-fix item, a planted fault made its fixture test fail.

## Automatic checks

| Check | Result |
|---|---|
| `bash tests/bouncer-reconcile.sh` | 44 checks pass |
| `bash tests/bouncer-dispatch.sh` | 91 checks pass |
| `bash tests/bouncer-record.sh` | 53 checks pass |
| `bash tests/bouncer-tick.sh` | 58 checks pass |
| `pi-herdr-tools`: `pnpm run test` | 339 tests pass |
| `pi-herdr-tools`: `pnpm run typecheck`, root `docs:validate`, `check:package-versions` | pass |

## Live test

Setup: private repository `HenryQW/bouncer-probe-20261126` with the labels `bouncer:open` and `bouncer:claimed`, and two issues by the owner. Issue 1 asked for `HELLO.md`. Issue 2 asked the Bartender to ask which colour to write. The Bouncer and both Bartenders used `magpie/vps/claude/haiku-5.5`. The tick interval was 20 seconds and the cap was 2.

| # | Proof | Result | Evidence |
|---|---|---|---|
| 1 | The first tick claims and dispatches without a model turn | Pass | Marks `refs/bouncer/1` and `refs/bouncer/2`, branches `bouncer/1-add-a-hello-file` and `bouncer/2-pick-a-colour`, all at the remote `main` `323d447`. Both issues `bouncer:claimed`. |
| 2 | A turn end writes one status comment | Pass | Issue 1: `done` with commit `0257635`. Issue 2: `question`. |
| 3 | A Bartender turn end gives exactly one Bouncer turn | Pass | Before the restart, 4 wakes in the Bouncer session file, one for each new Bartender turn. The second wake held only the new `done` line, not the earlier question. |
| 4 | A question reaches the owner and the answer reaches the Bartender | Pass | The Bouncer asked with a Decide callout and did not guess. After the answer "green", the Bartender committed `fa0a2b7` and reported `done`. |
| 5 | A repeated report edits the one comment | Pass | Each issue has 1 comment. The issue 2 comment changed from `question` to `done`. |
| 6 | A push in the Bouncer shows a confirm with the exact command | Pass | Two confirms: `git ... push -u origin bouncer/1-add-a-hello-file` and `gh pr create ...`. After Yes, pull request 3 opened. |
| 7 | A push in a Bartender is blocked | Pass | `git push origin HEAD` and `gh pr list` both stopped by the gate. |
| 8 | No wake while nothing changes | Pass, 6 minutes | 0 wakes in 6 minutes. Process samples showed ticks running (20 of 90 samples). |
| 9 | A Bouncer restart starts no second Bartender | Pass | Refs, branches and worktrees did not change after a restart. |
| 10 | Cost below US$2 | Pass | US$0.17 in total: Bouncer US$0.096, Bartenders US$0.044 and US$0.030. |

## Findings

- A restart sends all current items one time. The in-memory record of sent lines is lost, so the restarted Bouncer asked again about the issue 2 push that the owner had refused. An owner answer lives only in the conversation. A fix needs a durable record, for example a label or a line in the status comment.
- Herdr showed the Bouncer as `done` while the gate confirm was open. A script or a Rounds row that reads the Herdr status does not see a pending confirm.
- Bartenders wrote an untracked `.context/` folder in their worktrees (from the global agent rules). The Bouncer kept it out of each commit.

## Not verified

- One idle hour: the test covered 6 minutes.
- The `labels` write level (no comment) on a live `SleekFlow` repository. Only the fixture test covers it.
- A Herdr server restart, a Mac restart, and a crash of a Bartender during a turn.
- Two Bouncers on two Macs. The design allows one Bouncer.
- Rounds rows for Pi Bartenders. A Bartender is a top-level row, not a subagent.

## Cleanup

The Bouncer and both Bartenders stopped. Their Herdr workspaces, the worktrees, the test clone and the live `bouncer.json` are removed. The owner deleted the test repository on 2026-11-26. It now returns HTTP 404.
