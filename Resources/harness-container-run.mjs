import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { once } from "node:events";
import { lstat, mkdir, open, readFile, readdir, realpath, rename, rmdir } from "node:fs/promises";
import { dirname, join, relative, resolve, sep } from "node:path";
import { isDeepStrictEqual } from "node:util";

const identifier = /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$/;
const objectID = /^[0-9a-f]{40}$/;
const stateRef = "refs/notes/container-use-state";
const logRef = "refs/notes/container-use";
const builtIn = { base_image: "ubuntu:24.04", workdir: "/workdir" };
const gitEnv = {
    PATH: "/usr/bin:/bin", HOME: "/var/empty", GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_ATTR_NOSYSTEM: "1", GIT_NO_REPLACE_OBJECTS: "1", GIT_OPTIONAL_LOCKS: "0",
    GIT_TERMINAL_PROMPT: "0", GIT_ALLOW_PROTOCOL: "file", LC_ALL: "C",
};

function requireThat(ok, message) {
    if (!ok) throw new Error(message);
}

const gitOptions = ["-c", "core.attributesFile=/dev/null", "-c", "core.fileMode=true",
    "-c", "core.hookspath=/dev/null", "-c", "core.fsmonitor=false",
    "-c", "gc.auto=0", "-c", "maintenance.auto=false"];

function git(cwd, ...args) {
    const result = spawnSync("/usr/bin/git", [...gitOptions, ...args], {
        cwd, env: gitEnv, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"],
    });
    // Git diagnostics can contain the stored state. Only report the command name.
    requireThat(result.status === 0 && !result.stderr, `Container run Git ${args[0]} check failed.`);
    return result.stdout;
}

async function entry(path) {
    try {
        return await lstat(path, { bigint: true });
    } catch (error) {
        if (error.code === "ENOENT") return null;
        throw error;
    }
}

function identity(stat) {
    return [stat.dev, stat.ino, stat.uid, stat.mode].map(String);
}

function owned(stat) {
    return stat?.uid === BigInt(process.geteuid()) && (stat.mode & 0o7022n) === 0n;
}

async function directory(path, privateMode = false) {
    const stat = await entry(path);
    requireThat(owned(stat) && stat.isDirectory() && (!privateMode || (stat.mode & 0o777n) === 0o700n),
        "Invalid container run directory.");
    return identity(stat);
}

async function file(path, privateMode = false) {
    const stat = await entry(path);
    requireThat(owned(stat) && stat.isFile() && stat.nlink === 1n && (!privateMode || (stat.mode & 0o777n) === 0o600n),
        "Invalid container run file.");
    return stat;
}

async function read(path, privateMode = false) {
    await file(path, privateMode);
    return readFile(path, "utf8");
}

async function syncDirectory(path) {
    const handle = await open(path, "r");
    try { await handle.sync(); }
    finally { await handle.close(); }
}

async function save(path, temporary, data) {
    const handle = await open(temporary, "wx", 0o600);
    try {
        await handle.writeFile(JSON.stringify(data) + "\n");
        await handle.sync();
    } finally {
        await handle.close();
    }
    await rename(temporary, path);
    await syncDirectory(dirname(path));
}

function parseJSON(text, message) {
    try { return JSON.parse(text); }
    catch { throw new Error(message); }
}

function digest(value) {
    return createHash("sha256").update(value).digest("hex");
}

// Inspect Git's control files before any command can follow them. Only the
// stock layouts from init, fetch, push, worktree and notes are supported.
async function metadata(path, allowed) {
    for (const name of await readdir(path)) {
        requireThat((!allowed || allowed.has(name)) && !name.endsWith(".lock"), "Unexpected container run Git metadata.");
        const child = join(path, name);
        const stat = await entry(child);
        requireThat(owned(stat), "Invalid container run Git metadata.");
        if (stat.isDirectory()) {
            await metadata(child, name === "info" || name === "hooks" ? new Set() : undefined);
        } else {
            requireThat(stat.isFile() && stat.nlink === 1n, "Invalid container run Git metadata file.");
        }
    }
}

const repositoryFiles = ["HEAD", "config", "description", "hooks", "info", "objects", "packed-refs", "refs", "logs"];
const sourceFiles = new Set([...repositoryFiles, "FETCH_HEAD", "index"]);
const forkFiles = new Set([...repositoryFiles, "worktrees"]);
const worktreeFiles = new Set(["HEAD", "ORIG_HEAD", "COMMIT_EDITMSG", "commondir", "gitdir", "index", "logs", "refs"]);

