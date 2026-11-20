// Merge live scan results with stored labels. Pure core + thin I/O wrappers.
import * as store from './store.js';
import { scan, listeningPorts, listenersOn, IGNORE_PORTS, PORT_MIN, PORT_MAX } from './detect.js';
import { loadConfig } from './store.js';

export const PRUNE_AFTER_MS = 24 * 60 * 60 * 1000;
const SEEN_WRITE_INTERVAL_MS = 60 * 1000;

/**
 * Pure merge.
 * status: 'labeled' | 'unlabeled' | 'stale'
 * @returns {{ entries: object[], prune: string[], seen: string[] }}
 */
export function merge(live, servers, now = Date.now()) {
  const entries = [];
  const seen = [];
  const liveByPort = new Map(live.map((l) => [String(l.port), l]));

  for (const l of live) {
    const rec = servers[String(l.port)];
    let status = 'unlabeled';
    if (rec) {
      // Same port, different checkout → someone else's label. cwd is unknown for docker; trust the label then.
      status = rec.cwd && l.cwd && rec.cwd !== l.cwd ? 'stale' : 'labeled';
      if (status === 'labeled') seen.push(String(l.port));
    }
    entries.push({
      port: l.port,
      url: `http://localhost:${l.port}`,
      status,
      title: status === 'labeled' ? rec.title : null,
      description: status === 'labeled' ? rec.description || null : null,
      staleTitle: status === 'stale' ? rec.title : null,
      registeredAt: rec?.registeredAt || null,
      branch: l.branch,
      repo: l.repo,
      cwd: l.cwd,
      root: l.root ?? null,
      command: l.command,
      pids: l.pids,
      docker: l.docker,
      uptimeSec: l.uptimeSec ?? null,
    });
  }

  const prune = [];
  for (const [port, rec] of Object.entries(servers)) {
    if (liveByPort.has(port)) continue;
    const last = Date.parse(rec.lastSeenAt || rec.registeredAt || 0) || 0;
    if (now - last > PRUNE_AFTER_MS) prune.push(port);
  }
  return { entries, prune, seen };
}

/** Live board. Side effects: refresh lastSeenAt (throttled) and prune old labels. */
export function getBoard({ live = scan(), now = Date.now() } = {}) {
  const servers = store.load();
  const { entries, prune, seen } = merge(live, servers, now);
  const needsSeen = seen.filter((p) => now - (Date.parse(servers[p].lastSeenAt || 0) || 0) > SEEN_WRITE_INTERVAL_MS);
  if (prune.length || needsSeen.length) {
    try {
      store.update((s) => {
        for (const p of prune) delete s[p];
        for (const p of needsSeen) if (s[p]) s[p].lastSeenAt = new Date(now).toISOString();
      });
    } catch {
      /* read-only contexts are fine */
    }
  }
  return entries;
}

/**
 * Record that labeled `ports` were live just now. The live menu calls this right before rescanning after a port
 * closes: it no longer rescans on a timer, so lastSeenAt would otherwise be as old as the last change and the
 * 24h prune could drop a label the moment its server stops.
 */
export function markSeen(ports, now = Date.now()) {
  if (!ports.length) return;
  store.update((s) => {
    let touched = false;
    for (const p of ports) {
      const rec = s[String(p)];
      if (rec && typeof rec === 'object') (rec.lastSeenAt = new Date(now).toISOString()), (touched = true);
    }
    return touched ? s : false; // nothing to record → don't rewrite the file
  });
}

/**
 * Pure: first `count` ports in [min, max] that nothing listens on and no label claims,
 * starting at `preferred` (if in range) and wrapping around.
 */
export function freePorts(listening, servers, { min, max, preferred, count = 1, reserved = [] }) {
  const taken = new Set([...listening].map(Number));
  for (const k of Object.keys(servers)) taken.add(Number(k));
  for (const p of reserved) taken.add(Number(p));
  const start = Number.isInteger(preferred) && preferred >= min && preferred <= max ? preferred : min;
  const out = [];
  const span = max - min + 1;
  for (let i = 0; i < span && out.length < count; i++) {
    const p = min + ((start - min + i) % span);
    if (!taken.has(p) && !IGNORE_PORTS.has(p)) out.push(p);
  }
  return out;
}

/** Free ports, each reserved for RESERVE_TTL_MS so a parallel agent won't be handed the same one. */
export function suggestFreePorts({ preferred, count = 1 } = {}) {
  const cfg = loadConfig();
  const opts = { min: cfg.portMin ?? PORT_MIN, max: cfg.portMax ?? PORT_MAX, preferred };
  const listening = listeningPorts();
  const servers = store.load();
  const out = [];
  const lost = new Set(); // ports another process reserved between our read and our reserve()
  while (out.length < count) {
    const reserved = [...store.activeReservations(), ...out, ...lost];
    const [p] = freePorts(listening, servers, { ...opts, count: 1, reserved });
    if (p == null) break; // range exhausted
    if (store.reserve(p)) out.push(p);
    else lost.add(p);
  }
  return out;
}

export function findLive(port, live = scan()) {
  return live.find((l) => l.port === Number(port)) || null;
}

/**
 * Register/overwrite a label. Waits up to `waitMs` for the port to start listening
 * (Claude often registers right after launching a server).
 * `live` ({cwd, branch}) is what the caller already knows about the server (the menu passes it); it's used instead of
 * a full scan when something is still listening on the port.
 */
export async function register({ port, title, description, waitMs = 10000, live }) {
  port = Number(port);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error(`Invalid port: ${port}`);
  if (!title || !String(title).trim()) throw new Error('title is required');
  let l = live && listenersOn(port).size ? live : findLive(port);
  const deadline = Date.now() + waitMs;
  while (!l && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 1000));
    l = findLive(port);
  }
  if (!l) {
    throw new Error(
      `Nothing is listening on port ${port} (checked ${Math.round(waitMs / 1000)}s). Start the dev server first, then register it.`,
    );
  }
  const now = new Date().toISOString();
  const rec = {
    port,
    title: String(title).trim(),
    description: description ? String(description).trim() : undefined,
    cwd: l.cwd,
    branch: l.branch,
    registeredAt: now,
    lastSeenAt: now,
  };
  store.update((s) => {
    s[String(port)] = rec;
  });
  store.release(port);
  return rec;
}

export function updateLabel({ port, title, description }) {
  const key = String(Number(port));
  if (title == null && description == null) throw new Error('Nothing to update: pass title and/or description.');
  if (title != null && !String(title).trim()) throw new Error('title cannot be empty (use remove_server to clear a label).');
  let rec;
  store.update((s) => {
    if (!s[key]) throw new Error(`Port ${key} is not registered. Use register_server first.`);
    if (title != null) s[key].title = String(title).trim();
    if (description != null) s[key].description = String(description).trim() || undefined;
    rec = s[key];
  });
  return rec;
}

export function remove(port) {
  const key = String(Number(port));
  let existed = false;
  store.update((s) => {
    existed = key in s;
    delete s[key];
  });
  return existed;
}
