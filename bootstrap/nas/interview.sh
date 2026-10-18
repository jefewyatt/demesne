#!/usr/bin/env bash
# First-time setup interview for the core host (NAS).
#
# Walks through bootstrap/README.md steps 0–2: personalize Forgejo + Komodo,
# write configs, optionally create dirs/network and bring the stacks up.
# UI-only steps (Forgejo install wizard, users, tokens, sync, webhook) stay
# printed as a checklist — those need a browser.
#
# Where to run it
# ---------------
# On the NAS, after copying bootstrap material:
#
#   # from a machine that has this repo:
#   scp -r bootstrap/nas <nas-user>@<nas-ip>:~/bootstrap
#   ssh <nas-user>@<nas-ip>
#   cd ~/bootstrap && ./interview.sh
#
# Or from a full repo checkout on the NAS:
#   ./bootstrap/nas/interview.sh
#
# Options
# -------
#   --dry-run     Print what would be written; touch nothing
#   --start       After writing configs, create network/dirs and compose up
#   --no-start    Write configs only (default)
#   -h, --help    This help
#
# Non-interactive answers: set env vars before running (see ask_* defaults),
# or pipe lines to stdin. Secrets default to openssl rand -hex 24 when Enter
# is pressed on an empty prompt.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
DO_START=0

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --start) DO_START=1; shift ;;
    --no-start) DO_START=0; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

# Resolve layout: ~/bootstrap/{forgejo,komodo}  or  repo/bootstrap/nas/{forgejo,komodo}
FORGEJO_DIR=""
KOMODO_DIR=""
REPO_ROOT=""

if [[ -d "$SCRIPT_DIR/forgejo" && -d "$SCRIPT_DIR/komodo" ]]; then
  FORGEJO_DIR="$SCRIPT_DIR/forgejo"
  KOMODO_DIR="$SCRIPT_DIR/komodo"
  # Full checkout: bootstrap/nas → repo root is ../..
  if [[ -f "$SCRIPT_DIR/../../hosts.toml" ]]; then
    REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  fi
elif [[ -d "$SCRIPT_DIR/nas/forgejo" && -d "$SCRIPT_DIR/nas/komodo" ]]; then
  FORGEJO_DIR="$SCRIPT_DIR/nas/forgejo"
  KOMODO_DIR="$SCRIPT_DIR/nas/komodo"
  if [[ -f "$SCRIPT_DIR/../hosts.toml" ]]; then
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  fi
else
  echo "Can't find forgejo/ and komodo/ next to this script." >&2
  echo "Expected layout after: scp -r bootstrap/nas user@nas:~/bootstrap" >&2
  exit 1
fi

say() { printf '%s\n' "$*"; }
hdr() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

ask() {
  # ask VAR "Prompt" "default"
  local var="$1" prompt="$2" default="${3:-}"
  local reply
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " reply || true
    reply="${reply:-$default}"
  else
    read -r -p "$prompt: " reply || true
  fi
  printf -v "$var" '%s' "$reply"
}

ask_secret() {
  # ask_secret VAR "Prompt" — empty → openssl rand -hex 24
  local var="$1" prompt="$2" reply gen
  read -r -s -p "$prompt [Enter = generate]: " reply || true
  echo
  if [[ -z "$reply" ]]; then
    gen="$(openssl rand -hex 24)"
    printf -v "$var" '%s' "$gen"
    say "  (generated)"
  else
    printf -v "$var" '%s' "$reply"
  fi
}

ask_yn() {
  # ask_yn VAR "Prompt" "y"|"n"
  local var="$1" prompt="$2" default="${3:-n}" reply
  read -r -p "$prompt [$default]: " reply || true
  reply="${reply:-$default}"
  case "$reply" in
    y|Y|yes|YES) printf -v "$var" '1' ;;
    *) printf -v "$var" '0' ;;
  esac
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || {
      echo "Missing required command: $c" >&2
      exit 1
    }
  done
}

