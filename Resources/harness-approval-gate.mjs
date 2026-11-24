import { isDeepStrictEqual } from "node:util";
import { defineDoc, defineExtension, defineSignal, hook, ToolTask } from "@earendil-works/pi-durable";
import { lit, obj, str, union } from "@earendil-works/pi-schema";
import { withSchedulingGuard } from "./harness-scheduling.mjs";

const approval = defineSignal({
    name: "rounds.approval.decision", version: 1,
    schema: union([
        obj({ requestID: str(), decision: lit("approve") }),
        obj({ requestID: str(), decision: lit("reject"), reason: str() }),
    ]),
});
const bindingMemo = "rounds.approval.binding";
const Receipts = defineDoc({ kind: "rounds.approval.receipts", version: 1, scope: "conversation",
    initial: () => ({ answers: {} }), checkpointWhen: (_value, _ops, info) => info.deltasSinceBase >= 64 });
const requestIDPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const itemID = value => Number.isSafeInteger(value) && value > 0;

function validBinding(binding) {
    return binding && typeof binding.requestID === "string" && requestIDPattern.test(binding.requestID) &&
        itemID(binding.taskID) && itemID(binding.conversationID) && typeof binding.callID === "string" &&
        binding.callID.length > 0 && Buffer.byteLength(binding.callID) <= 1024 && !binding.callID.includes("\0");
}

function validDecision(value, requestID) {
    if (!value || value.requestID !== requestID) return false;
    const keys = Object.keys(value).sort().join(",");
    return (value.decision === "approve" && keys === "decision,requestID") ||
        (value.decision === "reject" && keys === "decision,reason,requestID" &&
            typeof value.reason === "string" && value.reason.trim().length > 0);
}

// load uses the trusted local adapter. It verifies the exact saved binding and current snapshot
// on every call. A stale or unreadable request throws or returns no record. Before the first
// sleep the adapter must have persisted the binding and linked it to the request.
export function approvalGate({ tool, load }) {
    return defineExtension({
        name: "rounds.approval",
        hooks: [hook(ToolTask, {
            async beforeTool(call, api, context) {
                if (call.name !== tool) return;
                const identity = { taskID: api.taskId, conversationID: api.conversationId, callID: call.id };
                const record = await load(identity, context);
                if (!validBinding(record?.binding)) return { block: "Rounds could not verify the approval request." };
                const binding = { ...identity, requestID: record.binding.requestID };
                if (!isDeepStrictEqual(record.binding, binding) ||
                    !isDeepStrictEqual(await api.memo(bindingMemo, binding, context), binding)) {
                    return { block: "The saved approval belongs to a different tool call." };
                }
                const state = await api.readSignal(approval, binding.requestID, context);
                if (state === undefined) return { sleep: { signals: [approval.key(binding.requestID)] } };
                if (state.expired) return { block: "The approval request expired." };
                if (!validDecision(record.value, binding.requestID) || !isDeepStrictEqual(record.value, state.value)) {
                    return { block: "The delivered approval does not match the saved decision." };
                }
                if (record.value.decision === "reject") return { block: record.value.reason };
            },
        })],
    });
}

async function checkScheduling(harness, binding, context) {
    const { tasks, submissions } = await harness.inspect(context);
    const remaining = new Map(tasks.map(({ record }) => [record.id, record]));
    let current = remaining.get(binding.taskID);
    const hasCall = current !== undefined;
    while (current && current.conversationId === binding.conversationID) {
        remaining.delete(current.id);
        current = remaining.get(current.owner);
    }
    const foreignSubmission = submissions.some(submission => !hasCall || submission.status !== "placed" ||
        submission.type !== "input" || submission.conversationId !== binding.conversationID);
    if (remaining.size || submissions.length > 1 || foreignSubmission) {
        throw new Error("Harness has unrelated work that needs restart reconciliation.");
    }
    return hasCall;
}

// All inputs come from the local decision path. A delivery result reports acceptance, not execution.
export function deliverApproval(harness, binding, authority, context) {
    return withSchedulingGuard(harness, () => deliver(harness, binding, authority, context));
}

async function deliver(harness, binding, { load, armRecovery }, context) {
    if (!validBinding(binding)) throw new Error("Invalid approval binding.");
    await armRecovery(context);
    await checkScheduling(harness, binding, context);
    const record = await load(binding, context);
    if (!record || !isDeepStrictEqual(record.binding, binding) || !validDecision(record.value, binding.requestID)) {
        throw new Error("Could not verify the saved approval decision.");
    }
    const conversation = await harness.conversation(binding.conversationID, context);
    if (!conversation) return "not_found";
    const result = await conversation.commit(async tx => {
        const receipts = (await tx.doc(Receipts, binding.conversationID)).answers;
        const saved = receipts[binding.taskID];
        if (saved) {
            if (!isDeepStrictEqual(saved, { binding, value: record.value })) {
                throw new Error("A different decision already exists for this approval key.");
            }
            return "duplicate";
        }
        const task = await tx.task(binding.taskID);
        if (!task) return "not_found";
        if (task.conversationId !== binding.conversationID || task.kind !== ToolTask.definition.name) {
            throw new Error("The Harness task does not own this approval binding.");
        }
        if (task.state.status === "terminal" || task.state.status === "completing") return "closed";
        if (!isDeepStrictEqual(task.memos?.[bindingMemo], binding)) {
            throw new Error("The Harness task does not own this approval binding.");
        }
        const delivered = await tx.signal(binding.taskID, approval, binding.requestID, record.value);
        if (delivered === "duplicate") throw new Error("An earlier signal has no verified receipt.");
        if (delivered === "delivered") receipts[binding.taskID] = { binding, value: record.value };
        return delivered;
    }, context);
    if ((result === "delivered" || result === "duplicate") && await checkScheduling(harness, binding, context)) harness.resume();
    return result;
}
