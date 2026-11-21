# 02 Node Harness host

## Goal

Rounds starts and stops one Node Host that runs a pi-durable Harness. The Bouncer moves into it, and it is ready to hold Bartenders and Barbacks.

## State

Brief, 2026-11-20. No open owner decision.

## Depends

Slice 01: the `BouncerAdapter` protocol and the Bouncer Window.

## Builds

- Rounds starts and stops one Node process with pi-durable built from source at the pinned pi commit `5a14e69c067d40dfbff4f2fff7d3b34c897e2dc9`.
- SQLite storage in an approved folder.
- Magpie models.
- The pinned container-use wrapper: a small stdio MCP server with 12 tools, without `environment_checkpoint`, and with `environment_source` pinned to the task repository.
- The Bouncer as a Harness conversation with no tools, and a Rounds protocol between the Bouncer Window and the Node Host: messages, text deltas, tool steps, questions and answers, model list, stop. A durable adapter replaces `PiRPCBouncer`, which this slice deletes with its tests.
- On start, Rounds kills any leftover MCP process group before `resume()`. After a `kill -9` during a tool, the orphaned `container-use stdio` child finished the command.

## Decided

- Decisions "Bouncer on pi-durable", "pi-durable Harness for Bartenders and Barbacks", "Build on unreleased pi-durable" and "Option 3: container-use for all agent work" ([decisions.md](../decisions.md)).
- Build pi-durable in a folder with no symbolic link in its path. Under `/tmp` (a link to `/private/tmp`) TypeScript loads the same file twice and `harness.ts(202,49)` fails with TS2322.
- Preview packages at `pkg.earendil.com` need a login (HTTP 401), so Rounds cannot use them.
- The new database format cannot go back to 1.5.2, so keep no data from earlier probes.
- Evidence for this brief: the pi-durable probe results in [archive/reuse-review.md](../archive/reuse-review.md#pi-durable-checked-2026-11-18), and the container-use, Dagger and egress rows in [archive/feasibility-check.md](../archive/feasibility-check.md).

## Open

- Magpie models that do not use `openAICompletionsApi` were not tested in the Harness. Resolve the selected model and protocol at launch.
- A `kill -9` during a model request sends the request again on resume, so the provider can bill it twice.
- The shared engine version must match the container-use release. Nesting still lets code in a container start normal containers on that engine.
- Choose the one egress allowlist for version one. An allowed domain can still receive data from the container. The proxy address must be an IP address, because the engine DNS does not resolve Docker aliases.
- Check whether secret references in a repository's `.container-use/environment.json` resolve on the host when an environment starts from an agent branch.
- Verify the identity of a process before Rounds signals it. A detached descendant can escape process-group cleanup.
- After a restart, reconcile run identity, process state, checkout ownership and local-only records before work resumes.
