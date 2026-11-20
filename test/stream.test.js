import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

process.env.PORTHOLE_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'porthole-stream-test-'));
const { plan, aged, settingsKey, looksStale, REDRAW_MS } = await import('../src/stream.js');
const { parseNetstatListen, parseHead, headBranch, filterLivePids } = await import('../src/detect.js');
const store = await import('../src/store.js');
const { freePorts, markSeen } = await import('../src/board.js');
const { render } = await import('../src/swiftbar.js');
const { pickApps } = await import('../src/apps.js');

const NETSTAT = `Active Internet connections (including servers)
Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)          rxbytes      txbytes  rhiwat  shiwat          process:pid    state  options           gencnt    flags   flags1 usecnt rtncnt fltrs
tcp4       0      0  127.0.0.1.3001         *.*                    LISTEN                 0            0  131072  131072             node:4242  00100 00000006 0000000000eef459 00000001 00000800      1      0 000000
tcp6       0      0  ::1.3001               *.*                    LISTEN                 0            0  131072  131072             node:4242  00100 00000006 0000000000eef45a 00000001 00000800      1      0 000000
tcp46      0      0  *.3000                 *.*                    LISTEN                 0            0  131072  131072 com.docker.backe:22139  00100 00000006 0000000000ee1133 00000000 00000800      1      0 000000
tcp4       0      0  *.8080                 *.*                    LISTEN                 0            0  131072  131072  Google Chrome H:999   00100 00000006 0000000000ee1134 00000000 00000800      1      0 000000
tcp4       0      0  127.0.0.1.3001         127.0.0.1.50000        ESTABLISHED            0            0  131072  131072             node:4242  00102 00000004 0000000000eef460 00000001 00000800      1      0 000000
`;

test('parseNetstatListen: LISTEN rows only, v4/v6 deduped, names with spaces', () => {
  assert.deepEqual(parseNetstatListen(NETSTAT), [
    { pid: 4242, command: 'node', port: 3001 },
    { pid: 22139, command: 'com.docker.backe', port: 3000 },
    { pid: 999, command: 'Google Chrome H', port: 8080 },
  ]);
});

test('plan: rescan only on port or settings change; redraw (no rescan) once a minute', () => {
  const base = { fingerprint: 'a', prevFingerprint: 'a', dirty: false, lastRender: 1000 };
  assert.deepEqual(plan(base, 1500), { portsChanged: false, rescan: false, redraw: false });
  assert.deepEqual(plan({ ...base, fingerprint: 'b' }, 1500), { portsChanged: true, rescan: true, redraw: true });
  assert.deepEqual(plan({ ...base, dirty: true }, 1500), { portsChanged: false, rescan: true, redraw: true });
  assert.deepEqual(plan(base, 1000 + REDRAW_MS), { portsChanged: false, rescan: false, redraw: true });
  // First tick (prevFingerprint still null, as runStream starts it) isn't a "change"; dirty covers the initial scan.
  assert.equal(plan({ ...base, prevFingerprint: null, fingerprint: 'a' }, 1500).portsChanged, false);
});

test('aged: advances uptimes to now without rescanning', () => {
  const out = aged([{ port: 1, uptimeSec: 60 }, { port: 2, uptimeSec: null }], 0, 120000);
  assert.deepEqual(out.map((e) => e.uptimeSec), [180, null]);
});

test('settingsKey ignores lastSeenAt (our own writes) but not label or config edits; tolerates junk', () => {
  const a = { 3000: { port: 3000, title: 'A', lastSeenAt: '2026-01-01' } };
  const b = { 3000: { port: 3000, title: 'A', lastSeenAt: '2026-06-01' } };
  const c = { 3000: { port: 3000, title: 'B', lastSeenAt: '2026-01-01' } };
  assert.equal(settingsKey(a, {}), settingsKey(b, {}));
  assert.notEqual(settingsKey(a, {}), settingsKey(c, {}));
  assert.notEqual(settingsKey(a, {}), settingsKey(a, { ignorePorts: [3000] }));
  assert.doesNotThrow(() => settingsKey({ 3000: null, 3001: 'x' }, {})); // a bad hand edit must not crash the stream
});

test('looksStale: branch switched under a running server, or docker info missing', () => {
  const e = (extra) => ({ port: 3000, root: '/r', branch: 'main', docker: false, ...extra });
  assert.equal(looksStale([e()], () => 'main'), false);
  assert.equal(looksStale([e()], () => 'feat/x'), true);
  assert.equal(looksStale([e()], () => null), false); // unknown never forces a rescan
  assert.equal(looksStale([e({ branch: 'detached@1a2b3c4d5' })], () => 'detached@1a2b3c4'), false);
  assert.equal(looksStale([e({ branch: 'detached@1a2b3c4' })], () => 'detached@9f9f9f9'), true);
  assert.equal(looksStale([e({ docker: { container: null } })]), true);
  assert.equal(looksStale([e({ docker: { container: 'web-1' } })]), false);
});

test('parseHead / headBranch: branch, detached, worktree .git file', () => {
  assert.equal(parseHead('ref: refs/heads/feat/x\n'), 'feat/x');
  assert.equal(parseHead('1a2b3c4d5e6f\n'), 'detached@1a2b3c4');
  assert.equal(parseHead('garbage'), null);
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'porthole-head-'));
  fs.mkdirSync(path.join(root, 'main/.git'), { recursive: true });
  fs.writeFileSync(path.join(root, 'main/.git/HEAD'), 'ref: refs/heads/main\n');
  fs.mkdirSync(path.join(root, 'main/.git/worktrees/wt'), { recursive: true });
  fs.writeFileSync(path.join(root, 'main/.git/worktrees/wt/HEAD'), 'ref: refs/heads/feat/wt\n');
  fs.mkdirSync(path.join(root, 'wt'));
  fs.writeFileSync(path.join(root, 'wt/.git'), 'gitdir: ../main/.git/worktrees/wt\n');
  assert.equal(headBranch(path.join(root, 'main')), 'main');
  assert.equal(headBranch(path.join(root, 'wt')), 'feat/wt');
  assert.equal(headBranch(path.join(root, 'nope')), null);
});

