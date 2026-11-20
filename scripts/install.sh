#!/bin/bash
# Install Porthole: build Porthole.app, put it in Applications, link the `porthole` command, start the menu.
# Safe to re-run (e.g. after pulling changes). Replaces the old Node + SwiftBar install if there is one.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORTHOLE_HOME="${PORTHOLE_HOME:-$HOME/.porthole}"
BIN="$PORTHOLE_HOME/bin/porthole"
ok() { echo "✓ $*"; }
warn() { echo "! $*"; }

# 1. Toolchain
if ! command -v swift >/dev/null; then
  warn "Swift not found. Install Xcode or the Command Line Tools (xcode-select --install) and re-run."
  exit 1
fi

# 2. Build
echo "Building Porthole (first build takes a minute)…"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
"$ROOT/scripts/build-app.sh" "$BUILD" >/dev/null
ok "Built Porthole.app"

# 3. Install into /Applications (or ~/Applications if that isn't writable)
DEST=/Applications
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
APP="$DEST/Porthole.app"
if pgrep -f "Porthole.app/Contents/MacOS/Porthole" >/dev/null; then
  osascript -e 'tell application id "io.github.gregglickert.porthole" to quit' >/dev/null 2>&1 || true
  sleep 1
  pkill -f "Porthole.app/Contents/MacOS/Porthole" 2>/dev/null || true
fi
rm -rf "$APP"
# A copy from an earlier install in the other Applications folder would be a second, stale Porthole.
for other in /Applications/Porthole.app "$HOME/Applications/Porthole.app"; do
  [ "$other" != "$APP" ] && [ -d "$other" ] && rm -rf "$other" 2>/dev/null || true
done
ditto "$BUILD/Porthole.app" "$APP"
ok "Installed $APP"

# 4. The command MCP clients run. Same path as before, so existing MCP configs keep working.
mkdir -p "$(dirname "$BIN")"
rm -f "$BIN"
ln -s "$APP/Contents/Helpers/porthole" "$BIN"
ok "Linked $BIN → $APP/Contents/Helpers/porthole"

# 5. Remove the old SwiftBar plugin (Node version), if installed
PLUGIN_DIR="${SWIFTBAR_PLUGIN_DIR:-$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)}"
REMOVED=0
if [ -n "$PLUGIN_DIR" ]; then
  for f in porthole.sh porthole.5s.sh porthole.60s.sh; do  # only the names the Node installer used
    if [ -e "$PLUGIN_DIR/$f" ]; then rm -f "$PLUGIN_DIR/$f" && REMOVED=1; fi
  done
fi
if [ "$REMOVED" = 1 ]; then
  open -g "swiftbar://refreshallplugins" 2>/dev/null || true
  ok "Removed the old SwiftBar plugin (SwiftBar itself is no longer needed)"
fi
pkill -f "src/cli.js stream" 2>/dev/null || true

# 6. Start it
open "$APP"
ok "Porthole is running in your menu bar. Quit it from its menu; turn on Settings → Launch at login to start it automatically."

cat <<EOF

Connect your MCP client (the server command is: $BIN mcp)

  Claude Code:   claude mcp add porthole -s user -- "$BIN" mcp
  Codex:         codex mcp add porthole -- "$BIN" mcp
  Cursor, Claude Desktop, VS Code, Windsurf: add this server to the client's MCP config
                 { "command": "$BIN", "args": ["mcp"] }

Already connected from the Node version? Nothing to change: it's the same path.
Optional: add $(dirname "$BIN") to your PATH to use the \`porthole\` command in a terminal.
EOF
