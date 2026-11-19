#!/bin/bash
# Porthole launcher, installed to ~/.porthole/bin/porthole by scripts/install.sh.
# Finds node at run time, so switching or removing node versions (nvm, Volta, Homebrew)
# doesn't break the SwiftBar plugin or MCP config.
#   porthole <cli args>   → src/cli.js
#   porthole mcp          → src/mcp.js (stdio MCP server)
ROOT="__ROOT__"

usable() { [ -n "$1" ] && [ -x "$1" ]; }

# nvm's default alias may be a full or partial version ("22", "v22.16.0") or "node"/"stable".
nvm_default() {
  local dir="${NVM_DIR:-$HOME/.nvm}" alias v
  [ -f "$dir/alias/default" ] || return 1
  alias="$(tr -d '[:space:]' < "$dir/alias/default")"
  case "$alias" in node | stable) alias="" ;; esac
  v="$(ls -d "$dir/versions/node/v${alias#v}"* 2>/dev/null | sort -V | tail -1)"
  [ -n "$v" ] && echo "$v/bin/node"
}

nvm_newest() {
  local v
  v="$(ls -d "${NVM_DIR:-$HOME/.nvm}"/versions/node/v* 2>/dev/null | sort -V | tail -1)"
  [ -n "$v" ] && echo "$v/bin/node"
}

find_node() {
  local c
  for c in \
    "$PORTHOLE_NODE" \
    "$(nvm_default)" \
    "$(command -v node 2>/dev/null)" \
    "$(nvm_newest)" \
    "$HOME/.volta/bin/node" \
    /opt/homebrew/bin/node \
    /usr/local/bin/node; do
    if usable "$c"; then echo "$c"; return 0; fi
  done
  return 1
}

NODE="$(find_node)" || {
  echo "porthole: couldn't find node (need v20+). Set PORTHOLE_NODE=/path/to/node." >&2
  exit 1
}

if [ "$1" = "mcp" ]; then
  shift
  exec "$NODE" "$ROOT/src/mcp.js" "$@"
fi
exec "$NODE" "$ROOT/src/cli.js" "$@"
