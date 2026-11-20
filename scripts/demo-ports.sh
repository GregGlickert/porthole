#!/bin/bash
# Demo ports for screenshots: five Python web servers on :4100–:4104, each running from its own throwaway git
# checkout, four of them labeled the way an agent would label them.
#
#   scripts/demo-ports.sh start   # start servers, add labels, show only 4100–4199 in the menu
#   scripts/demo-ports.sh stop    # stop servers, remove labels, restore your port range
#
# While the demo runs, the menu's port range is narrowed to 4100–4199 so your real servers stay out of the
# screenshot. `stop` restores your config.json exactly as it was.
set -euo pipefail
DEMO="${PORTHOLE_DEMO_DIR:-/tmp/porthole-demo}"
HOME_DIR="${PORTHOLE_HOME:-$HOME/.porthole}"
PORTHOLE="${PORTHOLE_BIN:-$HOME_DIR/bin/porthole}"
CONFIG="$HOME_DIR/config.json"
BACKUP="$HOME_DIR/config.json.demo-backup"
PORTS=(4100 4101 4102 4103 4104)

# port | folder | branch | label (empty = leave unlabeled) | description
SERVERS=(
  "4100|storefront|main|Main storefront|"
  "4101|storefront-checkout|feat/checkout-redesign|Checkout redesign|One-page checkout with saved addresses. Try a guest order, then one with a coupon."
  "4102|storefront-cart-fix|fix/cart-totals||"
  "4103|admin|feat/bulk-export|Admin bulk CSV export|Export 10k orders from Orders > Export. Should stream, not time out."
  "4104|docs|main|Docs site preview|"
)

need_porthole() {
  [ -x "$PORTHOLE" ] || { echo "porthole not found at $PORTHOLE (run scripts/install.sh, or set PORTHOLE_BIN)"; exit 1; }
}

start() {
  need_porthole
  mkdir -p "$DEMO"
  for row in "${SERVERS[@]}"; do
    IFS='|' read -r port folder branch label desc <<< "$row"
    dir="$DEMO/$folder"
    if [ ! -d "$dir/.git" ]; then
      mkdir -p "$dir"
      git -C "$dir" init -q -b "$branch"
      printf '<h1>%s</h1><p>Porthole demo server on :%s</p>\n' "${label:-$folder}" "$port" > "$dir/index.html"
    fi
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "! :$port is already in use; skipping it"
      continue
    fi
    (cd "$dir" && nohup python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 &)
  done

  # Show only the demo range while it runs (keep a backup of your config to restore on stop).
  if [ ! -e "$BACKUP" ]; then
    if [ -e "$CONFIG" ]; then cp "$CONFIG" "$BACKUP"; else echo "none" > "$BACKUP"; fi
  fi
  python3 -I - "$CONFIG" <<'EOF'
import json, sys
path = sys.argv[1]
try:
    cfg = json.load(open(path))
except Exception:
    cfg = {}
cfg["portMin"], cfg["portMax"] = 4100, 4199
json.dump(cfg, open(path, "w"), indent=2)
EOF

  for row in "${SERVERS[@]}"; do
    IFS='|' read -r port folder branch label desc <<< "$row"
    [ -n "$label" ] || continue
    if [ -n "$desc" ]; then "$PORTHOLE" register "$port" "$label" "$desc"; else "$PORTHOLE" register "$port" "$label"; fi
  done
  echo
  echo "Demo running on :4100–:4104. Stop it with: scripts/demo-ports.sh stop"
}

stop() {
  for port in "${PORTS[@]}"; do
    pkill -f "http.server $port --bind 127.0.0.1" 2>/dev/null || true
    [ -x "$PORTHOLE" ] && "$PORTHOLE" remove "$port" >/dev/null 2>&1 || true
  done
  if [ -e "$BACKUP" ]; then
    if [ "$(cat "$BACKUP")" = "none" ]; then rm -f "$CONFIG"; else cp "$BACKUP" "$CONFIG"; fi
    rm -f "$BACKUP"
    echo "✓ Restored your port range"
  fi
  rm -rf "$DEMO"
  echo "✓ Demo stopped"
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  *) echo "usage: $0 start|stop"; exit 1 ;;
esac
