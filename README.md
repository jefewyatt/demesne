# homelab

Single source of truth for every service in Jeff's homelab. Coding agents change this repo; **merging to `main` deploys**. Agents never hold deploy credentials or Docker access. Only Jeff can merge to `main`.

For the one-time Forgejo + Komodo bring-up, see [`bootstrap/README.md`](bootstrap/README.md). Detailed agent rules live in [`AGENTS.md`](AGENTS.md) (also loaded by Cursor).

---

## Architecture

```
 Cursor agent ──push branch──▶ Forgejo (NAS) ──PR──▶ Jeff reviews & merges to main
                                     │
                          push webhook (main only)
                                     ▼
                         Komodo Core (NAS) runs procedure "deploy-on-push"
                           1. RunSync: apply komodo/**/*.toml
                           2. Deploy stacks
                                     │
                 ┌───────────────────┴───────────────────┐
                 ▼                                       ▼
        Periphery on nas (amd64)              Periphery on orangepi (arm64)
        git pull → build → compose up         git pull → build → compose up
        …and any other hosts you add…
```

| Piece | Role |
|---|---|
| **This repo** | Compose files, Dockerfiles, and Komodo stack definitions for every managed service |
| **Forgejo** (NAS) | Git host; webhook on push to `main` |
| **Komodo Core** (NAS) | Syncs `komodo/`, then deploys stacks to the right Periphery |
| **Periphery** (each host) | Komodo agent on the machine: clones the repo, builds images natively, runs `docker compose` |
| **`hosts.toml`** | Authoritative list of machines (arch, IP, appdata root, reserved ports) |

Each host builds its own images. There is no shared registry and no cross-compiling. The directory a service lives under (`hosts/<host>/…`) is the machine it runs on.

### Layout

