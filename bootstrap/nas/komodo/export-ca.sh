#!/usr/bin/env bash
# Copy Caddy's internal root CA out of the proxy container so browsers and
# the Orange Pi can trust https:// / wss:// to Komodo.
#
# Usage (on the NAS, after compose is up):
#   ./export-ca.sh
#   ./export-ca.sh /path/to/komodo-root-ca.crt

set -euo pipefail

cd "$(dirname "$0")"
out="${1:-./komodo-root-ca.crt}"
container="$(docker compose ps -q proxy)"
if [[ -z "$container" ]]; then
  echo "proxy container not running; docker compose up -d first" >&2
  exit 1
fi

# Caddy stores the local CA here when using `tls internal`.
docker cp "$container:/data/caddy/pki/authorities/local/root.crt" "$out"
echo "Wrote $out"
echo "Install on admin machines (browser/OS trust store) and on the Orange Pi:"
echo "  sudo cp komodo-root-ca.crt /usr/local/share/ca-certificates/komodo-root-ca.crt"
echo "  sudo update-ca-certificates"
