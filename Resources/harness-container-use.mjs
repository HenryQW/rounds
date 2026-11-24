import { spawn } from "node:child_process";
import { addAbortListener } from "node:events";
import { accessSync, constants, statSync } from "node:fs";
import { basename, dirname, isAbsolute } from "node:path";

// container-use v0.4.2, with mcp-go v0.29.0 and Dagger v0.18.14.
const protocolVersion = "2024-11-05";
const byteLimit = 1024 * 1024;
const callTimeout = 120_000;
const exitTimeout = 2_000;
const environmentID = /^[a-z]+-[a-z]+$/;
const revisionID = /^(?:[a-f0-9]{40}|[a-f0-9]{64})$/;
const dockerEngine = /^docker-container:\/\/[a-f0-9]{64}$/;

const string = value => typeof value === "string";
const nonempty = value => string(value) && value.length > 0;
const nonemptyNulFree = value => nonempty(value) && !value.includes("\0");
const absolute = value => nonemptyNulFree(value) && isAbsolute(value);
const boolean = value => typeof value === "boolean";
const lineNumber = value => Number.isSafeInteger(value) && value > 0;
const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
const validEnvironment = value => string(value) && value.length <= 64 && environmentID.test(value);

const startLine = "start_line_one_indexed_inclusive";
const endLine = "end_line_one_indexed_inclusive";
const tools = {
    environment_create: { required: { title: nonempty } },
    environment_open: {},
    environment_update_metadata: { optional: { title: string } },
    environment_file_read: {
        required: { target_file: nonemptyNulFree },
        optional: { should_read_entire_file: boolean, [startLine]: lineNumber, [endLine]: lineNumber },
    },
    environment_file_list: { required: { path: nonemptyNulFree } },
    environment_file_write: { required: { target_file: nonemptyNulFree, contents: string } },
    environment_file_edit: {
        required: { target_file: nonemptyNulFree, search_text: nonempty, replace_text: string },
        optional: { which_match: string },
    },
    environment_file_delete: { required: { target_file: nonemptyNulFree } },
    environment_run_cmd: { required: { command: nonemptyNulFree } },
};

function toolArguments(name, args, foregroundCommands) {
    if (name === "environment_list") throw new Error("Environment listing is unavailable for a single verified run.");
    if (typeof name !== "string" || !Object.hasOwn(tools, name) ||
        (name === "environment_run_cmd" && !foregroundCommands)) {
        throw new Error("This container-use tool is unavailable in the local bridge.");
    }
    if (!object(args) || ![Object.prototype, null].includes(Object.getPrototypeOf(args))) {
        throw new Error("Container-use arguments must be an object.");
    }
    const { required = {}, optional } = tools[name];
    const fields = { ...required, ...optional, explanation: string };
    const validated = {};
    for (const key of Object.keys(args)) {
        if (!Object.hasOwn(fields, key)) throw new Error(`Unsupported argument for ${name}.`);
        const value = args[key];
        if (!fields[key](value)) throw new Error(`Invalid ${key} argument for ${name}.`);
        if (typeof value === "string" && Buffer.byteLength(value) > byteLimit) {
            throw new Error("The container-use request exceeds the byte limit.");
        }
        validated[key] = value;
    }
    for (const key of Object.keys(required)) {
        if (!Object.hasOwn(validated, key)) throw new Error(`Missing ${key} argument for ${name}.`);
    }
    if (name === "environment_file_read" && !validated.should_read_entire_file &&
        (validated[startLine] === undefined || validated[endLine] === undefined || validated[endLine] < validated[startLine])) {
        throw new Error("Provide an ordered line range or request the entire file.");
    }
    if (Buffer.byteLength(JSON.stringify(validated)) > byteLimit) {
        throw new Error("The container-use request exceeds the byte limit.");
    }
    return validated;
}

function childEnvironment(home, searchPath, daggerCLI, socket, engine) {
    return {
        HOME: home,
        TMPDIR: home,
        PATH: searchPath,
        DOCKER_HOST: `unix://${socket}`,
        DOCKER_CONFIG: "/var/empty",
        GIT_CONFIG_NOSYSTEM: "1",
        GIT_CONFIG_GLOBAL: "/dev/null",
        GIT_CONFIG_COUNT: "2",
        GIT_CONFIG_KEY_0: "core.hookspath",
        GIT_CONFIG_VALUE_0: "/dev/null",
        GIT_CONFIG_KEY_1: "commit.gpgsign",
        GIT_CONFIG_VALUE_1: "false",
        GIT_ALLOW_PROTOCOL: "file",
        GIT_TERMINAL_PROMPT: "0",
        GIT_ASKPASS: "/usr/bin/false",
        GIT_AUTHOR_NAME: "Rounds",
        GIT_AUTHOR_EMAIL: "rounds@example.invalid",
        GIT_COMMITTER_NAME: "Rounds",
        GIT_COMMITTER_EMAIL: "rounds@example.invalid",
        CONTAINER_USE_STDERR_FILE: "/dev/null",
        _EXPERIMENTAL_DAGGER_CLI_BIN: daggerCLI,
        _EXPERIMENTAL_DAGGER_RUNNER_HOST: engine,
    };
}