async function repositoryConfig(path, bare, extra = new Map()) {
    const raw = await read(path);
    const output = git(dirname(path), "config", "--file", path, "--no-includes", "--null", "--list");
    const entries = output.split("\0").slice(0, -1).map(line => {
        const separator = line.indexOf("\n");
        requireThat(separator > 0, "Invalid container run Git configuration.");
        return [line.slice(0, separator), line.slice(separator + 1)];
    });
    const settings = new Map(entries);
    const expected = new Map([
        ["core.repositoryformatversion", "0"], ["core.bare", String(bare)],
        ["core.filemode", settings.get("core.filemode")], ...extra,
    ]);
    if (!bare) expected.set("core.logallrefupdates", "true");
    for (const key of ["core.ignorecase", "core.precomposeunicode"]) {
        if (settings.has(key)) expected.set(key, "true");
    }
    requireThat(["true", "false"].includes(settings.get("core.filemode")) && settings.size === entries.length &&
        isDeepStrictEqual(settings, expected), "Unexpected container run Git configuration.");
    return { config: digest(raw), core: new Map([...settings].filter(([key]) => key.startsWith("core."))) };
}

function refs(path) {
    return new Map(git(path, "for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)")
        .split("\n").filter(Boolean).map(line => {
            const [ref, oid, symref] = line.split("\0");
            requireThat(objectID.test(oid) && symref === "", "Invalid container run Git ref.");
            return [ref, oid];
        }));
}

async function clean(path, message, ignored) {
    requireThat(git(path, "status", "--porcelain=v1", "--untracked-files=all", `--ignored=${ignored}`,
        "--ignore-submodules=none") === "", message);
    const child = spawn("/usr/bin/git", [...gitOptions, "ls-files", "-v", "-z"], {
        cwd: path, env: gitEnv, stdio: ["ignore", "pipe", "pipe"],
    });
    let warned = false;
    child.stderr.on("data", () => { warned = true; });
    async function normalIndex() {
        let tail = "";
        let valid = true;
        for await (const chunk of child.stdout.setEncoding("utf8")) {
            const records = (tail + chunk).split("\0");
            tail = records.pop();
            valid &&= records.every(line => line.startsWith("H "));
        }
        return valid && tail === "";
    }
    const [[code], normal] = await Promise.all([once(child, "close"), normalIndex()]);
    requireThat(code === 0 && !warned, "Container run Git ls-files check failed.");
    requireThat(normal, message);
}

function ancestor(path, previous, current) {
    if (previous !== current) git(path, "merge-base", "--is-ancestor", previous, current);
}

function readNote(worktree, head) {
    const entries = new Map(git(worktree, "notes", "--ref", stateRef, "list").trimEnd().split("\n").filter(Boolean)
        .map(line => {
            const [blob, target, extra] = line.split(" ");
            requireThat(objectID.test(blob) && objectID.test(target) && extra === undefined, "Invalid container run state note entry.");
            return [target, blob];
        }));
    const noteBlob = entries.get(head);
    requireThat(objectID.test(noteBlob), "Invalid container run state note identity.");
    const text = git(worktree, "cat-file", "blob", noteBlob);
    const hash = createHash("sha1").update(`blob ${Buffer.byteLength(text)}\0`).update(text).digest("hex");
    const message = "Invalid container run state note.";
    requireThat(hash === noteBlob, message);
    const state = parseJSON(text, message);
    requireThat(state && Object.keys(state).every(key => ["created_at", "updated_at", "config", "container", "title"].includes(key)) &&
        isDeepStrictEqual(state.config, builtIn) && typeof state.container === "string" && /^[^\s\x00-\x1f\x7f]+$/u.test(state.container) &&
        (state.title === undefined || typeof state.title === "string") &&
        [state.created_at, state.updated_at].every(time => typeof time === "string" &&
            /^\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,9})?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$/.test(time) &&
            Number.isFinite(Date.parse(time)) && new Date(`${time.slice(0, 10)}T00:00:00Z`).toISOString().startsWith(time.slice(0, 10))), message);
    // Go merges duplicate config objects. JSON.parse keeps only the last one.
    const keys = [...text.matchAll(/"(?:[^"\\]|\\.)*"(\s*:)?/gs)].filter(match => match[1]);
    requireThat(keys.length === Object.keys(state).length + Object.keys(builtIn).length, message);
    return { entries, noteBlob, container: digest(state.container), config: state.config };
}

