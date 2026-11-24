# Bouncer mode reuse review

This review records candidates for the planned Bouncer mode in Rounds. The user chose Rounds as the product home. It does not select an isolation or approval mechanism.

| Need | Existing resource | Finding | Open check |
|---|---|---|---|
| Shared guidance and model routing | [Magpie](https://github.com/yetone/magpie) | Its Library distributes instructions, skills, servers, and subagents. It also routes models. Pi already reads the shared instruction source through `SYSTEM.md`. | Check how a worker receives only the organization guidance for its task. |
| Agent dispatch | `acp_delegate` and [pi-task-models](https://github.com/HenryQW/pi-harness/tree/main/extensions/pi-task-models) | Delegate runs support nested workers and explicit model routes. In the locally installed `billion-context` 0.1.215, the runtime inherits its parent environment, its live run registry is process-local, and it places run output under the system temporary directory. | Test recovery and isolation with the actual delegate runtime. Verify the locations of session transcripts, output, logs, and temporary files against organization storage rules before dispatch. Check whether these locations can be configured. |
| Isolation | [pi-sandbox](https://pi.dev/packages/pi-sandbox) | Its documentation says it sandboxes Bash and intercepts Pi file tools. Its permissions use interactive widgets and its parent and subagent allowances are separate. Its documented commands can also disable sandboxing. | Check the actual delegate's headless behavior, whether it can disable the sandbox, other tools and extensions, credentials, and direct approval relay. Do not assume Bash sandboxing covers the whole agent. |
| Isolation | [pi-gear](https://github.com/ackneal/pi-gear) | Its documentation says Bash fails closed when sandbox initialization fails and outside-workspace file access is denied in headless sessions. Its Bash can inherit host environment credentials; its own subagents share the host process. | Check whether its guarded tools can be reused with `acp_delegate`, an isolated environment, and the required approval boundary. |
| Isolation | [agents-sandbox](https://github.com/inoio/agents-sandbox) | It supports Pi in a virtual machine, network policy, and host-side secret injection. Its default convenience setup can copy host agent settings into the guest. The project describes its Pi profile as experimental. | Verify non-interactive delegate compatibility, credentials, writable mounts, and protected-action enforcement. |
| Isolation | [lilbox](https://github.com/0xfe/lilbox) | It wraps commands in operating-system sandboxes on macOS and Linux. Its default profile permits network access; its isolated profile denies it. | Verify Pi and delegate compatibility, model access, and protected-action enforcement. |
| Durable approvals | [Open Multi-Agent](https://github.com/open-multi-agent/open-multi-agent/blob/main/docs/durable-approvals.md) | Its durable tool-call approval supports its built-in workers. The documentation excludes process and Agent Client Protocol backends from tool-call suspension. | Do not assume it can suspend an `acp_delegate` tool call. Check whether another integration meets the approval boundary. |
| Task records | [Backlog.md](https://github.com/MrLesk/Backlog.md) | Its documentation describes local Markdown tasks, acceptance criteria, milestones, and dependencies in a Git repository. | Check programmatic integration, concurrent writers, custom metadata, and Git controls against the router requirements. |
| Task records | [tick-md](https://github.com/Purple-Horizons/tick-md) | Its documentation describes Git-backed Markdown, dependency tracking, and a cross-process write lock. Its documented default commits every change. | Test actual concurrency and crash behavior. Disable or adapt automatic commits to meet the approved milestone and unrelated-change rules. |
| Task records | Git | The user chose Git for the root repository and durable records. | Define how local state, commits, and recovery relate. |
| Checkpoints | [pi-rewind](https://github.com/arpagon/pi-rewind) | The installed 0.5.0 creates snapshots under `refs/pi-checkpoints`, prunes old session refs on startup, and restores with `git reset --hard`. Checkpoint failures are non-fatal. | Check whether its Git snapshot code can be reused with router-owned retention, explicit failure handling, and safe recovery. Its checkpoints are separate from branch history. |
| Product and task view | [Rounds](https://github.com/HenryQW/rounds) | Its macOS app shows live agent sessions, project groups, and `acp_delegate` children. It flattens nested children under the root, and finished delegate runs leave its live list. A hook logs some observed approvals. Configured notification channels can send session metadata. | Reuse the app and review existing behavior against the router design. Durable task records, complete decision history, approval controls, and the execution guard remain separate needs. Check direct approval alerts and organization rules for notifications. |
| Flow animation | [Magpie routing animation](https://github.com/yetone/magpie/issues/302) | Magpie stopped queuing animations while its window is hidden. On return it limits animation to four active requests and does not replay finished ones. | Check whether a native Rounds flow can reuse this behavior. Motion must not imply that an unverified agent is running. |
| Task view | [mdboard](https://github.com/Patrik-Stas/mdboard) | Its documentation describes a local web board backed by Markdown task files. It exposes task editing, movement, and deletion. | Check whether the board can be adapted to the Bouncer mode record format and limited to the approved actions. |
| Approval interface | [Agent Inbox](https://github.com/Zijian-Ni/agent-inbox) | Its documentation describes a local approval interface and append-only decision log. It explicitly says its approval gate is cooperative and has no authentication. | Test delegate integration, rejection reasons, local access controls, and the required independent execution guard. |

### tick-md implementation check

At [revision `031e815`](https://github.com/Purple-Horizons/tick-md/tree/031e81550d82a93de17ce977f5b61358bc5d09ef), the command-line lock treats a lock as stale after 60 seconds even when its owner is alive. The completion command writes the task file directly and does not check the task's own dependencies. Invalid configuration restores automatic commits. Its task model has dependency IDs but no parent field. These behaviors need changes before use for Bouncer mode records. Concurrency and crash behavior were not tested.

### Backlog.md implementation check

At [revision `53f8ffe`](https://github.com/MrLesk/Backlog.md/tree/53f8ffe7150e521a3002326f213f3611b11192b3), existing task records are rewritten in place. Automatic commits default to off, but callers can override that choice. Serialization preserves unknown frontmatter. Crash recovery, concurrent writers, and restricted local details were not tested. Rounds needs to verify these controls before adopting it.

### Rounds evidence

- Its [Pi tracker](https://github.com/HenryQW/rounds/blob/e3bf1a955c4c641b7410c93832c51ff6f6c200de/Sources/RoundsCore/Pi.swift#L32-L43) finds live delegate parents. Its [app model](https://github.com/HenryQW/rounds/blob/e3bf1a955c4c641b7410c93832c51ff6f6c200de/Sources/Rounds/AppModel.swift#L263-L277) removes ended delegates.
- Its [grouping](https://github.com/HenryQW/rounds/blob/e3bf1a955c4c641b7410c93832c51ff6f6c200de/Sources/RoundsCore/Grouping.swift#L158-L182) excludes subagents from attention by default. It [flattens children under the root](https://github.com/HenryQW/rounds/blob/e3bf1a955c4c641b7410c93832c51ff6f6c200de/Sources/RoundsCore/Grouping.swift#L213-L225).
- Its [notification specification](https://github.com/HenryQW/rounds/blob/e3bf1a955c4c641b7410c93832c51ff6f6c200de/docs/spec.md#L175-L183) describes metadata sent to configured channels. Its [package](https://github.com/HenryQW/rounds/blob/e3bf1a955c4c641b7410c93832c51ff6f6c200de/Package.swift#L1-L15) targets macOS.

A network allowlist or hidden credential alone does not establish the required approval boundary. Verify the complete execution path against the [authority decision](../decisions/authority.md) before choosing a mechanism.

## Orchestration for option 3 (2026-11-18)

Option 3 needs Rounds to start each Bartender as a Pi process with container-use tools only.

| Candidate | Finding | Fit |
|---|---|---|
| `acp_delegate` (billion-context) | Roles are a fixed table. Role config sets only model and thinking level. Only restricted roles get `--tools`, and every child gets the delegate tools, inherited environment, and system-temp outputs. | Does not fit. It cannot start a container-use-only Bartender, and a Bartender started with `--no-extensions` has no `acp_delegate`. |
| Pi RPC mode (`pi --mode rpc`) | JSONL over stdin and stdout: `prompt`, `steer`, `follow_up`, `abort`, `get_state`, session events, and extension dialogs (`select`, `confirm`) relayed to the client. Normal CLI flags select model, tools and session. | Fits. Rounds drives each Bartender and Barback directly, with progress, cancel and resume. |
| [vibe-kanban](https://github.com/BloopAI/vibe-kanban) | 28.7k stars, Apache-2.0. Worktree per task, agents run without a sandbox. Listed agents do not include Pi. Search results report a 2026 shutdown announcement. | Does not fit. It duplicates the Rounds task view and adds no isolation. |
| [agentbox](https://github.com/rlaope/agentbox), [gluon-agent](https://github.com/carrotly-ai/gluon-agent), [choragos](https://github.com/sphragis-oss/choragos), [squad](https://github.com/lobs-ai/squad) | 0 to 11 stars. agentbox was created and last pushed on 2026-07-04. | Too young to trust as a dependency. agentbox's egress-proxy design matches ours and is a reference only. |

### pi-durable (checked 2026-11-18)

[`@earendil-works/pi-durable`](https://github.com/earendil-works/pi/tree/ff8721f178fbb5c7ed560ed5c6ba254c5ed425e4/packages/durable) 1.5.2, MIT, marked experimental: "The API changes without notice between releases." It is a TypeScript library, not part of the `pi` CLI 1.5.2 install, so Pi RPC does not use it.

| Need | pi-durable feature |
|---|---|
| Recovery | Every turn, tool call and task commits to SQLite or JSONL before it shows. `resume()` continues unfinished runs; `requestId` stops a double submit. |
| Approval | A `beforeTool` hook parks the call on a signal until a person answers, with a deadline. Every wake runs the gates again, and the approval binds to the call arguments. |
| Barbacks | A tool creates a child conversation owned by its task. Aborting the parent aborts the child. |
| Task view | `watchTaskGraph()` streams every live task with owner and status. |
| Containers | `env` builds the execution environment per conversation, so one container per conversation is possible. |
| Tool limits | `callers` and `modelTools` decide which tools the model sees. |

Probe on 2026-11-19 (throwaway scripts, not kept):

| Check | Result |
|---|---|
| Magpie model | Pass. `magpie/fast` answered through `createProvider` with `openAICompletionsApi`. Magpie models that use other APIs were not tested. |
| container-use tools | Pass. A small stdio MCP wrapper offers 12 tools, leaves out `environment_checkpoint` and pins `environment_source`. `@earendil-works/pi-mcp` is only a client; the durable MCP bridge exists only inside `apps/p2`. |
| Gate and `kill -9` | Pass. The parked `environment_run_cmd` stayed parked after restart, did not run, ran once after the signal, and a second signal returned `closed`. |
| `kill -9` during a model request | The request is sent again on resume, so the provider can bill it twice. |
| `kill -9` during a tool | The tool is not run again; the transcript says it was interrupted. **The orphaned `container-use stdio` child finished the command.** Rounds must kill the MCP process group before resume. |
| Barback abort | Pass. Aborting the parent aborted the child and cancelled its container command. |

Limits: signals (`defineSignal`) are not in the npm 1.5.2 release, so the gate and abort checks ran from source at `ff8721f`. The `tsc` build of that source fails (`harness.ts(202,49): error TS2322`). Rounds must wait for a release with signals or pin a source build.
