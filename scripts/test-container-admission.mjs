// Offline admission boundary only. No container tool is registered.
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, mkdir, readFile, readdir, rm, symlink, writeFile, lstat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { admit } from "./container-admission-fixture.mjs";

const gitEnv = { ...Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("GIT_"))),
    GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_AUTHOR_NAME: "Fixture", GIT_AUTHOR_EMAIL: "fixture@example.invalid",
    GIT_COMMITTER_NAME: "Fixture", GIT_COMMITTER_EMAIL: "fixture@example.invalid" };
function git(checkout, ...args) {
    return execFileSync("git", ["-C", checkout, ...args], { env: gitEnv, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
}

async function fixture(t) {
    const root = await mkdtemp(join(tmpdir(), "rounds-admission-"));
    t.after(() => rm(root, { recursive: true, force: true }));
    const checkout = join(root, "checkout");
    const stateDir = join(root, "state");
    await mkdir(checkout);
    await mkdir(stateDir);
    git(checkout, "init", "-q");
    await writeFile(join(checkout, "source.txt"), "pinned source\n");
    git(checkout, "add", "source.txt");
    git(checkout, "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture");
    const revision = git(checkout, "rev-parse", "HEAD");
    const recordPath = join(root, "run.json");
    const statePath = join(stateDir, "environment.json");
    const record = { environment: "env-one", run: "run-one", revision, container: "container-one",
        ownedMetadata: { remotes: [], notes: [] }, config: { image: "fixture-default", setup: [], secrets: [] } };
    const { ownedMetadata, ...saved } = record;
    const state = structuredClone(saved);
    await writeFile(recordPath, JSON.stringify(record));
    await writeFile(statePath, JSON.stringify(state));
    let calls = 0;
    const tool = async request => { calls++; return request.operation; };
    return { root, checkout, recordPath, statePath, record, state, tool,
        calls: () => calls,
        request: { checkout, recordPath, statePath, operation: "create", environment: record.environment, run: record.run, revision } };
}

async function rejected(f, expected) {
    const before = f.calls();
    await assert.rejects(admit(f.request, f.tool), expected);
    assert.equal(f.calls(), before, "rejected request must not call the tool");
}

test("a clean pinned checkout admits create exactly once", async t => {
    const f = await fixture(t);
    assert.equal(git(f.checkout, "rev-parse", "HEAD"), f.record.revision);
    assert.equal(await admit(f.request, f.tool), "create");
    assert.equal(f.calls(), 1);
});

test("create accepts a configuration directory without a config file", async t => {
    const f = await fixture(t);
    await mkdir(join(f.checkout, ".container-use"));
    assert.equal(await admit(f.request, f.tool), "create");
    assert.equal(f.calls(), 1);
});

test("create rejects a config file, dangling config link, and linked config directory", async t => {
    for (const kind of ["file", "dangling-link", "linked-directory"]) {
        await t.test(kind, async t => {
            const f = await fixture(t);
            const dir = join(f.checkout, ".container-use");
            const config = join(dir, "environment.json");
            if (kind === "linked-directory") {
                const outside = join(f.root, "outside");
                await mkdir(outside);
                await writeFile(join(outside, "environment.json"), '{"secrets":["unsafe"]}');
                await symlink(outside, dir);
                assert.equal((await lstat(dir)).isSymbolicLink(), true);
                assert.match(await readFile(config, "utf8"), /unsafe/);
            } else {
                await mkdir(dir);
                if (kind === "file") {
                    await writeFile(config, '{"secrets":["unsafe"]}');
                    assert.match(await readFile(config, "utf8"), /unsafe/);
                } else {
                    await symlink(join(f.root, "absent"), config);
                    await assert.rejects(readFile(config), { code: "ENOENT" });
                }
                assert.equal((await lstat(config)).isSymbolicLink(), kind === "dangling-link");
            }
            await rejected(f, { message: "Fixture configuration is present or linked" });
            assert.equal(f.calls(), 0);
        });
    }
});

test("load rejects saved state without config", async t => {
    const f = await fixture(t);
    f.request.operation = "load";
    delete f.state.config;
    await writeFile(f.statePath, JSON.stringify(f.state));
    assert.equal("config" in JSON.parse(await readFile(f.statePath, "utf8")), false);
    await rejected(f, { message: "Unverified fixture state config" });
    assert.equal(f.calls(), 0);
});

test("load rejects wrong environment, run, source revision, or container", async t => {
    for (const field of ["environment", "run", "revision", "container"]) {
        await t.test(field, async t => {
            const f = await fixture(t);
            f.request.operation = "load";
            f.state[field] = "foreign";
            await writeFile(f.statePath, JSON.stringify(f.state));
            assert.equal(JSON.parse(await readFile(f.statePath, "utf8"))[field], "foreign");
            assert.notEqual(f.state[field], f.record[field]);
            await rejected(f, { message: field === "container" ? "Unverified fixture container" : "Unverified fixture state identity" });
            assert.equal(f.calls(), 0);
        });
    }
});

test("every load rechecks saved state after an allowed load", async t => {
    const f = await fixture(t);
    f.request.operation = "load";
    assert.equal(await admit(f.request, f.tool), "load");
    assert.equal(f.calls(), 1);
    f.state.config.secrets.push("foreign-secret-reference");
    await writeFile(f.statePath, JSON.stringify(f.state));
    assert.deepEqual(JSON.parse(await readFile(f.statePath, "utf8")).config.secrets, ["foreign-secret-reference"]);
    await rejected(f, { message: "Unverified fixture state config" });
    assert.equal(f.calls(), 1);
});

test("create rejects inherited container-use remotes and Git notes", async t => {
    for (const kind of ["remote", "notes"]) {
        await t.test(kind, async t => {
            const f = await fixture(t);
            if (kind === "remote") {
                git(f.checkout, "remote", "add", "container-use", join(f.root, "foreign"));
                assert.equal(git(f.checkout, "remote"), "container-use");
            } else {
                git(f.checkout, "notes", "--ref=container-use", "add", "-m", "foreign state");
                assert.match(git(f.checkout, "notes", "--ref=container-use", "show"), /foreign state/);
            }
            await rejected(f, { message: "Unverified checkout metadata" });
            assert.equal(f.calls(), 0);
        });
    }
});

test("load rejects a missing saved state file", async t => {
    const f = await fixture(t);
    f.request.operation = "load";
    await rm(f.statePath);
    await assert.rejects(readFile(f.statePath), { code: "ENOENT" });
    await rejected(f, { code: "ENOENT", path: f.statePath });
    assert.equal(f.calls(), 0);
});

test("request and checkout must match the run record", async t => {
    for (const kind of ["environment", "run", "revision", "checkout-head"]) {
        await t.test(kind, async t => {
            const f = await fixture(t);
            if (kind === "checkout-head") {
                await writeFile(join(f.checkout, "source.txt"), "new revision\n");
                git(f.checkout, "add", "source.txt");
                git(f.checkout, "-c", "core.hooksPath=/dev/null", "commit", "-qm", "new revision");
                assert.notEqual(git(f.checkout, "rev-parse", "HEAD"), f.record.revision);
            } else {
                f.request[kind] = "foreign";
                assert.notEqual(f.request[kind], JSON.parse(await readFile(f.recordPath, "utf8"))[kind]);
            }
            await rejected(f, { message: kind === "checkout-head" ? "Unverified checkout revision" : "Unverified fixture record" });
            assert.equal(f.calls(), 0);
        });
    }
});

async function installOwnedMetadata(f) {
    const name = "container-use";
    const url = join(f.root, "owned-repository");
    const ref = "refs/notes/container-use";
    git(f.checkout, "remote", "add", name, url);
    git(f.checkout, "notes", `--ref=${ref}`, "add", "-m", "owned state");
    f.record.ownedMetadata = { remotes: [{ name, url }], notes: [{ ref, oid: git(f.checkout, "rev-parse", ref) }] };
    await writeFile(f.recordPath, JSON.stringify(f.record));
}

test("create followed by load accepts metadata owned by the run", async t => {
    const f = await fixture(t);
    const tool = async request => {
        const result = await f.tool(request);
        if (request.operation === "create") await installOwnedMetadata(f);
        return result;
    };
    assert.equal(await admit(f.request, tool), "create");
    assert.equal(f.calls(), 1);
    assert.equal(git(f.checkout, "remote", "get-url", "container-use"), f.record.ownedMetadata.remotes[0].url);
    assert.equal(git(f.checkout, "rev-parse", "refs/notes/container-use"), f.record.ownedMetadata.notes[0].oid);
    f.request.operation = "load";
    assert.equal(await admit(f.request, tool), "load");
    assert.equal(f.calls(), 2);
});

test("load rejects metadata that differs from the run record", async t => {
    for (const kind of ["remote-url", "notes-content", "extra-remote", "extra-notes"]) {
        await t.test(kind, async t => {
            const f = await fixture(t);
            await installOwnedMetadata(f);
            f.request.operation = "load";
            if (kind === "remote-url") {
                const foreign = join(f.root, "foreign-repository");
                git(f.checkout, "remote", "set-url", "container-use", foreign);
                assert.equal(git(f.checkout, "remote", "get-url", "container-use"), foreign);
                assert.notEqual(foreign, f.record.ownedMetadata.remotes[0].url);
            } else if (kind === "notes-content") {
                git(f.checkout, "notes", "--ref=container-use", "append", "-m", "foreign state");
                assert.notEqual(git(f.checkout, "rev-parse", "refs/notes/container-use"), f.record.ownedMetadata.notes[0].oid);
            } else if (kind === "extra-remote") {
                git(f.checkout, "remote", "add", "foreign", join(f.root, "foreign-repository"));
                assert.match(git(f.checkout, "remote"), /foreign/);
            } else {
                git(f.checkout, "notes", "--ref=foreign", "add", "-m", "foreign state");
                assert.match(git(f.checkout, "for-each-ref", "--format=%(refname)", "refs/notes/"), /refs\/notes\/foreign/);
            }
            await rejected(f, { message: "Unverified checkout metadata" });
            assert.equal(f.calls(), 0);
        });
    }
});

async function treeDigest(root) {
    const hash = createHash("sha256");
    async function visit(path, prefix) {
        const entries = (await readdir(path, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name));
        for (const item of entries) {
            const relative = `${prefix}/${item.name}`;
            if (item.isDirectory()) await visit(join(path, item.name), relative);
            else {
                hash.update(relative).update("\0");
                hash.update(await readFile(join(path, item.name))).update("\0");
            }
        }
    }
    await visit(root, "");
    return hash.digest("hex");
}

test("fixture Git commands ignore inherited Git paths", async t => {
    for (const key of ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"]) {
        await t.test(key, async t => {
            const root = await mkdtemp(join(tmpdir(), "rounds-foreign-git-"));
            t.after(() => rm(root, { recursive: true, force: true }));
            const foreign = join(root, "foreign");
            await mkdir(foreign);
            git(foreign, "init", "-q");
            await writeFile(join(foreign, "source.txt"), "foreign source\n");
            git(foreign, "add", "source.txt");
            git(foreign, "-c", "core.hooksPath=/dev/null", "commit", "-qm", "foreign");
            const head = git(foreign, "rev-parse", "HEAD");
            const indexPath = join(foreign, ".git", "index");
            const index = await readFile(indexPath);
            const configPath = join(foreign, ".git", "config");
            const config = await readFile(configPath);
            const digest = await treeDigest(foreign);
            const value = key === "GIT_DIR" ? join(foreign, ".git") : key === "GIT_WORK_TREE" ? foreign : indexPath;
            const childEnv = { ...gitEnv, [key]: value, NODE_OPTIONS: "--test-reporter=tap" };
            delete childEnv.NODE_TEST_CONTEXT;
            const child = spawnSync(process.execPath, ["--test", "--test-name-pattern=^a clean pinned checkout admits create exactly once$",
                fileURLToPath(import.meta.url)], { env: childEnv, encoding: "utf8", timeout: 20000 });
            assert.equal(git(foreign, "rev-parse", "HEAD"), head);
            assert.deepEqual(await readFile(indexPath), index);
            assert.deepEqual(await readFile(configPath), config);
            assert.equal(await readFile(join(foreign, "source.txt"), "utf8"), "foreign source\n");
            assert.equal(await treeDigest(foreign), digest);
            assert.equal(child.status, 0, child.stderr || child.stdout);
            assert.match(child.stdout, /^ok 1 - a clean pinned checkout admits create exactly once$/m);
            assert.match(child.stdout, /^# tests 1$/m);
            assert.match(child.stdout, /^# pass 1$/m);
            assert.match(child.stdout, /^# fail 0$/m);
            assert.match(child.stdout, /^# skipped 0$/m);
        });
    }
});
