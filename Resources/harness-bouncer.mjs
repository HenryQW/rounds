import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { AssistantEntry, configure, defineDoc, LiveDoc, UserEntry } from "@earendil-works/pi-durable";
import { BouncerRequestError, registerMagpie } from "./harness-magpie.mjs";

const marker = "ROUNDS_QUESTION ";
const instructions = `You are the Rounds Bouncer. Help the user understand and plan work. You have no tools and cannot perform actions.
When you need an ordinary answer, use one line that starts with ${marker}followed by a JSON object. Use title and either an options array of one to three strings or no options for a text answer. With options, use recommended for the zero-based index of the recommended option. Use this format for the whole reply. Do not use it for approval to perform an action.`;
const answerKind = "rounds.answer";
const stoppedKind = "rounds.stopped";
const interruptedKind = "rounds.interrupted";
const liveID = "live-reply";
const Selection = defineDoc({
    kind: "rounds.model", version: 1, scope: "conversation", history: "rewindable", fork: "asOf",
    initial: () => ({ model: null }), checkpointWhen: () => true,
});

function text(content) {
    return typeof content === "string" ? content : (content ?? []).filter(block => block.type === "text").map(block => block.text).join("");
}

function questionPrefix(body) {
    return marker.startsWith(body) || body.startsWith(marker);
}

function question(body) {
    if (!body.startsWith(marker) || body.length > 4096) return;
    let parsed;
    try { parsed = JSON.parse(body.slice(marker.length)); } catch { return; }
    const { title, options = [], recommended } = parsed ?? {};
    if (typeof title !== "string" || !title.trim() || !Array.isArray(options) || options.length > 3
        || options.some(option => typeof option !== "string" || !option.trim())
        || (recommended !== undefined && (!Number.isInteger(recommended) || recommended < 0 || recommended >= options.length))) return;
    return { title, options, recommended };
}

function answerText(question, answer) {
    if (answer?.kind === "option" && Number.isInteger(answer.index) && question.options[answer.index] !== undefined) {
        return question.options[answer.index];
    }
    if (answer?.kind === "text" && question.options.length === 0 && typeof answer.text === "string" && answer.text.trim()) {
        return answer.text;
    }
    throw new BouncerRequestError("Choose an option or enter an answer to this question.");
}

