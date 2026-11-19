#!/usr/bin/env node
// Porthole CLI — used by you in a terminal and by the SwiftBar plugin for menu actions.
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { getBoard, findLive, register, remove } from './board.js';
import { render, where2 } from './swiftbar.js';
import { loadConfig, saveConfig } from './store.js';

const CLI_PATH = fileURLToPath(import.meta.url);

const HELP = `porthole — which feature is on which localhost port

  porthole list                      show live dev servers + labels
  porthole register <port> <title> [description]
  porthole remove <port>             clear a label
  porthole open <port>               open in Chrome (falls back to default browser)
  porthole copy <port>               copy http://localhost:<port> to the clipboard
  porthole kill <port>               SIGTERM the process listening on <port>
  porthole ignore <port|command>     hide a port or a process name (e.g. claude-science) from the board
  porthole unignore <port|command>   undo ignore
  porthole ignored                   show the ignore list (~/.porthole/config.json)
  porthole swiftbar                  SwiftBar plugin output
`;

function ignore(target, add) {
  if (!target) die('Usage: porthole ignore <port|command>');
  const cfg = loadConfig();
  const isPort = /^\d+$/.test(target);
  const key = isPort ? 'ignorePorts' : 'ignoreCommands';
  const val = isPort ? needPort(target) : target;
  const set = new Set(cfg[key]);
  add ? set.add(val) : set.delete(val);
  cfg[key] = [...set];
  saveConfig(cfg);
  console.log(`${add ? 'Ignoring' : 'No longer ignoring'} ${isPort ? `port ${val}` : `command "${val}"`}.`);
}

function die(msg) {
  console.error(msg);
  process.exit(1);
}

function needPort(p) {
  const n = Number(p);
  if (!Number.isInteger(n) || n < 1 || n > 65535) die(`Invalid port: ${p ?? '(missing)'}`);
  return n;
}

function list() {
  const entries = getBoard();
  if (!entries.length) return console.log('No dev servers running.');
  for (const e of entries) {
    const loc = e.docker ? 'docker' : where2(e.branch, e.repo) || e.command;
    const label = e.status === 'labeled' ? e.title : e.status === 'stale' ? `(stale label: ${e.staleTitle})` : '(unlabeled)';
    console.log(`:${String(e.port).padEnd(5)}  ${label.padEnd(36)}  ${loc}`);
    if (e.description) console.log(`        ${e.description}`);
  }
}

function open(port) {
  const url = `http://localhost:${port}`;
  const r = spawnSync('/usr/bin/open', ['-a', 'Google Chrome', url]);
  if (r.status !== 0) spawnSync('/usr/bin/open', [url]);
}

function copy(port) {
  execFileSync('/usr/bin/pbcopy', { input: `http://localhost:${port}` });
}

function kill(port) {
  const l = findLive(port);
  if (!l) die(`Nothing listening on ${port}.`);
  if (l.docker) die(`Port ${port} is published by Docker; stop the container instead (killing ${l.command} would stop Docker).`);
  for (const pid of l.pids) {
    try {
      process.kill(pid, 'SIGTERM');
    } catch (err) {
      console.error(`Could not kill ${pid}: ${err.message}`);
    }
  }
  console.log(`Sent SIGTERM to ${l.pids.join(', ')} (${l.command}) on :${port}`);
}

async function main() {
  const [cmd, ...args] = process.argv.slice(2);
  switch (cmd) {
    case 'list':
    case undefined:
      return list();
    case 'swiftbar':
      return process.stdout.write(render(getBoard(), { node: process.execPath, cli: CLI_PATH }));
    case 'register': {
      const [p, title, ...desc] = args;
      const rec = await register({ port: needPort(p), title, description: desc.join(' ') || undefined, waitMs: 3000 });
      return console.log(`Registered :${rec.port} — ${rec.title}${rec.branch ? ` (${rec.branch})` : ''}`);
    }
    case 'remove':
      return console.log(remove(needPort(args[0])) ? 'Removed.' : 'No label for that port.');
    case 'open':
      return open(needPort(args[0]));
    case 'copy':
      return copy(needPort(args[0]));
    case 'kill':
      return kill(needPort(args[0]));
    case 'ignore':
      return ignore(args[0], true);
    case 'unignore':
      return ignore(args[0], false);
    case 'ignored': {
      const c = loadConfig();
      return console.log(`ports: ${c.ignorePorts.join(', ') || '(none)'}\ncommands: ${c.ignoreCommands.join(', ') || '(none)'}`);
    }
    case 'help':
    case '-h':
    case '--help':
      return console.log(HELP);
    default:
      die(`Unknown command: ${cmd}\n\n${HELP}`);
  }
}

main().catch((err) => die(err.message));