test('labels file with invalid JSON is never overwritten', () => {
  const file = path.join(process.env.PORTHOLE_HOME, 'servers.json');
  fs.writeFileSync(file, '{ "version": 1, "servers": { "3000": { "title": "A" }, } }'); // trailing comma
  assert.throws(() => markSeen([3000]), /isn't valid JSON/);
  assert.throws(() => store.update(() => {}), /isn't valid JSON/);
  assert.match(fs.readFileSync(file, 'utf8'), /"title": "A" \}, \}/); // untouched
  store.save({});
});

test('load drops malformed records; markSeen with nothing to touch does not rewrite the file', () => {
  const file = path.join(process.env.PORTHOLE_HOME, 'servers.json');
  fs.writeFileSync(file, JSON.stringify({ version: 1, servers: { 3000: null, 3001: 'x', 3002: { port: 3002, title: 'ok' } } }));
  assert.deepEqual(Object.keys(store.load()), ['3002']);
  const before = fs.statSync(file).mtimeMs;
  markSeen([4000]);
  assert.equal(fs.statSync(file).mtimeMs, before);
  store.save({});
});

test('markSeen refreshes lastSeenAt for labeled ports only', () => {
  store.save({ 3000: { port: 3000, title: 'A', lastSeenAt: '2026-01-01T00:00:00.000Z' } });
  markSeen([3000, 3001], Date.parse('2026-02-01T00:00:00Z'));
  assert.deepEqual(Object.keys(store.load()), ['3000']);
  assert.equal(store.load()['3000'].lastSeenAt, '2026-02-01T00:00:00.000Z');
});

test('reserve: one winner, expired reservations can be taken over, release frees it', () => {
  assert.equal(store.reserve(3005), true);
  assert.equal(store.reserve(3005), false); // a second agent loses
  assert.deepEqual([...store.activeReservations()], [3005]);
  assert.equal(store.reserve(3005, Date.now() + store.RESERVE_TTL_MS + 1000), true); // expired → takeover
  store.release(3005);
  assert.deepEqual([...store.activeReservations()], []);
  assert.equal(store.reserve(3005), true);
  store.release(3005);
});

test('freePorts skips reserved ports', () => {
  assert.deepEqual(freePorts([3000], {}, { min: 3000, max: 3010, count: 2, reserved: [3001] }), [3002, 3003]);
});

test('render: open-in items only with a folder; actions never force a refresh', () => {
  const e = (port, extra) => ({ port, url: `http://localhost:${port}`, status: 'unlabeled', pids: [1], command: 'node', docker: false, ...extra });
  const out = render(
    [
      e(3000, { root: '/repo', cwd: '/repo/web' }),
      e(3001, {}),
    ],
    { node: '/n', cli: '/c', editor: 'Zed', terminal: 'Ghostty' },
  );
  assert.equal((out.match(/Open in Zed/g) || []).length, 1);
  assert.match(out, /--Open in Zed \| bash="\/usr\/bin\/open" param1="-a" param2="Zed" param3="\/repo" terminal=false/);
  assert.match(out, /--Open in Ghostty \| bash="\/usr\/bin\/open" param1="-a" param2="Ghostty" param3="\/repo" terminal=false/);
  assert.match(out, /--Open in Finder \| bash="\/usr\/bin\/open" param1="\/repo" terminal=false/);
  assert.doesNotMatch(out, /param2="(open|copy|remove|ignore|confirm-kill|prompt-label)".*refresh=true/);
});

test('pickApps: config wins, else first installed', () => {
  const has = (n) => n === 'Visual Studio Code' || n === 'Terminal';
  assert.deepEqual(pickApps({}, has), { editor: 'Visual Studio Code', terminal: 'Terminal', browser: null });
  assert.deepEqual(pickApps({ editor: 'Zed', terminal: 'iTerm', browser: 'Arc' }, has), { editor: 'Zed', terminal: 'iTerm', browser: 'Arc' });
  assert.equal(pickApps({}, (n) => n === 'Google Chrome').browser, 'Google Chrome');
  assert.deepEqual(pickApps({}, () => false), { editor: null, terminal: null, browser: null });
});

test('render: open and copy run without node; browser picked at render time', () => {
  const e = { port: 3000, url: 'http://localhost:3000', status: 'unlabeled', pids: [1], command: 'node', docker: false };
  const out = render([e], { node: '/n', cli: '/c', browser: 'Google Chrome' });
  assert.match(out, /^:3000.* \| bash="\/usr\/bin\/open" param1="-a" param2="Google Chrome" param3="http:\/\/localhost:3000" terminal=false$/m);
  assert.match(out, /--Copy URL \| bash="\/bin\/bash" param1="-c" param2="printf %s \$1 \| \/usr\/bin\/pbcopy" param3="porthole" param4="http:\/\/localhost:3000" terminal=false/);
  // No click on open/copy/open-in goes through node.
  assert.doesNotMatch(out, /bash="\/n".*param2="(open|copy|open-editor|open-terminal)"/);
});

test('filterLivePids drops PIDs no longer listening (never signal a reused PID)', () => {
  assert.deepEqual(filterLivePids([10, 20], new Set([20, 30])), [20]);
  assert.deepEqual(filterLivePids([10], new Set()), []);
});
