#!/bin/bash
# Install Portboard: deps, SwiftBar plugin, and print the Claude Code MCP command.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NODE="$(command -v node)"
CLI="$ROOT/src/cli.js"
PLUGIN_DIR="${SWIFTBAR_PLUGIN_DIR:-$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || echo "$HOME/Library/Application Support/SwiftBar/Plugins")}"

cd "$ROOT"
npm install --silent
chmod +x src/cli.js src/mcp.js

mkdir -p "$PLUGIN_DIR"
sed -e "s#__NODE__#$NODE#" -e "s#__CLI__#$CLI#" swiftbar/portboard.5s.sh > "$PLUGIN_DIR/portboard.5s.sh"
chmod +x "$PLUGIN_DIR/portboard.5s.sh"
echo "✓ SwiftBar plugin installed to: $PLUGIN_DIR/portboard.5s.sh"

if ! [ -d /Applications/SwiftBar.app ]; then
  echo "! SwiftBar not found — install it with: brew install --cask swiftbar"
fi
open -g "swiftbar://refreshallplugins" 2>/dev/null || true

echo
echo "Register the MCP server with Claude Code (all projects):"
echo "  claude mcp add portboard -s user -- \"$NODE\" \"$ROOT/src/mcp.js\""
