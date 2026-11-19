#!/bin/bash
# Install Porthole: deps, the `porthole` launcher, the SwiftBar plugin, and MCP setup instructions.
# Safe to re-run (e.g. after moving the repo or changing node versions).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORTHOLE_HOME="${PORTHOLE_HOME:-$HOME/.porthole}"
BIN="$PORTHOLE_HOME/bin/porthole"
ok() { echo "✓ $*"; }
warn() { echo "! $*"; }

cd "$ROOT"

# 1. Dependencies
if ! command -v node >/dev/null; then
  warn "node not found on PATH. Install Node 20+ (nvm, Volta or Homebrew) and re-run."
  exit 1
fi
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 20 ]; then
  warn "node $(node -v) is too old; Porthole needs Node 20+."
  exit 1
fi
npm install --silent
chmod +x src/cli.js src/mcp.js
ok "Dependencies installed (node $(node -v))"

# 2. Launcher: finds node at run time, so nvm/Volta/Homebrew switches don't break anything.
mkdir -p "$(dirname "$BIN")"
sed -e "s#__ROOT__#$ROOT#" scripts/porthole-shim.sh > "$BIN"
chmod +x "$BIN"
ok "Launcher installed: $BIN"

# 3. SwiftBar plugin
SWIFTBAR_APP=""
for app in /Applications/SwiftBar.app "$HOME/Applications/SwiftBar.app"; do
  [ -d "$app" ] && SWIFTBAR_APP="$app"
done
PLUGIN_DIR="${SWIFTBAR_PLUGIN_DIR:-$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)}"
if [ -z "$SWIFTBAR_APP" ]; then
  warn "SwiftBar isn't installed. Install it with: brew install --cask swiftbar"
  warn "Then launch it once, choose a plugin folder, and re-run this script."
elif [ -z "$PLUGIN_DIR" ]; then
  warn "SwiftBar has no plugin folder yet. Launch SwiftBar, choose one, and re-run this script."
else
  mkdir -p "$PLUGIN_DIR"
  sed -e "s#__PORTHOLE__#$BIN#" swiftbar/porthole.5s.sh > "$PLUGIN_DIR/porthole.5s.sh"
  chmod +x "$PLUGIN_DIR/porthole.5s.sh"
  ok "SwiftBar plugin installed: $PLUGIN_DIR/porthole.5s.sh"
  open -g "swiftbar://refreshallplugins" 2>/dev/null || true
fi

# 4. Docker (optional): the plugin needs `docker` on SwiftBar's PATH to name containers.
SWIFTBAR_PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$HOME/.docker/bin"
if command -v docker >/dev/null && ! PATH="$SWIFTBAR_PATH" command -v docker >/dev/null; then
  warn "docker is at $(command -v docker), which the menu bar can't see. Docker ports will show"
  warn "without container names. Symlink it into /usr/local/bin to fix that."
fi

# 5. Connect your agent
cat <<EOF

Connect your MCP client (the server command is: $BIN mcp)

  Claude Code:   claude mcp add porthole -s user -- "$BIN" mcp
  Codex:         codex mcp add porthole -- "$BIN" mcp
  Cursor, Claude Desktop, VS Code, Windsurf: add this server to the client's MCP config
                 { "command": "$BIN", "args": ["mcp"] }

See README.md → "Connect your agent" for each client's config file.
Optional: add $(dirname "$BIN") to your PATH to use the \`porthole\` command in a terminal.
EOF
