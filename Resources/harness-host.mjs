import { mkdir } from "node:fs/promises";
import { resolve, join } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import { Harness, createRegistry } from "@earendil-works/pi-durable";
import { bouncer } from "./harness-bouncer.mjs";
import { BouncerRequestError } from "./harness-magpie.mjs";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";

const commit = "5a14e69c067d40dfbff4f2fff7d3b34c897e2dc9";
const folder = process.argv[2];
if (!folder || resolve(folder) !== folder || process.argv.length !== 4
    || !/^ROUNDS_HARNESS_RUN_ID=[0-9A-F-]{36}$/.test(process.argv[3])) {
    throw new Error("Expected one absolute data folder.");
}
// The first health request is also the startup handshake. Swift persists ownership before sending it.
// If Swift exits before that write, input closes and this process exits without opening storage.
const models = createModels();
let opening, conversation;
const conversationCommands = ["bouncerOpen", "bouncerSend", "bouncerStop", "bouncerAnswer", "bouncerModel"];
function emit(event, data) {
    if (!closing) process.stdout.write(JSON.stringify({ version: 1, event, ...data }) + "\n");
}
function open() {
    opening ??= (async () => {
        await mkdir(folder, { recursive: true, mode: 0o700 });
        const storage = await openNodeSqliteStorage(join(folder, "harness.sqlite"));
        try {
            return await Harness.open(storage, {
                models, registry: createRegistry(),
                settings: { retry: { enabled: false }, stream: { maxRetries: 0 }, compaction: { enabled: false }, afterFailedRun: "withdraw" },
            }, BACKGROUND_CONTEXT);
        } catch (error) {
            await storage.close(BACKGROUND_CONTEXT);
            throw error;
        }
    })();
    return opening;
}
let closing;
function close() {
    closing ??= (async () => {
        try { if (opening) await (await opening).close(BACKGROUND_CONTEXT); }
        finally { process.stdin.destroy(); }
    })();
    return closing;
}
function fail(error) {
    console.error(error instanceof Error ? error.message : "Host failure.");
    process.exitCode = 1;
    void close().catch(() => { process.exitCode = 1; });
}
process.on("SIGTERM", () => { void close().catch(fail); });
process.stdin.on("end", () => { void close().catch(fail); });
process.stdin.on("error", fail);
process.stdout.on("error", fail);

let buffered = Buffer.alloc(0);
let requests = Promise.resolve();
process.stdin.on("data", (chunk) => {
    buffered = Buffer.concat([buffered, chunk]);
    let end;
    while ((end = buffered.indexOf(10)) !== -1) {
        const line = buffered.subarray(0, end);
        buffered = buffered.subarray(end + 1);
        if (line.length > 65_536) return fail(new Error("Request exceeds 65536 bytes."));
        requests = requests.then(async () => {
            if (closing) return;
            const request = JSON.parse(line.toString("utf8"));
            if (request === null || request.version !== 1 || typeof request.id !== "string"
                || !["health", "shutdown", ...conversationCommands].includes(request.command)) throw new Error("Invalid Harness request.");
            const response = { version: 1, id: request.id, command: request.command, ok: true, commit };
            if (request.command === "health") {
                response.scheduling = (await (await open()).inspect(BACKGROUND_CONTEXT)).scheduling;
            } else if (request.command === "shutdown") {
                await close();
            } else {
                if (!opening) throw new Error("The first Harness request must be health.");
                conversation ??= bouncer(await opening, models, emit);
                try { await conversation(request); } catch (error) {
                    response.ok = false;
                    response.error = error instanceof BouncerRequestError ? error.message : "Rounds could not complete the Bouncer command.";
                }
            }
            process.stdout.write(JSON.stringify(response) + "\n");
        }).catch(fail);
    }
    if (buffered.length > 65_536) fail(new Error("Request exceeds 65536 bytes."));
});
