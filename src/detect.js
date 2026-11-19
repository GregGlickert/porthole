// Live detection of listening dev servers via lsof, plus cwd → git branch lookup.
import { execFileSync } from 'node:child_process';
import path from 'node:path';

export const PORT_MIN = Number(process.env.PORTHOLE_PORT_MIN || 3000);
export const PORT_MAX = Number(process.env.PORTHOLE_PORT_MAX || 9999);

// macOS/system processes that hold ports in the dev range but are never "your app".
export const IGNORE_COMMANDS = new Set([
  'ControlCenter', // AirPlay receiver on 5000/7000
  'rapportd',
  'sharingd',
  'identityservicesd',
  'launchd',
  'mDNSResponder',
]);

// Databases / caches that aren't web dev servers.
export const IGNORE_PORTS = new Set([3306, 5432, 6379, 9200, 9300]);

export const DOCKER_COMMANDS = new Set(['com.docker.backend', 'com.docker.vpnkit', 'vpnkit-bridge', 'docker-proxy']);

function run(cmd, args) {
  try {
    return execFileSync(cmd, args, { encoding: 'utf8', timeout: 4000, stdio: ['ignore', 'pipe', 'ignore'] });
  } catch (err) {
    // lsof exits 1 when nothing matches but may still print partial output.
    return typeof err?.stdout === 'string' ? err.stdout : '';
  }
}

/**
 * Parse `lsof -F pcn` output into unique {pid, command, port} entries.
 * Format: per process a `p<pid>` line and `c<command>` line, then per fd `f<fd>` and `n<addr>`.
 */
export function parseLsofListen(text) {
  const out = [];
  const seen = new Set();
  let pid = null;
  let command = null;
  for (const line of text.split('\n')) {
    if (!line) continue;
    const tag = line[0];
    const val = line.slice(1);
    if (tag === 'p') {
      pid = Number(val);
      command = null;
    } else if (tag === 'c') {
      command = val;
    } else if (tag === 'n' && pid != null) {
      const m = val.match(/:(\d+)$/);
      if (!m) continue;
      const port = Number(m[1]);
      const key = `${pid}:${port}`;
      if (seen.has(key)) continue; // IPv4 + IPv6 duplicates
      seen.add(key);
      out.push({ pid, command, port });
    }
  }
  return out;
}

/** Parse `lsof -a -p <pids> -d cwd -Fpn` output into Map<pid, cwd>. */
export function parseLsofCwd(text) {
  const map = new Map();
  let pid = null;
  for (const line of text.split('\n')) {
    if (line[0] === 'p') pid = Number(line.slice(1));
    else if (line[0] === 'n' && pid != null) map.set(pid, line.slice(1));
  }
  return map;
}

export function isDevCandidate({ command, port }) {
  return port >= PORT_MIN && port <= PORT_MAX && !IGNORE_PORTS.has(port) && !IGNORE_COMMANDS.has(command);
}

export function gitInfo(cwd) {
  if (!cwd || cwd === '/') return { branch: null, repo: null };
  const out = run('git', ['-C', cwd, 'rev-parse', '--abbrev-ref', 'HEAD', '--show-toplevel']).trim().split('\n');
  if (out.length < 2 || !out[0]) return { branch: null, repo: path.basename(cwd) };
  let branch = out[0];
  if (branch === 'HEAD') {
    const sha = run('git', ['-C', cwd, 'rev-parse', '--short', 'HEAD']).trim();
    branch = sha ? `detached@${sha}` : 'detached';
  }
  return { branch, repo: path.basename(out[1]) };
}

/**
 * All listening dev-range ports, grouped by port.
 * @returns {Array<{port:number,pids:number[],command:string,cwd:string|null,branch:string|null,repo:string|null,docker:boolean}>}
 */
export function scan() {
  const raw = parseLsofListen(run('lsof', ['-nP', '-iTCP', '-sTCP:LISTEN', '-F', 'pcn'])).filter(isDevCandidate);
  const byPort = new Map();
  for (const e of raw) {
    const cur = byPort.get(e.port);
    if (cur) {
      if (!cur.pids.includes(e.pid)) cur.pids.push(e.pid);
    } else {
      byPort.set(e.port, { port: e.port, pids: [e.pid], command: e.command, docker: DOCKER_COMMANDS.has(e.command) });
    }
  }
  const nonDockerPids = [...new Set([...byPort.values()].filter((s) => !s.docker).flatMap((s) => s.pids))];
  const cwds = nonDockerPids.length
    ? parseLsofCwd(run('lsof', ['-a', '-p', nonDockerPids.join(','), '-d', 'cwd', '-Fpn']))
    : new Map();
  const gitCache = new Map();
  return [...byPort.values()]
    .map((s) => {
      const cwd = s.docker ? null : cwds.get(s.pids[0]) ?? null;
      if (cwd && !gitCache.has(cwd)) gitCache.set(cwd, gitInfo(cwd));
      const { branch, repo } = cwd ? gitCache.get(cwd) : { branch: null, repo: null };
      return { ...s, cwd, branch, repo };
    })
    .sort((a, b) => a.port - b.port);
}
