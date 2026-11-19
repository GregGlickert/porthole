import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseLsofListen, parseLsofCwd, isDevCandidate, parseDockerPs, parseDockerStarted, parsePsEtime } from '../src/detect.js';

const LSOF = `p652
cControlCenter
f9
n*:7000
f10
n*:7000
p11916
ccom.docker.backend
f17
n*:5678
f108
n*:5432
p4242
cnode
f20
n127.0.0.1:3001
f21
n[::1]:3001
p4300
cpython3.12
f5
n*:3005
`;

test('parseLsofListen dedupes IPv4/IPv6 and keeps pid/command', () => {
  const r = parseLsofListen(LSOF);
  assert.deepEqual(r, [
    { pid: 652, command: 'ControlCenter', port: 7000 },
    { pid: 11916, command: 'com.docker.backend', port: 5678 },
    { pid: 11916, command: 'com.docker.backend', port: 5432 },
    { pid: 4242, command: 'node', port: 3001 },
    { pid: 4300, command: 'python3.12', port: 3005 },
  ]);
});

test('isDevCandidate filters system processes, DB ports and out-of-range ports', () => {
  assert.equal(isDevCandidate({ command: 'ControlCenter', port: 7000 }), false);
  assert.equal(isDevCandidate({ command: 'com.docker.backend', port: 5432 }), false);
  assert.equal(isDevCandidate({ command: 'node', port: 3001 }), true);
  assert.equal(isDevCandidate({ command: 'node', port: 60009 }), false);
});

test('parseLsofCwd maps pid to cwd', () => {
  const m = parseLsofCwd('p4242\nfcwd\nn/Users/me/app\np4300\nfcwd\nn/Users/me/app-wt\n');
  assert.equal(m.get(4242), '/Users/me/app');
  assert.equal(m.get(4300), '/Users/me/app-wt');
});

test('isDevCandidate honors user config ignore lists and range', () => {
  const cfg = { ignorePorts: [8000], ignoreCommands: ['claude-science'], portMin: 3000, portMax: 4000 };
  assert.equal(isDevCandidate({ command: 'node', port: 8000 }, cfg), false);
  assert.equal(isDevCandidate({ command: 'claude-science', port: 3500 }, cfg), false);
  assert.equal(isDevCandidate({ command: 'node', port: 4500 }, cfg), false);
  assert.equal(isDevCandidate({ command: 'node', port: 3500 }, cfg), true);
});

const DOCKER_PS = [
  'a1b2c3d4e5f6\tbalance-api-1\tbalance-api\t0.0.0.0:5678->5678/tcp, [::]:5678->5678/tcp, 0.0.0.0:8080->8080/tcp, [::]:8080->8080/tcp\tbalance\tapi',
  'b1b2c3d4e5f6\tbalance-postgres-1\tpostgres:17\t0.0.0.0:5432->5432/tcp\tbalance\tpostgres',
  'c1b2c3d4e5f6\tworker\tredis\t6379/tcp\t\t',
  'd1b2c3d4e5f6\tranged\tnginx\t0.0.0.0:9000-9001->80-81/tcp\t\t',
].join('\n');

test('parseDockerPs maps host ports to containers (dedupes v4/v6, ranges, unpublished)', () => {
  const m = parseDockerPs(DOCKER_PS);
  assert.deepEqual([...m.keys()].sort(), [5432, 5678, 8080, 9000, 9001]);
  assert.deepEqual(m.get(8080), {
    id: 'a1b2c3d4e5f6',
    container: 'balance-api-1',
    image: 'balance-api',
    project: 'balance',
    service: 'api',
    containerPort: 8080,
  });
  assert.equal(m.get(9001).containerPort, 81);
  assert.equal(m.get(9000).project, null);
  assert.equal(parseDockerPs('').size, 0);
});

test('parseDockerStarted keys by short id', () => {
  const m = parseDockerStarted('a1b2c3d4e5f6aaaaaaaa\t2026-11-19T19:19:15.29Z\nbad\tnope\n');
  assert.equal(m.get('a1b2c3d4e5f6'), Date.parse('2026-11-19T19:19:15.29Z'));
  assert.equal(m.size, 1);
});

test('parsePsEtime handles mm:ss, hh:mm:ss and dd-hh:mm:ss', () => {
  const m = parsePsEtime('  14000    04:58:43\n    1 17-04:40:31\n  99    00:07\n');
  assert.equal(m.get(14000), 4 * 3600 + 58 * 60 + 43);
  assert.equal(m.get(1), ((17 * 24 + 4) * 60 + 40) * 60 + 31);
  assert.equal(m.get(99), 7);
});
