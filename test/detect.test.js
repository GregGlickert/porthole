import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseLsofListen, parseLsofCwd, isDevCandidate } from '../src/detect.js';

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
