# Porthole

Which feature is running on which localhost port — in your macOS menu bar, labeled by Claude.

```
◉3
:3001  Upload retry flow          ← click: open in Chrome · ⌥-click: copy URL
    feat/upload · myapp ▸         ← submenu: description, uptime + label age, cwd, PID,
                                     Open, Copy, Rename…, Remove label, Hide, Kill server… / Stop container… (asks first)
:3003  fix/css                    ← running but nobody labeled it yet
    unlabeled · node ▸            ← submenu has "Label this port…" (native text prompt)
:8080  Main API
    balance · api ▸               ← Docker ports show compose project · service, container and image
Settings ▸                        ← hidden ports/processes (click to unhide), port range, open config/labels file
About Porthole ▸                  ← version, View on GitHub, open project folder
Refresh
```

- **MCP server** (`src/mcp.js`) — Claude calls `register_server(port, title, description?)` after starting a dev server. Branch and folder are detected automatically. Also `update_server`, `remove_server`, `list_servers` (optional `port` filter; includes uptime and Docker container info), and `suggest_free_port(preferred?, count?)`, which returns ports nothing is listening on and no label claims.
- **SwiftBar plugin** — refreshes every 5s. Shows every listening port in 3000–9999 (system processes and DB ports filtered), with git branch, even if unregistered.
- **No daemon** — labels live in `~/.porthole/servers.json`; live state comes from `lsof` each refresh.
- **Stale labels** — if a different checkout starts listening on a labeled port, the old label is ignored (shown as "old label: …"). Labels for ports that stay dead 24h are pruned.
- **Docker-published ports** are listed like any other port, named by compose project · service with the container and image in the submenu. Instead of Kill they get **Stop container…**, which runs `docker stop <container>` for just that container (killing the listening PID would take down all of Docker). Use **Hide this port** for ones you don't care about.

## Install

```bash
brew install --cask swiftbar          # launch it once and pick a plugin folder
./scripts/install.sh                  # npm install + installs the SwiftBar plugin
claude mcp add porthole -s user -- "$(command -v node)" "$PWD/src/mcp.js"
```

Then add to `~/.claude/CLAUDE.md`:

> When you start a local dev server (or the user tells you one is running), call the porthole `register_server` tool with its port and a ≤8-word title describing the feature/branch being tested. Update or remove it when that changes.

The plugin and MCP command pin the absolute node path. If you remove that node version (e.g. via nvm), rerun `install.sh` and the `claude mcp add` command.

## CLI

```
porthole list | register <port> <title> [desc] | remove <port> | open <port> | copy <port> | kill <port>
         | confirm-kill <port> | prompt-label <port> | ignore/unignore <port|command> | ignored | edit | swiftbar
```
(`node src/cli.js …`, or `npm link` to get `porthole` on your PATH.)

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

## Env vars

`PORTHOLE_HOME` (default `~/.porthole`), `PORTHOLE_PORT_MIN` / `PORTHOLE_PORT_MAX` (default 3000–9999; `portMin`/`portMax` in config.json override these).

## Tests

`npm test`

## License

MIT — see [LICENSE](LICENSE).
