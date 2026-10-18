#!/usr/bin/env bash
# Restrict Docker-published TCP 9120 to KOMODO_ALLOWED_SOURCES.
#
# Docker applies DNAT before the filter table; rules that affect published
# ports belong in the DOCKER-USER chain. Run on the NAS after
# `docker compose up`, and again after reboot unless you persist iptables
# (OMV openmediavault-iptables plugin, or a small systemd unit).
#
# Usage:
#   cd ~/bootstrap/komodo
#   set -a && source .env && set +a
#   sudo -E ./firewall.sh
#   sudo -E ./firewall.sh --flush

set -euo pipefail

CHAIN="DOCKER-USER"
COMMENT="homelab-komodo-9120"
PORT=9120
BIND_ADDRESS="${KOMODO_BIND_ADDRESS:-192.168.1.96}"
ALLOWED_SOURCES="${KOMODO_ALLOWED_SOURCES:-}"

flush_rules() {
  # Delete from the end so line numbers stay valid.
  local n
  while n="$(iptables -L "$CHAIN" --line-numbers -n 2>/dev/null | awk -v c="$COMMENT" 'index($0, c) { print $1; exit }")"; do
    [[ -z "$n" ]] && break
    iptables -D "$CHAIN" "$n"
  done
}

if [[ "${1:-}" == "--flush" ]]; then
  flush_rules
  echo "Removed $COMMENT rules from $CHAIN."
  exit 0
fi

if [[ -z "$ALLOWED_SOURCES" || "$ALLOWED_SOURCES" == "CHANGE_ME" ]]; then
  echo "Set KOMODO_ALLOWED_SOURCES in .env (comma-separated IPs/CIDRs), then re-run." >&2
  exit 1
fi

if ! iptables -L "$CHAIN" -n >/dev/null 2>&1; then
  echo "iptables chain $CHAIN not found. Is Docker running?" >&2
  exit 1
fi

flush_rules

# DROP last among our rules: insert DROP first, then ACCEPT lines at position 1
# so they sit above it.
iptables -I "$CHAIN" 1 -p tcp -d "$BIND_ADDRESS" --dport "$PORT" \
  -m comment --comment "$COMMENT" -j DROP

IFS=',' read -ra sources <<< "$ALLOWED_SOURCES"
for raw in "${sources[@]}"; do
  src="$(echo "$raw" | xargs)"
  [[ -z "$src" ]] && continue
  iptables -I "$CHAIN" 1 -p tcp -s "$src" -d "$BIND_ADDRESS" --dport "$PORT" \
    -m comment --comment "$COMMENT" -j ACCEPT
  echo "allow $src -> $BIND_ADDRESS:$PORT"
done

echo "drop  others -> $BIND_ADDRESS:$PORT"
echo "Done. Persist across reboot (OMV iptables plugin or a systemd unit)."
