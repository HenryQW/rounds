// Run against the bundled host with private storage and a loopback provider.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { test } from "node:test";

const payload = resolve(process.env.ROUNDS_HARNESS_PAYLOAD ?? ".build/harness-host");
const model = "magpie/team/first";
const otherModel = "magpie/team/second";
const fixtureKey = randomUUID();
const responsesModel = "team/responses";
const messagesModel = "team/messages";

function providerReply(response, url) {
    const output = { type: "output_text", text: "Responses reply." };
    const item = { type: "message", id: "msg", role: "assistant" };
    const events = url === "/v1/responses" ? [
        { type: "response.output_item.added", item: { ...item, status: "in_progress", content: [] } },
        { type: "response.content_part.added", part: { ...output, text: "" } },
        { type: "response.output_text.delta", delta: output.text },
        { type: "response.output_item.done", item: { ...item, status: "completed", content: [output] } },
        { type: "response.completed", response: { status: "completed", usage: { input_tokens: 3, output_tokens: 2 } } },
    ] : [
        { type: "message_start", message: { id: "msg", usage: { input_tokens: 3, output_tokens: 0 } } },
        { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
        { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "Messages reply." } },
        { type: "content_block_stop", index: 0 },
        { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 2 } },
        { type: "message_stop" },
    ];
    response.writeHead(200, { "Content-Type": "text/event-stream" });
    response.end(events.map(event => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join(""));
}

class Host {
    frames = [];

    constructor(folder) {
        this.child = spawn(join(payload, "node"), [join(payload, "host.mjs"), join(folder, "data"),
            "ROUNDS_HARNESS_RUN_ID=00000000-0000-0000-0000-000000000000"], {
            env: { HOME: folder, PATH: "/usr/bin:/bin" }, stdio: ["pipe", "pipe", "inherit"],
        });
        this.exit = once(this.child, "close");
        this.child.stdin.on("error", () => {});
        this.lines = createInterface({ input: this.child.stdout });
        this.lines.on("line", line => this.frames.push(JSON.parse(line)));
    }

    async wait(predicate, from = 0) {
        const deadline = Date.now() + 5000;
        while (true) {
            const found = this.frames.slice(from).find(predicate);
            if (found) return found;
            if (Date.now() >= deadline || this.child.exitCode !== null || this.child.signalCode !== null) {
                assert.fail(`Missing host frame. Received ${JSON.stringify(this.frames.slice(from))}`);
            }
            await new Promise(resolve => setTimeout(resolve, 10));
        }
    }

    request(command, fields = {}) {
        const id = randomUUID();
        this.child.stdin.write(JSON.stringify({ version: 1, id, command, ...fields }) + "\n");
        return this.wait(frame => frame.id === id);
    }

    async command(name, fields) {
        const reply = await this.request(name, fields);
        assert.equal(reply.ok, true, JSON.stringify(reply));
        return reply;
    }

    async close() {
        await this.command("shutdown");
        assert.deepEqual(await this.exit, [0, null]);
    }
}

test("recovery preserves an aborted partial reply without a user stop on later opens", async () => {
    const source = (await readFile(new URL("../Resources/harness-bouncer.mjs", import.meta.url), "utf8"))
        .split("\n").filter(line => !line.startsWith("import ")).join("\n");
    globalThis.roundsFixture = {
        context: {}, AssistantEntry: { is: entry => entry.kind === "assistant" },
        UserEntry: { is: entry => entry.kind === "user" }, configure() {}, defineDoc: value => value,
        LiveDoc: {}, BouncerRequestError: class extends Error {},
        registerMagpie: async () => ({ resolve: () => null, models: [] }),
    };
    try {
        const prefix = "const { context, AssistantEntry, UserEntry, configure, defineDoc, LiveDoc, BouncerRequestError, registerMagpie } = globalThis.roundsFixture;\n";
        const { bouncer } = await import(`data:text/javascript;base64,${Buffer.from(prefix + source).toString("base64")}`);
        const rows = [
            { id: 1, kind: "user", model: [{ content: "Question" }] },
            { id: 2, kind: "assistant", model: [{ content: "Partial reply", stopReason: "aborted" }] },
        ];
        const conversation = {
            id: "root", commit: async callback => callback({ doc: async () => ({ model: null }),
                appendEntry: async (_id, entry) => { rows.push({ ...entry, id: rows.length + 1 }); } }),
            configure: async () => {}, abort: async () => {},
            entries: async ({ minEntryId }) => ({ items: rows.filter(row => !minEntryId || row.id >= minEntryId) }),
            submit: async ({ entry }) => { rows.push({ ...entry, id: rows.length + 1 }); },
        };
        let recovering = true;
        let interruptAbort = true;
        const harness = {
            root: async () => conversation,
            inspect: async () => ({ tasks: recovering ? [{ record: { id: "task", conversationId: "root" } }] : [], submissions: [] }),
            abortTask: async () => { if (interruptAbort) { interruptAbort = false; throw new Error("simulated crash"); } },
        };
        await assert.rejects(bouncer(harness, {}, () => {})({ command: "bouncerOpen" }), /simulated crash/);
        assert.ok(rows.some(row => row.kind === "rounds.interrupted" && row.data.afterID === 1));
        recovering = false;
        for (let attempt = 0; attempt < 2; attempt++) {
            const frames = [];
            await bouncer(harness, {}, (event, fields) => frames.push({ event, ...fields }))({ command: "bouncerOpen" });
            assert.ok(frames.some(frame => frame.event === "delta" && frame.text === "Partial reply"));
            assert.equal(frames.some(frame => frame.event === "stopped"), false);
            assert.ok(frames.some(frame => frame.event === "failed" && frame.text.includes("interrupted")));
        }
    } finally {
        delete globalThis.roundsFixture;
    }
});

