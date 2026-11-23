import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { mkdir, mkdtemp, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { setTimeout as sleep } from "node:timers/promises";
import { containerUse } from "../Resources/harness-container-use.mjs";

const engine = `docker-container://${"a".repeat(64)}`;
const generation = "2026-11-23T00:00:00Z";
const revision = "a".repeat(40);
const environment = "quiet-panda";
const textResult = (text, isError) => ({ content: [{ type: "text", text }], ...(isError ? { isError } : {}) });

// The fixture is an executable with the pinned server's message sequence and result shape.
const fake = String.raw`
import { appendFileSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";

const log = fileURLToPath(new URL("events", import.meta.url));
const [mode, version, name] = readFileSync(new URL("mode", import.meta.url), "utf8").split("\n");
function record(event, fields = {}) {
    appendFileSync(log, JSON.stringify({ event, pid: process.pid, ...fields }) + "\n");
}
function reply(id, result) {
    process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}
function result(id, text, isError) {
    reply(id, { content: [{ type: "text", text }], ...(isError ? { isError: true } : {}) });
}
record("start", { env: process.env, args: process.argv.slice(2), cwd: process.cwd() });
process.on("exit", code => record("exit", { code }));
process.on("SIGTERM", () => {
    record("term");
    if (mode !== "hang") process.exit(0);
});
const input = createInterface({ input: process.stdin });
input.on("close", () => {
    record("stdin-close");
    if (mode === "hang") setInterval(() => {}, 1000);
});
input.on("line", line => {
    const request = JSON.parse(line);
    record("request", { request });
    if (request.method === "initialize") {
        const init = JSON.stringify({ jsonrpc: "2.0", id: request.id, result: {
            protocolVersion: mode === "version" ? "2025-06-18" : "2024-11-05",
            capabilities: { tools: { listChanged: true } },
            serverInfo: { name, version },
        } });
        process.stdout.write(init.slice(0, 20));
        setTimeout(() => process.stdout.write(init.slice(20) + "\n"), 10);
        return;
    }
    if (request.method !== "tools/call") return;
    const { id } = request;
    switch (mode) {
    case "hang": return;
    case "bad-id": return result(id, JSON.stringify({ id: "../../another-run" }));
    case "dirty-create": return result(id, JSON.stringify({ id: "quiet-panda" }) + "\n\nCRITICAL: dirty source");
    case "tool-error": return result(id, "tool ran and returned an error", true);
    case "unexpected": return reply(id + 1, { private: "unexpected server data" });
    case "rpc-error":
        process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32603, message: "private error" } }) + "\n");
        return;
    case "invalid-result": return reply(id, { content: [{ type: "image", data: "opaque" }] });
    case "partial":
        process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: "ok" }] } }));
        process.exitCode = 0;
        input.close();
        process.stdin.destroy();
        return;
    case "oversize": return process.stdout.write("界".repeat(400_000));
    case "invalid-utf8": return process.stdout.write(Buffer.from([0xff, 0x0a]));
    case "extra":
        result(id, "done");
        return result(id, "unsolicited duplicate");
    case "bad-exit":
        result(id, "done");
        process.exitCode = 9;
        return;
    default:
        if (request.params.name === "environment_create") return result(id, JSON.stringify({ id: "quiet-panda", title: "fixture" }));
        return result(id, "done 🧪");
    }
});
`;

async function fixture(t) {
    const root = await realpath(await mkdtemp(join(tmpdir(), "rounds-container-transport-")));
    t.after(() => rm(root, { recursive: true, force: true }));
    const binary = join(root, "container-use.mjs");
    const home = join(root, "home");
    const checkout = join(root, "checkout");
    const daggerCLI = join(root, "dagger");
    const docker = join(root, "docker");
    const socket = join(root, "docker.sock");
    const events = join(root, "events");
    const mode = (value, version = "1.0.0", name = "Dagger") =>
        writeFile(join(root, "mode"), [value, version, name].join("\n"));
    await Promise.all([
        mkdir(home, { mode: 0o700 }), mkdir(checkout, { mode: 0o700 }),
        writeFile(binary, `#!${await realpath(process.execPath)}\n${fake}`, { mode: 0o700 }),
        writeFile(daggerCLI, "fixture executable\n", { mode: 0o700 }),
        writeFile(docker, "fixture executable\n", { mode: 0o700 }), writeFile(events, ""), mode("ok"),
    ]);
    const log = () => readFileSync(events, "utf8").trim().split("\n").filter(Boolean).map(line => JSON.parse(line));
    const count = { admitted: 0, verified: 0, readback: 0 };
    const state = { environment: undefined, refuse: false, rejectReadback: false };
    let locked = false;
    const run = {
        async create(invoke, prepare) {
            return withRun(async () => {
                const result = await invoke({ checkout, home, revision }, await prepare());
                assert.deepEqual(Object.keys(result).sort(), ["environment", "value"]);
                state.environment = result.environment;
                count.readback++;
                return result.value;
            });
        },
        async use(invoke, prepare) {
            return withRun(async () => {
                const value = await invoke({ checkout, home, revision, environment: state.environment }, await prepare());
                count.readback++;
                if (state.rejectReadback) throw new Error("Fixture readback refused");
                return value;
            });
        },
    };
    async function withRun(invoke) {
        assert.equal(locked, false);
        count.admitted++;
        if (state.refuse) throw new Error("Fixture admission refused");
        locked = true;
        const before = log().length;
        try {
            return await invoke();
        } finally {
            for (const { pid } of log().slice(before).filter(event => event.event === "start")) {
                assert.throws(() => process.kill(pid, 0), { code: "ESRCH" }, "child survived the run lock");
            }
            locked = false;
        }
    }
    const options = { binary, daggerCLI, docker, socket, engine, run, async verifyEngine(uri, request) {
        assert.equal(locked, true);
        assert.equal(uri, engine);
        assert.equal(request.docker, docker);
        assert.equal(request.socket, socket);
        count.verified++;
        return generation;
    } };
    return { options, invoke: containerUse(options), mode, state, count, log, home, checkout, root };
}

function contaminateEnvironment(t) {
    const ambient = {
        PATH: "/agent/bin", TMPDIR: "/agent/tmp", XDG_CONFIG_HOME: "/agent/config", GIT_DIR: "/agent/repo/.git",
        GIT_CONFIG_COUNT: "123", GIT_CONFIG_KEY_3: "custody", GIT_SSH_COMMAND: "fake", SSH_AUTH_SOCK: "fake",
        HTTPS_PROXY: "fake", http_proxy: "fake", DOCKER_HOST: "fake", DOCKER_CONFIG: "fake", GITHUB_TOKEN: "fake",
        DAGGER_SESSION_PORT: "9", DAGGER_SESSION_TOKEN: "fake", DAGGER_CLOUD_TOKEN: "fake",
        _EXPERIMENTAL_DAGGER_CLI_BIN: "/agent/dagger", _EXPERIMENTAL_DAGGER_RUNNER_HOST: "tcp://agent",
    };
    const before = Object.entries(ambient).map(([key, value]) => {
        const previous = process.env[key];
        process.env[key] = value;
        return [key, previous];
    });
    t.after(() => {
        for (const [key, value] of before) {
            if (value === undefined) delete process.env[key];
            else process.env[key] = value;
        }
    });
}

test("pinned handshake, clean child environment and host bindings across separate calls", async t => {
    const f = await fixture(t);
    contaminateEnvironment(t);
    const created = await f.invoke("environment_create", { title: "fixture", explanation: "Create the fixture" });
    assert.deepEqual(created, textResult(JSON.stringify({ id: environment, title: "fixture" })));
    assert.equal(f.state.environment, environment);

    const next = containerUse(f.options);
    const commands = {
        environment_open: {},
        environment_update_metadata: { title: "next" },
        environment_file_read: { target_file: "notes.txt", should_read_entire_file: true },
        environment_file_list: { path: "." },
        environment_file_write: { target_file: "notes.txt", contents: "" },
        environment_file_edit: { target_file: "notes.txt", search_text: "old", replace_text: "", which_match: "abc" },
        environment_file_delete: { target_file: "notes.txt" },
    };
    for (const [name, args] of Object.entries(commands)) {
        assert.deepEqual(await next(name, args), textResult("done 🧪"));
    }
    // macOS can add its own text-encoding setting when a runtime starts.
    const probe = spawnSync(process.execPath, ["-p", "JSON.stringify(process.env)"], { env: {}, encoding: "utf8" });
    assert.equal(probe.status, 0);
    const runtimeEnv = JSON.parse(probe.stdout);
    assert.ok(Object.keys(runtimeEnv).every(key => key === "__CF_USER_TEXT_ENCODING" && process.platform === "darwin"));

    const log = f.log();
    const starts = log.filter(event => event.event === "start");
    assert.equal(starts.length, 8);
    assert.equal(new Set(starts.map(event => event.pid)).size, starts.length);
    for (const child of starts) {
        assert.deepEqual(child.args, ["stdio"]);
        assert.equal(child.cwd, f.home);
        assert.deepEqual(child.env, {
            ...runtimeEnv,
            HOME: f.home, TMPDIR: f.home, PATH: `${f.root}:/usr/bin:/bin:/usr/sbin:/sbin`,
            DOCKER_HOST: `unix://${f.options.socket}`, DOCKER_CONFIG: "/var/empty",
            GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_COUNT: "2",
            GIT_CONFIG_KEY_0: "core.hookspath", GIT_CONFIG_VALUE_0: "/dev/null",
            GIT_CONFIG_KEY_1: "commit.gpgsign", GIT_CONFIG_VALUE_1: "false",
            GIT_ALLOW_PROTOCOL: "file", GIT_TERMINAL_PROMPT: "0", GIT_ASKPASS: "/usr/bin/false",
            GIT_AUTHOR_NAME: "Rounds", GIT_AUTHOR_EMAIL: "rounds@example.invalid",
            GIT_COMMITTER_NAME: "Rounds", GIT_COMMITTER_EMAIL: "rounds@example.invalid",
            CONTAINER_USE_STDERR_FILE: "/dev/null", _EXPERIMENTAL_DAGGER_CLI_BIN: f.options.daggerCLI,
            _EXPERIMENTAL_DAGGER_RUNNER_HOST: engine,
        });
        const events = log.filter(event => event.pid === child.pid);
        assert.deepEqual(events.map(event => event.event), ["start", "request", "request", "request", "stdin-close", "exit"]);
        assert.deepEqual(events[1].request, { jsonrpc: "2.0", id: 1, method: "initialize", params: {
            protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "Rounds", version: "1.0.0" },
        } });
        assert.deepEqual(events[2].request, { jsonrpc: "2.0", method: "notifications/initialized" });
        const { name } = events[3].request.params;
        const bound = name === "environment_create"
            ? { title: "fixture", explanation: "Create the fixture", from_git_ref: revision }
            : { ...commands[name], environment_id: environment };
        assert.deepEqual(events[3].request, { jsonrpc: "2.0", id: 2, method: "tools/call", params: {
            name, arguments: { ...bound, environment_source: f.checkout },
        } });
    }
    assert.deepEqual(f.count, { admitted: 8, verified: 16, readback: 8 });
});

