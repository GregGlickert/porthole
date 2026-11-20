// Live detection of listening dev servers via lsof, plus cwd → git branch lookup.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { loadConfig } from './store.js';

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

// Absolute path: MCP clients and SwiftBar often launch us with a PATH that lacks /usr/sbin.
const LSOF = '/usr/sbin/lsof';

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

/** `config` is the user's ~/.porthole/config.json (see store.loadConfig); defaults apply when omitted. */
export function isDevCandidate({ command, port }, config = {}) {
  const min = config.portMin ?? PORT_MIN;
  const max = config.portMax ?? PORT_MAX;
  return (
    port >= min &&
    port <= max &&
    !IGNORE_PORTS.has(port) &&
    !IGNORE_COMMANDS.has(command) &&
    !(config.ignorePorts || []).includes(port) &&
    !(config.ignoreCommands || []).includes(command)
  );
}

/** Parse `ps -o pid=,etime=` output into Map<pid, seconds>. etime is [[dd-]hh:]mm:ss. */
export function parsePsEtime(text) {
  const map = new Map();
  for (const line of text.split('\n')) {
    const m = line.trim().match(/^(\d+)\s+(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)$/);
    if (!m) continue;
    const [, pid, d = 0, h = 0, mi, s] = m;
    map.set(Number(pid), ((Number(d) * 24 + Number(h)) * 60 + Number(mi)) * 60 + Number(s));
  }
  return map;
}

const DOCKER_FORMAT =
  '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.service"}}' +
  '\t{{.Label "com.docker.compose.project.working_dir"}}';

/**
 * Parse `docker ps --format DOCKER_FORMAT` output into Map<hostPort, container info>.
 * Ports look like `0.0.0.0:8080->8080/tcp, [::]:8080->8080/tcp` or ranges `0.0.0.0:8000-8001->8000-8001/tcp`.
 */
export function parseDockerPs(text) {
  const map = new Map();
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    const [id, container, image, ports = '', project = '', service = '', workingDir = ''] = line.split('\t');
    for (const part of ports.split(',')) {
      const m = part.trim().match(/:(\d+)(?:-(\d+))?->(\d+)(?:-\d+)?\/tcp$/);
      if (!m) continue;
      const lo = Number(m[1]);
      const hi = m[2] ? Number(m[2]) : lo;
      for (let p = lo; p <= hi; p++) {
        if (map.has(p)) continue;
        map.set(p, {
          id,
          container,
          image,
          project: project || null,
          service: service || null,
          workingDir: workingDir || null,
          containerPort: Number(m[3]) + (p - lo),
        });
      }
    }
  }
  return map;
}

/** Parse `docker inspect -f '{{.Id}}\t{{.State.StartedAt}}'` into Map<shortId, startedAt ms>. */
export function parseDockerStarted(text) {
  const map = new Map();
  for (const line of text.split('\n')) {
    const [id, started] = line.trim().split('\t');
    const t = Date.parse(started);
    if (id && Number.isFinite(t)) map.set(id.slice(0, 12), t);
  }
  return map;
}

/** Container info per published host port; empty map if docker is missing or not running. */
export function dockerPorts(now = Date.now()) {
  const ports = parseDockerPs(run('docker', ['ps', '--format', DOCKER_FORMAT]));
  const ids = [...new Set([...ports.values()].map((c) => c.id))];
  if (ids.length) {
    const started = parseDockerStarted(run('docker', ['inspect', '-f', '{{.Id}}\t{{.State.StartedAt}}', ...ids]));
    for (const c of ports.values()) {
      const t = started.get(c.id.slice(0, 12));
      c.uptimeSec = t ? Math.max(0, Math.round((now - t) / 1000)) : null;
    }
  }
  return ports;
}

export function gitInfo(cwd) {
  if (!cwd || cwd === '/') return { branch: null, repo: null, root: null };
  const out = run('git', ['-C', cwd, 'rev-parse', '--abbrev-ref', 'HEAD', '--show-toplevel']).trim().split('\n');
  if (out.length < 2 || !out[0]) return { branch: null, repo: path.basename(cwd), root: null };
  let branch = out[0];
  if (branch === 'HEAD') {
    const sha = run('git', ['-C', cwd, 'rev-parse', '--short', 'HEAD']).trim();
    branch = sha ? `detached@${sha}` : 'detached';
  }
  return { branch, repo: path.basename(out[1]), root: out[1] };
}

/**
 * Parse `netstat -anv -p tcp` LISTEN rows into unique {pid, command, port}. ~25× cheaper than lsof, so the
 * live menu polls this and only runs the full scan() when the result changes.
 * Local address is `127.0.0.1.3000`, `*.3000` or `::1.3000`; the process column is `name:pid` (name cut to 16 chars, may contain spaces).
 */
