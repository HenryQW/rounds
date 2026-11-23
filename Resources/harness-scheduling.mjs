const admitting = new WeakSet();

// The callers of this boundary can both start the Harness scheduler.
export async function withSchedulingGuard(harness, action) {
    if (admitting.has(harness)) throw new Error("Another Harness request is checking scheduling.");
    admitting.add(harness);
    try { return await action(); }
    finally { admitting.delete(harness); }
}
