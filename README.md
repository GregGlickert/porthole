# Portboard

Which feature is running on which localhost port — in your macOS menu bar, labeled by Claude.

```
⚡3
:3001  Upload retry flow          ← click: open in Chrome · ⌥-click: copy URL
    feat/upload · myapp ▸         ← submenu: description, cwd, PID, Open, Copy, Kill, Remove label
:3002  New OAuth login
    feat/auth ▸
:3003  fix/css                    ← gray = running but nobody labeled it yet
    unlabeled · node ▸
Docker (4) ▸
Refresh
```

- **MCP server** (`src/mcp.js`) — Claude calls `register_server(port, title, description?)` after starting a dev server. Branch and folder are detected automatically. Also `update_server`, `remove_server`, `list_servers`.
- **SwiftBar plugin** — refreshes every 5s. Shows every listening port in 3000–9999 (system processes and DB ports filtered), with git branch, even if unregistered.
- **No daemon** — labels live in `~/.portboard/servers.json`; live state comes from `lsof` each refresh.
- **Stale labels** — if a different checkout starts listening on a labeled port, the old label is ignored (shown as "old label: …"). Labels for ports that stay dead 24h are pruned.
- **Docker-published ports** go in a separate submenu and can't be killed from the menu (that would kill Docker).

## Install

```bash
brew install --cask swiftbar          # launch it once and pick a plugin folder
./scripts/install.sh                  # npm install + installs the SwiftBar plugin
claude mcp add portboard -s user -- "$(command -v node)" "$PWD/src/mcp.js"
```

Then add to `~/.claude/CLAUDE.md`:

> When you start a local dev server (or the user tells you one is running), call the portboard `register_server` tool with its port and a ≤8-word title describing the feature/branch being tested. Update or remove it when that changes.

The plugin and MCP command pin the absolute node path. If you remove that node version (e.g. via nvm), rerun `install.sh` and the `claude mcp add` command.

## CLI

```
portboard list | register <port> <title> [desc] | remove <port> | open <port> | copy <port> | kill <port> | swiftbar
```
(`node src/cli.js …`, or `npm link` to get `portboard` on your PATH.)

## Config (env vars)

`PORTBOARD_HOME` (default `~/.portboard`), `PORTBOARD_PORT_MIN` / `PORTBOARD_PORT_MAX` (default 3000–9999).

## Tests

`npm test`
