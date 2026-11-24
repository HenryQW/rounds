import { execFile as execFileCallback } from "node:child_process";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { isIPv4 } from "node:net";
import { isAbsolute } from "node:path";
import { promisify } from "node:util";

const execFile = promisify(execFileCallback);
const script = "/rounds-egress.sh";
const engineFiles = ["/etc/dagger/engine.json", "/run/rounds-egress.sha256"];
const engineImage = "registry.dagger.io/engine@sha256:56b68be5d9fc8e0a4e7c8db7599a76571f8806d5a9623d9afa6764ae3f8cae36";
const dockerID = /^[a-f0-9]{64}$/;

export function engineEgressVerifier({ docker, socket, startupScript, container, network, worker, proxy, port }) {
    const denyAll = proxy === undefined && port === undefined;
    if (![docker, socket, startupScript].every(path => typeof path === "string" && isAbsolute(path) && !path.includes("\0")) ||
        ![container, network].every(id => typeof id === "string" && dockerID.test(id)) ||
        typeof worker !== "string" || !/^[a-z0-9]{1,14}$/.test(worker) ||
        (!denyAll && (typeof proxy !== "string" || !isIPv4(proxy) || !Number.isInteger(port) || port < 1 || port > 65535))) {
        throw new Error("Invalid Dagger engine egress settings.");
    }
    const parameters = denyAll ? [worker] : [worker, proxy, String(port)];
    const read = async (args, signal) => (await execFile(docker, ["--host", `unix://${socket}`, ...args], {
        env: { PATH: "/usr/bin:/bin", HOME: "/var/empty" },
        timeout: 10_000,
        maxBuffer: 16_384,
        signal,
    })).stdout.trim();
    const identity = async signal => {
        const fields = [".Id", ".State.Running", ".State.StartedAt", ".Config.Image", ".Path", ".Args", ".Mounts"];
        const format = fields.map(field => `{{json ${field}}}`).join("\n") +
            "{{range .NetworkSettings.Networks}}{{println}}{{json .NetworkID}}{{end}}";
        const [id, running, startedAt, image, entrypoint, args, mounts, ...networkIDs] =
            (await read(["container", "inspect", "--format", format, container], signal)).split("\n").map(JSON.parse);
        const scriptMount = mounts.find(item => item.Destination === script);
        const policyMount = mounts.some(({ Destination: path }) => engineFiles.some(file =>
            path === "/" || file === path || file.startsWith(path + "/")));
        if (id !== container || running !== true || !Number.isFinite(Date.parse(startedAt)) || image !== engineImage ||
            entrypoint !== "/bin/sh" || JSON.stringify(args) !== JSON.stringify([script, "start", ...parameters]) ||
            scriptMount?.Type !== "bind" || scriptMount.Source !== startupScript || scriptMount.RW !== false ||
            policyMount || networkIDs.length !== 1 || networkIDs[0] !== network) {
            throw new Error("Unexpected engine identity.");
        }
        return startedAt;
    };

    return async (endpoint, request = {}) => {
        if (endpoint !== `docker-container://${container}` || request.docker !== docker || request.socket !== socket) {
            throw new Error("Unexpected Dagger engine endpoint.");
        }
        const { signal } = request;
        try {
            const startedAt = await identity(signal);
            if (await read(["network", "inspect", "--format", "{{.Internal}}", network], signal) !== "true") {
                throw new Error("Expected an internal network.");
            }
            const hash = createHash("sha256").update(await readFile(startupScript, { signal })).digest("hex");
            const mounted = await read(["exec", container, "sha256sum", script], signal);
            if (mounted.split(/\s/)[0] !== hash) throw new Error("Unexpected engine startup script contents.");
            await read(["exec", container, "/bin/sh", script, "check", ...parameters], signal);
            if (await identity(signal) !== startedAt) throw new Error("Engine restarted during egress verification.");
            return startedAt;
        } catch {
            signal?.throwIfAborted();
            throw new Error("Could not verify the approved Dagger engine and worker egress.");
        }
    };
}
