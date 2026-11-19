// Render the board as SwiftBar plugin output. Pure: (entries, {node, cli}) -> string.
// Format reference: https://github.com/swiftbar/SwiftBar#plugin-api

import fs from 'node:fs';

// Menu bar icon (template image: macOS tints it for light/dark). Regenerate with scripts/make-icon.swift.
let ICON = '';
try {
  ICON = fs.readFileSync(new URL('../assets/porthole-icon.png', import.meta.url)).toString('base64');
} catch {
  /* fall back to an SF Symbol */
}
const iconParam = ICON ? `templateImage=${ICON}` : 'sfimage=circle.circle';

const clean = (s) => String(s ?? '').replace(/\s*[|\n\r]+\s*/g, ' / ').trim();
const q = (s) => `"${String(s).replace(/"/g, '\\"')}"`;

function action({ node, cli }, verb, arg, extra = '') {
  const a3 = arg === undefined ? '' : ` param3=${q(arg)}`;
  return `bash=${q(node)} param1=${q(cli)} param2=${verb}${a3} terminal=false${extra}`;
}

/** One-line human description of a live server for dialogs: "balance · frontend (container balance-frontend-1)" or "feat/x · app (node)". */
export function describeLive(l) {
  if (!l) return '';
  if (l.docker) return l.docker.container ? `${dockerWhere(l.docker)} (container ${clean(l.docker.container)})` : 'Docker';
  const loc = where2(l.branch, l.repo);
  return loc ? `${loc} (${clean(l.command)})` : clean(l.command);
}

function where(e) {
  if (e.docker) return dockerWhere(e.docker);
  return where2(e.branch, e.repo) || e.command || '';
}

/** "project · service" for compose containers, else the container name. */
export function dockerWhere(d) {
  if (!d || (!d.container && !d.project)) return 'docker';
  if (d.project && d.service) return `${d.project} · ${d.service}`;
  return d.container || d.project;
}

/** "branch · folder", dropping the folder when the branch name already contains it (common with worktrees). */
export function where2(branch, repo) {
  if (branch && repo && branch.includes(repo)) return branch;
  return [branch, repo].filter(Boolean).join(' · ');
}

function truncate(s, n) {
  s = clean(s);
  return s.length > n ? s.slice(0, n - 1) + '…' : s;
}

/** 90 → "1m", 7380 → "2h 3m", 200000 → "2d 7h". */
export function humanAge(sec) {
  if (sec == null || !Number.isFinite(sec) || sec < 0) return null;
  const m = Math.floor(sec / 60);
  const h = Math.floor(m / 60);
  const d = Math.floor(h / 24);
  if (d) return h % 24 ? `${d}d ${h % 24}h` : `${d}d`;
  if (h) return m % 60 ? `${h}h ${m % 60}m` : `${h}h`;
  return `${Math.max(1, m)}m`;
}

/**
 * Wrap text into lines of at most `width` chars: keep sentences together when they fit,
 * otherwise break on words. Never leaves a final line of one short word.
 */
export function wrap(text, width = 60) {
  const sentences = clean(text).split(/(?<=[.!?])\s+/).filter(Boolean);
  const lines = [];
  let cur = '';
  const push = () => {
    if (cur) lines.push(cur);
    cur = '';
  };
  for (const sentence of sentences) {
    if (cur && (cur + ' ' + sentence).length <= width) {
      cur += ' ' + sentence;
      continue;
    }
    push();
    for (const w of sentence.split(/\s+/)) {
      if (cur && (cur + ' ' + w).length > width) push();
      cur = cur ? cur + ' ' + w : w;
    }
  }
  push();
  // Orphan control: pull a lone short word back onto the previous line.
  if (lines.length > 1) {
    const last = lines[lines.length - 1];
    if (!last.includes(' ') && last.length <= 12) lines.splice(-2, 2, lines[lines.length - 2] + ' ' + last);
  }
  return lines;
}

