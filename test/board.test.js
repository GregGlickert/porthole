import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

process.env.PORTHOLE_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'porthole-test-'));
const store = await import('../src/store.js');
const { merge, getBoard, freePorts, updateLabel, PRUNE_AFTER_MS } = await import('../src/board.js');
const { render, portLabel, humanAge, wrap, describeLive } = await import('../src/swiftbar.js');

const live = (port, cwd, extra = {}) => ({
  port,
  pids: [1000 + port],
  command: 'node',
  cwd,
  branch: 'feat/x',
  repo: path.basename(cwd || 'docker'),
  docker: false,
  ...extra,
});

beforeEach(() => store.save({}));

test('store round-trips', () => {
  store.save({ 3001: { port: 3001, title: 'A', registeredAt: 'x' } });
  assert.equal(store.load()['3001'].title, 'A');
});

test('merge: labeled, unlabeled, stale', () => {
  const servers = {
    3001: { port: 3001, title: 'Upload retry', cwd: '/a', registeredAt: new Date().toISOString() },
    3002: { port: 3002, title: 'Old feature', cwd: '/old', registeredAt: new Date().toISOString() },
  };
  const { entries } = merge([live(3001, '/a'), live(3002, '/new'), live(3003, '/c')], servers);
  assert.deepEqual(
    entries.map((e) => [e.port, e.status, e.title, e.staleTitle]),
    [
      [3001, 'labeled', 'Upload retry', null],
      [3002, 'stale', null, 'Old feature'],
      [3003, 'unlabeled', null, null],
    ],
  );
});

test('merge: docker port with label stays labeled (cwd unknown)', () => {
  const servers = { 8080: { port: 8080, title: 'Jellyfin', cwd: null, registeredAt: new Date().toISOString() } };
  const { entries } = merge([live(8080, null, { docker: true, command: 'com.docker.backend' })], servers);
  assert.equal(entries[0].status, 'labeled');
});

test('getBoard prunes labels not seen for 24h, keeps recent ones', () => {
  const now = Date.now();
  store.save({
    3001: { port: 3001, title: 'old', registeredAt: new Date(now - PRUNE_AFTER_MS - 1000).toISOString() },
    3002: { port: 3002, title: 'recent', registeredAt: new Date(now - 1000).toISOString() },
  });
  assert.deepEqual(getBoard({ live: [], now }), []);
  assert.deepEqual(Object.keys(store.load()), ['3002']);
});

