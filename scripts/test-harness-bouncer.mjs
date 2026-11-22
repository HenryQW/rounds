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
            send(prompt === "stop" ? 'ROUNDS_QUESTION {"title":' : "First ");
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
        await host.wait(frame => frame.event === "delta" && frame.text === "First ", from);
        host.child.kill("SIGKILL");
        await host.exit;
        host = await open();
        assert.ok(host.frames.some(frame => frame.event === "failed" && frame.text.includes("interrupted")));
        assert.ok(host.frames.some(frame => frame.event === "answered" && frame.questionID === question.itemID));
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