function response(line, id) {
    const message = JSON.parse(line);
    if (!object(message) || message.jsonrpc !== "2.0" || message.id !== id ||
        Object.keys(message).some(key => !["jsonrpc", "id", "result", "error"].includes(key)) ||
        Object.hasOwn(message, "result") === Object.hasOwn(message, "error")) {
        throw new Error("Unexpected container-use response.");
    }
    if (Object.hasOwn(message, "error")) throw new Error("Container-use returned a JSON-RPC error.");
    return message.result;
}

function toolResult(result) {
    if (!object(result) || Object.keys(result).some(key => !["content", "isError"].includes(key)) ||
        (Object.hasOwn(result, "isError") && !boolean(result.isError)) ||
        !Array.isArray(result.content) || result.content.length !== 1) {
        throw new Error("Invalid container-use tool result.");
    }
    const [content] = result.content;
    if (!object(content) || content.type !== "text" || !string(content.text) ||
        Object.keys(content).some(key => !["type", "text"].includes(key))) {
        throw new Error("Invalid container-use tool content.");
    }
    return result;
}

class InitializationMismatch extends Error {}

function callUpstream(binary, serverVersion, home, env, name, args, signal) {
    const call = JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name, arguments: args } }) + "\n";
    if (Buffer.byteLength(call) > byteLimit) throw new Error("The container-use request exceeds the byte limit.");

    return new Promise((resolve, reject) => {
        // Keep the child in the Harness process group for host crash recovery.
        const child = spawn(binary, ["stdio"], { cwd: home, env, stdio: ["pipe", "pipe", "ignore"] });
        let deadline, forceExit, failure, value;
        let id = 1;
        let received = 0;
        let lineStart = 0;
        const output = Buffer.allocUnsafe(byteLimit);
        const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });

        function fail(error) {
            if (failure) return;
            failure = error;
            clearTimeout(deadline);
            child.kill("SIGTERM");
            child.stdin.destroy();
            forceExit = setTimeout(() => {
                child.kill("SIGKILL");
                child.stdout.destroy();
            }, exitTimeout);
        }

        function accept(line) {
            if (id === 0) throw new Error("Unexpected container-use response after the tool result.");
            const result = response(line, id);
            if (id === 1) {
                if (!object(result) || result.protocolVersion !== protocolVersion ||
                    result.serverInfo?.name !== "Dagger" || result.serverInfo?.version !== serverVersion ||
                    !object(result.capabilities?.tools)) {
                    throw new InitializationMismatch("Incompatible container-use initialization response.");
                }
                id = 2;
                child.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n');
                child.stdin.write(call);
                return;
            }
            value = toolResult(result);
            id = 0;
            child.stdin.end();
            clearTimeout(deadline);
            deadline = setTimeout(() => fail(new Error("Container-use did not exit after its reply.")), exitTimeout);
        }

        const abortListener = signal && addAbortListener(signal, () => {
            fail(new DOMException("The container-use call was cancelled.", "AbortError"));
        });
        child.on("close", (code, exitSignal) => {
            clearTimeout(deadline);
            clearTimeout(forceExit);
            abortListener?.[Symbol.dispose]();
            if (failure) reject(failure);
            else if (lineStart !== received) reject(new Error("Incomplete container-use response line."));
            else if (code !== 0 || id !== 0) {
                reject(new Error(`Container-use exited before a clean reply (${exitSignal ?? code}).`));
            } else resolve(value);
        });
        child.on("error", () => fail(new Error("Could not start or signal container-use.")));
        child.stdin.on("error", () => fail(new Error("Could not write to container-use.")));
        child.stdout.on("error", () => fail(new Error("Could not read from container-use.")));
        child.stdout.on("data", chunk => {
            if (failure) return;
            const end = received + chunk.length;
            if (end > byteLimit) {
                fail(new Error("The container-use response exceeds the byte limit."));
                return;
            }
            // A newline completes a frame. Limit the full stream, including partial lines.
            chunk.copy(output, received);
            try {
                for (let newline = chunk.indexOf(10); newline !== -1; newline = chunk.indexOf(10, newline + 1)) {
                    const lineEnd = received + newline;
                    accept(decoder.decode(output.subarray(lineStart, lineEnd)));
                    lineStart = lineEnd + 1;
                }
                received = end;
            } catch (error) {
                // Parsing errors can contain private data from the wire.
                fail(error instanceof SyntaxError || error instanceof TypeError
                    ? new Error("Malformed container-use response line.") : error);
            }
        });
        deadline = setTimeout(() => fail(new Error("Container-use did not reply in time.")), callTimeout);
        child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {
            protocolVersion, capabilities: {}, clientInfo: { name: "Rounds", version: "1.0.0" },
        } }) + "\n");
    });
}