escape_sed() {
  # Escape for sed replacement (|&\.)
  printf '%s' "$1" | sed -e 's/[\\/&|]/\\&/g'
}

write_file() {
  local path="$1" content="$2"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "[dry-run] would write $path"
    return 0
  fi
  printf '%s' "$content" >"$path"
  say "Wrote $path"
}

# --------------------------------------------------------------------------- #
# Interview
# --------------------------------------------------------------------------- #

hdr "demesne core-host interview (NAS)"
say "Forgejo dir: $FORGEJO_DIR"
say "Komodo dir:  $KOMODO_DIR"
if [[ -n "$REPO_ROOT" ]]; then
  say "Repo root:   $REPO_ROOT (will update hosts.toml)"
else
  say "Repo root:   (not found — will write hosts.toml.snippet here)"
fi
say "Mode:        $([[ "$DRY_RUN" -eq 1 ]] && echo dry-run || echo write)$([[ "$DO_START" -eq 1 ]] && echo ', then start stacks')"
say
say "This covers bootstrap/README.md steps 0–2 (personalize + bring up Forgejo/Komodo)."
say "Browser steps (users, tokens, sync, webhook) stay manual — you'll get a checklist."
say

require_cmd openssl sed awk
if [[ "$DO_START" -eq 1 ]]; then
  require_cmd docker
fi

# Defaults from current system / common homelab values
DEFAULT_UID="$(id -u 2>/dev/null || echo 1000)"
DEFAULT_GID="$(id -g 2>/dev/null || echo 1000)"
DEFAULT_NAS_IP="192.168.1.96"
DEFAULT_NAS_APPDATA="/tank/appdata"
DEFAULT_TZ="${TZ:-America/Los_Angeles}"
DEFAULT_ADMIN="jeff"
DEFAULT_REPO_OWNER="jeff"
DEFAULT_REPO_NAME="homelab"
DEFAULT_TLS_HOST="komodo.lan"
DEFAULT_OPI_APPDATA="/srv/appdata"

hdr "1. Core host identity"
ask NAS_IP "NAS LAN IP (management address)" "$DEFAULT_NAS_IP"
ask NAS_APPDATA "NAS appdata root" "$DEFAULT_NAS_APPDATA"
ask NAS_DESC "NAS description" "OMV8 NAS, Intel N150, ZFS RAIDZ1 pool at /tank"
ask TZ_VALUE "Timezone (TZ)" "$DEFAULT_TZ"
ask FORGEJO_UID "Forgejo data owner UID (id -u)" "$DEFAULT_UID"
ask FORGEJO_GID "Forgejo data owner GID (id -g)" "$DEFAULT_GID"

hdr "2. Forgejo / git"
ask ADMIN_USER "Forgejo + Komodo admin username" "$DEFAULT_ADMIN"
ask REPO_OWNER "Forgejo repo owner" "$DEFAULT_REPO_OWNER"
ask REPO_NAME "Forgejo repo name" "$DEFAULT_REPO_NAME"
ask KOMODO_GIT_USER "Komodo git account username on Forgejo" "komodo"

hdr "3. Komodo TLS + firewall"
ask TLS_HOST "Komodo TLS hostname (must match /etc/hosts)" "$DEFAULT_TLS_HOST"
ask ALLOWED_SOURCES \
  "IPs/CIDRs allowed to open :9120 (comma-separated: admin PC, Orange Pi, …)" \
  ""
while [[ -z "${ALLOWED_SOURCES// /}" || "$ALLOWED_SOURCES" == "CHANGE_ME" ]]; do
  warn "KOMODO_ALLOWED_SOURCES cannot be empty — firewall.sh will refuse to run."
  ask ALLOWED_SOURCES "IPs/CIDRs allowed to open :9120" ""
done