// Fixed-width port column in the normal menu font. The system font's digits are proportional
// (":3001" is ~2pt narrower than ":3000"), and SwiftBar can't select its monospaced-digit variant
// (`font=` only takes names) and its tab stops are a fixed 100pt apart (too wide). So we pad each
// port with thin/hair spaces up to the width of the widest number with that many digits.
// Advance widths of the macOS menu font (SF, 13pt) in ems; kerning between these is negligible.
const EM = {
  0: 0.624, 1: 0.458, 2: 0.598, 3: 0.621, 4: 0.638, 5: 0.612, 6: 0.631, 7: 0.563, 8: 0.633, 9: 0.631,
  ':': 0.291,
};
// Spaces narrower than a regular space, in ems; mixing them gets the padding within ~0.1pt.
const SPACES = [
  { ch: '\u2009', em: 0.135 }, // thin space
  { ch: '\u2006', em: 0.16 }, // six-per-em space
  { ch: '\u200A', em: 0.064 }, // hair space
];
const WIDEST_DIGIT = Math.max(...Object.values(EM).slice(0, 10));

/** Fewest-error mix of thin/six-per-em/hair spaces that adds up to `gap` ems. */
function padding(gap) {
  const [thin, six, hair] = SPACES;
  let best = { err: Infinity, str: '' };
  for (let t = 0; t * thin.em <= gap + hair.em; t++) {
    for (let s = 0; s <= 3; s++) {
      for (let h = 0; h <= 3; h++) {
        const err = Math.abs(gap - (t * thin.em + s * six.em + h * hair.em));
        if (err < best.err - 1e-9) best = { err, str: thin.ch.repeat(t) + six.ch.repeat(s) + hair.ch.repeat(h) };
      }
    }
  }
  return best.str;
}

export function portLabel(port, digits = 4) {
  const text = `:${port}`;
  const width = [...text].reduce((w, c) => w + (EM[c] ?? WIDEST_DIGIT), 0);
  const gap = Math.max(0, EM[':'] + Math.max(digits, String(port).length) * WIDEST_DIGIT - width);
  return text + padding(gap);
}

function entryLines(e, ctx, portWidth = 4) {
  const lines = [];
  const port = portLabel(e.port, portWidth);
  const loc = where(e);
  const label = e.status === 'labeled' ? truncate(e.title, 48) : loc || 'unlabeled';
  // One row per port; everything else (where it runs, actions) lives in its submenu.
  lines.push(`${port}  ${label}`);

  const sub =
    e.status === 'labeled'
      ? loc
      : e.status === 'stale'
        ? `unlabeled (old label: ${truncate(e.staleTitle, 30)})`
        : `unlabeled · ${e.docker ? e.docker.image || 'docker' : e.command}`;
  if (sub) lines.push(`--${truncate(sub, 60)} | size=11 color=gray`);
  if (e.status === 'labeled' && e.description) {
    for (const l of wrap(e.description, 60)) lines.push(`--${l} | color=gray`);
    lines.push('-----');
  }

  const ages = [];
  const up = humanAge(e.uptimeSec);
  if (up) ages.push(`up ${up}`);
  const labeledAgo = e.status === 'labeled' && e.registeredAt ? humanAge((Date.now() - Date.parse(e.registeredAt)) / 1000) : null;
  if (labeledAgo) ages.push(`labeled ${labeledAgo} ago`);
  if (ages.length) lines.push(`--${ages.join(' · ')} | size=11 color=gray sfimage=clock`);
  if (e.cwd && e.cwd !== '/') lines.push(`--${truncate(e.cwd, 70)} | size=11 color=gray`);
  if (e.docker && e.docker.container) {
    const cport = e.docker.containerPort && e.docker.containerPort !== e.port ? ` → :${e.docker.containerPort}` : '';
    lines.push(`--container ${clean(e.docker.container)}${cport} · image ${clean(e.docker.image)} | size=11 color=gray`);
  } else {
    lines.push(`--PID ${e.pids.join(', ')} · ${clean(e.command)} | size=11 color=gray`);
  }
  lines.push('-----');
  lines.push(`--Open ${e.url} | ${action(ctx, 'open', e.port)} sfimage=safari`);
  lines.push(`--Copy URL | ${action(ctx, 'copy', e.port)} sfimage=doc.on.doc`);
  if (e.status === 'labeled') lines.push(`--Rename… | ${action(ctx, 'prompt-label', e.port, ' refresh=true')} sfimage=pencil`);
  else lines.push(`--Label this port… | ${action(ctx, 'prompt-label', e.port, ' refresh=true')} sfimage=tag`);
  if (e.status !== 'unlabeled') lines.push(`--Remove label | ${action(ctx, 'remove', e.port, ' refresh=true')} sfimage=tag.slash`);
  lines.push(`--Hide this port | ${action(ctx, 'ignore', e.port, ' refresh=true')} sfimage=eye.slash`);
  if (!e.docker) {
    lines.push('-----');
    lines.push(`--Kill server… | ${action(ctx, 'confirm-kill', e.port, ' refresh=true')} sfimage=xmark.octagon`);
  } else if (e.docker.container) {
    // Never kill the PID for Docker ports (it's Docker itself); confirm-kill runs `docker stop <container>`.
    lines.push('-----');
    lines.push(`--Stop container… | ${action(ctx, 'confirm-kill', e.port, ' refresh=true')} sfimage=stop.circle`);
  }
  return lines;
}

