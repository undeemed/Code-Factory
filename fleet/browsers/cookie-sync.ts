// cookie-sync.ts - one session, three browsers.
//
// The fleet's browser ladder is obscura -> chrome -> vnc (see fleet-browser).
// A login made in any tier must be usable in the other two, so this keeps ONE
// canonical cookie jar (~/.fleet-browser/cookies.json) and converges every
// live tier to it over CDP:
//
//   1. read each live tier's jar;
//   2. compare with what that tier held after the previous sync
//      (seen-<tier>.json): a value that changed since then is an edit made IN
//      that tier; a key that vanished is a deletion made in that tier;
//   3. fold edits and deletions into the canonical jar - when two tiers edited
//      the same cookie, the later `expires` wins (a refreshed session outranks
//      a stale one), ties go to the higher tier;
//   4. push the canonical jar back into every live tier, then record what each
//      tier now holds as its seen-state.
//
// Cookies are the portable part of a session: the app's Supabase SSR auth,
// GitHub, Google all live there. localStorage is engine-local and NOT synced
// (Obscura exposes no DOMStorage domain); it holds UI preferences only.
//
// Obscura is special (measured 2026-09-17). Its session file is the live truth
// it flushes on every Storage.setCookies, so lane logins appear there
// immediately and it is the correct READ source. But writing that file
// externally while the process runs is clobbered on the next restart; the only
// durable write path is CDP Storage.setCookies into the running server. So a
// tier may declare BOTH: `obscura=http://host:port|file:///path`. cookie-sync
// reads from the file and writes over CDP.
//
// usage:
//   bun cookie-sync.ts [--state DIR] [--seed http://127.0.0.1:PORT] tier=<spec> ...
//   <spec> is http(s)://host:port | ws(s)://host/path | file:///path | <cdp>|file:///path
//   --seed imports a browser's jar as edits (used once for the old VNC profile)
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "fs";
import { homedir } from "os";

type Cookie = {
	name: string;
	value: string;
	domain: string;
	path: string;
	expires: number; // unix seconds; -1 = session cookie
	httpOnly: boolean;
	secure: boolean;
	sameSite?: "Strict" | "Lax" | "None";
};
type Jar = Record<string, Cookie>;
type CdpReply = { id?: number; result?: Record<string, unknown>; error?: { code: number; message: string } };

// One tier endpoint as declared on the command line. `cdp` is the HTTP or WS
// URL we connect to for reads/writes; `file` (when present) is an on-disk jar
// that overrides CDP as the READ source and is kept in sync on CDP writes.
type Endpoint = { cdp?: string; file?: string };

function parseEndpoint(spec: string): Endpoint {
	const parts = spec.split("|").map((p) => p.trim()).filter(Boolean);
	const out: Endpoint = {};
	for (const p of parts) {
		if (p.startsWith("file://")) out.file = p.slice("file://".length);
		else out.cdp = p;
	}
	return out;
}

const args = process.argv.slice(2);
let stateDir = `${homedir()}/.fleet-browser`;
let seedUrl = "";
const tiers: Array<{ name: string; ep: Endpoint }> = [];
for (let i = 0; i < args.length; i++) {
	if (args[i] === "--state") stateDir = args[++i];
	else if (args[i] === "--seed") seedUrl = args[++i];
	else {
		const eq = args[i].indexOf("=");
		if (eq > 0) tiers.push({ name: args[i].slice(0, eq), ep: parseEndpoint(args[i].slice(eq + 1)) });
	}
}
mkdirSync(stateDir, { recursive: true, mode: 0o700 });