| Path | What |
|---|---|
| `hosts/<host>/<service>/` | Service definition: `compose.yaml`, optional `Dockerfile`/`src/`, and `README.md` |
| `komodo/stacks/<host>/<service>.toml` | Komodo stack (one file per service so parallel agents don't collide) |
| `komodo/procedures.toml` | `deploy-on-push` webhook target — do not edit |
| `hosts.toml` | Machines, git settings, reserved ports |
| `scripts/new_service.py` | Scaffolds a service + stack with correct settings |
| `scripts/validate.py` | Convention checker; agents run before every PR; CI on PRs |
| `AGENTS.md`, `.cursor/rules/` | Rules for coding agents |
| `bootstrap/` | One-time Forgejo/Komodo setup (not managed by Komodo) |

### How a merge becomes a deploy

Each stack is tagged with a deploy strategy:

| Tag | When Komodo redeploys | Use for |
|---|---|---|
| `redeploy-if-changed` | Only when `compose.yaml` (or a file listed in `config_files`) differs from what's deployed | Pinned prebuilt images |
| `redeploy-always` | Every merge: `compose build` + `compose up` | Built from source. Unchanged builds hit the cache; compose leaves the container alone |

Ownership: Komodo owns everything under `hosts/`. Forgejo and Komodo themselves are run by hand from `bootstrap/`. Don't manage Komodo-owned stacks from the OMV Compose plugin, and don't add bootstrap stacks to Komodo.

---

## Day to day (Jeff)

1. **Ask an agent for a change.** It works on a branch, runs `validate.py`, and opens a PR.
2. **Create any secrets first.** If the PR lists `[[SECRET]]` names, add them in Komodo → Settings → Variables (mark as secret) before merging.
3. **Review and merge.** Merge is the deploy.
4. **Watch it land.** Komodo → Procedures → `deploy-on-push`; each stack shows build/compose logs.
5. **Roll back.** Revert the commit and merge the revert. Data under `APPDATA` is not touched by deploys.

### Removing a service

1. In Komodo, open the stack → **Destroy** (stops and removes containers).
2. Merge a PR that deletes `hosts/<host>/<service>/` and `komodo/stacks/<host>/<service>.toml`.
3. Delete the host's `<appdata>/<service>` directory yourself if you don't want the data.

---

## Adding a new host (Jeff)

Do this when you build a new machine that should run services from this repo. Agents cannot register hosts; you edit `hosts.toml` and install Periphery.

### 1. Decide the host identity

Pick values and add a `[hosts.<key>]` block to `hosts.toml` (Jeff edits this file; agents must not unless you ask):

| Field | Meaning |
|---|---|
| key | Short name, e.g. `orangepi`, `media`. Must match Komodo's Server name (`--connect-as`) |
| `arch` | `amd64` or `arm64` — images build natively on this machine |
| `address` | LAN IP |
| `appdata` | Persistent data root (e.g. `/srv/appdata`). Each service gets `<appdata>/<service>` |
| `reserved_ports` | Ports already used outside this repo (SSH, host UIs, etc.). `validate.py` refuses to reuse them |
| `description` | Human-readable note |

Commit and merge that change (or include it with the first service PR after Periphery is up).

### 2. Prepare the machine

On the new host:

```bash
# Docker
docker --version || curl -fsSL https://get.docker.com | sudo sh

# Persistent data root — match appdata in hosts.toml
sudo mkdir -p /srv/appdata   # or whatever path you chose
```

### 3. Trust Komodo's TLS and reach Core

Komodo UI/API is HTTPS on `komodo.lan:9120`. On the new host (same as for the Orange Pi):

```bash
# Point komodo.lan at the NAS (IP from [hosts.nas].address)
echo "192.168.1.96 komodo.lan" | sudo tee -a /etc/hosts

# Trust the CA exported on the NAS (bootstrap/nas/komodo/export-ca.sh → komodo-root-ca.crt)
sudo cp komodo-root-ca.crt /usr/local/share/ca-certificates/komodo-root-ca.crt
sudo update-ca-certificates
```

On the NAS, add this host's IP to `KOMODO_ALLOWED_SOURCES` in the Komodo `.env`, then re-run `firewall.sh` so the new box can open TCP 9120. See [`bootstrap/README.md`](bootstrap/README.md) steps 2 and 4.

### 4. Install Periphery

In Komodo → Settings → Onboarding, create an **onboarding key** (starts with `O-`).

```bash
# on the new host — --connect-as MUST equal the hosts.toml key
curl -sSL https://raw.githubusercontent.com/moghtech/komodo/main/scripts/setup-periphery.py \
  | sudo python3 - \
  --core-address="wss://komodo.lan:9120" \
  --connect-as="<host-key>" \
  --onboarding-key="O-PASTE-YOUR-KEY"

sudo systemctl enable periphery
```

In Komodo → Servers, the new name should show **OK**.

### 5. Deploy services to it

Once the host is in `hosts.toml` and Periphery is **OK**, agents (or you) can scaffold services under `hosts/<host-key>/` — see the next section. First stack lands via the usual PR → merge → `deploy-on-push` path.

**Placement reminder:** heavy / storage-bound / always-on → `nas`. Experiments, AI/NPU, or hardware-tied work → the machine that has the hardware (today: `orangepi`).

---

## For coding agents: stand up or change a service

Full rules: [`AGENTS.md`](AGENTS.md). Summary for the common paths:

### Non-negotiables

- Work on a branch. Never push to `main`.
- Never deploy, never touch Docker on the hosts, never edit machines directly. Manual host steps go in the PR for Jeff.
- Run `python scripts/validate.py` before every PR; fix every ERROR. Mention WARNs in the PR.
- Never commit secrets. Use Komodo `[[SECRET_NAME]]` in the stack `environment` and `${VAR}` in compose.
- Do not edit unless Jeff asks: `komodo/procedures.toml`, `bootstrap/**`, `.forgejo/**`, `scripts/validate.py` (to loosen a rule), `hosts.toml`.

### Add a new service

1. Scaffold (never hand-copy an existing service):

   ```bash
   python scripts/new_service.py <host> <name> --build [--container-port N]
   python scripts/new_service.py <host> <name> --image <image:pinned-tag> [--port HOST:CONTAINER]
   ```

   Host ports auto-assign from 8100 unless you pass `--port`. Names are lowercase-with-dashes and unique across all hosts.

2. Replace every `TODO(new_service)` (description, healthcheck, Dockerfile).
3. Fill `hosts/<host>/<name>/README.md`: purpose, URL, secrets Jeff must create, data paths.
4. `python scripts/validate.py` → 0 errors.
5. Open a PR using the template in `AGENTS.md` (What / Where / Before merging / Validation).

`hosts/orangepi/**` must work on **arm64**. Prefer `python scripts/validate.py --check-images` when Docker is available.

### Modify an existing service

1. Edit only under that service's directory and/or its stack file `komodo/stacks/<host>/<service>.toml`.
2. For `redeploy-if-changed` stacks: any repo file mounted into the container must be listed in the stack's `config_files`, or the change will never deploy. Prefer inline compose `configs:` for small files.
3. Moving a service between hosts = move the directory **and** the stack file, and tell Jeff to **Destroy** the old stack in Komodo first.
4. Validate, PR, same as above.

### Compose expectations (enforced by validate.py)

- Pinned image tags (`nginx:1.28-alpine`, not `latest`)
- `restart: unless-stopped` and a real healthcheck on every long-running service
- Persistent data under `${APPDATA}/…`
- Unique host ports; no `reserved_ports`
- No top-level compose `name:` (Komodo sets the project name)
- Dangerous options (`privileged`, host network, Docker socket, etc.) need an `x-homelab.allow` reason

Build-from-source: scaffold sets `redeploy-always`, `run_build = true`, `auto_pull = false`, and `image: homelab/<service>:local`.

### Secrets

```toml
# in komodo/stacks/<host>/<service>.toml
environment = """
APPDATA = /tank/appdata/myservice
DB_PASSWORD = [[MYSERVICE_DB_PASSWORD]]
"""
```

```yaml
# in compose.yaml
environment:
  POSTGRES_PASSWORD: ${DB_PASSWORD}
```

List every new `[[SECRET]]` in the service README and the PR checklist so Jeff can create them before merge.