test('render: SwiftBar output has count, actions, docker ports in main list, no kill for docker', () => {
  const { entries } = merge(
    [live(3001, '/a'), live(8080, null, { docker: true, command: 'com.docker.backend' })],
    { 3001: { port: 3001, title: 'Upload | retry', description: 'Adds backoff', cwd: '/a', registeredAt: 'x' } },
  );
  const out = render(entries, { node: '/usr/bin/node', cli: '/p/cli.js' });
  const lines = out.split('\n');
  assert.match(lines[0], /^2 \| templateImage=[A-Za-z0-9+/=]+$/);
  // One row per port: the title alone, with location and actions in its submenu.
  assert.match(out, /^:3001[\u2009\u2006\u200A]* {2}Upload \/ retry \| bash="\/usr\/bin\/open" param1="http:\/\/localhost:3001" terminal=false$/m);
  assert.match(out, /^--Open http:\/\/localhost:3001 \| bash="\/usr\/bin\/open" param1="http:\/\/localhost:3001" terminal=false/m);
  assert.doesNotMatch(out, /^ {4}\S/m);
  assert.match(out, /--Kill server… .*param2="confirm-kill" param3="3001" param4="4001" param5="feat\/x \(node\)" terminal=false/);
  assert.doesNotMatch(out, /^Docker \(/m);
  assert.match(out, /^:8080[\u2009\u2006\u200A]* {2}docker \| .*param1="http:\/\/localhost:8080"/m);
  assert.match(out, /--Label this port… .*param3="8080"/);
  assert.doesNotMatch(out, /Kill server.*param3="8080"/);
  // No container identified (docker ps unavailable) → no stop action either.
  assert.doesNotMatch(out, /Stop container.*param3="8080"/);
});

test('render: Settings lists hidden ports/processes with unignore actions; About has version + repo', () => {
  const out = render([], {
    node: '/n',
    cli: '/c',
    config: { ignorePorts: [8000], ignoreCommands: ['claude-science'] },
    portMin: 3000,
    portMax: 9999,
    version: '0.1.0',
    repoUrl: 'https://github.com/x/porthole',
    root: '/r',
  });
  assert.match(out, /^Settings \| sfimage=gearshape$/m);
  assert.match(out, /^--:8000 {2}— click to show again \| .*param2="unignore" param3="8000"/m);
  assert.match(out, /^--claude-science {2}— click to show again \| .*param3="claude-science"/m);
  assert.match(out, /--Port range: 3000–9999/);
  assert.match(out, /--Porthole 0\.1\.0/);
  assert.match(out, /href=https:\/\/github\.com\/x\/porthole/);
});

const ctx = { node: '/n', cli: '/c' };
const balanceApi = { container: 'balance-api-1', image: 'balance-api', project: 'balance', service: 'api', containerPort: 8080 };

test('merge passes docker info and uptime through', () => {
  const { entries } = merge([live(8080, null, { docker: balanceApi, command: 'com.docker.backend', repo: 'balance', uptimeSec: 60 })], {});
  assert.deepEqual(entries[0].docker, balanceApi);
  assert.equal(entries[0].uptimeSec, 60);
});

test('render: docker entries show container names instead of backend PID', () => {
  const { entries } = merge(
    [
      live(8080, null, { docker: balanceApi, command: 'com.docker.backend', uptimeSec: 3600 }),
      live(3000, null, { docker: { ...balanceApi, container: 'balance-frontend-1', service: 'frontend', containerPort: 3000 }, command: 'com.docker.backend' }),
    ],
    { 8080: { port: 8080, title: 'Main API', cwd: null, registeredAt: new Date(Date.now() - 40 * 60e3).toISOString() } },
  );
  const out = render(entries, ctx);
  assert.match(out, /^--balance · api \| size=11/m);
  assert.match(out, /--container balance-api-1 · image balance-api/);
  assert.match(out, /--up 1h · labeled 40m ago/);
  assert.doesNotMatch(out, /com\.docker\.backend/);
  assert.match(out, /^:3000[\u2009\u2006\u200A]* {2}balance · frontend \| .*param1="http:\/\/localhost:3000"/m);
  assert.match(out, /--Label this port… .*param3="3000"/);
  // Docker ports get "Stop container…" (docker stop) instead of killing Docker's PID.
  assert.match(out, /--Stop container… .*param2="confirm-kill" param3="3000" param4="-" param5="balance · frontend \(container balance-frontend-1\)" param6="balance-frontend-1".*sfimage=stop\.circle/);
  assert.doesNotMatch(out, /Kill server/);
});

test('render: label/rename items, cwd "/" hidden, kill last, icons on every action', () => {
  const { entries } = merge([live(3001, '/a'), live(8000, '/', { command: 'claude-science' })], {
    3001: { port: 3001, title: 'A', cwd: '/a', registeredAt: new Date().toISOString() },
  });
  const out = render(entries, ctx);
  assert.match(out, /--Rename… \| .*param2="prompt-label" param3="3001" param4="feat\/x \(node\)" param5="\/a" param6="feat\/x"/);
  assert.match(out, /--Label this port… \| .*param2="prompt-label" param3="8000"/);
  assert.doesNotMatch(out, /^--\/ \|/m);
  assert.doesNotMatch(out, /^:8000.*color=gray/m); // unlabeled title row is not grayed out
  const actions = out.split('\n').filter((l) => /^--.*\bbash=/.test(l));
  for (const l of actions) assert.match(l, /sfimage=/, l);
  // Kill is the last item of each port submenu.
  const sub3001 = out.split('\n:8000')[0].split('\n');
  assert.match(sub3001[sub3001.length - 1], /Kill server…/);
  assert.equal(sub3001[sub3001.length - 2], '-----');
});

test('render: Settings collapses to "Nothing hidden"', () => {
  const out = render([], { ...ctx, config: { ignorePorts: [], ignoreCommands: [] } });
  assert.match(out, /^--Nothing hidden/m);
  assert.doesNotMatch(out, /Hidden ports|none/);
});

test('humanAge', () => {
  assert.equal(humanAge(30), '1m');
  assert.equal(humanAge(3600), '1h');
  assert.equal(humanAge(17640), '4h 54m');
  assert.equal(humanAge(200000), '2d 7h');
  assert.equal(humanAge(null), null);
});

test('wrap: no one-word last line, sentences kept together', () => {
  const lines = wrap("Docker frontend from the main checkout (test/print-blank-fix). Test that printed reports aren't blank.", 60);
  assert.ok(lines.every((l) => l.length <= 60 || !l.includes(' ')));
  assert.ok(lines[lines.length - 1].includes(' '));
  assert.deepEqual(wrap('Short one. Another.', 60), ['Short one. Another.']);
  assert.deepEqual(wrap('aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj kkkk llll x', 60).length, 1);
});

test('freePorts skips listening, labeled and DB ports; starts at preferred and wraps', () => {
  assert.deepEqual(freePorts(new Set([3000, 3001]), { 3002: {} }, { min: 3000, max: 3010, count: 2 }), [3003, 3004]);
  assert.deepEqual(freePorts(new Set(), {}, { min: 3000, max: 3010, preferred: 3009, count: 3 }), [3009, 3010, 3000]);
  assert.deepEqual(freePorts(new Set(), {}, { min: 5431, max: 5433, count: 3 }), [5431, 5433]);
  assert.deepEqual(freePorts(new Set(), {}, { min: 3000, max: 3010, preferred: 80 }), [3000]);
});

test('describeLive: readable names for dialogs', () => {
  assert.equal(describeLive(live(3000, null, { docker: balanceApi })), 'balance · api (container balance-api-1)');
  assert.equal(describeLive(live(3001, '/x/myapp', { repo: 'myapp' })), 'feat/x · myapp (node)');
  assert.equal(describeLive(live(8000, '/', { branch: null, repo: null, command: 'claude-science' })), 'claude-science');
  assert.equal(describeLive(live(8081, null, { docker: {} })), 'Docker');
});

test('updateLabel rejects blank titles and empty updates, keeps the label', () => {
  store.save({ 4910: { port: 4910, title: 'Keep me', registeredAt: 'x' } });
  assert.throws(() => updateLabel({ port: 4910, title: '   ' }), /title cannot be empty/);
  assert.throws(() => updateLabel({ port: 4910 }), /Nothing to update/);
  assert.equal(store.load()['4910'].title, 'Keep me');
  assert.equal(updateLabel({ port: 4910, description: 'd' }).title, 'Keep me');
});

test('portLabel pads ports to one column width in the menu font', () => {
  const EM = { 0: 0.624, 1: 0.458, 2: 0.598, 3: 0.621, 4: 0.638, 5: 0.612, 6: 0.631, 7: 0.563, 8: 0.633, 9: 0.631, ':': 0.291, '\u2009': 0.135, '\u2006': 0.16, '\u200A': 0.064 };
  const width = (s) => [...s].reduce((w, c) => w + EM[c], 0);
  const widths = [3000, 3001, 1111, 8081, 4444, 7777].map((p) => width(portLabel(p)));
  // Within ~0.3pt of each other at 13pt.
  assert.ok(Math.max(...widths) - Math.min(...widths) <= 0.025, widths.join(' '));
  // 5-digit ports still line up with padded 4-digit ones when the column is 5 wide.
  assert.ok(Math.abs(width(portLabel(5173, 5)) - width(portLabel(11434, 5))) <= 0.025);
  assert.match(portLabel(3000), /^:3000[\u2009\u2006\u200A]*$/);
});