// Engines disagree on the leading dot (Obscura reports ".github.com" back as
// "github.com"), so the key ignores it; the canonical entry keeps whichever
// form it first saw, dotted preferred.
const keyOf = (c: Cookie) => `${c.domain.replace(/^\./, "").toLowerCase()}|${c.path}|${c.name}`;
const loadJar = (file: string): Jar => (existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as Jar) : {});
const saveJar = (file: string, jar: Jar) => {
	writeFileSync(`${file}.tmp`, JSON.stringify(jar, null, 1), { mode: 0o600 });
	renameSync(`${file}.tmp`, file);
};
const normalize = (raw: Record<string, unknown>): Cookie => ({
	name: String(raw.name),
	value: String(raw.value ?? ""),
	domain: String(raw.domain ?? ""),
	path: String(raw.path ?? "/"),
	expires: typeof raw.expires === "number" && raw.expires > 0 ? Math.floor(raw.expires) : -1,
	httpOnly: Boolean(raw.httpOnly),
	secure: Boolean(raw.secure),
	sameSite: raw.sameSite === "Strict" || raw.sameSite === "Lax" || raw.sameSite === "None" ? raw.sameSite : undefined,
});
const sameCookie = (a: Cookie, b: Cookie) => a.value === b.value && a.expires === b.expires && a.httpOnly === b.httpOnly && a.secure === b.secure;

class Cdp {
	#ws: WebSocket;
	#id = 0;
	#pending = new Map<number, (r: CdpReply) => void>();
	private constructor(ws: WebSocket) {
		this.#ws = ws;
		ws.onmessage = (m) => {
			const d = JSON.parse(String(m.data)) as CdpReply;
			if (d.id !== undefined && this.#pending.has(d.id)) {
				this.#pending.get(d.id)!(d);
				this.#pending.delete(d.id);
			}
		};
	}
	static async connect(endpoint: string, timeoutMs = 4000): Promise<Cdp | null> {
		// A ws(s) URL is used directly; an http(s) URL is resolved via /json/version.
		let wsUrl = endpoint;
		try {
			if (/^https?:/.test(endpoint)) {
				const ctrl = new AbortController();
				const t = setTimeout(() => ctrl.abort(), timeoutMs);
				const v = (await (await fetch(`${endpoint.replace(/\/$/, "")}/json/version`, { signal: ctrl.signal })).json()) as { webSocketDebuggerUrl?: string };
				clearTimeout(t);
				if (!v.webSocketDebuggerUrl) return null;
				wsUrl = v.webSocketDebuggerUrl;
			}
			const ws = new WebSocket(wsUrl);
			const { promise, resolve, reject } = Promise.withResolvers<void>();
			ws.onopen = () => resolve();
			ws.onerror = () => reject(new Error("ws error"));
			setTimeout(() => reject(new Error("ws timeout")), timeoutMs);
			await promise;
			return new Cdp(ws);
		} catch {
			return null;
		}
	}
	call(method: string, params: Record<string, unknown> = {}, sessionId?: string, timeoutMs = 15000): Promise<CdpReply> {
		const { promise, resolve } = Promise.withResolvers<CdpReply>();
		const id = ++this.#id;
		this.#pending.set(id, resolve);
		this.#ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
		setTimeout(() => {
			if (this.#pending.has(id)) {
				this.#pending.delete(id);
				resolve({ id, error: { code: -1, message: `timeout ${method}` } });
			}
		}, timeoutMs);
		return promise;
	}
	close() {
		this.#ws.close();
	}
}

// Obscura's on-disk jar: [{name,value,domain,path,secure,httpOnly,sameSite,expires|null}]
type ObscuraFileCookie = { name: string; value: string; domain: string; path: string; secure: boolean; httpOnly: boolean; sameSite: string | null; expires: number | null };
function readFileJar(file: string): Jar {
	const jar: Jar = {};
	if (!existsSync(file)) return jar;
	try {
		for (const raw of JSON.parse(readFileSync(file, "utf8")) as ObscuraFileCookie[]) {
			const c = normalize({ ...raw, expires: raw.expires ?? -1, sameSite: raw.sameSite ?? undefined });
			if (c.domain && c.name) jar[keyOf(c)] = c;
		}
	} catch {
		// A half-written file is not fatal: treat it as empty for this pass.
	}
	return jar;
}
function writeFileJar(file: string, jar: Jar): number {
	const rows: ObscuraFileCookie[] = Object.values(jar).map((c) => ({
		name: c.name, value: c.value, domain: c.domain, path: c.path, secure: c.secure, httpOnly: c.httpOnly,
		sameSite: c.sameSite ?? "Lax", expires: c.expires > 0 ? c.expires : null,
	}));
	writeFileSync(`${file}.tmp`, JSON.stringify(rows, null, 1), { mode: 0o600 });
	renameSync(`${file}.tmp`, file);
	return rows.length;
}

