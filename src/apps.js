// Which editor / terminal "Open in …" uses: config.json `editor` / `terminal`, else the first one installed.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

export const EDITORS = ['Cursor', 'Visual Studio Code', 'Zed', 'Windsurf', 'Sublime Text'];
export const TERMINALS = ['Ghostty', 'iTerm', 'Warp', 'Terminal'];

const APP_DIRS = ['/Applications', path.join(os.homedir(), 'Applications'), '/System/Applications/Utilities'];

export function installed(name) {
  return APP_DIRS.some((d) => fs.existsSync(path.join(d, `${name}.app`)));
}

/** @returns {{editor: string|null, terminal: string|null}} */
export function pickApps(config = {}, isInstalled = installed) {
  return {
    editor: config.editor || EDITORS.find(isInstalled) || null,
    terminal: config.terminal || TERMINALS.find(isInstalled) || null,
  };
}

/**
 * Open `dir` in `app`. Editors and terminals (Ghostty, iTerm, Terminal, Warp) all accept a folder this way and open it
 * in the running instance. Don't launch a second instance with `open -n`: Ghostty's exits right away.
 */
export function openIn(app, dir) {
  const r = spawnSync('/usr/bin/open', ['-a', app, dir], { stdio: 'ignore' });
  if (r.status !== 0) throw new Error(`Couldn't open ${dir} in ${app}.`);
}