test("Bouncer streams and stops, restores questions and model, and never exposes tools", { timeout: 25_000 }, async () => {
    const folder = await mkdtemp(join(tmpdir(), "rounds-bouncer-"));
    const requests = [];
    const children = [];
    let release;
    const server = createServer(async (req, res) => {
        const chunks = [];
        for await (const chunk of req) chunks.push(chunk);
        const body = JSON.parse(Buffer.concat(chunks));
        const url = req.url.split("?")[0];
        requests.push({ body, url, auth: req.headers.authorization, key: req.headers["x-api-key"] });
        if (url === "/v1/responses" || url === "/v1/messages") {
            providerReply(res, url);
            return;
        }
        const input = body.messages.at(-1).content;
        const prompt = typeof input === "string" ? input : input[0].text;
        if (prompt === "fail") {
            res.writeHead(401, { "Content-Type": "application/json" });
            res.end(JSON.stringify({ error: { message: `Private provider error with ${fixtureKey}` } }));
            return;
        }
        res.writeHead(200, { "Content-Type": "text/event-stream" });
        const send = (content, finish_reason = null) => res.write(`data: ${JSON.stringify({ id: "fixture", model: body.model,
            choices: [{ index: 0, delta: { content }, finish_reason }] })}\n\n`);
        if (["stream", "stop", "crash"].includes(prompt)) {
            send(prompt === "stop" ? 'ROUNDS_QUESTION {"title":' : prompt === "crash" ? "Interrupted partial" : "First ");
            await new Promise(resolve => { release = resolve; res.once("close", resolve); });
            if (res.destroyed) return;
            send("second");
        } else if (prompt === "question") {
            send('ROUNDS_QUESTION {"title":"Which?","options":["First","Second"],"recommended":1}');
        } else if (prompt.startsWith("Answer to")) {
            send("Answer received.");
        } else {
            send("Recovered.");
        }
        send(null, "stop");
        res.end("data: [DONE]\n\n");
    });
    try {
        server.listen(0, "127.0.0.1");
        await once(server, "listening");
        const agent = join(folder, ".pi/agent");
        await mkdir(join(agent, "sessions"), { recursive: true });
        await writeFile(join(agent, "sessions/existing.jsonl"), "private existing session");
        const origin = `http://127.0.0.1:${server.address().port}`;
        const config = { providers: { magpie: { api: "openai-completions", apiKey: fixtureKey,
            baseUrl: `${origin}/v1`,
            models: [{ id: "team/first" }, { id: "team/second" },
                { id: responsesModel, api: "openai-responses" },
                { id: messagesModel, api: "anthropic-messages", baseUrl: origin }] } } };
        const settings = JSON.stringify({ defaultProvider: "magpie", defaultModel: "team/first" });
        await writeFile(join(agent, "models.json"), JSON.stringify(config));
        await writeFile(join(agent, "settings.json"), settings);
        const open = async () => {
            const host = new Host(folder);
            children.push(host);
            assert.equal((await host.command("health")).scheduling, "paused");
            await host.command("bouncerOpen");
            return host;
        };
        let host = await open();
        assert.equal(host.frames.find(frame => frame.event === "started").model, model);
        assert.equal(host.frames.find(frame => frame.event === "started").selection, null);
        assert.deepEqual(host.frames.filter(frame => frame.event === "model").map(frame => frame.model),
            [model, otherModel, `magpie/${responsesModel}`, `magpie/${messagesModel}`]);
        assert.equal(requests.length, 0);
        await host.command("bouncerModel", { model: otherModel });
        let from = host.frames.length;
        await host.command("bouncerSend", { text: "stream" });
        await host.wait(frame => frame.event === "delta" && frame.text === "First ", from);
        assert.equal(host.frames.slice(from).some(frame => frame.replying === false), false);
        const busy = await host.request("bouncerSend", { text: "must not run" });
        assert.equal(busy.ok, false);
        assert.equal(busy.rejected, true);
        assert.equal(busy.error, "Wait for the current Bouncer reply to finish.");
        release();
        await host.wait(frame => frame.replying === false, from);
        assert.ok(host.frames.slice(from).some(frame => frame.event === "delta" && frame.text === "First second"));
        assert.equal((await host.command("health")).scheduling, "running");

        from = host.frames.length;
        await host.command("bouncerSend", { text: "stop" });
        await host.wait(frame => frame.event === "replying" && frame.replying, from);
        while (requests.length < 2) await new Promise(resolve => setTimeout(resolve, 10));
        await host.command("bouncerStop");
        assert.equal(host.frames.slice(from).filter(frame => frame.event === "stopped").length, 1);
        assert.ok(host.frames.slice(from).some(frame => frame.replying === false));

        from = host.frames.length;
        await host.command("bouncerSend", { text: "question" });
        const question = await host.wait(frame => frame.event === "question", from);
        await host.wait(frame => frame.replying === false, from);
        assert.deepEqual(question.options, ["First", "Second"]);
        assert.equal(question.recommended, 1);
        await host.close();

        host = await open();
        assert.equal(host.frames.find(frame => frame.event === "started").model, otherModel);
        assert.equal(host.frames.find(frame => frame.event === "started").selection, otherModel);
        assert.equal(host.frames.find(frame => frame.event === "question").itemID, question.itemID);
        assert.ok(host.frames.some(frame => frame.event === "delta" && frame.text === "First second"));
        assert.equal((await host.request("bouncerAnswer", {
            questionID: question.itemID, answer: { kind: "option", index: 2 },
        })).ok, false);
        assert.equal(requests.length, 3);
        from = host.frames.length;
        await host.command("bouncerAnswer", { questionID: question.itemID, answer: { kind: "option", index: 1 } });
        await host.wait(frame => frame.replying === false, from);
        await host.wait(frame => frame.event === "answered" && frame.answer.index === 1, from);

        from = host.frames.length;
        await host.command("bouncerSend", { text: "crash" });
        await host.wait(frame => frame.event === "delta" && frame.text === "Interrupted partial", from);
        // Live progress is persisted within one second by the pinned Harness.
        await new Promise(resolve => setTimeout(resolve, 1500));
        host.child.kill("SIGKILL");
        await host.exit;
        host = await open();
        assert.ok(host.frames.some(frame => frame.event === "failed" && frame.text.includes("interrupted")));
        assert.equal(host.frames.filter(frame => frame.event === "stopped").length, 1);
        const partial = host.frames.filter(frame => frame.event === "delta" && frame.text === "Interrupted partial");
        assert.ok(partial.length > 0, JSON.stringify(host.frames));
        assert.ok(host.frames.some(frame => frame.event === "answered" && frame.questionID === question.itemID));
        await host.close();
        host = await open();
        assert.equal(host.frames.filter(frame => frame.event === "stopped").length, 1);
        assert.ok(host.frames.some(frame => frame.event === "failed" && frame.text.includes("interrupted")));
        assert.ok(host.frames.some(frame => frame.event === "delta" && frame.text === "Interrupted partial"));
        assert.equal(requests.length, 5);
        from = host.frames.length;
        await host.command("bouncerSend", { text: "continue" });
        await host.wait(frame => frame.replying === false, from);
        assert.ok(host.frames.slice(from).some(frame => frame.event === "delta" && frame.text === "Recovered."));
        from = host.frames.length;
        await host.command("bouncerSend", { text: "fail" });
        await host.wait(frame => frame.replying === false, from);
        assert.ok(host.frames.slice(from).some(frame => frame.event === "failed" && frame.text.includes("Magpie")));
        assert.ok(!JSON.stringify(host.frames).includes(fixtureKey));
        assert.equal(requests.length, 7);
        for (const { body, url, auth } of requests) {
            assert.equal(body.model, "team/second");
            assert.equal(url, "/v1/chat/completions");
            assert.equal(auth, `Bearer ${fixtureKey}`);
            assert.ok(!body.tools?.length && !body.functions?.length);
            assert.ok(!JSON.stringify(body).includes("private existing session"));
        }
        await host.command("bouncerModel", { model: null });
        assert.equal(host.frames.findLast(frame => frame.event === "selectedModel").model, model);
        await host.close();
        assert.equal(await readFile(join(agent, "settings.json"), "utf8"), settings);
        const changedSettings = JSON.stringify({ defaultProvider: "magpie", defaultModel: "team/second" });
        await writeFile(join(agent, "settings.json"), changedSettings);
        host = await open();
        const started = host.frames.find(frame => frame.event === "started");
        assert.equal(started.model, otherModel);
        assert.equal(started.selection, null);
        assert.equal(requests.length, 7);
        for (const [id, path, expected] of [
            [responsesModel, "/v1/responses", "Responses reply."],
            [messagesModel, "/v1/messages", "Messages reply."],
        ]) {
            await host.command("bouncerModel", { model: `magpie/${id}` });
            from = host.frames.length;
            await host.command("bouncerSend", { text: "Use the selected model." });
            await host.wait(frame => frame.replying === false, from);
            assert.ok(host.frames.slice(from).some(frame => frame.event === "delta" && frame.text === expected),
                `${path}: ${JSON.stringify(host.frames.slice(from))}`);
            const { body, url, auth, key } = requests.at(-1);
            assert.equal(body.model, id);
            assert.equal(url, path);
            assert.ok(auth === `Bearer ${fixtureKey}` || key === fixtureKey);
            assert.ok(!body.tools?.length);
        }
        await host.close();
        assert.equal(requests.length, 9);
        assert.equal(await readFile(join(agent, "sessions/existing.jsonl"), "utf8"), "private existing session");
    } finally {
        for (const host of children) host.child.kill("SIGKILL");
        await Promise.all(children.map(host => host.exit));
        server.closeAllConnections();
        server.close();
        await rm(folder, { recursive: true, force: true });
    }
});

