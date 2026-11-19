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
export function load() {
  try {
    const data = JSON.parse(fs.readFileSync(storePath(), 'utf8'));
    return data && typeof data === 'object' && data.servers ? data.servers : {};
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

/** Read-modify-write helper. `fn` mutates (or returns) the servers object. */
export function update(fn) {
  const servers = load();
  const result = fn(servers);
  save(result && typeof result === 'object' ? result : servers);
  return result;
}