async function readJar(cdp: Cdp): Promise<Jar | null> {
	const r = await cdp.call("Storage.getCookies");
	if (r.error) return null;
	const jar: Jar = {};
	for (const raw of (r.result?.cookies as Array<Record<string, unknown>> | undefined) ?? []) {
		const c = normalize(raw);
		if (c.domain && c.name) jar[keyOf(c)] = c;
	}
	return jar;
}

async function pushJar(cdp: Cdp, want: Jar, have: Jar): Promise<{ set: number; deleted: number; failed: number }> {
	const toSet = Object.values(want).filter((c) => !have[keyOf(c)] || !sameCookie(have[keyOf(c)], c));
	const toDelete = Object.values(have).filter((c) => !want[keyOf(c)]);
	let set = 0, deleted = 0, failed = 0;
	if (toSet.length) {
		const cookies = toSet.map((c) => ({
			name: c.name, value: c.value, domain: c.domain, path: c.path,
			secure: c.secure, httpOnly: c.httpOnly,
			...(c.sameSite ? { sameSite: c.sameSite } : {}),
			...(c.expires > 0 ? { expires: c.expires } : {}),
		}));
		const r = await cdp.call("Storage.setCookies", { cookies });
		if (r.error) {
			// One bad cookie fails the batch in Chromium; retry individually so one
			// odd cookie cannot block the whole session.
			for (const one of cookies) {
				const r1 = await cdp.call("Storage.setCookies", { cookies: [one] });
				if (r1.error) failed++; else set++;
			}
		} else set = cookies.length;
	}
	if (toDelete.length) {
		const first = await cdp.call("Storage.deleteCookies", { cookies: toDelete.map((c) => ({ name: c.name, domain: c.domain, path: c.path })) });
		if (!first.error) deleted = toDelete.length;
		else {
			// Chromium: Network.deleteCookies needs a page session.
			const t = await cdp.call("Target.createTarget", { url: "about:blank" });
			const targetId = t.result?.targetId as string | undefined;
			const a = targetId ? await cdp.call("Target.attachToTarget", { targetId, flatten: true }) : null;
			const sid = a?.result?.sessionId as string | undefined;
			if (sid) {
				await cdp.call("Network.enable", {}, sid);
				for (const c of toDelete) {
					const r = await cdp.call("Network.deleteCookies", { name: c.name, domain: c.domain, path: c.path }, sid);
					if (r.error) failed++; else deleted++;
				}
				await cdp.call("Target.closeTarget", { targetId });
			} else failed += toDelete.length;
		}
	}
	return { set, deleted, failed };
}

const canonicalFile = `${stateDir}/cookies.json`;
const canonical = loadJar(canonicalFile);
const now = Math.floor(Date.now() / 1000);
for (const k of Object.keys(canonical)) if (canonical[k].expires > 0 && canonical[k].expires < now) delete canonical[k];

