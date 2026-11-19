#!/usr/bin/env node
// Porthole CLI — used by you in a terminal and by the SwiftBar plugin for menu actions.
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { getBoard, findLive, register, remove } from './board.js';
import { render, where2 } from './swiftbar.js';
import fs from 'node:fs';
import path from 'node:path';
import { loadConfig, saveConfig, homeDir } from './store.js';
import { PORT_MIN, PORT_MAX } from './detect.js';

const CLI_PATH = fileURLToPath(import.meta.url);
const ROOT = path.dirname(path.dirname(CLI_PATH));
const PKG = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8'));
const REPO_URL = (PKG.repository?.url || PKG.repository || '').replace(/^git\+/, '').replace(/\.git$/, '') || undefined;

/** Open ~/.porthole/config.json or servers.json in the default text editor, creating it if missing. */
function edit(which) {
  const file = path.join(homeDir(), which === 'labels' ? 'servers.json' : 'config.json');
  if (!fs.existsSync(file)) {
    if (which === 'labels') fs.mkdirSync(homeDir(), { recursive: true }), fs.writeFileSync(file, '{ "version": 1, "servers": {} }\n');
    else saveConfig({ ignorePorts: [], ignoreCommands: [], portMin: PORT_MIN, portMax: PORT_MAX });
  }
  spawnSync('/usr/bin/open', ['-t', file]);
}

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
  porthole edit [config|labels]      open ~/.porthole/config.json or servers.json in your editor
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
      return process.stdout.write(
        render(getBoard(), {
          node: process.execPath,
          cli: CLI_PATH,
          config: loadConfig(),
          portMin: PORT_MIN,
          portMax: PORT_MAX,
          version: PKG.version,
          repoUrl: REPO_URL,
          root: ROOT,
        }),
      );
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
    case 'edit':
      return edit(args[0] === 'labels' ? 'labels' : 'config');
    case 'help':
    case '-h':
    case '--help':
      return console.log(HELP);
    default:
      die(`Unknown command: ${cmd}\n\n${HELP}`);
  }
}

main().catch((err) => die(err.message));
