// Build with ROUNDS_TEST_HARNESS_WORKFLOW=1 scripts/build-harness-host.sh.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { isIPv4 } from "node:net";
import { setTimeout as delay } from "node:timers/promises";
import { mkdir, mkdtemp, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai/providers/faux";
import { createRegistry, Harness } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { dispatchContainers, taskDispatch } from "./harness-task-dispatch.mjs";

const done = { status: "done", changedLocations: ["result.txt"], validationOutcomes: ["File is present."], risks: [] };
const blocked = { status: "blocked", reason: "Choose the content.", options: ["Use these results"] };
const fakeModel = { provider: "faux", modelId: "faux-1" };
const git = (cwd, ...args) => execFileSync("/usr/bin/git", ["-C", cwd, ...args], {
    encoding: "utf8", env: { PATH: "/usr/bin:/bin", GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null",
        GIT_AUTHOR_NAME: "Probe", GIT_AUTHOR_EMAIL: "probe@example.invalid",
        GIT_COMMITTER_NAME: "Probe", GIT_COMMITTER_EMAIL: "probe@example.invalid" },
}).trim();

async function workflow(t) {
    const folder = await mkdtemp(join(await realpath(tmpdir()), "rounds-dispatch-"));
    const grants = new Map(), reports = new Map(), containers = new Map(), calls = [];
    const organizationID = randomUUID();
    const faux = fauxProvider();
    const models = createModels();
    models.setProvider(faux.provider);
    let harness, permission = true;
    t.after(async () => {
        await harness?.close(context);
        await rm(folder, { recursive: true, force: true });
    });
    function localFixture({ runID, enrollment }) {
        return {
            async call(name, args) {
                calls.push({ runID, name, args });
                if (name === "environment_create") containers.set(runID, { environment: "local-fixture", revision: enrollment.revision });
                assert.ok(containers.has(runID));
                return { content: [{ type: "text", text: "Fixture tool reply." }] };
            },
            async inspect() { return containers.get(runID); },
            async importResult(saved) { return { ref: "refs/remotes/container-use/local-fixture", revision: saved.revision }; },
        };
    }
    const path = process.env.ROUNDS_DISPATCH_TEST_ENGINE;
    const config = path ? JSON.parse(await readFile(path, "utf8")) : undefined;
    const runFolder = join(folder, "runs");
    await mkdir(runFolder, { mode: 0o700 });
    const containersForDispatch = config ? dispatchContainers({ ...config, folder: runFolder }) : {
        open: localFixture,
        async verifyInventory(records) { assert.equal(records.length, containers.size); },
    };
    async function open() {
        const dispatch = taskDispatch({
            containers: containersForDispatch,
            async verifyRecovery(records) {
                return records.every(record => grants.get(record.taskID)?.detailID === record.detailID);
            },
            async authorize(taskID, detailID) {
                const record = grants.get(taskID);
                if (!permission || record?.detailID !== detailID ||
                    (record.dependency && reports.get(record.dependency)?.report.status !== "done")) return;
                return record?.grant;
            },
            async saveResult(record, report) {
                const request = grants.get(record.taskID);
                assert.equal(request.detailID, record.detailID);
                reports.set(record.taskID, { record, report });
                request.detailID = randomUUID();
                return request.detailID;
            },
        });
        const registry = createRegistry();
        registry.install(dispatch.extension);
        harness = await Harness.open(await openNodeSqliteStorage(join(folder, "harness.sqlite")), { registry, models }, context);
        return dispatch;
    }
    async function add(name, dependency) {
        const source = join(folder, name);
        await mkdir(source);
        git(source, "init", "-q", "--template=", "--initial-branch=main");
        await writeFile(join(source, "input.txt"), `${name}\n`);
        git(source, "add", "input.txt");
        git(source, "commit", "-qm", "Fixture source");
        const revision = git(source, "rev-parse", "HEAD");
        await writeFile(join(source, "input.txt"), `Local ${name}\n`);
        const taskID = randomUUID(), detailID = randomUUID();
        grants.set(taskID, { detailID, dependency, grant: { enrollment: { repositoryID: randomUUID(), organizationID,
            source, revision }, model: fakeModel, instructions: `Work on ${name}.`, handoff: `Complete ${name}.` } });
        return { source, taskID, detailID, revision };
    }
    return { add, calls, reports, config, runFolder, faux, open, harness: () => harness, allow: value => { permission = value; } };
}

test("checks dependencies, resumes the same blocked run after reopen and accepts two repository results", { timeout: 120_000 }, async t => {
    const f = await workflow(t);
    const a = await f.add("first");
    const b = await f.add("second", a.taskID);
    let dispatch = await f.open();
    const start = (task, answer) => dispatch.start(f.harness(), { taskID: task.taskID, detailID: task.detailID, answer }, context);
    await assert.rejects(start(b), /permission/);
    f.allow(false);
    await assert.rejects(start(a), /permission/);
    f.allow(true);
    const write = contents => fauxAssistantMessage(fauxToolCall("environment_file_write", { target_file: "result.txt", contents }),
        { stopReason: "toolUse" });
    const report = expected => transcript => {
        const tool = transcript.messages.findLast(message => message.role === "toolResult");
        assert.equal(tool?.isError, false);
        if (expected === done && f.config) {
            const read = transcript.messages.findLast(message => message.role === "toolResult" && message.toolName === "environment_file_read");
            if (read) assert.match(read.content.map(block => block.text ?? "").join(""), /First result/);
        }
        if (expected !== done) return fauxAssistantMessage(JSON.stringify(expected));
        assert.equal(tool.toolName, "environment_verified_revision");
        const checkedRevision = tool.content.map(block => block.text ?? "").join("");
        assert.match(checkedRevision, /^[0-9a-f]{40}$/);
        return fauxAssistantMessage(JSON.stringify({ ...done, checkedRevision }));
    };
    const checkedRevision = () => fauxAssistantMessage(fauxToolCall("environment_verified_revision", {}), { stopReason: "toolUse" });
    const denied = [];
    if (f.config) {
        assert.ok(isIPv4(f.config.mirror));
        const command = `test -z \"\${DAGGER_SESSION_PORT-}\" && ! timeout 2 bash -c 'exec 3<>/dev/tcp/${f.config.mirror}/5000'`;
        denied.push(fauxAssistantMessage(fauxToolCall("environment_run_cmd", { command }), { stopReason: "toolUse" }));
    }
    f.faux.setResponses([write("First result"), ...denied, report(blocked),
        fauxAssistantMessage(fauxToolCall("environment_file_read", { target_file: "result.txt" }), { stopReason: "toolUse" }),
        checkedRevision(), report(done), write("Second result"), ...denied, checkedRevision(), report(done)]);
    const waiting = await start(a);
    assert.deepEqual(waiting.report, blocked);
    const before = f.reports.get(a.taskID).record;
    await f.harness().close(context);
    if (f.config) {
        const { docker, socket, policy } = f.config;
        const run = (...args) => execFileSync(docker, ["--host", `unix://${socket}`, ...args], { stdio: "pipe", timeout: 10_000 });
        const [engine] = JSON.parse(run("inspect", policy.container));
        assert.equal(engine.Id, policy.container);
        assert.equal(engine.Config.Labels["rounds.probe"], f.config.probe);
        assert.equal(engine.Path, "/bin/sh");
        assert.deepEqual(engine.Args, ["/rounds-egress.sh", "start", policy.worker]);
        assert.ok(engine.Mounts.some(mount => mount.Destination === "/rounds-owner" && mount.RW === false &&
            mount.Source === join(dirname(policy.startupScript), "owner")));
        run("restart", policy.container);
        assert.notEqual(run("inspect", "-f", "{{.State.StartedAt}}", policy.container).toString().trim(), engine.State.StartedAt);
        for (let attempt = 0;; attempt++) {
            try { run("exec", policy.container, "/bin/sh", "/rounds-egress.sh", "check", policy.worker); break; }
            catch (error) { if (attempt === 30) throw error; await delay(250); }
        }
    }
    dispatch = await f.open();
    assert.equal((await f.harness().inspect(context)).scheduling, "paused");
    if (f.config) {
        const unexpected = join(f.runFolder, ".unverified.lock");
        await mkdir(unexpected);
        await assert.rejects(start(a), /unverified runs or locks/);
        assert.equal((await f.harness().inspect(context)).scheduling, "paused");
        await rm(unexpected, { recursive: true });
    }
    await assert.rejects(start(a, "Old answer"), /cannot start/);
    await assert.rejects(start({ ...a, detailID: waiting.detailID }, "Unknown option"), /cannot start/);
    const first = await start({ ...a, detailID: waiting.detailID }, blocked.options[0]);
    const second = await start(b);
    assert.deepEqual(first.report, { ...done, checkedRevision: first.saved.revision });
    assert.deepEqual(second.report, { ...done, checkedRevision: second.saved.revision });
    const resumed = f.reports.get(a.taskID).record;
    assert.equal(resumed.runID, before.runID);
    assert.equal(resumed.conversationID, before.conversationID);
    assert.equal(first.saved.environment, waiting.saved.environment);
    assert.notEqual(f.reports.get(b.taskID).record.runID, before.runID);
    if (process.env.ROUNDS_DISPATCH_TEST_ENGINE) {
        for (const [task, accepted, text] of [[a, first, "First result"], [b, second, "Second result"]]) {
            assert.equal(git(task.source, "rev-parse", "HEAD"), task.revision);
            assert.equal(git(task.source, "rev-parse", accepted.imported.ref), accepted.saved.revision);
            assert.equal(git(task.source, "show", `${accepted.imported.ref}:result.txt`), text);
        }
    } else {
        assert.deepEqual(f.calls.map(call => call.name), ["environment_create", "environment_file_write", "environment_open",
            "environment_file_read", "environment_create", "environment_file_write"]);
    }
    for (const [task, name] of [[a, "first"], [b, "second"]]) {
        assert.equal(await readFile(join(task.source, "input.txt"), "utf8"), `Local ${name}\n`);
    }
});

test("records a malformed result as failed and dispatches the next task after database reopen", {
    timeout: 120_000, skip: !!process.env.ROUNDS_DISPATCH_TEST_ENGINE,
}, async t => {
    const f = await workflow(t);
    const a = await f.add("first"), b = await f.add("second");
    let dispatch = await f.open();
    f.faux.setResponses([fauxAssistantMessage(JSON.stringify({ ...blocked, options: ["One", "Two", "Three", "Four"] }))]);
    await assert.rejects(dispatch.start(f.harness(), a, context), /handoff contract/);
    assert.equal(f.reports.size, 0);
    await f.harness().close(context);
    dispatch = await f.open();
    assert.equal((await dispatch.review(f.harness(), context))[a.taskID].status, "failed");
    await assert.rejects(dispatch.start(f.harness(), { ...a, answer: blocked.options[0] }, context), /cannot start/);
    f.faux.setResponses([fauxAssistantMessage(JSON.stringify(blocked))]);
    assert.deepEqual((await dispatch.start(f.harness(), b, context)).report, blocked);
    assert.deepEqual(f.calls.map(call => call.name), ["environment_create", "environment_create"]);
});