test("rejects unapproved tools, arguments, executable paths and engine before spawn", async t => {
    const f = await fixture(t);
    for (const binary of ["container-use", f.root, join(f.root, "missing")]) {
        assert.throws(() => containerUse({ ...f.options, binary }), /absolute executable paths/);
    }
    for (const engine of ["tcp://engine:80", "docker-container://", "docker-container://one/two", "docker-container://a?x=y"]) {
        assert.throws(() => containerUse({ ...f.options, engine }), /approved Docker container engine/);
    }
    assert.throws(() => containerUse({ ...f.options, verifyEngine: undefined }), /a verifier/);
    const invalid = [
        ["environment_list", {}, /single verified run/],
        ...["checkpoint", "config", "add_service", "run_cmd"].map(name => [`environment_${name}`, {}, /unavailable/]),
        ["constructor", {}, /unavailable/],
        ["environment_open", null, /must be an object/],
        ["environment_open", { environment_source: "/elsewhere" }, /Unsupported argument/],
        ["environment_open", { environment_id: "other-id" }, /Unsupported argument/],
        ["environment_create", { title: "fixture", from_git_ref: "HEAD" }, /Unsupported argument/],
        ["environment_create", { title: "fixture", allow_replace: true }, /Unsupported argument/],
        ["environment_file_write", { target_file: "large", contents: "🚀".repeat(270_000) }, /request exceeds the byte limit/],
        ["environment_file_read", { target_file: "file" }, /ordered line range/],
        ["environment_file_read", { target_file: "file", start_line_one_indexed_inclusive: 1.1 }, /Invalid start_line/],
        ["environment_file_write", { target_file: "file" }, /Missing contents/],
        ["environment_file_edit", { target_file: "file", search_text: "", replace_text: "x" }, /Invalid search_text/],
        ["environment_update_metadata", { title: 42 }, /Invalid title/],
    ];
    for (const [name, args, pattern] of invalid) await assert.rejects(f.invoke(name, args), pattern);
    assert.deepEqual(f.count, { admitted: 0, verified: 0, readback: 0 });

    const denied = containerUse({ ...f.options, verifyEngine: async () => false });
    await assert.rejects(denied("environment_create", { title: "fixture" }), /Could not verify/);
    f.state.refuse = true;
    await assert.rejects(f.invoke("environment_create", { title: "fixture" }), /admission refused/);
    f.state.refuse = false;
    await assert.rejects(f.invoke("environment_open", {}), /Invalid container-use run binding/);
    await assert.rejects(f.invoke("environment_create", { title: "fixture" }, { signal: AbortSignal.abort() }), { name: "AbortError" });
    const controller = new AbortController();
    const cancelled = containerUse({ ...f.options, verifyEngine: () => { controller.abort(); return true; } });
    await assert.rejects(cancelled("environment_create", { title: "fixture" }, { signal: controller.signal }), { name: "AbortError" });
    assert.deepEqual(f.count, { admitted: 4, verified: 1, readback: 0 });
    assert.deepEqual(f.log(), []);
});