class CreateToolError extends Error {
    constructor(value) {
        super("Container-use could not create the environment.");
        this.value = value;
    }
}

function executable(file) {
    if (!absolute(file) || dirname(file).includes(":")) return false;
    try {
        if (!statSync(file).isFile()) return false;
        accessSync(file, constants.X_OK);
        return true;
    } catch {
        return false;
    }
}

// Paths and their containing directories must come from the trusted host.
export function containerUse({ binary, daggerCLI, docker, socket, engine, run, verifyEngine, foregroundCommands = false }) {
    if (!boolean(foregroundCommands)) throw new Error("Container-use foregroundCommands must be a boolean.");
    const serverVersion = foregroundCommands ? "1.0.0-rounds-foreground-v1" : "1.0.0";
    if (![binary, daggerCLI, docker].every(executable) || basename(docker) !== "docker") {
        throw new Error("Container-use, Dagger and Docker need trusted absolute executable paths.");
    }
    if (!absolute(socket) || !string(engine) || !dockerEngine.test(engine) || typeof verifyEngine !== "function") {
        throw new Error("Container-use needs an approved Docker container engine and a verifier.");
    }
    if (typeof run?.create !== "function" || typeof run?.use !== "function") {
        throw new Error("Container-use needs a verified run.");
    }
    const searchPath = [...new Set([dirname(docker), "/usr/bin", "/bin", "/usr/sbin", "/sbin"])].join(":");

    return async (name, args, { signal } = {}) => {
        const validated = toolArguments(name, args, foregroundCommands);
        const create = name === "environment_create";
        if (signal !== undefined && !(signal instanceof AbortSignal)) throw new Error("Invalid cancellation signal.");
        signal?.throwIfAborted();
        const engineRequest = { signal, docker, socket };
        async function prepare() {
            signal?.throwIfAborted();
            const generation = await verifyEngine(engine, engineRequest);
            signal?.throwIfAborted();
            if (!nonempty(generation)) throw new Error("Could not verify the approved Docker container engine.");
            return generation;
        }
        async function invoke({ checkout, home, revision, environment }, generation) {
            if (!absolute(checkout) || !absolute(home) || !string(revision) || !revisionID.test(revision) ||
                (!create && !validEnvironment(environment))) {
                throw new Error("Invalid container-use run binding.");
            }
            const bound = { ...validated, environment_source: checkout, ...(create
                ? { from_git_ref: revision } : { environment_id: environment }) };
            signal?.throwIfAborted();
            const env = childEnvironment(home, searchPath, daggerCLI, socket, engine);
            let value;
            try { value = await callUpstream(binary, serverVersion, home, env, name, bound, signal); }
            catch (error) {
                if (create || !(error instanceof InitializationMismatch)) throw error;
                // No tool call was sent. Verify the existing run before releasing its lock.
                value = error;
            }
            const after = await verifyEngine(engine, engineRequest);
            signal?.throwIfAborted();
            if (after !== generation) throw new Error("The Dagger engine restarted during the container-use call.");
            // Command errors can follow Git note updates. A completed use always lets
            // the run verify and record its post-call state, including on isError.
            if (!create) return value;
            if (value.isError) throw new CreateToolError(value);

            // A dirty source adds a warning after the JSON. Refuse that create and
            // leave ownership unrecorded, just as for a malformed identifier.
            let result;
            try { result = JSON.parse(value.content[0].text); }
            catch { throw new Error("Container-use did not return a clean create record."); }
            if (!object(result) || !validEnvironment(result.id)) {
                throw new Error("Container-use returned an invalid environment ID.");
            }
            return { environment: result.id, value };
        }
        if (!create) {
            const value = await run.use(invoke, prepare);
            if (value instanceof InitializationMismatch) throw value;
            return value;
        }
        try { return await run.create(invoke, prepare); }
        catch (error) {
            if (error instanceof CreateToolError) return error.value;
            throw error;
        }
    };
}
