# Porthole

Which feature is running on which localhost port — in your macOS menu bar, labeled by your coding agent (Claude Code, Codex, Cursor, or any MCP client).

```
◉3
:3001  Upload retry flow ▸        ← one row per port; click opens it in Chrome, hover for the submenu: branch · repo, description, uptime + label age,
                                     cwd/PID, Open, Copy URL, Rename…, Remove label, Hide, Kill server… (asks first)
:3003  fix/css · myapp ▸          ← running but nobody labeled it yet; submenu has "Label this port…"
:8080  Main API ▸                 ← Docker ports: submenu shows compose project · service, container and image,
                                     and Stop container… instead of Kill
Settings ▸                        ← hidden ports/processes (click to unhide), port range, open config/labels file
About Porthole ▸                  ← version, View on GitHub, open project folder
Refresh
```

- **MCP server** (`src/mcp.js`) — your agent calls `register_server(port, title, description?)` after starting a dev server. Branch and folder are detected automatically. Also `update_server`, `remove_server`, `list_servers` (optional `port` filter; includes uptime, checkout folder and Docker container info), and `suggest_free_port(preferred?, count?)`, which returns ports nothing is listening on and no label claims, and reserves them for 2 minutes so a parallel agent isn't handed the same port.
- **SwiftBar plugin** — a live menu: one background process checks listening ports every 5s with `netstat` (cheap) and only rescans when that list changes, so a server appears or disappears within ~5s. Label and setting changes show immediately. Shows every listening port in 3000–9999 (system processes and DB ports filtered), with git branch, even if unregistered.
- **Open in editor / terminal / Finder** from a port's submenu, at the checkout's git root (or the compose project folder for Docker).
- **No daemon to manage** — labels live in `~/.porthole/servers.json`; the menu's one background process is started and stopped by SwiftBar.
- **Stale labels** — if a different checkout starts listening on a labeled port, the old label is ignored (shown as "old label: …"). Labels for ports that stay dead 24h are pruned.
- **Docker-published ports** are listed like any other port, named by compose project · service with the container and image in the submenu. Instead of Kill they get **Stop container…**, which runs `docker stop <container>` for just that container (killing the listening PID would take down all of Docker). Use **Hide this port** for ones you don't care about.

## Install

Requires macOS, Node 20+ and [SwiftBar](https://swiftbar.app).

```bash
brew install --cask swiftbar          # launch it once and pick a plugin folder
git clone https://github.com/GregGlickert/porthole.git && cd porthole
./scripts/install.sh
```

`install.sh` is safe to re-run. It installs dependencies, a launcher at `~/.porthole/bin/porthole`, and the SwiftBar plugin. The launcher finds node each time it runs (nvm default, `PATH`, Volta, Homebrew), so switching or removing node versions doesn't break the menu or your MCP config. To force a specific node, set `PORTHOLE_NODE=/path/to/node`.

## Connect your agent

Every client runs the same stdio server: `~/.porthole/bin/porthole mcp`. Use the full path (`install.sh` prints it), because most clients don't expand `~`.

**Claude Code**
```bash
claude mcp add porthole -s user -- ~/.porthole/bin/porthole mcp
```

**Codex**
```bash
codex mcp add porthole -- ~/.porthole/bin/porthole mcp
```
(or add `[mcp_servers.porthole]` with `command = "/Users/you/.porthole/bin/porthole"` and `args = ["mcp"]` to `~/.codex/config.toml`)

**Cursor** (`~/.cursor/mcp.json`), **Claude Desktop** (`~/Library/Application Support/Claude/claude_desktop_config.json`), **Windsurf** (`~/.codeium/windsurf/mcp_config.json`):
```json
{
  "mcpServers": {
    "porthole": { "command": "/Users/you/.porthole/bin/porthole", "args": ["mcp"] }
  }
}
```

**VS Code** (`.vscode/mcp.json`, or the user-level MCP config):
```json
{
  "servers": {
    "porthole": { "type": "stdio", "command": "/Users/you/.porthole/bin/porthole", "args": ["mcp"] }
  }
}
```

The server already tells agents when to use it. For clients that ignore server instructions, add this to your agent rules (`~/.claude/CLAUDE.md`, `AGENTS.md`, Cursor rules, …):

> When you start a local dev server (or the user says one is running), call the porthole `register_server` tool with its port and a ≤8-word title describing the feature/branch being tested. Call `suggest_free_port` before picking a port. Update or remove the label when that changes.

## CLI

```
porthole list | register <port> <title> [desc] | remove <port> | open <port> | copy <port> | kill <port>
         | confirm-kill <port> | prompt-label <port> | ignore/unignore <port|command> | ignored | edit | swiftbar
```
(Add `~/.porthole/bin` to your `PATH` to get the `porthole` command, or run `node src/cli.js …`.)

## Hiding ports

Use **Hide this port** in a port's submenu, or the CLI:

```bash
porthole ignore 8000             # hide a port
porthole ignore claude-science   # hide every port owned by a process name
porthole unignore 8000
porthole ignored                 # show the list
```

Hidden items are listed under **Settings** in the menu — click one to show it again. They live in `~/.porthole/config.json` (**Settings → Open config file…**, or `porthole edit`):

```json
{ "ignorePorts": [8000], "ignoreCommands": ["claude-science"], "portMin": 3000, "portMax": 9999 }
```

"Open in …" uses the first editor found (Cursor, Visual Studio Code, Zed, Windsurf, Sublime Text) and terminal (Ghostty, iTerm, Warp, Terminal). Override with `"editor": "Zed"` or `"terminal": "iTerm"` in the same file.

## Env vars

`PORTHOLE_HOME` (default `~/.porthole`), `PORTHOLE_PORT_MIN` / `PORTHOLE_PORT_MAX` (default 3000–9999; `portMin`/`portMax` in config.json override these).

## Tests

`npm test`

## License

MIT — see [LICENSE](LICENSE).
