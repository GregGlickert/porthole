#!/usr/bin/env node
// Porthole CLI — used by you in a terminal and by the SwiftBar plugin for menu actions.
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { getBoard, findLive, register, remove, updateLabel } from './board.js';
import * as store from './store.js';
import { render, where2, describeLive, dockerWhere } from './swiftbar.js';
import fs from 'node:fs';
import path from 'node:path';
import { loadConfig, saveConfig, homeDir } from './store.js';
import { PORT_MIN, PORT_MAX } from './detect.js';
import { pickApps, openIn } from './apps.js';

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
  porthole kill <port>               SIGTERM the process on <port> (docker stop for containers)
  porthole confirm-kill <port>       same, after a confirmation dialog (used by the menu)
  porthole prompt-label <port>       set/rename a label in a dialog; empty removes it (used by the menu)
  porthole ignore <port|command>     hide a port or a process name (e.g. claude-science) from the board
  porthole unignore <port|command>   undo ignore
  porthole ignored                   show the ignore list (~/.porthole/config.json)
  porthole open-editor <port> [dir]  open the server's checkout in your editor (config: "editor")
  porthole open-terminal <port> [dir] open a terminal in the server's checkout (config: "terminal")
  porthole edit [config|labels]      open ~/.porthole/config.json or servers.json in your editor
  porthole swiftbar                  SwiftBar plugin output (one shot)
  porthole stream                    SwiftBar streamable plugin: live menu, re-rendered on change
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
    const loc = e.docker ? `docker · ${dockerWhere(e.docker)}` : where2(e.branch, e.repo) || e.command;
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

/** Folder for "Open in …": the git checkout root (or compose project dir for Docker). */
function openFolder(port, kind, dir) {
  // The menu passes the folder it already knows, so a click doesn't rerun the full scan.
  if (!dir) {
    const l = findLive(port);
    if (!l) die(`Nothing listening on ${port}.`);
    if (!l.root) die(`No folder known for :${port}.`);
    dir = l.root;
  }
  const app = pickApps(loadConfig())[kind];
  if (!app) die(`No ${kind} found. Set "${kind}" in ~/.porthole/config.json, e.g. "${kind === 'editor' ? 'Visual Studio Code' : 'Terminal'}".`);
  openIn(app, dir);
}

/** ctx for render(): paths for menu actions, settings, and which apps "Open in …" uses. */
function renderCtx() {
  const config = loadConfig();
  return {
    node: process.execPath,
    cli: CLI_PATH,
    config,
    portMin: PORT_MIN,
    portMax: PORT_MAX,
    version: PKG.version,
    repoUrl: REPO_URL,
    root: ROOT,
    ...pickApps(config),
  };
}

function copy(port) {
  execFileSync('/usr/bin/pbcopy', { input: `http://localhost:${port}` });
}

function kill(port) {
  const l = findLive(port);
  if (!l) die(`Nothing listening on ${port}.`);
  if (l.docker) return stopContainer(port, l);
  for (const pid of l.pids) {
    try {
      process.kill(pid, 'SIGTERM');
    } catch (err) {
      console.error(`Could not kill ${pid}: ${err.message}`);
    }
  }
  console.log(`Sent SIGTERM to ${l.pids.join(', ')} (${l.command}) on :${port}`);
}

/** Docker ports: `docker stop` just the publishing container (killing the PID would kill Docker itself). */
function stopContainer(port, l) {
  const name = l.docker.container;
  if (!name) die(`Port ${port} is published by Docker but its container couldn't be identified (is \`docker ps\` working?).`);
  try {
    execFileSync('docker', ['stop', name], { encoding: 'utf8', timeout: 60000, stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (err) {
    die(`Could not stop container ${name}: ${(err.stderr || err.message).trim()}`);
  }
  console.log(`Stopped container ${name} on :${port}`);
}

/**
 * Native macOS dialog via osascript. Values go in as argv, never interpolated into the script.
 * @returns {{button:string, text:string}|null} null when the user cancels.
 */
function dialog({ message, defaultAnswer, buttons = ['Cancel', 'OK'], defaultButton = 'OK', cancelButton = 'Cancel', icon = 'note' }) {
  const withAnswer = defaultAnswer !== undefined;
  const script = `on run argv
  set btns to {}
  repeat with i from 4 to count of argv
    set end of btns to item i of argv
  end repeat
  ${withAnswer ? 'set r to display dialog (item 1 of argv) default answer (item 2 of argv)' : 'set r to display dialog (item 1 of argv)'} with title "Porthole" buttons btns default button (item 3 of argv) cancel button "${cancelButton}" with icon ${icon}
  if ${withAnswer} then
    return (button returned of r) & linefeed & (text returned of r)
  else
    return button returned of r
  end if
end run`;
  const r = spawnSync('/usr/bin/osascript', ['-e', script, message, defaultAnswer ?? '', defaultButton, ...buttons], {
    encoding: 'utf8',
  });
  if (r.status !== 0) return null; // Cancel → osascript error -128
  const [button, ...rest] = r.stdout.replace(/\n$/, '').split('\n');
  return { button, text: rest.join('\n') };
}

/** Menu action: ask for a label in a native dialog. Empty → remove the label. */
async function promptLabel(port) {
  const rec = store.load()[String(port)];
  const l = findLive(port);
  const stale = rec && rec.cwd && l?.cwd && rec.cwd !== l.cwd;
  const current = rec && !stale ? rec.title : '';
  const r = dialog({
    message: `Label for :${port}${l ? `\n${describeLive(l)}` : ''}\n\nLeave empty to remove the label.`,
    defaultAnswer: current,
  });
  if (!r) return;
  const title = r.text.trim();
  if (!title) return void remove(port);
  if (current) updateLabel({ port, title });
  else await register({ port, title, waitMs: 0 });
}

/** Menu action: confirm before killing. */
function confirmKill(port) {
  const l = findLive(port);
  if (!l) die(`Nothing listening on ${port}.`);
  const rec = store.load()[String(port)];
  const what = rec?.title ? `"${rec.title}" — ` : '';
  const container = l.docker && l.docker.container;
  if (l.docker && !container) die(`Port ${port} is published by Docker but its container couldn't be identified.`);
  const verb = container ? 'Stop' : 'Kill';
  const r = dialog({
    message: container
      ? `Stop ${what}${describeLive(l)} on :${port}?\nRuns: docker stop ${container}`
      : `Kill ${what}${describeLive(l)} on :${port}?\nPID ${l.pids.join(', ')}`,
    buttons: ['Cancel', verb],
    defaultButton: 'Cancel',
    icon: 'caution',
  });
  if (r?.button === verb) kill(port);
}

async function main() {
  const [cmd, ...args] = process.argv.slice(2);
  switch (cmd) {
    case 'list':
    case undefined:
      return list();
    case 'swiftbar':
      return process.stdout.write(render(getBoard(), renderCtx()));
    case 'stream': {
      const { runStream } = await import('./stream.js');
      return runStream({ renderCtx });
    }
    case 'open-editor':
      return openFolder(needPort(args[0]), 'editor', args[1]);
    case 'open-terminal':
      return openFolder(needPort(args[0]), 'terminal', args[1]);
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
    case 'confirm-kill':
      return confirmKill(needPort(args[0]));
    case 'prompt-label':
      return promptLabel(needPort(args[0]));
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
