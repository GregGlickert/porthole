// SwiftBar streamable plugin: one long-lived process that rescans only when something changed.
// Every POLL_MS it takes a cheap netstat fingerprint of listening ports. The full scan (lsof/ps/git/docker)
// runs only when that fingerprint changes or when labels/config in ~/.porthole/ change (fs.watch).
// Once a minute it redraws from the last scan so "up 5m" / "labeled 2h ago" stay current, and checks
// cheaply (file reads, no processes) for what the fingerprint can't see: a branch switch in a running
// server's checkout, or a Docker row whose container name couldn't be read last time.
import fs from 'node:fs';
import { getBoard, markSeen } from './board.js';
import { headBranch, listenFingerprint } from './detect.js';
import { homeDir, load, loadConfig } from './store.js';
import { render } from './swiftbar.js';

export const POLL_MS = 5000;
export const REDRAW_MS = 60000;
// lastSeenAt keeps labels from being pruned (24h unseen). Refresh it for live labeled ports at most this often.
const SEEN_EVERY_MS = 10 * 60 * 1000;

/** Pure: which work this tick needs. The first tick (no previous fingerprint) isn't a port change. */
export function plan(s, now) {
  const portsChanged = s.prevFingerprint != null && s.fingerprint !== s.prevFingerprint;
  const rescan = portsChanged || s.dirty;
  const redraw = rescan || now - s.lastRender >= REDRAW_MS;
  return { portsChanged, rescan, redraw };
}

/**
 * What in ~/.porthole/ affects the menu: labels (minus lastSeenAt, which we write ourselves) and config.
 * Reservations aren't shown, so they're left out. A file event that leaves this unchanged needs no rescan.
 */
export function settingsKey(servers = load(), config = loadConfig()) {
  const labels = Object.entries(servers)
    .filter(([, v]) => v && typeof v === 'object')
    .map(([port, { lastSeenAt, ...rest }]) => [port, rest])
    .sort(([a], [b]) => Number(a) - Number(b));
  return JSON.stringify([labels, config]);
}

/** Pure: entries from a scan at `scannedAt`, with uptimes advanced to `now` so ages are right without rescanning. */
export function aged(entries, scannedAt, now) {
  const dt = Math.max(0, Math.round((now - scannedAt) / 1000));
  return entries.map((e) => (e.uptimeSec == null ? e : { ...e, uptimeSec: e.uptimeSec + dt }));
}

/**
 * Pure: does the last scan look out of date in ways the port fingerprint can't detect?
 * `branchOf(root)` reads the checkout's current branch (null = unknown, which never forces a rescan).
 */
export function looksStale(entries, branchOf = headBranch) {
  return entries.some((e) => {
    if (e.docker) return !e.docker.container; // docker ps failed or timed out last time
    if (!e.root || !e.branch) return false;
    const now = branchOf(e.root);
    if (now == null || now === e.branch) return false;
    // Detached: git's short sha can be longer than 7 chars, so compare by common prefix.
    const [a, b] = [now, e.branch].map((x) => x.match(/^detached@([0-9a-f]+)$/)?.[1]);
    return !(a && b && (a.startsWith(b) || b.startsWith(a)));
  });
}

export async function runStream({ renderCtx, out = process.stdout }) {
  const state = { fingerprint: null, prevFingerprint: null, dirty: true, lastRender: 0 };
  let entries = [];
  let scannedAt = 0;
  let lastSeenWrite = 0;
  let shownSettings = null;
  const log = (msg) => process.stderr.write(`porthole stream: ${msg}\n`);

  // Never outlive SwiftBar: it closes our stdout (EPIPE) or dies and we get reparented to launchd.
  out.on('error', () => process.exit(0));
  const parent = process.ppid;
  // A long-lived menu must not die on one bad event; log it and keep the loop going.
  process.on('uncaughtException', (err) => log(err.stack || err.message));

  let timer;
  const wake = () => {
    clearTimeout(timer);
    tick();
  };

  fs.mkdirSync(homeDir(), { recursive: true });
  let debounce;
  try {
    const watcher = fs.watch(homeDir(), { recursive: true }, () => {
      clearTimeout(debounce);
      debounce = setTimeout(() => {
        try {
          if (settingsKey() === shownSettings) return; // only lastSeenAt changed, or a reservation
        } catch {
          /* unreadable right now: rescan to be safe */
        }
        state.dirty = true;
        wake();
      }, 200);
    });
    watcher.on('error', (err) => log(`watch: ${err.message}`));
  } catch {
    /* no fs.watch: label changes show on the next port change */
  }

  function tick() {
    try {
      if (process.ppid !== parent || process.ppid === 1) process.exit(0);
      const now = Date.now();
      state.prevFingerprint = state.fingerprint;
      state.fingerprint = listenFingerprint(loadConfig());
      let { portsChanged, rescan, redraw } = plan(state, now);
      if (!rescan && redraw && looksStale(entries)) rescan = true;
      if (rescan) {
        state.dirty = false;
        // Labeled servers that just stopped were live until now; record that before the scan forgets them.
        if (portsChanged) touchSeen(entries, now);
        shownSettings = settingsKey();
        entries = getBoard();
        scannedAt = Date.now();
      } else if (redraw && now - lastSeenWrite >= SEEN_EVERY_MS) {
        touchSeen(entries, now);
      }
      if (redraw) {
        state.lastRender = Date.now();
        out.write('~~~\n' + render(aged(entries, scannedAt, state.lastRender), renderCtx()));
      }
    } catch (err) {
      log(err.message);
    } finally {
      timer = setTimeout(tick, POLL_MS);
    }
  }

  /** Best effort: a failed write (bad JSON, read-only disk) must not stop the rescan that follows. */
  function touchSeen(list, now) {
    lastSeenWrite = now;
    try {
      markSeen(list.filter((e) => e.status === 'labeled').map((e) => e.port), now);
    } catch (err) {
      log(`lastSeenAt: ${err.message}`);
    }
  }

  tick();
  await new Promise(() => {}); // run until SwiftBar stops us
}