test("foreground commands require a boolean opt-in and admit only command and explanation", async t => {
    const f = await fixture(t);
    for (const foregroundCommands of ["true", 1, null]) {
        assert.throws(() => containerUse({ ...f.options, foregroundCommands }), /must be a boolean/);
    }
    const name = "environment_run_cmd";
    const command = "printf ready";
    await assert.rejects(f.invoke(name, { command }), /unavailable/);
    const invoke = containerUse({ ...f.options, foregroundCommands: true });
    const invalid = [
        [{}, /Missing command/],
        [{ command: "" }, /Invalid command/],
        [{ command: "printf\0ready" }, /Invalid command/],
        [{ command: 7 }, /Invalid command/],
        [{ command, explanation: true }, /Invalid explanation/],
        [{ command: "🚀".repeat(270_000) }, /request exceeds the byte limit/],
        [{ command, explanation: "🚀".repeat(270_000) }, /request exceeds the byte limit/],
    ];
    for (const [args, error] of invalid) await assert.rejects(invoke(name, args), error);
    for (const key of ["shell", "background", "ports", "use_entrypoint", "source", "environment", "environment_source", "environment_id"]) {
        await assert.rejects(invoke(name, { command, [key]: null }), /Unsupported argument/);
    }
    assert.deepEqual(f.count, { admitted: 0, verified: 0, readback: 0 });
    assert.deepEqual(f.log(), []);
});