test("pending recovery marks work before the pinned scheduler starts", async () => {
    const path = join(payload, "host.mjs");
    const original = await readFile(path, "utf8");
    const source = original.split("// harness-host.mjs\nvar commit = ")[0]
        .replace("__createRequire(import.meta.url)", `__createRequire(${JSON.stringify(path)})`);
    assert.ok(source.length < original.length);
    const exported = "Harness, openNodeSqliteStorage, createRegistry, createModels, BACKGROUND_CONTEXT, admitSubmission, resolveSettings, defineDoc, configure, LiveDoc, UserEntry, AssistantEntry";
    const api = await import(`data:text/javascript;base64,${Buffer.from(source + `\nexport { ${exported} };`).toString("base64")}`);
    const context = api.BACKGROUND_CONTEXT;
    const storage = await api.openNodeSqliteStorage(":memory:");
    const harness = await api.Harness.open(storage, { models: api.createModels(), registry: api.createRegistry() }, context);
    const moduleSource = (await readFile(new URL("../Resources/harness-bouncer.mjs", import.meta.url), "utf8"))
        .split("\n").filter(line => !line.startsWith("import ")).join("\n");
    globalThis.roundsFixture = {
        context, AssistantEntry: api.AssistantEntry, UserEntry: api.UserEntry,
        configure: api.configure, defineDoc: api.defineDoc, LiveDoc: api.LiveDoc, BouncerRequestError: class extends Error {},
        registerMagpie: async () => ({ resolve: () => null, models: [] }),
    };
    try {
        const root = await harness.root(context);
        await root.commit(tx => api.admitSubmission(tx, root.id, { type: "input", content: "Pending fixture" },
            Date.now(), api.resolveSettings()), context);
        const before = await harness.inspect(context);
        assert.equal(before.scheduling, "paused");
        assert.equal(before.tasks[0].record.state.status, "pending");
        const prefix = "// pinned scheduler fixture\nconst { context, AssistantEntry, UserEntry, configure, defineDoc, LiveDoc, BouncerRequestError, registerMagpie } = globalThis.roundsFixture;\n";
        const { bouncer } = await import(`data:text/javascript;base64,${Buffer.from(prefix + moduleSource).toString("base64")}`);
        const abortTask = harness.abortTask.bind(harness);
        harness.abortTask = async (...args) => {
            const current = await harness.inspect(context);
            assert.equal(current.scheduling, "paused");
            assert.equal(current.tasks[0].record.state.status, "pending");
            return abortTask(...args);
        };
        const events = [];
        await bouncer(harness, {}, (event, fields) => events.push({ event, ...fields }))({ command: "bouncerOpen" });
        assert.ok(events.some(event => event.event === "failed" && event.text.includes("interrupted")));
        assert.equal((await harness.inspect(context)).tasks.length, 0);
    } finally {
        delete globalThis.roundsFixture;
        await harness.close(context);
    }
});
