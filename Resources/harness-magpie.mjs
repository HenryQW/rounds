import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { createProvider } from "@earendil-works/pi-ai/models";
import { openAICompletionsApi } from "@earendil-works/pi-ai/api/openai-completions.lazy";
import { openAIResponsesApi } from "@earendil-works/pi-ai/api/openai-responses.lazy";
import { anthropicMessagesApi } from "@earendil-works/pi-ai/api/anthropic-messages.lazy";

export class BouncerRequestError extends Error {}

async function config(file, optional = false) {
    try {
        return JSON.parse(await readFile(join(homedir(), ".pi/agent", file), "utf8"));
    } catch (error) {
        if (optional && error.code === "ENOENT") return {};
        throw new BouncerRequestError(`Rounds cannot read Pi ${file}. Check the Magpie configuration.`);
    }
}

function endpoint(value) {
    try {
        const url = new URL(value);
        if (["http:", "https:"].includes(url.protocol) && !url.username && !url.password) return value;
    } catch { /* Report malformed endpoints without printing their contents. */ }
    throw new BouncerRequestError("Magpie needs a valid HTTP or HTTPS endpoint.");
}

function literal(value) {
    if (typeof value !== "string" || !value.trim() || value.startsWith("!") || value.includes("$")) {
        throw new BouncerRequestError("Rounds needs literal values for the Magpie key and headers in Pi models.json.");
    }
    return value;
}

function headers(value) {
    return value == null ? undefined : Object.fromEntries(Object.entries(value).map(([key, val]) => [key, literal(val)]));
}

export async function registerMagpie(registry) {
    const cfg = (await config("models.json"))?.providers?.magpie;
    if (!Array.isArray(cfg?.models) || cfg.models.length === 0) {
        throw new BouncerRequestError("Configure at least one Magpie model in Pi models.json.");
    }
    const settings = await config("settings.json", true);
    const api = {
        "openai-completions": openAICompletionsApi(),
        "openai-responses": openAIResponsesApi(),
        "anthropic-messages": anthropicMessagesApi(),
    };
    const unsupported = new Set();
    const models = [];
    for (const model of cfg.models) {
        if (typeof model?.id !== "string" || !model.id.trim() || Buffer.byteLength(model.id) > 512) {
            throw new BouncerRequestError("A Magpie model has an invalid ID in Pi models.json.");
        }
        const protocol = model.api ?? cfg.api;
        if (!Object.hasOwn(api, protocol)) {
            unsupported.add(model.id);
            continue;
        }
        models.push({
            id: model.id, name: model.name ?? model.id, api: protocol, provider: "magpie",
            baseUrl: endpoint(model.baseUrl ?? cfg.baseUrl), headers: headers(model.headers),
            reasoning: model.reasoning ?? false, input: model.input ?? ["text"],
            cost: model.cost ?? { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
            contextWindow: model.contextWindow ?? 128_000, maxTokens: model.maxTokens ?? 16_384,
            thinkingLevelMap: model.thinkingLevelMap, compat: { ...cfg.compat, ...model.compat },
        });
    }
    if (models.length === 0) throw new BouncerRequestError("Rounds found no supported Magpie model protocol.");
    if (new Set(models.map(model => model.id)).size !== models.length) {
        throw new BouncerRequestError("Magpie model IDs must be unique in Pi models.json.");
    }
    const apiKey = literal(cfg.apiKey);
    registry.setProvider(createProvider({
        id: "magpie", name: "Magpie", headers: headers(cfg.headers), models, api,
        auth: { apiKey: { name: "Magpie", resolve: async () => ({ auth: { apiKey }, source: "models.json" }) } },
    }));
    const defaultID = settings?.defaultProvider === "magpie" && typeof settings.defaultModel === "string"
        ? settings.defaultModel : models[0].id;
    const thinkingLevel = ["off", "minimal", "low", "medium", "high", "xhigh", "max"].includes(settings?.defaultThinkingLevel)
        ? settings.defaultThinkingLevel : null;
    return {
        models: models.map(model => `magpie/${model.id}`),
        thinkingLevel,
        resolve(id) {
            const modelId = id === null ? defaultID : id?.startsWith?.("magpie/") ? id.slice(7) : undefined;
            if (unsupported.has(modelId)) throw new BouncerRequestError("The selected Magpie model uses an unsupported protocol.");
            if (!registry.getModel("magpie", modelId)) throw new BouncerRequestError("The selected Magpie model is missing from Pi models.json.");
            return { provider: "magpie", modelId };
        },
    };
}