test("foreground variant is required before dispatch and runs with host bindings and readback", async t => {
    const f = await fixture(t);
    f.state.environment = environment;
    const foregroundVersion = "1.0.0-rounds-foreground-v1";
    const name = "environment_run_cmd";
    const command = "printf ready";
    const invoke = containerUse({ ...f.options, foregroundCommands: true });
    const incompatible = /Incompatible container-use initialization/;
    await assert.rejects(invoke(name, { command }), incompatible);
    await f.mode("ok", `${foregroundVersion}-extra`);
    await assert.rejects(invoke("environment_open", {}), incompatible);
    await f.mode("ok", foregroundVersion, "Other");
    await assert.rejects(invoke(name, { command }), incompatible);
    await f.mode("ok", foregroundVersion);
    await assert.rejects(f.invoke("environment_open", {}), incompatible);
    const requests = () => f.log().flatMap(event => event.request ? [event.request] : []);
    assert.deepEqual(requests().map(request => request.method), Array(4).fill("initialize"));
    assert.deepEqual(f.count, { admitted: 4, verified: 8, readback: 4 });

    const args = { command, explanation: "Check foreground output" };
    assert.deepEqual(await invoke(name, args), textResult("done 🧪"));
    assert.deepEqual(requests().slice(4).map(request => request.method), ["initialize", "notifications/initialized", "tools/call"]);
    assert.deepEqual(requests().at(-1).params, {
        name, arguments: { ...args, environment_source: f.checkout, environment_id: environment },
    });
    assert.deepEqual(f.count, { admitted: 5, verified: 10, readback: 5 });
});