export function render(entries, ctx) {
  // Docker-published ports are listed like any other port (named by compose project · service).
  const main = entries;

  const out = [];
  out.push(main.length ? `${main.length} | ${iconParam}` : ` | ${iconParam}`);
  out.push('---');
  if (!main.length) out.push('No dev servers running | color=gray');
  const portWidth = Math.max(4, ...main.map((e) => String(e.port).length));
  for (const e of main) out.push(...entryLines(e, ctx, portWidth));

  out.push('---');
  out.push(...settingsLines(ctx));
  out.push(...aboutLines(ctx));
  out.push('Refresh | refresh=true sfimage=arrow.clockwise');
  return out.join('\n') + '\n';
}

function settingsLines(ctx) {
  const cfg = ctx.config || { ignorePorts: [], ignoreCommands: [] };
  const lines = ['Settings | sfimage=gearshape'];
  if (!cfg.ignorePorts.length && !cfg.ignoreCommands.length) {
    lines.push('--Nothing hidden | color=gray');
  } else {
    if (cfg.ignorePorts.length) lines.push('--Hidden ports | size=11 color=gray');
    for (const p of [...cfg.ignorePorts].sort((a, b) => a - b)) {
      lines.push(`--:${p}  — click to show again | ${action(ctx, 'unignore', p, ' refresh=true')} sfimage=eye.slash`);
    }
    if (cfg.ignoreCommands.length) lines.push('--Hidden processes | size=11 color=gray');
    for (const c of cfg.ignoreCommands) {
      lines.push(`--${clean(c)}  — click to show again | ${action(ctx, 'unignore', c, ' refresh=true')} sfimage=eye.slash`);
    }
  }
  lines.push('-----');
  lines.push(`--Port range: ${cfg.portMin ?? ctx.portMin}–${cfg.portMax ?? ctx.portMax} | color=gray`);
  lines.push(`--Open config file… | ${action(ctx, 'edit', 'config')} sfimage=doc.text`);
  lines.push(`--Open labels file… | ${action(ctx, 'edit', 'labels')} sfimage=tag`);
  return lines;
}

function aboutLines(ctx) {
  const lines = ['About Porthole | sfimage=info.circle'];
  lines.push(`--Porthole ${ctx.version || ''} | color=gray`);
  lines.push('--Which feature is running on which localhost port. | size=11 color=gray');
  lines.push('-----');
  if (ctx.repoUrl) lines.push(`--View on GitHub | href=${ctx.repoUrl} sfimage=link`);
  if (ctx.root) lines.push(`--Open project folder | bash=/usr/bin/open param1=${q(ctx.root)} terminal=false sfimage=folder`);
  return lines;
}
