// Offline fixture only. The caller must keep these files private and unchanged during a call.
import { execFileSync } from "node:child_process";
import { lstat, readFile } from "node:fs/promises";
import { join } from "node:path";
import { isDeepStrictEqual } from "node:util";

const builtInConfig = { image: "fixture-default", setup: [], secrets: [] };

async function entry(path) {
    try {
        return await lstat(path);
    } catch (error) {
        if (error.code === "ENOENT") return null;
        throw error;
    }
}

function git(checkout, ...args) {
    const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("GIT_")));
    env.GIT_CONFIG_NOSYSTEM = "1";
    env.GIT_CONFIG_GLOBAL = "/dev/null";
    return execFileSync("git", ["-C", checkout, ...args], { env, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
}

export async function admit(request, tool) {
    const { checkout, recordPath, statePath, operation, environment, run, revision } = request;
    if (!["create", "load"].includes(operation) ||
        ![environment, run, revision].every(value => typeof value === "string" && value.length > 0)) {
        throw new Error("Invalid fixture request");
    }
    const record = JSON.parse(await readFile(recordPath, "utf8"));
    if (record.environment !== environment || record.run !== run || record.revision !== revision ||
        typeof record.container !== "string" || !record.container || !isDeepStrictEqual(record.config, builtInConfig)) {
        throw new Error("Unverified fixture record");
    }
    if (git(checkout, "rev-parse", "HEAD") !== revision) {
        throw new Error("Unverified checkout revision");
    }
    const { ownedMetadata } = record;
    if (!ownedMetadata || !Array.isArray(ownedMetadata.remotes) || !Array.isArray(ownedMetadata.notes) ||
        !ownedMetadata.remotes.every(remote => typeof remote.name === "string" && typeof remote.url === "string") ||
        !ownedMetadata.notes.every(note => typeof note.ref === "string" && typeof note.oid === "string")) {
        throw new Error("Unverified checkout metadata");
    }
    const remotes = git(checkout, "remote", "-v").split("\n").filter(Boolean).sort();
    const notes = git(checkout, "for-each-ref", "--format=%(refname) %(objectname)", "refs/notes/").split("\n").filter(Boolean).sort();
    const expectedRemotes = operation === "create" ? [] : ownedMetadata.remotes.flatMap(remote => [
        `${remote.name}\t${remote.url} (fetch)`, `${remote.name}\t${remote.url} (push)`,
    ]).sort();
    const expectedNotes = operation === "create" ? [] : ownedMetadata.notes.map(note => `${note.ref} ${note.oid}`).sort();
    if (!isDeepStrictEqual(remotes, expectedRemotes) || !isDeepStrictEqual(notes, expectedNotes)) {
        throw new Error("Unverified checkout metadata");
    }
    if (operation === "create") {
        const dir = join(checkout, ".container-use");
        const stat = await entry(dir);
        if (stat && (!stat.isDirectory() || await entry(join(dir, "environment.json")))) {
            throw new Error("Fixture configuration is present or linked");
        }
    } else {
        const state = JSON.parse(await readFile(statePath, "utf8"));
        if (state.environment !== record.environment || state.run !== record.run || state.revision !== record.revision) {
            throw new Error("Unverified fixture state identity");
        }
        if (state.container !== record.container) {
            throw new Error("Unverified fixture container");
        }
        if (!isDeepStrictEqual(state.config, record.config)) {
            throw new Error("Unverified fixture state config");
        }
    }
    return tool(request);
}