// The app owns this database and projects the reserved root into its window.
export function bouncer(harness, models, emit) {
    let root, catalog, lastEntry, pending, active;
    const interrupted = new Set();

    function delta(id, body) {
        let chunk = "";
        for (const char of body) {
            chunk += char;
            if (chunk.length >= 4096) { emit("delta", { itemID: id, text: chunk }); chunk = ""; }
        }
        if (chunk) emit("delta", { itemID: id, text: chunk });
    }

    function project(entry, interrupted) {
        if (entry.kind === stoppedKind) {
            emit("stopped", { itemID: entry.id });
            return true;
        }
        const message = entry.model?.[0];
        if (entry.kind === answerKind) {
            if (entry.data.questionID === pending?.id) pending = undefined;
            emit("answered", entry.data);
        } else if (UserEntry.is(entry)) {
            emit("user", { itemID: entry.id });
            delta(entry.id, text(message?.content));
        } else if (AssistantEntry.is(entry)) {
            const body = text(message?.content);
            const q = message?.stopReason === "stop" ? question(body) : undefined;
            if (q) {
                pending = { id: entry.id, ...q };
                emit("question", { itemID: entry.id, ...q });
            } else if (body && (message?.stopReason !== "aborted" || !questionPrefix(body))) {
                emit("reply", { itemID: entry.id });
                delta(entry.id, body);
            }
            if (message?.stopReason === "aborted" && !interrupted.has(entry.id)) {
                emit("stopped", { itemID: `stopped-${entry.id}` });
                return true;
            }
        }
    }

    async function allEntries() {
        let cursor;
        const result = [];
        do {
            const page = await root.entries({ order: "ascending" }, 64, cursor, context);
            result.push(...page.items);
            cursor = page.next;
        } while (cursor !== undefined);
        return result;
    }

    async function entries() {
        let cursor, stopped = false;
        do {
            const page = await root.entries({ order: "ascending", minEntryId: lastEntry }, 64, cursor, context);
            for (const entry of page.items) {
                if (entry.id === lastEntry) continue;
                if (project(entry, interrupted)) stopped = true;
                lastEntry = entry.id;
            }
            cursor = page.next;
        } while (cursor !== undefined);
        return stopped;
    }

    async function open() {
        if (root) throw new BouncerRequestError("The Bouncer conversation is already open.");
        catalog = await registerMagpie(models);
        const conversation = await harness.root(context);
        const selection = await conversation.commit(async tx => (await tx.doc(Selection, conversation.id)).model, context);
        let model, issue;
        try { model = catalog.resolve(selection); } catch (error) {
            if (!(error instanceof BouncerRequestError)) throw error;
            issue = error.message;
        }
        const state = await harness.inspect(context);
        if (state.tasks.some(task => task.record.conversationId !== conversation.id)
            || state.submissions.some(submission => submission.conversationId !== conversation.id)) {
            throw new BouncerRequestError("The Harness has work outside the Bouncer conversation. Rounds cannot resume it.");
        }
        await conversation.configure({
            model: model ?? null, thinkingLevel: catalog.thinkingLevel, extensions: [], tools: [], modelTools: [],
            instructions, maxTurns: 1,
        }, context);
        root = conversation;
        const hasWork = state.tasks.length || state.submissions.length;
        let recovered = await allEntries();
        const isInput = entry => UserEntry.is(entry) || entry.kind === answerKind;
        const lastInput = recovered.findLast(isInput);
        if (hasWork && lastInput && !recovered.some(entry => entry.kind === interruptedKind && entry.data.afterID === lastInput.id)) {
            await root.commit(tx => tx.appendEntry(root.id, { kind: interruptedKind, data: { afterID: lastInput.id } }), context);
        }
        // Save recovery intent before aborting work, so a second crash cannot turn it into a user stop.
        for (const submission of state.submissions) {
            if (submission.status === "queued") await harness.abortSubmission(submission.id, context, conversation.id);
        }
        for (const task of state.tasks) await harness.abortTask(task.record.id, context);
        if (hasWork) await conversation.abort(context);
        recovered = await allEntries();
        for (const marker of recovered.filter(entry => entry.kind === interruptedKind)) {
            const start = recovered.findIndex(entry => entry.id === marker.data.afterID);
            if (start < 0) continue;
            const next = recovered.findIndex((entry, index) => index > start && isInput(entry));
            const aborted = recovered.slice(start + 1, next < 0 ? undefined : next)
                .findLast(entry => AssistantEntry.is(entry) && entry.model?.[0]?.stopReason === "aborted");
            if (aborted) interrupted.add(aborted.id);
        }
        emit("started", { model: model ? `magpie/${model.modelId}` : null, selection });
        root = conversation;
        for (const id of catalog.models) emit("model", { model: id });
        await entries();
        if (hasWork || (lastInput && recovered.some(entry => entry.kind === interruptedKind && entry.data.afterID === lastInput.id))) {
            emit("failed", { text: "The previous Bouncer reply was interrupted. Send a message to continue." });
        }
        if (issue) emit("failed", { text: issue });
    }

    async function finish(turn) {
        try {
            const result = await turn.submission.wait(context);
            await turn.watch.stop();
            if (turn.partial) emit("remove", { itemID: liveID });
            const stopped = await entries();
            if (result.status === "unanswered") {
                if (result.reason === "aborted") {
                    if (!stopped) {
                        await root.submit({ type: "write", entry: { kind: stoppedKind } }, context);
                        await entries();
                    }
                } else {
                    // A provider error can contain credentials or the request body.
                    emit("failed", { text: result.reason === "no_model"
                        ? "Choose an available Magpie model and try again."
                        : "Magpie did not complete the reply. Check the provider or choose another model." });
                }
            }
        } catch {
            emit("failed", { text: "Rounds could not finish the Bouncer reply." });
        } finally {
            active = undefined;
            emit("replying", { replying: false });
        }
    }

    async function submit(id, content, entry) {
        if (typeof content !== "string" || !content.trim()) throw new BouncerRequestError("Enter a message first.");
        const ref = (await root.agent(context)).model;
        if (!ref) throw new BouncerRequestError("Choose a Magpie model first.");
        catalog.resolve(`${ref.provider}/${ref.modelId}`);
        const watch = await harness.watchDoc(LiveDoc, root.id, context);
        let submission;
        try {
            submission = await root.submit({ type: "input", content, entry, requestId: id, whenBusy: "reject" }, context);
        } catch (error) {
            await watch.stop();
            throw error;
        }
        emit("banner", { text: null });
        emit("replying", { replying: true });
        await entries();
        const turn = { submission, watch, partial: "" };
        active = turn;
        watch.start(async call => {
            if (call.kind !== "value" || active !== turn) return;
            const body = text(call.value?.generation?.message?.content);
            // Hold the protocol prefix and question body until the whole answer can be validated.
            if (!body || questionPrefix(body) || body === turn.partial) return;
            if (!turn.partial || !body.startsWith(turn.partial)) emit("reply", { itemID: liveID });
            delta(liveID, body.startsWith(turn.partial) ? body.slice(turn.partial.length) : body);
            turn.partial = body;
        });
        turn.done = finish(turn);
    }

    return async function command(request) {
        if (request.command === "bouncerOpen") return open();
        if (!root) throw new BouncerRequestError("The Bouncer conversation is not open.");
        if (request.command === "bouncerStop") {
            if (active) { const { done } = active; await root.abort(context); await done; }
            return;
        }
        if (active) throw new BouncerRequestError("Wait for the current Bouncer reply to finish.");
        switch (request.command) {
            case "bouncerSend":
                if (pending) throw new BouncerRequestError("Answer or dismiss the open question first.");
                return submit(request.id, request.text);
            case "bouncerAnswer": {
                if (request.questionID !== pending?.id || !pending) throw new BouncerRequestError("This question is no longer open.");
                const data = { questionID: pending.id, answer: request.answer };
                if (request.answer?.kind === "dismissed") {
                    await root.submit({ type: "write", requestId: request.id, entry: { kind: answerKind, data } }, context);
                    return entries();
                }
                const answer = answerText(pending, request.answer);
                return submit(request.id, `Answer to "${pending.title}": ${answer}`, { kind: answerKind, data });
            }
            case "bouncerModel": {
                const model = catalog.resolve(request.model);
                await root.commit(async tx => {
                    (await tx.doc(Selection, root.id)).model = request.model;
                    await configure(tx, root.id, { model });
                }, context);
                emit("selectedModel", { model: `magpie/${model.modelId}`, selection: request.model });
                emit("banner", { text: null });
                return;
            }
        }
    };
}
