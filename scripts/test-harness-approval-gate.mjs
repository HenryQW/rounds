// Build with ROUNDS_TEST_HARNESS_WORKFLOW=1 scripts/build-harness-host.sh.
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdtemp, readFile, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai/providers/faux";
import { obj } from "@earendil-works/pi-schema";
import { createRegistry, defineExtension, defineTool, Harness, ToolResultEntry } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { approvalGate, deliverApproval } from "./harness-approval-gate.mjs";

for (const scenario of ["approve", "reject", "stale", "mismatch", "unrelated queued input"]) {
    test(`saved ${scenario} after a SQLite reopen`, { timeout: 10_000 }, async () => {
        const folder = await mkdtemp(join(tmpdir(), "rounds-approval-"));
        const recordPath = join(folder, "approval.json");
        let harness, calls = 0, reads = 0, stale = false, armed = false;
        const save = async value => {
            const next = recordPath + ".next";
            await writeFile(next, JSON.stringify(value), { mode: 0o600 });
            await rename(next, recordPath);
        };
        const read = async () => JSON.parse(await readFile(recordPath, "utf8"));
        const load = async (identity) => {
            reads++;
            if (stale) return;
            try { return await read(); }
            catch (error) {
                if (error.code !== "ENOENT") throw error;
                const record = { binding: { ...identity, requestID: randomUUID() } };
                await save(record);
                return record;
            }
        };
        const armRecovery = () => { armed = true; };
        const tool = defineTool({ name: "counter", parameters: obj({}), description: "Increment a test counter.",
            async execute() { calls++; return { output: [{ type: "text", text: "incremented" }] }; } });
        const registry = createRegistry();
        registry.install(defineExtension({ name: "counter", tools: [tool] }));
        registry.install(approvalGate({ tool: tool.name, load }));
        const faux = fauxProvider();
        faux.setResponses([
            fauxAssistantMessage(fauxToolCall(tool.name, {}), { stopReason: "toolUse" }),
            fauxAssistantMessage("Finished."),
        ]);
        const models = createModels();
        models.setProvider(faux.provider);
        async function open() {
            harness = await Harness.open(await openNodeSqliteStorage(join(folder, "harness.sqlite")),
                { registry, models, onWake: () => {} }, context);
            return harness.root(context, { agent: { model: { provider: "faux", modelId: "faux-1" } } });
        }
        try {
            let root = await open();
            const submission = await root.submit({ type: "input", content: "Run the counter." }, context);
            let sleeping;
            for (let attempt = 0; attempt < 500 && !sleeping; attempt++) {
                sleeping = (await harness.inspect(context)).tasks.find(task => task.state.kind === "sleeping");
                if (!sleeping) await delay(5);
            }
            assert.ok(sleeping, "the call parked before running the counter");
            assert.equal(calls, 0);
            const saved = await read();
            assert.equal(saved.binding.taskID, sleeping.record.id);
            const { binding } = saved;
            await save({ binding, value: { requestID: binding.requestID,
                ...(scenario === "reject" ? { decision: "reject", reason: "Fixture decision." } : { decision: "approve" }) } });
            if (scenario === "unrelated queued input") {
                const followUp = await root.submit({ type: "input", content: "An unrelated follow-up.", whenBusy: "followUp" }, context);
                assert.ok((await harness.inspect(context)).submissions.some(item => item.id === followUp.id && item.status === "queued"));
            }
            await harness.close(context);
            root = await open();
            assert.equal((await harness.inspect(context)).scheduling, "paused");
            if (scenario === "unrelated queued input") {
                await assert.rejects(deliverApproval(harness, binding, { load, armRecovery }, context), /unrelated work/);
                assert.equal((await harness.inspect(context)).scheduling, "paused");
            } else if (scenario === "mismatch") {
                await assert.rejects(deliverApproval(harness, { ...binding, requestID: randomUUID() }, { load, armRecovery }, context), /saved approval/);
                assert.equal((await harness.inspect(context)).scheduling, "paused");
            } else if (scenario === "stale") {
                // Invalidate the request after the delivery read and before the gate can pass.
                const readOnce = async identity => { const record = await load(identity); stale = true; return record; };
                assert.equal(await deliverApproval(harness, binding, { load: readOnce, armRecovery }, context), "delivered");
            } else {
                assert.equal(await deliverApproval(harness, binding, { load, armRecovery }, context), "delivered");
            }
            if (scenario !== "mismatch" && scenario !== "unrelated queued input") {
                await (await harness.submission(submission.id, context)).wait(context);
                const entries = await root.entries({}, 20, undefined, context);
                const result = entries.items.find(entry => ToolResultEntry.is(entry));
                const output = result?.model?.[0]?.content.map(part => part.text ?? "").join("");
                assert.match(output ?? "", scenario === "approve" ? /incremented/ :
                    scenario === "reject" ? /Fixture decision/ : /could not verify the approval/);
                assert.ok(reads >= 3);
            }
            if (scenario === "approve") {
                await harness.close(context);
                await open();
                assert.equal(await deliverApproval(harness, binding, { load, armRecovery }, context), "duplicate");
                await save({ binding, value: { requestID: binding.requestID, decision: "reject", reason: "Changed." } });
                await assert.rejects(deliverApproval(harness, binding, { load, armRecovery }, context), /different decision/);
            }
            assert.equal(armed, true);
            assert.equal(calls, scenario === "approve" ? 1 : 0);
        } finally {
            await harness?.close(context);
            await rm(folder, { recursive: true, force: true });
        }
    });
}
