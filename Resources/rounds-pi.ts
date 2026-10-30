// Installed by Rounds (Settings > Sources); Rounds replaces this file when it changes and deletes it on Remove.
// Writes the live state of this pi session for Rounds (spec 2.7), as pi's own program status (OSC 7501) reports it:
// one line in ~/Library/Application Support/Rounds/pi/<session id>:
//   <unix ms>\t<state>\t<detail>\t<pid>\t<session file>
// state: working, blocked, done, error, stopped or idle. detail: a dialog title or the first line of an error.
// No prompt, tool input or model text is written.
// @ts-nocheck

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const dir = path.join(os.homedir(), "Library/Application Support/Rounds/pi");

function clean(text) {
	return String(text ?? "").split(/\r?\n/, 1)[0].replace(/\t/g, " ").trim().slice(0, 120);
}

export default function (pi) {
	let ctx;
	let runActive = false;
	let compacting = false;
	let outcome = { state: "done", detail: "" };
	let resting = { state: "idle", detail: "" };
	let dialogs = [];
	let written;

	function current() {
		if (dialogs.length > 0) return { state: "blocked", detail: dialogs.at(-1) };
		if (compacting) return { state: "working", detail: "Compacting" };
		return runActive ? { state: "working", detail: "" } : resting;
	}

	function report(next) {
		if (next) ctx = next;
		const id = ctx?.sessionManager?.getSessionId?.();
		const file = ctx?.sessionManager?.getSessionFile?.();
		if (!/^[A-Za-z0-9-]{1,64}$/.test(id ?? "") || typeof file !== "string") return;
		const s = current();
		const fields = [s.state, clean(s.detail), process.pid, file].join("\t");
		if (fields === written) return;
		written = fields;
		try {
			fs.mkdirSync(dir, { recursive: true });
			const temporary = path.join(dir, `.${id}.${process.pid}`);
			fs.writeFileSync(temporary, `${Date.now()}\t${fields}\n`);
			fs.renameSync(temporary, path.join(dir, id));
		} catch {
			// Rounds is a viewer: a failed write must never disturb the session.
		}
	}

	pi.on("session_start", (_event, c) => {
		runActive = false;
		compacting = false;
		dialogs = [];
		resting = { state: "idle", detail: "" };
		written = undefined;
		report(c);
	});
	pi.on("agent_start", (_event, c) => {
		runActive = true;
		outcome = { state: "done", detail: "" };
		report(c);
	});
	pi.on("message_end", (event) => {
		if (event.message?.role !== "assistant") return;
		outcome = event.message.stopReason === "error" ? { state: "error", detail: event.message.errorMessage || "Error" } : { state: "done", detail: "" };
	});
	pi.on("agent_settled", (event, c) => {
		runActive = false;
		resting = event.aborted ? { state: "stopped", detail: "" } : outcome;
		report(c);
	});
	pi.on("session_before_compact", (_event, c) => {
		compacting = true;
		report(c);
	});
	pi.on("session_compact", (_event, c) => {
		compacting = false;
		report(c);
	});
	pi.on("session_compact_failed", (event, c) => {
		compacting = false;
		if (!runActive && !event.aborted && event.errorMessage) resting = { state: "error", detail: event.errorMessage };
		else if (runActive && event.errorMessage) outcome = { state: "error", detail: event.errorMessage };
		report(c);
	});
	pi.on("ui_prompt_start", (event, c) => {
		dialogs.push(event.title || "Input required");
		report(c);
	});
	pi.on("ui_prompt_end", (_event, c) => {
		dialogs.pop();
		report(c);
	});
	// A quit or a switch to another session: this session no longer runs or waits.
	pi.on("session_shutdown", (_event, c) => {
		runActive = false;
		compacting = false;
		dialogs = [];
		report(c);
	});
}
