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

function where(e) {
  if (e.docker) return 'docker';
  return where2(e.branch, e.repo) || e.command || '';
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

function entryLines(e, ctx) {
  const lines = [];
  const port = `:${e.port}`;
  const loc = where(e);
  const label = e.status === 'labeled' ? truncate(e.title, 48) : loc || 'unlabeled';
  const style = e.status === 'labeled' ? '' : ' color=gray';
  lines.push(`${port}  ${label} | ${action(ctx, 'open', e.port)}${style}`);
  lines.push(`${port}  Copy ${e.url} | ${action(ctx, 'copy', e.port)} alternate=true`);

  const sub = e.status === 'labeled' ? loc : e.status === 'stale' ? `unlabeled (old label: ${truncate(e.staleTitle, 30)})` : `unlabeled · ${e.command}`;
  lines.push(`    ${truncate(sub, 60)} | size=11 color=gray`);
  if (e.status === 'labeled' && e.description) {
    // Wrap long descriptions across a few submenu lines.
    const words = clean(e.description).split(/\s+/);
    let cur = '';
    for (const w of words) {
      if ((cur + ' ' + w).trim().length > 60) {
        lines.push(`--${cur.trim()} | color=gray`);
        cur = '';
      }
      cur += ' ' + w;
    }
    if (cur.trim()) lines.push(`--${cur.trim()} | color=gray`);
    lines.push('-----');
  }
  if (e.cwd) lines.push(`--${truncate(e.cwd, 70)} | size=11 color=gray`);
  lines.push(`--PID ${e.pids.join(', ')} · ${clean(e.command)} | size=11 color=gray`);
  lines.push('-----');
  lines.push(`--Open ${e.url} | ${action(ctx, 'open', e.port)}`);
  lines.push(`--Copy URL | ${action(ctx, 'copy', e.port)}`);
  if (!e.docker) lines.push(`--Kill server | ${action(ctx, 'kill', e.port, ' refresh=true')} sfimage=xmark.octagon`);
  if (e.status !== 'unlabeled') lines.push(`--Remove label | ${action(ctx, 'remove', e.port, ' refresh=true')}`);
  lines.push(`--Hide this port | ${action(ctx, 'ignore', e.port, ' refresh=true')} sfimage=eye.slash`);
  return lines;
}

export function render(entries, ctx) {
  // Docker-published ports go in their own submenu unless someone labeled them.
  const main = entries.filter((e) => !e.docker || e.status === 'labeled');
  const docker = entries.filter((e) => e.docker && e.status !== 'labeled');

  const out = [];
  out.push(main.length ? `${main.length} | ${iconParam}` : ` | ${iconParam}`);
  out.push('---');
  if (!main.length) out.push('No dev servers running | color=gray');
  for (const e of main) out.push(...entryLines(e, ctx));

  if (docker.length) {
    out.push('---');
    out.push(`Docker (${docker.length}) | color=gray`);
    for (const e of docker) {
      out.push(`--:${e.port}  open | ${action(ctx, 'open', e.port)}`);
      out.push(`--:${e.port}  Copy ${e.url} | ${action(ctx, 'copy', e.port)} alternate=true`);
    }
  }
  out.push('---');
  out.push(...settingsLines(ctx));
  out.push(...aboutLines(ctx));
  out.push('Refresh | refresh=true sfimage=arrow.clockwise');
  return out.join('\n') + '\n';
}

function settingsLines(ctx) {
  const cfg = ctx.config || { ignorePorts: [], ignoreCommands: [] };
  const lines = ['Settings | sfimage=gearshape'];
  lines.push('--Hidden ports | size=11 color=gray');
  if (!cfg.ignorePorts.length) lines.push('--   none | color=gray');
  for (const p of [...cfg.ignorePorts].sort((a, b) => a - b)) {
    lines.push(`--:${p}  — click to show again | ${action(ctx, 'unignore', p, ' refresh=true')} sfimage=eye.slash`);
  }
  lines.push('--Hidden processes | size=11 color=gray');
  if (!cfg.ignoreCommands.length) lines.push('--   none | color=gray');
  for (const c of cfg.ignoreCommands) {
    lines.push(`--${clean(c)}  — click to show again | ${action(ctx, 'unignore', c, ' refresh=true')} sfimage=eye.slash`);
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