hdr "4. Second host (Orange Pi) — for hosts.toml"
ask_yn WANT_OPI "Configure orangepi in hosts.toml now?" "y"
OPI_IP="192.168.1.XXX"
OPI_APPDATA="$DEFAULT_OPI_APPDATA"
OPI_DESC="Orange Pi 6 Plus, Ubuntu 24.04, 1TB NVMe"
OPI_PORTS="22"
if [[ "$WANT_OPI" -eq 1 ]]; then
  ask OPI_IP "Orange Pi LAN IP" "$OPI_IP"
  ask OPI_APPDATA "Orange Pi appdata root" "$OPI_APPDATA"
  ask OPI_DESC "Orange Pi description" "$OPI_DESC"
  ask OPI_PORTS "Orange Pi reserved ports (comma-separated)" "$OPI_PORTS"
fi

hdr "5. Secrets (Enter = openssl rand -hex 24)"
ask_secret DB_PASSWORD "Komodo MongoDB password"
ask_secret ADMIN_PASSWORD "Komodo init admin password (KOMODO_INIT_ADMIN_PASSWORD)"
ask_secret WEBHOOK_SECRET "Komodo webhook secret (also used in Forgejo webhook)"
ask_secret JWT_SECRET "Komodo JWT secret"

NAS_RESERVED="22, 80, 443, 2222, 3000, 9120"
ask NAS_RESERVED "NAS reserved_ports (comma-separated)" "$NAS_RESERVED"

hdr "6. Confirm"
say "  NAS:          $NAS_IP  appdata=$NAS_APPDATA"
say "  Forgejo UID:  $FORGEJO_UID:$FORGEJO_GID"
say "  Git repo:     $REPO_OWNER/$REPO_NAME @ http://$NAS_IP:3000"
say "  Komodo UI:    https://$TLS_HOST:9120  (bind $NAS_IP)"
say "  Allowed :9120 $ALLOWED_SOURCES"
say "  Admin user:   $ADMIN_USER"
if [[ "$WANT_OPI" -eq 1 ]]; then
  say "  Orange Pi:    $OPI_IP  appdata=$OPI_APPDATA"
fi
say
ask_yn CONFIRM "Write configs with these values?" "y"
if [[ "$CONFIRM" -ne 1 ]]; then
  say "Aborted."
  exit 1
fi

# --------------------------------------------------------------------------- #
# Apply: Forgejo compose
# --------------------------------------------------------------------------- #

hdr "Writing Forgejo compose personalization"
FORGEJO_COMPOSE="$FORGEJO_DIR/compose.yaml"
if [[ ! -f "$FORGEJO_COMPOSE" ]]; then
  echo "Missing $FORGEJO_COMPOSE" >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  say "[dry-run] would set USER_UID=$FORGEJO_UID USER_GID=$FORGEJO_GID"
  say "[dry-run] would set ROOT_URL/SSH_DOMAIN to $NAS_IP"
else
  # In-place edits; keep a .bak once.
  cp -n "$FORGEJO_COMPOSE" "$FORGEJO_COMPOSE.bak" 2>/dev/null || true
  sed -i \
    -e "s/USER_UID: \"[^\"]*\"/USER_UID: \"$FORGEJO_UID\"/" \
    -e "s/USER_GID: \"[^\"]*\"/USER_GID: \"$FORGEJO_GID\"/" \
    -e "s|FORGEJO__server__ROOT_URL: .*|FORGEJO__server__ROOT_URL: http://$NAS_IP:3000/|" \
    -e "s/FORGEJO__server__SSH_DOMAIN: .*/FORGEJO__server__SSH_DOMAIN: $NAS_IP/" \
    "$FORGEJO_COMPOSE"
  # Strip trailing CHANGE ME comments on UID/GID lines we just set
  sed -i \
    -e 's/\(USER_UID: "[0-9]*"\).*/\1/' \
    -e 's/\(USER_GID: "[0-9]*"\).*/\1/' \
    "$FORGEJO_COMPOSE"
  say "Updated $FORGEJO_COMPOSE"
