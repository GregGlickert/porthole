// Persistent label store: ~/.porthole/servers.json, keyed by port.
// Shared by every MCP process, the CLI, and the SwiftBar plugin, so writes are atomic.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export function homeDir() {
  return process.env.PORTHOLE_HOME || path.join(os.homedir(), '.porthole');
}

function storePath() {
  return path.join(homeDir(), 'servers.json');
}

/** @returns {Record<string, {port:number,title:string,description?:string,cwd?:string|null,branch?:string|null,registeredAt:string,lastSeenAt?:string}>} */
/** Keep only well-formed records (a hand edit can leave `"3000": null` or a string). */
function sane(servers) {
  if (!servers || typeof servers !== 'object') return {};
  return Object.fromEntries(Object.entries(servers).filter(([k, v]) => /^\d+$/.test(k) && v && typeof v === 'object'));
}

export function load() {
  try {
    return sane(JSON.parse(fs.readFileSync(storePath(), 'utf8'))?.servers);
  } catch {
    return {};
  }
}

export function save(servers) {
  const dir = homeDir();
  fs.mkdirSync(dir, { recursive: true });
  const tmp = path.join(dir, `.servers.${process.pid}.${Date.now()}.tmp`);
  fs.writeFileSync(tmp, JSON.stringify({ version: 1, servers }, null, 2) + '\n');
  fs.renameSync(tmp, storePath());
}

// ---- User config: ~/.porthole/config.json ----
// { "ignorePorts": [8000], "ignoreCommands": ["claude-science"], "portMin": 3000, "portMax": 9999 }
function configPath() {
  return path.join(homeDir(), 'config.json');
}

export function loadConfig() {
  let c = {};
  try {
    c = JSON.parse(fs.readFileSync(configPath(), 'utf8')) || {};
  } catch {
    /* missing or invalid → defaults */
  }
  return {
    ignorePorts: Array.isArray(c.ignorePorts) ? c.ignorePorts.map(Number).filter(Number.isInteger) : [],
    ignoreCommands: Array.isArray(c.ignoreCommands) ? c.ignoreCommands.map(String) : [],
    portMin: Number.isInteger(c.portMin) ? c.portMin : undefined,
    portMax: Number.isInteger(c.portMax) ? c.portMax : undefined,
    editor: typeof c.editor === 'string' && c.editor.trim() ? c.editor.trim() : undefined,
    terminal: typeof c.terminal === 'string' && c.terminal.trim() ? c.terminal.trim() : undefined,
    browser: typeof c.browser === 'string' && c.browser.trim() ? c.browser.trim() : undefined,
  };
}

export function saveConfig(config) {
  const dir = homeDir();
  fs.mkdirSync(dir, { recursive: true });
  const clean = Object.fromEntries(Object.entries(config).filter(([, v]) => v !== undefined));
  const tmp = path.join(dir, `.config.${process.pid}.${Date.now()}.tmp`);
  fs.writeFileSync(tmp, JSON.stringify(clean, null, 2) + '\n');
  fs.renameSync(tmp, configPath());
}

/** Like load(), but throws if servers.json exists and isn't valid JSON, so a writer never saves over it. */
function loadForWrite() {
  let text;
  try {
    text = fs.readFileSync(storePath(), 'utf8');
  } catch (err) {
    if (err.code === 'ENOENT') return {};
    throw err;
  }
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    throw new Error(`${storePath()} isn't valid JSON; fix or delete it (porthole edit labels). Not overwriting it.`);
  }
  return sane(data?.servers);
}

/**
 * Read-modify-write helper. `fn` mutates (or returns) the servers object; returning `false` skips the save.
 * Refuses to run if the file is unreadable JSON (e.g. a typo from a hand edit), instead of replacing it with {}.
 */
export function update(fn) {
  const servers = loadForWrite();
  const result = fn(servers);
  if (result === false) return result;
  save(result && typeof result === 'object' ? result : servers);
  return result;
}

// ---- Port reservations: ~/.porthole/reserved/<port> ----
// suggest_free_port reserves what it hands out so two agents can't get the same port before either server listens.
// One file per port created with O_EXCL ('wx'), so the OS settles races between MCP processes.
export const RESERVE_TTL_MS = 2 * 60 * 1000;

function reservedDir() {
  return path.join(homeDir(), 'reserved');
}

/** Try to reserve `port`. Returns false if someone else holds a live reservation. */
export function reserve(port, now = Date.now()) {
  const dir = reservedDir();
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, String(port));
  const body = JSON.stringify({ port, pid: process.pid, at: new Date(now).toISOString() }) + '\n';
  try {
    fs.writeFileSync(file, body, { flag: 'wx' });
    return true;
  } catch (err) {
    if (err.code !== 'EEXIST') throw err;
  }
  // Expired? Take it over. Move the stale file aside first: rename is atomic, so if two callers both see it
  // expired, only one moves it; the other gets ENOENT and gives up instead of deleting the winner's fresh file.
  try {
    if (now - fs.statSync(file).mtimeMs <= RESERVE_TTL_MS) return false;
    const aside = `${file}.stale.${process.pid}.${Date.now()}`;
    fs.renameSync(file, aside);
    fs.rmSync(aside, { force: true });
  } catch {
    return false; // someone else took it over (or released it) just now; try another port
  }
  try {
    fs.writeFileSync(file, body, { flag: 'wx' });
    return true;
  } catch {
    return false;
  }
}

export function release(port) {
  try {
    fs.unlinkSync(path.join(reservedDir(), String(port)));
  } catch {
    /* not reserved */
  }
}

/** Ports with a live reservation (expired files are cleaned up). */
export function activeReservations(now = Date.now()) {
  const out = new Set();
  let names = [];
  try {
    names = fs.readdirSync(reservedDir());
  } catch {
    return out;
  }
  for (const name of names) {
    if (!/^\d+$/.test(name)) continue;
    const file = path.join(reservedDir(), name);
    try {
      if (now - fs.statSync(file).mtimeMs <= RESERVE_TTL_MS) out.add(Number(name));
      else fs.unlinkSync(file);
    } catch {
      /* raced with another cleanup */
    }
  }
  return out;
}
