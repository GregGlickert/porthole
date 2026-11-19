import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

process.env.PORTBOARD_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'portboard-test-'));
const store = await import('../src/store.js');
const { merge, getBoard, PRUNE_AFTER_MS } = await import('../src/board.js');
const { render } = await import('../src/swiftbar.js');

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

test('render: SwiftBar output has count, actions, docker submenu, no kill for docker', () => {
  const { entries } = merge(
    [live(3001, '/a'), live(8080, null, { docker: true, command: 'com.docker.backend' })],
    { 3001: { port: 3001, title: 'Upload | retry', description: 'Adds backoff', cwd: '/a', registeredAt: 'x' } },
  );
  const out = render(entries, { node: '/usr/bin/node', cli: '/p/cli.js' });
  const lines = out.split('\n');
  assert.equal(lines[0], '⚡1');
  assert.match(out, /^:3001 {2}Upload \/ retry \| bash="\/usr\/bin\/node" param1="\/p\/cli.js" param2=open param3=3001/m);
  assert.match(out, /alternate=true/);
  assert.match(out, /--Kill server .*param3=3001/);
  assert.match(out, /^Docker \(1\)/m);
  assert.doesNotMatch(out, /Kill server .*param3=8080/);
});