fi

# --------------------------------------------------------------------------- #
# Apply: Komodo .env
# --------------------------------------------------------------------------- #

hdr "Writing Komodo .env"
ENV_EXAMPLE="$KOMODO_DIR/env.example"
ENV_FILE="$KOMODO_DIR/.env"
if [[ ! -f "$ENV_EXAMPLE" ]]; then
  echo "Missing $ENV_EXAMPLE" >&2
  exit 1
fi

# shellcheck disable=SC2016
ENV_CONTENT="$(
  sed \
    -e "s|^COMPOSE_KOMODO_BACKUPS_PATH=.*|COMPOSE_KOMODO_BACKUPS_PATH=$NAS_APPDATA/komodo/backups|" \
    -e "s|^KOMODO_BIND_ADDRESS=.*|KOMODO_BIND_ADDRESS=$NAS_IP|" \
    -e "s|^KOMODO_TLS_HOSTNAME=.*|KOMODO_TLS_HOSTNAME=$TLS_HOST|" \
    -e "s|^KOMODO_DATABASE_PASSWORD=.*|KOMODO_DATABASE_PASSWORD=$DB_PASSWORD|" \
    -e "s|^TZ=.*|TZ=$TZ_VALUE|" \
    -e "s|^KOMODO_HOST=.*|KOMODO_HOST=https://$TLS_HOST:9120|" \
    -e "s|^KOMODO_INIT_ADMIN_USERNAME=.*|KOMODO_INIT_ADMIN_USERNAME=$ADMIN_USER|" \
    -e "s|^KOMODO_INIT_ADMIN_PASSWORD=.*|KOMODO_INIT_ADMIN_PASSWORD=$ADMIN_PASSWORD|" \
    -e "s|^KOMODO_WEBHOOK_SECRET=.*|KOMODO_WEBHOOK_SECRET=$WEBHOOK_SECRET|" \
    -e "s|^KOMODO_JWT_SECRET=.*|KOMODO_JWT_SECRET=$JWT_SECRET|" \
    -e "s|^KOMODO_ALLOWED_SOURCES=.*|KOMODO_ALLOWED_SOURCES=$ALLOWED_SOURCES|" \
    -e "s|^KOMODO_FIRST_SERVER_NAME=.*|KOMODO_FIRST_SERVER_NAME=nas|" \
    -e "s|^PERIPHERY_CONNECT_AS=.*|PERIPHERY_CONNECT_AS=nas|" \
    "$ENV_EXAMPLE"
)"

if [[ "$DRY_RUN" -eq 1 ]]; then
  say "[dry-run] would write $ENV_FILE (secrets redacted in preview):"
  printf '%s\n' "$ENV_CONTENT" | sed -E \
    -e 's/(PASSWORD|SECRET)=.*/\1=***/' \
    | sed -n '1,80p'
else
  if [[ -f "$ENV_FILE" ]]; then
    cp "$ENV_FILE" "$ENV_FILE.bak.$(date +%Y%m%d%H%M%S)"
    warn "Existing .env backed up"
  fi
  printf '%s\n' "$ENV_CONTENT" >"$ENV_FILE"
  chmod 600 "$ENV_FILE"
  say "Wrote $ENV_FILE (mode 600)"
fi

# --------------------------------------------------------------------------- #
# Apply: hosts.toml (or snippet)
# --------------------------------------------------------------------------- #

hdr "hosts.toml"
# Format reserved ports for TOML arrays
format_ports() {
  local raw="$1" out="" p
  raw="${raw//,/ }"
  for p in $raw; do
    p="$(echo "$p" | xargs)"
    [[ -z "$p" ]] && continue
    if [[ -n "$out" ]]; then out+=", "; fi
    out+="$p"
  done
  printf '%s' "$out"
}

NAS_PORTS_TOML="$(format_ports "$NAS_RESERVED")"
OPI_PORTS_TOML="$(format_ports "$OPI_PORTS")"