export function parseNetstatListen(text) {
  const out = [];
  const seen = new Set();
  for (const line of text.split('\n')) {
    const m = line.match(/^tcp\S*\s+\d+\s+\d+\s+(\S+)\s+\S+\s+LISTEN\s+\d+\s+\d+\s+\d+\s+\d+\s+(.+?):(\d+)\s/);
    if (!m) continue;
    const port = Number(m[1].slice(m[1].lastIndexOf('.') + 1));
    const pid = Number(m[3]);
    if (!Number.isInteger(port)) continue;
    const key = `${pid}:${port}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push({ pid, command: m[2].trim(), port });
  }
  return out;
}

/** Cheap change detector: sorted "pid:port" of dev-range listeners. Falls back to lsof if netstat's format isn't recognized. */
export function listenFingerprint(config = loadConfig()) {
  const text = run('/usr/sbin/netstat', ['-anv', '-p', 'tcp']);
  let rows = parseNetstatListen(text);
  if (!rows.length && /LISTEN/.test(text)) rows = parseLsofListen(run(LSOF, ['-nP', '-iTCP', '-sTCP:LISTEN', '-F', 'pcn']));
  const inRange = (port) => isDevCandidate({ port, command: '' }, { ...config, ignoreCommands: [] });
  return rows
    .filter((r) => inRange(r.port))
    .map((r) => `${r.pid}:${r.port}`)
    .sort()
    .join(',');
}

/** Pure: branch name from a .git/HEAD file's text, in the same form gitInfo() reports ("detached@<sha7>" when detached). */
export function parseHead(text) {
  const t = String(text || '').trim();
  const m = t.match(/^ref:\s*refs\/heads\/(.+)$/);
  if (m) return m[1];
  return /^[0-9a-f]{7,}$/.test(t) ? `detached@${t.slice(0, 7)}` : null;
}

/**
 * Current branch of the checkout at `root` by reading .git/HEAD directly (no git process), or null if unknown.
 * Worktrees have a `.git` file pointing at their gitdir.
 */
export function headBranch(root) {
  if (!root) return null;
  try {
    let gitDir = path.join(root, '.git');
    if (fs.statSync(gitDir).isFile()) {
      const m = fs.readFileSync(gitDir, 'utf8').match(/^gitdir:\s*(.+)$/m);
      if (!m) return null;
      gitDir = path.resolve(root, m[1].trim());
    }
    return parseHead(fs.readFileSync(path.join(gitDir, 'HEAD'), 'utf8'));
  } catch {
    return null;
  }
}

/** Every TCP port anything is listening on (no dev-range filtering). */
export function listeningPorts() {
  return new Set(parseLsofListen(run(LSOF, ['-nP', '-iTCP', '-sTCP:LISTEN', '-F', 'pcn'])).map((e) => e.port));
}

/**
 * All listening dev-range ports, grouped by port.
 * `docker` is false, or {container, image, project, service, containerPort} (`{}` if `docker ps` was unavailable).
 * @returns {Array<{port:number,pids:number[],command:string,cwd:string|null,branch:string|null,repo:string|null,docker:false|object,uptimeSec:number|null}>}
 */
export function scan(config = loadConfig()) {
  const raw = parseLsofListen(run(LSOF, ['-nP', '-iTCP', '-sTCP:LISTEN', '-F', 'pcn'])).filter((e) =>
    isDevCandidate(e, config),
  );
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
    ? parseLsofCwd(run(LSOF, ['-a', '-p', nonDockerPids.join(','), '-d', 'cwd', '-Fpn']))
    : new Map();
  const etimes = nonDockerPids.length ? parsePsEtime(run('ps', ['-o', 'pid=,etime=', '-p', nonDockerPids.join(',')])) : new Map();
  const containers = [...byPort.values()].some((s) => s.docker) ? dockerPorts() : new Map();
  const gitCache = new Map();
  return [...byPort.values()]
    .map((s) => {
      if (s.docker) {
        const c = containers.get(s.port);
        const { uptimeSec = null, id, ...info } = c || {};
        return { ...s, docker: info, cwd: null, root: info.workingDir || null, branch: null, repo: c?.project || null, uptimeSec };
      }
      const cwd = cwds.get(s.pids[0]) ?? null;
      if (cwd && !gitCache.has(cwd)) gitCache.set(cwd, gitInfo(cwd));
      const { branch, repo, root } = cwd ? gitCache.get(cwd) : { branch: null, repo: null, root: null };
      return { ...s, cwd, root: root || (cwd && cwd !== '/' ? cwd : null), branch, repo, uptimeSec: etimes.get(s.pids[0]) ?? null };
    })
    .sort((a, b) => a.port - b.port);
}
