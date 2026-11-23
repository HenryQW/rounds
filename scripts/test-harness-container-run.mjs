import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmod, lstat, mkdir, mkdtemp, readFile, realpath, rename, rm, symlink, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { openContainerRun } from "../Resources/harness-container-run.mjs";

const stateRef = "refs/notes/container-use-state";
const environment = "calm-otter";
const container = "fixture-container";
const config = { workdir: "/workdir", base_image: "ubuntu:24.04" };
const stamp = "2026-11-23T12:34:56.123456789Z";
const note = { created_at: stamp, updated_at: stamp, config, container, title: "Fixture" };
const gitEnv = {
    PATH: "/usr/bin:/bin", GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_AUTHOR_NAME: "Fixture", GIT_AUTHOR_EMAIL: "test@example.invalid",
    GIT_COMMITTER_NAME: "Fixture", GIT_COMMITTER_EMAIL: "test@example.invalid",
};

function git(path, ...args) {
    return execFileSync("/usr/bin/git", ["-C", path, ...args], {
        env: gitEnv, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"],
    }).trim();
}

async function fixture(t, files = {}) {
    const root = await mkdtemp(join(await realpath(tmpdir()), "rounds-container-run-"));
    t.after(() => rm(root, { recursive: true, force: true }));
    const folder = join(root, "private");
    const source = join(root, "input");
    await mkdir(folder, { mode: 0o700 });
    await mkdir(source);
    git(source, "init", "-q", "--template=", "-b", "main");
    await writeFile(join(source, "selected.txt"), "selected\n");
    await writeFile(join(source, ".gitignore"), "/.container-use/\n");
    for (const [file, content] of Object.entries(files)) await writeFile(join(source, file), content);
    git(source, "add", ".");
    git(source, "commit", "-qm", "Selected revision");
    const revision = git(source, "rev-parse", "HEAD");
    await writeFile(join(source, "selected.txt"), "later\n");
    git(source, "commit", "-qam", "Later revision");
    git(source, "remote", "add", "origin", "https://example.invalid/not-copied");
    git(source, "notes", "add", "-m", "not copied", revision);
    const options = { folder, run: "run-1", source, revision };
    const rootRun = join(folder, options.run);
    const checkout = join(rootRun, "source");
    const home = join(rootRun, "state");
    const base = join(home, ".config", "container-use");
    const fork = join(base, "repos", checkout.slice(1));
    const worktree = join(base, "worktrees", environment);
    const record = join(rootRun, "ownership.json");
    let calls = 0;
    function counted(invoke = () => undefined) {
        return async args => {
            calls++;
            return invoke(args);
        };
    }
    function saveState(state = note) {
        git(worktree, "notes", "--ref", stateRef, "add", "-f", "-m",
            typeof state === "string" ? state : JSON.stringify(state));
        git(checkout, "fetch", "-q", "container-use", `${stateRef}:${stateRef}`);
    }
    const create = counted(async args => {
        assert.deepEqual(args, { checkout, home, revision });
        assert.equal(await readFile(join(checkout, "selected.txt"), "utf8"), "selected\n");
        assert.equal(git(checkout, "remote"), "");
        assert.equal(git(checkout, "for-each-ref"), "");
        await mkdir(fork, { recursive: true });
        git(fork, "init", "-q", "--bare", "--template=");
        git(checkout, "remote", "add", "container-use", fork);
        git(checkout, "push", "-q", "container-use", `${revision}:refs/heads/${environment}`);
        git(fork, "worktree", "add", "-q", worktree, environment);
        git(worktree, "commit", "-qm", "Create environment", "--allow-empty");
        // The upstream export writes this pointer without a final newline.
        await writeFile(join(worktree, ".git"), `gitdir: ${join(fork, "worktrees", environment)}`);
        git(checkout, "fetch", "-q", "container-use", environment);
        saveState();
        return { environment, value: "created" };
    });
    async function closed() {
        const before = calls;
        await assert.rejects(open().use(counted()));
        assert.equal(calls, before);
    }
    function open(overrides = {}) { return openContainerRun({ ...options, ...overrides }); }
    return { options, rootRun, checkout, home, base, fork, worktree, record, create, saveState, counted, closed, open,
        lock: join(folder, `.${options.run}.lock`), calls: () => calls };
}