// A live tier holds the connection we write through (cdp), the file we read
// truth from (file, optional), and the jar we actually read this pass.
type Live = { name: string; cdp: Cdp | null; file?: string; jar: Jar; seen: Jar; rank: number };
const live: Live[] = [];
for (const [rank, t] of tiers.entries()) {
	const seen = loadJar(`${stateDir}/seen-${t.name}.json`);
	if (t.ep.file && !t.ep.cdp) {
		// File-only tier: read and write the file directly.
		live.push({ name: t.name, cdp: null, file: t.ep.file, jar: readFileJar(t.ep.file), seen, rank });
		continue;
	}
	const cdp = t.ep.cdp ? await Cdp.connect(t.ep.cdp) : null;
	if (!cdp) {
		// Not reachable this pass. If we have a file, still read it so its edits
		// are not lost while the server is down; we simply cannot write back.
		if (t.ep.file) live.push({ name: t.name, cdp: null, file: t.ep.file, jar: readFileJar(t.ep.file), seen, rank });
		continue;
	}
	// Prefer the file as the read source when present (Obscura's live truth);
	// otherwise read through CDP (Chromium/VNC).
	const jar = t.ep.file ? readFileJar(t.ep.file) : await readJar(cdp);
	if (!jar) { cdp.close(); continue; }
	live.push({ name: t.name, cdp, file: t.ep.file, jar, seen, rank });
}
if (seedUrl) {
	const cdp = await Cdp.connect(seedUrl);
	const jar = cdp ? await readJar(cdp) : null;
	if (jar) live.push({ name: "seed", cdp, jar, seen: {}, rank: 99 });
	else console.error(`seed: could not read cookies from ${seedUrl}`);
}
if (live.length === 0) {
	console.log("cookie-sync: no live tier reachable; nothing to do");
	process.exit(0);
}

// Fold edits/deletions from each tier into the canonical jar.
const edits = new Map<string, { c: Cookie; rank: number }>();
const deletions = new Set<string>();
for (const t of live) {
	for (const [k, c] of Object.entries(t.jar)) {
		if (c.expires > 0 && c.expires < now) continue;
		const inCanon = canonical[k];
		const inSeen = t.seen[k];
		const changedHere = !inSeen || !sameCookie(inSeen, c);
		if (!inCanon || (changedHere && !sameCookie(inCanon, c))) {
			// keep the dotted domain form the jar already knows
			const merged = inCanon && inCanon.domain.startsWith(".") && !c.domain.startsWith(".") ? { ...c, domain: inCanon.domain } : c;
			const prev = edits.get(k);
			if (!prev || merged.expires > prev.c.expires || (merged.expires === prev.c.expires && t.rank < prev.rank)) edits.set(k, { c: merged, rank: t.rank });
		}
	}
	if (t.name !== "seed") for (const k of Object.keys(t.seen)) if (!t.jar[k] && canonical[k]) deletions.add(k);
}
for (const [k, e] of edits) { canonical[k] = e.c; deletions.delete(k); }
for (const k of deletions) delete canonical[k];
saveJar(canonicalFile, canonical);

const report: string[] = [];
for (const t of live) {
	if (t.name === "seed") { t.cdp?.close(); continue; }
	if (t.cdp) {
		// CDP is the only durable write path for a running server (Obscura
		// clobbers external file writes; Chromium has no such file at all).
		const r = await pushJar(t.cdp, canonical, t.jar);
		saveJar(`${stateDir}/seen-${t.name}.json`, canonical);
		report.push(`${t.name}: set ${r.set} del ${r.deleted}${r.failed ? ` FAILED ${r.failed}` : ""}`);
		t.cdp.close();
		continue;
	}
	if (t.file) {
		// File-only tier (server down): reconcile the file so the next start is correct.
		const differs = Object.keys(canonical).length !== Object.keys(t.jar).length || Object.values(canonical).some((c) => !t.jar[keyOf(c)] || !sameCookie(t.jar[keyOf(c)], c));
		if (differs) { writeFileJar(t.file, canonical); report.push(`${t.name}: file rewritten (${Object.keys(canonical).length})`); }
		else report.push(`${t.name}: file unchanged`);
		saveJar(`${stateDir}/seen-${t.name}.json`, canonical);
	}
}
console.log(`cookie-sync: canonical ${Object.keys(canonical).length} cookies; edits ${edits.size} deletions ${deletions.size}; ${report.join("; ")}${seedUrl ? "; seeded" : ""}`);
process.exit(0);