// The caller controls the private folder and keeps all other writers out.
// invoke must await transport completion before returning and use the supplied HOME.
export function openContainerRun({ folder, run, source, revision }) {
    requireThat([folder, source].every(path => typeof path === "string" && resolve(path) === path && !/[\x00-\x1f\x7f]/.test(path)) &&
        typeof run === "string" && identifier.test(run) && typeof revision === "string" && objectID.test(revision),
        "Invalid container run request.");
    const root = join(folder, run);
    const checkout = join(root, "source");
    const gitDir = join(checkout, ".git");
    const home = join(root, "state");
    const base = join(home, ".config", "container-use");
    const repos = join(base, "repos");
    const worktrees = join(base, "worktrees");
    // container-use v0.4.2 maps a local source path to this path below repos.
    const fork = join(repos, checkout.slice(1).replace(/[:<>|?*"]/g, "_"));
    const record = join(root, "ownership.json");
    const temporary = record + ".tmp";
    const lock = join(folder, `.${run}.lock`);
    const binding = { version: 1, source, run, revision };
    const locations = [folder, root, checkout, home, dirname(base), base, repos, worktrees];

    async function basePaths() {
        const paths = [];
        for (const path of locations) paths.push(await directory(path, true));
        return [...paths, await directory(gitDir)];
    }

    async function locked(action) {
        requireThat(await realpath(folder) === folder, "Container run folder must be physical.");
        const owner = await directory(folder, true);
        try { await mkdir(lock, { mode: 0o700 }); }
        catch (error) {
            if (error.code === "EEXIST") throw new Error("Container run is locked.");
            throw error;
        }
        const held = await directory(lock, true);
        await syncDirectory(folder);
        async function verifyLock() {
            requireThat(await realpath(folder) === folder && isDeepStrictEqual(await directory(folder, true), owner) &&
                isDeepStrictEqual(await directory(lock, true), held), "Container run lock identity changed.");
        }
        let invoked = false;
        let finished = false;
        try {
            const value = await action(verifyLock, async (invoke, request, prepared) => {
                await verifyLock();
                invoked = true;
                return invoke(request, prepared);
            });
            finished = true;
            return value;
        } finally {
            // Preserve ownership after an uncertain operation for the restart gate.
            if (!invoked || finished) {
                await verifyLock();
                await rmdir(lock);
                await syncDirectory(folder);
            }
        }
    }

    async function checkSource(expectedRemote) {
        await metadata(gitDir, sourceFiles);
        const remote = expectedRemote ? new Map([
            ["remote.container-use.url", fork], ["remote.container-use.fetch", "+refs/heads/*:refs/remotes/container-use/*"],
        ]) : new Map();
        const settings = await repositoryConfig(join(gitDir, "config"), false, remote);
        requireThat(await read(join(gitDir, "HEAD")) === revision + "\n" &&
            git(checkout, "rev-parse", "--verify", "HEAD^{commit}").trimEnd() === revision, "Container source revision changed.");
        const configDir = join(checkout, ".container-use");
        const configEntry = await entry(configDir);
        requireThat(!configEntry || (configEntry.isDirectory() && !await entry(join(configDir, "environment.json"))),
            "Container source configuration is present or linked.");
        await clean(checkout, "Container source is dirty.", "matching");
        const index = join(gitDir, "index");
        await file(index);
        return { ...settings, index: digest(await readFile(index)) };
    }

    async function inspect(environment, expectedPaths) {
        requireThat(typeof environment === "string" && identifier.test(environment), "Invalid container environment identifier.");
        const paths = await basePaths();
        requireThat(isDeepStrictEqual(paths.slice(0, expectedPaths.length), expectedPaths), "Container run paths changed.");
        const worktree = join(worktrees, environment);
        const admin = join(fork, "worktrees", environment);
        let parent = repos;
        for (const name of relative(repos, fork).split(sep)) {
            parent = join(parent, name);
            paths.push(await directory(parent));
        }
        for (const path of [worktree, dirname(admin), admin]) paths.push(await directory(path));
        const pointer = join(worktree, ".git");
        const pointerID = identity(await file(pointer));
        const pointerText = await readFile(pointer, "utf8");
        const target = `gitdir: ${admin}`;
        requireThat(pointerText === target || pointerText === target + "\n", "Invalid container worktree pointer.");
        await metadata(fork, forkFiles);
        requireThat(isDeepStrictEqual(await readdir(dirname(admin)), [environment]), "Foreign container worktree metadata.");
        await metadata(admin, worktreeFiles);
        const adminRefs = join(admin, "refs");
        if (await entry(adminRefs)) requireThat((await readdir(adminRefs)).length === 0, "Foreign container worktree refs.");
        const branch = `refs/heads/${environment}`;
        requireThat(await read(join(admin, "commondir")) === "../..\n" &&
            await read(join(admin, "gitdir")) === pointer + "\n" &&
            await read(join(admin, "HEAD")) === `ref: ${branch}\n`, "Invalid container worktree Git metadata.");
        const forkSettings = await repositoryConfig(join(fork, "config"), true);
        const forkHead = await read(join(fork, "HEAD"));
        requireThat(/^ref: refs\/heads\/[a-zA-Z0-9_-]+\n$/.test(forkHead), "Invalid container fork HEAD.");
        const { core, ...sourceState } = await checkSource(true);
        const forkRefs = refs(fork);
        const head = forkRefs.get(branch);
        const notes = forkRefs.get(stateRef);
        const log = forkRefs.get(logRef);
        requireThat(head && notes && forkRefs.size === (log ? 3 : 2), "Unexpected container fork refs.");
        const sourceRefs = new Map([[`refs/remotes/container-use/${environment}`, head], [stateRef, notes]]);
        if (log) sourceRefs.set(logRef, log);
        requireThat(isDeepStrictEqual(refs(checkout), sourceRefs), "Unexpected container source refs.");
        requireThat(git(worktree, "rev-parse", "--verify", "HEAD^{commit}").trimEnd() === head && head !== revision,
            "Invalid container worktree revision.");
        ancestor(worktree, revision, head);
        for (const oid of [notes, log].filter(Boolean)) {
            requireThat(git(fork, "cat-file", "-t", oid) === "commit\n", "Invalid container notes ref.");
        }
        // Upstream exports ignored artifacts. The saved note remains the source
        // of truth. A partial export can still change tracked files without a note.
        await clean(worktree, "Container worktree is dirty.", "no");
        const { entries, ...note } = readNote(worktree, head);
        return { core, worktree, entries, snapshot: { paths, pointerID, sourceState, forkConfig: forkSettings.config, forkHead,
            head, notes, log: log ?? null, ...note } };
    }

    return {
        create(invoke, prepare) {
            return locked(async (verifyLock, call) => {
                requireThat(!await entry(root), "Container run already has state.");
                const prepared = await prepare?.();
                for (const path of locations.slice(1)) await mkdir(path, { mode: 0o700 });
                git(checkout, "init", "--quiet", "--template=", "--object-format=sha1");
                git(checkout, "fetch", "--quiet", "--no-tags", "--no-recurse-submodules", "--no-write-fetch-head", "--", source, revision);
                git(checkout, "checkout", "--quiet", "--detach", revision);
                const paths = await basePaths();
                const initial = await checkSource(false);
                requireThat(refs(checkout).size === 0 && !await entry(record) && !await entry(temporary), "Container run already has state.");
                const { environment, value } = await call(invoke, { checkout, home, revision }, prepared);
                const { core, entries, snapshot } = await inspect(environment, paths);
                requireThat(isDeepStrictEqual(core, initial.core) && snapshot.sourceState.index === initial.index &&
                    !await entry(record), "Container source metadata changed during creation.");
                requireThat(entries.size === 1, "Foreign container state notes.");
                await verifyLock();
                await save(record, temporary, { ...binding, environment, snapshot });
                return value;
            });
        },
        use(invoke, prepare) {
            return locked(async (verifyLock, call) => {
                const paths = await basePaths();
                const raw = await read(record, true);
                const saved = parseJSON(raw, "Invalid container run ownership record.");
                requireThat(saved && Object.entries(binding).every(([key, value]) => saved[key] === value) && !await entry(temporary),
                    "Container run ownership does not match the request.");
                const { environment } = saved;
                const before = await inspect(environment, paths);
                requireThat(isDeepStrictEqual(before.snapshot, saved.snapshot), "Container run state changed since ownership was recorded.");
                const prepared = await prepare?.();
                const value = await call(invoke, { checkout, home, revision, environment }, prepared);
                const after = await inspect(environment, paths);
                const { snapshot: old } = before;
                const { snapshot: next } = after;
                requireThat(isDeepStrictEqual(next.paths, old.paths) && isDeepStrictEqual(next.sourceState, old.sourceState) &&
                    next.forkConfig === old.forkConfig && next.forkHead === old.forkHead &&
                    await read(record, true) === raw && !await entry(temporary),
                    "Container run ownership changed during use.");
                ancestor(after.worktree, old.head, next.head);
                ancestor(after.worktree, old.notes, next.notes);
                if (old.log) {
                    requireThat(next.log, "Container run log note ref disappeared.");
                    ancestor(after.worktree, old.log, next.log);
                }
                requireThat(next.notes !== old.notes || isDeepStrictEqual(next, { ...old, log: next.log }),
                    "Container run state changed without a new state note.");
                const expectedNotes = new Map(before.entries).set(next.head, next.noteBlob);
                requireThat(isDeepStrictEqual(after.entries, expectedNotes), "Unexpected container state note changes.");
                await verifyLock();
                if (!isDeepStrictEqual(next, old)) await save(record, temporary, { ...binding, environment, snapshot: next });
                return value;
            });
        },
    };
}