test("completed tool errors use verified readback and create errors leave no binding", async t => {
    const f = await fixture(t);
    await f.mode("tool-error");
    const error = textResult("tool ran and returned an error", true);
    assert.deepEqual(await f.invoke("environment_create", { title: "fixture" }), error);
    assert.equal(f.state.environment, undefined);
    assert.equal(f.count.readback, 0);

    f.state.environment = environment;
    assert.deepEqual(await f.invoke("environment_file_delete", { target_file: "absent" }), error);
    assert.equal(f.count.readback, 1);
    f.state.rejectReadback = true;
    await assert.rejects(f.invoke("environment_file_delete", { target_file: "absent" }), /readback refused/);
});

test("wire failures and invalid create records fail closed", async t => {
    const f = await fixture(t);
    for (const [mode, error] of [
        ["version", /Incompatible container-use initialization/],
        ["unexpected", /Unexpected container-use response/],
        ["rpc-error", /returned a JSON-RPC error/],
        ["invalid-result", /Invalid container-use tool content/],
        ["extra", /Unexpected container-use response after the tool result/],
        ["partial", /Incomplete container-use response line/],
        ["oversize", /response exceeds the byte limit/],
        ["invalid-utf8", /Malformed container-use response line/],
        ["bad-exit", /exited before a clean reply \(9\)/],
        ["bad-id", /invalid environment ID/],
        ["dirty-create", /did not return a clean create record/],
    ]) {
        await f.mode(mode);
        await assert.rejects(f.invoke("environment_create", { title: "fixture" }), error);
        assert.equal(f.state.environment, undefined);
    }
    const records = f.log();
    const first = records[0].pid;
    assert.deepEqual(records.filter(record => record.pid === first && record.request).map(record => record.request.method), ["initialize"]);
    assert.deepEqual(f.count, { admitted: 11, verified: 13, readback: 0 });
});

test("an engine restart during the call blocks run readback", async t => {
    const f = await fixture(t);
    f.state.environment = environment;
    const invoke = containerUse({ ...f.options, async verifyEngine(uri, request) {
        await f.options.verifyEngine(uri, request);
        return `${generation}/${f.count.verified}`;
    } });
    await assert.rejects(invoke("environment_open", {}), /engine restarted/);
    assert.ok(f.log().some(event => event.request?.method === "tools/call"));
    assert.deepEqual(f.count, { admitted: 1, verified: 2, readback: 0 });
});

async function waitForRequest(f) {
    for (let attempt = 0; attempt < 200; attempt++) {
        if (f.log().some(event => event.request?.method === "tools/call")) return;
        await sleep(10);
    }
    assert.fail("The fixture did not receive the tool call.");
}

test("a missing reply times out and does not allow readback", { timeout: 10_000 }, async t => {
    const f = await fixture(t);
    f.state.environment = environment;
    await f.mode("hang");
    t.mock.timers.enable({ apis: ["setTimeout"] });
    const pending = assert.rejects(f.invoke("environment_open", {}), /did not reply in time/);
    try {
        await waitForRequest(f);
    } finally {
        t.mock.timers.tick(120_000);
        t.mock.timers.tick(2_000);
        await pending;
    }
    assert.deepEqual(f.count, { admitted: 1, verified: 1, readback: 0 });
});

test("cancellation sends termination and waits for forced exit inside the run lock", { timeout: 10_000 }, async t => {
    const f = await fixture(t);
    f.state.environment = environment;
    await f.mode("hang");
    const controller = new AbortController();
    const pending = assert.rejects(f.invoke("environment_open", {}, { signal: controller.signal }), { name: "AbortError" });
    try {
        await waitForRequest(f);
    } finally {
        controller.abort();
        await pending;
    }
    assert.ok(f.log().some(event => event.event === "term"));
    assert.ok(!f.log().some(event => event.event === "exit"), "fixture exited without the force signal");
    assert.deepEqual(f.count, { admitted: 1, verified: 1, readback: 0 });
});