HOSTS_BODY="$(cat <<EOF
# Generated by bootstrap/nas/interview.sh — review before committing.
# Single source of truth for the machines this repo deploys to.

[git]
provider = "$NAS_IP:3000"
https = false
account = "$KOMODO_GIT_USER"
repo = "$REPO_OWNER/$REPO_NAME"
branch = "main"

[hosts.nas]
arch = "amd64"
description = "$NAS_DESC"
address = "$NAS_IP"
appdata = "$NAS_APPDATA"
reserved_ports = [$NAS_PORTS_TOML]
EOF
)"

if [[ "$WANT_OPI" -eq 1 ]]; then
  HOSTS_BODY+="$(cat <<EOF


[hosts.orangepi]
arch = "arm64"
description = "$OPI_DESC"
address = "$OPI_IP"
appdata = "$OPI_APPDATA"
reserved_ports = [$OPI_PORTS_TOML]
EOF
)"
fi

HOSTS_BODY+=$'\n'

SNIPPET_PATH="$SCRIPT_DIR/hosts.toml.snippet"
if [[ -n "$REPO_ROOT" && -f "$REPO_ROOT/hosts.toml" ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "[dry-run] would replace $REPO_ROOT/hosts.toml"
  else
    cp "$REPO_ROOT/hosts.toml" "$REPO_ROOT/hosts.toml.bak.$(date +%Y%m%d%H%M%S)"
    printf '%s' "$HOSTS_BODY" >"$REPO_ROOT/hosts.toml"
    say "Updated $REPO_ROOT/hosts.toml (backup kept)"
    # Keep stack git provider in sync when repo/account/provider change
    if [[ -d "$REPO_ROOT/komodo/stacks" ]]; then
      while IFS= read -r -d '' toml; do
        sed -i \
          -e "s|^git_provider = .*|git_provider = \"$NAS_IP:3000\"|" \
          -e "s|^git_account = .*|git_account = \"$KOMODO_GIT_USER\"|" \
          -e "s|^repo = .*|repo = \"$REPO_OWNER/$REPO_NAME\"|" \
          "$toml"
      done < <(find "$REPO_ROOT/komodo/stacks" -name '*.toml' -print0)
      say "Synced git_provider/account/repo in komodo/stacks/**/*.toml"
    fi
  fi
else
  write_file "$SNIPPET_PATH" "$HOSTS_BODY"
  say "Merge $SNIPPET_PATH into the repo's hosts.toml on your workstation, then commit."
fi

# Save a non-secret summary for the operator
SUMMARY_PATH="$SCRIPT_DIR/interview-summary.txt"
SUMMARY="$(cat <<EOF
demesne core-host interview summary ($(date -Iseconds 2>/dev/null || date))
======================================================================
NAS_IP=$NAS_IP
NAS_APPDATA=$NAS_APPDATA
FORGEJO_UID:GID=$FORGEJO_UID:$FORGEJO_GID
ADMIN_USER=$ADMIN_USER
REPO=$REPO_OWNER/$REPO_NAME
KOMODO_GIT_USER=$KOMODO_GIT_USER
TLS_HOST=$TLS_HOST
KOMODO_BIND=$NAS_IP
KOMODO_ALLOWED_SOURCES=$ALLOWED_SOURCES
ORANGEPI_IP=$OPI_IP
ORANGEPI_APPDATA=$OPI_APPDATA

URLs
----
Forgejo:  http://$NAS_IP:3000
Komodo:   https://$TLS_HOST:9120
  (/etc/hosts on clients:  $NAS_IP $TLS_HOST)

Secrets are in $ENV_FILE only — not repeated here.
Keep the webhook secret handy for Forgejo → Komodo webhook (README step 6).

Next UI checklist: see end of interview output / bootstrap/README.md steps 1–10.
EOF
)"
write_file "$SUMMARY_PATH" "$SUMMARY"

# --------------------------------------------------------------------------- #
# Optional: start stacks (README steps 1–2 automation)
# --------------------------------------------------------------------------- #

if [[ "$DO_START" -eq 1 ]]; then
  hdr "Starting Forgejo + Komodo on this host"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "[dry-run] would: mkdir appdata, docker network create, compose up, export-ca, firewall"
  else
    require_cmd docker
    sudo mkdir -p "$NAS_APPDATA/forgejo" "$NAS_APPDATA/komodo/backups"
    sudo chown "$FORGEJO_UID:$FORGEJO_GID" "$NAS_APPDATA/forgejo"
    docker network create homelab-komodo 2>/dev/null || true

    say "→ Forgejo"
    (cd "$FORGEJO_DIR" && docker compose up -d)

    say "→ Komodo"
    (cd "$KOMODO_DIR" && docker compose up -d)

    # Caddy may need a moment before the internal CA exists
    sleep 3
    if [[ -x "$KOMODO_DIR/export-ca.sh" ]]; then
      (cd "$KOMODO_DIR" && ./export-ca.sh)
    fi

    if [[ -x "$KOMODO_DIR/firewall.sh" ]]; then
      say "→ firewall.sh (DOCKER-USER allowlist for :9120)"
      (
        cd "$KOMODO_DIR"
        set -a
        # shellcheck disable=SC1091
        source .env
        set +a
        sudo -E ./firewall.sh
      )
    fi

    say
    say "Add to this machine and every admin/client /etc/hosts:"
    say "  echo \"$NAS_IP $TLS_HOST\" | sudo tee -a /etc/hosts"
  fi
else
  hdr "Stacks not started (--start to bring them up)"
  say "When ready on the NAS:"
  say "  sudo mkdir -p $NAS_APPDATA/forgejo $NAS_APPDATA/komodo/backups"
  say "  sudo chown $FORGEJO_UID:$FORGEJO_GID $NAS_APPDATA/forgejo"
  say "  docker network create homelab-komodo 2>/dev/null || true"
  say "  cd $FORGEJO_DIR && docker compose up -d"
  say "  cd $KOMODO_DIR && docker compose up -d && ./export-ca.sh"
  say "  set -a && source .env && set +a && sudo -E ./firewall.sh"
  say
  say "Or re-run:  $0 --start"
fi

# --------------------------------------------------------------------------- #
# Remaining manual checklist (README steps 1 UI … 10)
# --------------------------------------------------------------------------- #

hdr "Manual checklist (browser / other hosts)"
cat <<EOF
[ ] Forgejo install page → http://$NAS_IP:3000  (SQLite, admin=$ADMIN_USER)
[ ] Forgejo users: agent (Write), $KOMODO_GIT_USER (Read) on $REPO_OWNER/$REPO_NAME
[ ] Create empty repo $REPO_OWNER/$REPO_NAME; push skeleton; save tokens
[ ] /etc/hosts on admin PC + Orange Pi:  $NAS_IP $TLS_HOST
[ ] Trust CA: $KOMODO_DIR/komodo-root-ca.crt (after export-ca.sh)
[ ] Komodo login → https://$TLS_HOST:9120  (user=$ADMIN_USER)
[ ] Servers: nas should show OK
[ ] Komodo git provider: $NAS_IP:3000 / account=$KOMODO_GIT_USER / HTTPS off
[ ] Orange Pi: demesne host script orangepi …  (or README step 4)
[ ] Sync name exactly "homelab"; webhook http://core:9120/listener/github/procedure/deploy-on-push/main
[ ] Protect main; point Cursor agent; smoke-test hello

Webhook secret is in $ENV_FILE (KOMODO_WEBHOOK_SECRET).
Full narrative: bootstrap/README.md from step 1 (UI) onward.
EOF

say
say "Done."
[[ "$DRY_RUN" -eq 1 ]] && say "(dry-run: no files modified)"
exit 0