test("imports the pinned commit into a private run and reopens it from disk", async t => {
    const f = await fixture(t, { ".gitattributes": "*.txt filter=probe\n" });
    const previous = process.env.GIT_CONFIG_GLOBAL;
    const global = join(f.options.folder, "untrusted-global");
    await writeFile(global, "[filter \"probe\"]\nrequired = true\nsmudge = false\n");
    process.env.GIT_CONFIG_GLOBAL = global;
    t.after(() => {
        if (previous === undefined) delete process.env.GIT_CONFIG_GLOBAL;
        else process.env.GIT_CONFIG_GLOBAL = previous;
    });
    assert.equal(await f.open().create(f.create), "created");
    for (const path of [f.rootRun, f.checkout, f.home, f.base]) {
        assert.equal((await lstat(path)).mode & 0o777, 0o700);
    }
    assert.equal((await lstat(f.record)).mode & 0o777, 0o600);
    assert.equal(await f.open().use(f.counted(args => {
        assert.deepEqual(args, { checkout: f.checkout, home: f.home, revision: f.options.revision, environment });
        return "reopened";
    })), "reopened");
    const before = f.calls();
    await assert.rejects(f.open().create(f.counted()));
    await assert.rejects(f.open({ revision: git(f.options.source, "rev-parse", "HEAD") }).use(f.counted()));
    assert.equal(f.calls(), before);
});

test("requires a private physical root, a safe run and a full commit ID", async t => {
    const f = await fixture(t);
    const link = join(f.options.folder, "linked");
    await symlink(f.options.folder, link);
    for (const overrides of [{ folder: link }, { run: "../outside" }, { revision: "main" }]) {
        await assert.rejects(async () => f.open(overrides).create(f.counted()));
    }
    await chmod(f.options.folder, 0o755);
    await assert.rejects(f.open().create(f.counted()));
    assert.equal(f.calls(), 0);
});

test("refuses tracked host configuration before create", async t => {
    const f = await fixture(t);
    await mkdir(join(f.options.source, ".container-use"));
    await writeFile(join(f.options.source, ".container-use", "environment.json"), "{}");
    git(f.options.source, "add", "-f", ".container-use/environment.json");
    git(f.options.source, "commit", "-qm", "Host config");
    const revision = git(f.options.source, "rev-parse", "HEAD");
    await assert.rejects(f.open({ revision }).create(f.counted()), /configuration/i);
    assert.equal(f.calls(), 0);
});

test("holds the lock over the awaited call and blocks leftover ownership", async t => {
    const f = await fixture(t);
    for (const operation of ["create", "use"]) {
        const { promise, resolve } = Promise.withResolvers();
        const { promise: entered, resolve: enter } = Promise.withResolvers();
        const pending = f.open()[operation](async args => {
            enter();
            await promise;
            if (operation === "create") return f.create(args);
        });
        await Promise.race([entered, pending]);
        try {
            const before = f.calls();
            await assert.rejects(f.open().create(f.counted()), /lock/i);
            await assert.rejects(f.open().use(f.counted()), /lock/i);
            assert.equal(f.calls(), before);
        } finally {
            resolve();
            await pending;
        }
    }
    await mkdir(f.lock, { mode: 0o700 });
    await f.closed();
});

test("a failed engine preflight allows a later create or reopen", async t => {
    const f = await fixture(t);
    const unavailable = () => { throw new Error("Engine unavailable"); };
    await assert.rejects(f.open().create(f.create, unavailable), /Engine unavailable/);
    assert.equal(f.calls(), 0);
    await f.open().create(f.create);
    await assert.rejects(f.open().use(f.counted(), unavailable), /Engine unavailable/);
    assert.equal(f.calls(), 1);
    assert.equal(await f.open().use(f.counted(() => true)), true);
});

test("a clean checkout can have more than a mebibyte of tracked paths", async t => {
    const files = Object.fromEntries(Array.from({ length: 4700 }, (_, index) => [`${index}-${"x".repeat(228)}`, "fixture\n"]));
    const f = await fixture(t, files);
    assert.equal(await f.open().create(f.create), "created");
    assert.equal(await f.open().use(f.counted(() => true)), true);
});

