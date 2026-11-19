// Merge live scan results with stored labels. Pure core + thin I/O wrappers.
import * as store from './store.js';
import { scan } from './detect.js';

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
      command: l.command,
      pids: l.pids,
      docker: l.docker,
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

export function findLive(port, live = scan()) {
  return live.find((l) => l.port === Number(port)) || null;
}

/**
 * Register/overwrite a label. Waits up to `waitMs` for the port to start listening
 * (Claude often registers right after launching a server).
 */
export async function register({ port, title, description, waitMs = 10000 }) {
  port = Number(port);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error(`Invalid port: ${port}`);
  if (!title || !String(title).trim()) throw new Error('title is required');
  let l = findLive(port);
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
  return rec;
}

export function updateLabel({ port, title, description }) {
  const key = String(Number(port));
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
