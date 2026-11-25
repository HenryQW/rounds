import { randomUUID } from "node:crypto";
import { readdir, rm } from "node:fs/promises";
import { join } from "node:path";
import { isDeepStrictEqual } from "node:util";
import { AssistantEntry, GenerationTask, defineDoc, defineExtension, defineTool, hook } from "@earendil-works/pi-durable";
import { obj, str } from "@earendil-works/pi-schema";
import { openContainerRun } from "./harness-container-run.mjs";
import { containerUse } from "./harness-container-use.mjs";
import { engineEgressVerifier } from "./harness-engine-egress.mjs";
import { withSchedulingGuard } from "./harness-scheduling.mjs";

const Runs = defineDoc({
    kind: "rounds.runs", version: 1, scope: "session", initial: () => ({ tasks: {} }),
    checkpointWhen: (_value, _ops, info) => info.deltasSinceBase >= 64,
});
const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
const revision = /^[0-9a-f]{40}$/;
const bounded = (value, limit = 4096) => typeof value === "string" && value.trim().length > 0 && Buffer.byteLength(value) <= limit;
const list = (value, limit = 32) => Array.isArray(value) && value.length <= limit && value.every(item => bounded(item));
const output = (text, isError = false) => ({ output: [{ type: "text", text }], isError });
// Older done runs and their folders are pruned at the next dispatch.
const keepDone = 8;
const toolSpecs = [
    ["environment_run_cmd", "Run a foreground command in the assigned container.", obj({ command: str() })],
    ["environment_file_read", "Read the entire file in the assigned container.", obj({ target_file: str() })],
    ["environment_file_write", "Write a file in the assigned container.", obj({ target_file: str(), contents: str() })],
];
const contract = `Work only in the assigned container. Return a single JSON object when finished.
For Done, include status "done", checkedRevision from environment_verified_revision after validation, and arrays changedLocations, validationOutcomes, and risks. Include at least one validation outcome.
For Blocked, include status "blocked", reason, and an options array with at most three strings. Wait for an answer before continuing.`;

function check(condition, message) {
    if (!condition) throw new Error(message);
}

function result(text) {
    check(bounded(text, 32_768), "The task did not return a bounded result.");
    let value;
    try { value = JSON.parse(text); } catch { throw new Error("The task did not return a structured result."); }
    const keys = Object.keys(value ?? {}).sort().join(",");
    if (value?.status === "done" && keys === "changedLocations,checkedRevision,risks,status,validationOutcomes" &&
        typeof value.checkedRevision === "string" && revision.test(value.checkedRevision) &&
        [value.changedLocations, value.validationOutcomes, value.risks].every(items => list(items)) && value.validationOutcomes.length) return value;
    if (value?.status === "blocked" && keys === "options,reason,status" && bounded(value.reason) && list(value.options, 3)) return value;
    throw new Error("The task result does not match the handoff contract.");
}

// The host supplies the confined engine and private run directory.
export function dispatchContainers({ folder, binary, daggerCLI, docker, socket, policy }) {
    const verifyEngine = engineEgressVerifier({ ...policy, docker, socket });
    const engine = `docker-container://${policy.container}`;
    return {
        open({ runID, enrollment: { source, revision: selected } }) {
            const run = openContainerRun({ folder, run: runID, source, revision: selected });
            const call = containerUse({ binary, daggerCLI, docker, socket, engine, run, verifyEngine, foregroundCommands: true });
            return { ...run, call };
        },
        async verifyInventory(records) {
            const actual = await readdir(folder);
            const known = new Set(records.map(record => record.runID));
            // A prune removes the folder before the record, so a done record can have no folder.
            check(actual.every(name => known.has(name)) && records.every(record => record.status === "done" || actual.includes(record.runID)),
                "The container folder has unverified runs or locks.");
        },
        async remove({ runID }) {
            check(uuid.test(runID), "Invalid container run identifier.");
            await rm(join(folder, runID), { recursive: true, force: true });
        },
    };
}