test("records a forward Git update and a new Dagger container identity", async t => {
    const f = await fixture(t);
    await f.open().create(f.create);
    const before = await readFile(f.record, "utf8");
    await f.open().use(f.counted(async () => {
        await writeFile(join(f.worktree, "result.txt"), "result\n");
        git(f.worktree, "add", "result.txt");
        git(f.worktree, "commit", "-qm", "Advance environment");
        git(f.checkout, "fetch", "-q", "container-use", environment);
        f.saveState({ ...note, container: "advanced-container" });
    }));
    const advanced = await readFile(f.record, "utf8");
    assert.notEqual(advanced, before);
    await f.open().use(f.counted(async () => {
        const ignored = join(f.worktree, ".container-use");
        await mkdir(ignored);
        await writeFile(join(ignored, "artifact.txt"), "ignored output\n");
        f.saveState({ ...note, container: "another-container" });
    }));
    assert.notEqual(await readFile(f.record, "utf8"), advanced);
    assert.equal(await f.open().use(f.counted(() => true)), true);
});

test("does not bless a failed or invalid update", async t => {
    for (const complete of [false, true]) await t.test(`callback ${complete ? "returns" : "throws"}`, async t => {
        const f = await fixture(t);
        await f.open().create(f.create);
        const before = await readFile(f.record, "utf8");
        await assert.rejects(f.open().use(f.counted(async () => {
            if (complete) f.saveState({ ...note, config: { ...config, env: ["oops"] } });
            else {
                await writeFile(join(f.worktree, "leftover.txt"), "partial\n");
                throw new Error("Transport failed");
            }
        })));
        assert.equal(await readFile(f.record, "utf8"), before);
        assert.equal((await lstat(f.lock)).isDirectory(), true);
        await f.closed();
    });
});

test("refuses invalid first state without recording ownership or exposing the note", async t => {
    const f = await fixture(t);
    await assert.rejects(f.open().create(async args => {
        const result = await f.create(args);
        f.saveState(`{"config":{"secrets":["note-private"]},${JSON.stringify(note).slice(1)}`);
        return result;
    }), error => /note/i.test(error.message) && !JSON.stringify(error).includes("note-private"));
    await assert.rejects(lstat(f.record), { code: "ENOENT" });
    await f.closed();
});

const drift = {
    "missing record": f => unlink(f.record),
    "foreign run record": async f => {
        const record = JSON.parse(await readFile(f.record, "utf8"));
        await writeFile(f.record, JSON.stringify({ ...record, run: "foreign" }));
    },
    "dirty tracked source": f => writeFile(join(f.checkout, "selected.txt"), "drift\n"),
    "ignored host configuration": async f => {
        await mkdir(join(f.checkout, ".container-use"));
        await writeFile(join(f.checkout, ".container-use", "environment.json"), "{}");
    },
    "linked config directory": f => symlink(f.options.folder, join(f.checkout, ".container-use")),
    "linked config file": async f => {
        await mkdir(join(f.checkout, ".container-use"));
        await symlink(join(f.checkout, "missing"), join(f.checkout, ".container-use", "environment.json"));
    },
    "foreign remote": f => git(f.checkout, "remote", "add", "foreign", f.fork),
    "foreign ref": f => git(f.checkout, "update-ref", "refs/heads/foreign", f.options.revision),
    "local Git filters": f => git(f.checkout, "config", "filter.probe.smudge", "false"),
    "hidden dirty source": async f => {
        git(f.checkout, "update-index", "--assume-unchanged", "selected.txt");
        await writeFile(join(f.checkout, "selected.txt"), "hidden\n");
    },
    "missing note": f => git(f.worktree, "notes", "--ref", stateRef, "remove"),
    "changed note": f => f.saveState({ ...note, title: "changed" }),
    "wrong container": f => f.saveState({ ...note, container: "foreign" }),
    "config-less note": f => f.saveState({ ...note, config: undefined }),
    "invalid note": f => f.saveState("invalid JSON"),
    "foreign worktree pointer": f => writeFile(join(f.worktree, ".git"), `gitdir: ${join(f.checkout, ".git")}`),
    "linked worktree parent": async f => {
        const parent = join(f.base, "worktrees");
        await rename(parent, join(f.home, "moved-worktrees"));
        await symlink(join(f.home, "moved-worktrees"), parent);
    },
};

test("rejects drift before invoking upstream", async t => {
    for (const [name, tamper] of Object.entries(drift)) await t.test(name, async t => {
        const f = await fixture(t);
        await f.open().create(f.create);
        await tamper(f);
        await f.closed();
    });
});