// The Rounds adapter is the authority for enrollment, dependencies, folders,
// model data permissions and linked records. No model can supply this adapter.
export function taskDispatch({ authorize, saveResult, containers, verifyRecovery }) {
    let active;
    async function recheck(record, grant, context) {
        check(isDeepStrictEqual(await authorize(record.taskID, record.detailID, context), grant), "Task dispatch permission changed.");
    }
    const tools = [...toolSpecs, ["environment_verified_revision", "Read the verified revision after your last container change.", obj({})]]
        .map(([name, description, parameters]) => defineTool({
        name, description, parameters, replay: "unsafe", executionMode: "sequential",
        async execute(args, api, context) {
            const current = active;
            if (current?.record?.conversationID !== api.conversationId) return output("Rounds could not verify the task run.", true);
            try {
                await recheck(current.record, current.grant, context);
                if (name === "environment_verified_revision") return output((await current.container.inspect()).revision);
                const response = await current.container.call(name, name === "environment_file_read"
                    ? { ...args, should_read_entire_file: true } : args, { signal: context.abortSignal });
                return { output: response.content, isError: response.isError === true };
            } catch { return output("Rounds could not verify or complete the container operation.", true); }
        },
    }));
    async function beforeRequest(_request, api, context) {
        const current = active;
        check(current?.record?.conversationID === api.conversationId, "Rounds could not verify the task run.");
        await recheck(current.record, current.grant, context);
    }
    const extension = defineExtension({ name: "rounds.task.container", tools,
        hooks: [hook(GenerationTask, { beforeRequest, beforeProviderRequest: beforeRequest })] });

    async function read(harness, context) {
        return (await harness.snapshot(Runs, context))?.tasks ?? {};
    }

    async function write(harness, taskID, next, context) {
        await harness.commit(async tx => { (await tx.doc(Runs)).tasks[taskID] = next; }, context);
    }

    async function review(harness, context) {
        const state = await harness.inspect(context);
        check(!state.tasks.length && !state.submissions.length, "Harness has work that needs restart reconciliation.");
        const tasks = await read(harness, context);
        check(await verifyRecovery(Object.values(tasks), context) === true, "Rounds could not verify task records and process cleanup.");
        for (const old of Object.values(tasks).filter(record => record.status === "done").slice(0, -keepDone)) {
            await containers.remove(old);
            await harness.commit(async tx => { delete (await tx.doc(Runs)).tasks[old.taskID]; }, context);
            delete tasks[old.taskID];
        }
        const records = Object.values(tasks);
        await containers.verifyInventory(records);
        for (const record of records) {
            check(["blocked", "done", "failed"].includes(record.status), "An interrupted task needs inspection before scheduling.");
            // Only a blocked task resumes; done and failed runs are not opened again.
            if (record.status !== "blocked") continue;
            check(await harness.conversation(record.conversationID, context), "A saved task conversation is missing.");
            const saved = await containers.open(record).inspect();
            check(isDeepStrictEqual(saved, record.saved), "The saved task container does not match its run.");
        }
        return tasks;
    }

    async function start(harness, { taskID, detailID, answer }, context) {
        check(typeof taskID === "string" && uuid.test(taskID) && typeof detailID === "string" && uuid.test(detailID) &&
            (answer === undefined || bounded(answer)), "Invalid task handoff identity or answer.");
        check(!active, "Another task dispatch is in progress.");
        active = {};
        try {
            const tasks = await review(harness, context);
            const previous = tasks[taskID];
            check(previous ? previous.status === "blocked" && previous.detailID === detailID && answer !== undefined &&
                (!previous.options.length || previous.options.includes(answer)) : answer === undefined,
                "The task cannot start or receive this answer.");
            const grant = structuredClone(await authorize(taskID, detailID, context));
            check(grant?.enrollment && uuid.test(grant.enrollment.repositoryID) && uuid.test(grant.enrollment.organizationID) &&
                bounded(grant.enrollment.source) && revision.test(grant.enrollment.revision) &&
                bounded(grant.instructions, 16_384) && bounded(grant.handoff, 32_768) &&
                bounded(grant.model?.provider, 128) && bounded(grant.model?.modelId, 128), "Task dispatch needs current enrollment and data permission.");
            check(!previous || isDeepStrictEqual(grant.enrollment, previous.enrollment), "The blocked task enrollment changed.");
            check(!Object.values(tasks).some(record => record.taskID !== taskID && record.status === "blocked" &&
                record.enrollment.source === grant.enrollment.source), "A blocked task owns this checkout.");
            const record = { taskID, detailID, enrollment: grant.enrollment, runID: previous?.runID ?? randomUUID(), status: "running" };
            const work = containers.open(record);
            let conversation;
            const agent = { model: grant.model, instructions: `${contract}\n\n${grant.instructions}`, extensions: [extension],
                tools, modelTools: tools, maxTurns: 16 };
            if (previous) {
                conversation = await harness.conversation(previous.conversationID, context);
                record.conversationID = conversation.id;
                await write(harness, taskID, record, context);
                await conversation.configure(agent, context);
            } else {
                conversation = await harness.createConversation({ ownership: { kind: "ownerless" }, agent,
                    async init(tx, id) {
                        record.conversationID = id;
                        (await tx.doc(Runs)).tasks[taskID] = record;
                    },
                }, context);
                await recheck(record, grant, context);
                const created = await work.call("environment_create", { title: "Rounds task", explanation: "Start the assigned task." },
                    { signal: context.abortSignal });
                check(created.isError !== true, "Rounds could not create the task container.");
            }
            active = { record, container: work, grant };
            if (previous) {
                await recheck(record, grant, context);
                const reopened = await work.call("environment_open", {}, { signal: context.abortSignal });
                check(reopened.isError !== true, "Rounds could not reopen the verified task container.");
            }
            await recheck(record, grant, context);
            const submission = await conversation.submit({ type: "input", content: answer ?? grant.handoff, whenBusy: "reject" }, context);
            const settled = await submission.wait(context);
            check(settled.status === "done" && settled.type === "input", "The task turn needs inspection.");
            const response = await harness.commit(tx => tx.entry(AssistantEntry, settled.answer), context);
            const message = response?.model?.[0];
            let report;
            try { report = result(message?.content.filter(block => block.type === "text").map(block => block.text).join("")); } catch (error) {
                // A malformed result ends the task, so it does not hold the dispatch queue.
                await write(harness, taskID, { ...record, status: "failed" }, context);
                throw error;
            }
            const saved = await work.inspect();
            check(report.status !== "done" || report.checkedRevision === saved.revision, "The reported checks name a different revision.");
            await recheck(record, grant, context);
            const imported = report.status === "done" ? await work.importResult(saved) : null;
            const next = await saveResult({ ...record, saved, imported }, report, context);
            check(typeof next === "string" && uuid.test(next), "Rounds could not link the accepted result.");
            await write(harness, taskID, { ...record, detailID: next, saved, status: report.status,
                ...(report.status === "blocked" ? { options: report.options } : {}) }, context);
            return { report, detailID: next, saved, imported };
        } finally {
            active = undefined;
        }
    }

    return { extension, start: (harness, request, context) =>
        withSchedulingGuard(harness, () => start(harness, request, context)), review };
}
