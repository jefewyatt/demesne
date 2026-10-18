# Bootstrap: one-time setup

Order matters: Forgejo first (it hosts the repo), then Komodo (it reads the repo), then the Orange Pi agent, then wiring. Budget an hour or so.

Forgejo's UI stays on plain HTTP on the LAN. Komodo's UI is HTTPS on the NAS
management IP only (Caddy in front of Core), and a host firewall should limit
who can open port 9120. Don't port-forward Forgejo or Komodo to the internet.

## 0. Personalize the repo first

Search the repo for `CHANGE ME` and fix each one. The ones that matter most:

| File | What to set |
|---|---|
| `hosts.toml` | Orange Pi IP, Forgejo `owner/repo` if not `jeff/homelab`, `reserved_ports` for anything you already run on either box |
| `bootstrap/nas/forgejo/compose.yaml` | `USER_UID` / `USER_GID` (run `id` on the NAS as the user who'll own the data) |
| `bootstrap/nas/komodo/env.example` | Copied to `.env` in step 2; all `CHANGE_ME` values (secrets + `KOMODO_ALLOWED_SOURCES`) |

If you change `repo`/`account` in `hosts.toml`, also update the two example stack files in `komodo/stacks/` (or delete the examples). `python scripts/validate.py` will flag any mismatch.

## 1. Forgejo on the NAS

**Change before running:** `<nas-user>` below is your SSH login on the NAS. Run the `scp` from the unzipped `homelab` folder on your Windows PC (PowerShell has `scp` built in).

```powershell
scp -r bootstrap/nas <nas-user>@192.168.1.96:~/bootstrap
```

**Change before running:** `1000:1000` must match `USER_UID`/`USER_GID` in the Forgejo compose file. Prefix the `docker` commands with `sudo` if your user isn't in the `docker` group.

```bash
# on the NAS
sudo mkdir -p /tank/appdata/forgejo /tank/appdata/komodo/backups
sudo chown 1000:1000 /tank/appdata/forgejo
# Shared network: Forgejo webhooks reach Komodo Core as http://core:9120
# without crossing the LAN TLS listener. Create once; both compose files use it.
docker network create homelab-komodo 2>/dev/null || true
cd ~/bootstrap/forgejo
docker compose up -d
```

Open http://192.168.1.96:3000 and finish the install page: keep SQLite, and create the admin account (`jeff`).

Then create the rest in the Forgejo UI:

1. **Users** (Site Administration → User Accounts → Create): `agent` (for Cursor) and `komodo` (read-only, for deploys).
2. **Repo:** as `jeff`, create an empty repo `homelab` (no README, so the first push is clean).
3. **Collaborators** (repo → Settings → Collaborators): `agent` = Write, `komodo` = Read.
4. **Tokens** (log in as each user → Settings → Applications → Generate token):
   - `komodo`: scope `repository: read`. Save it for step 3.
   - `agent`: scope `repository: read and write`. Save it for step 8.

Push the skeleton from Windows. **Change before running:** `jeff/homelab` if your owner/repo differs. Git will prompt for your Forgejo login.

```powershell
cd homelab
git init -b main
git add .
git commit -m "Homelab deploy skeleton"
git remote add origin http://192.168.1.96:3000/jeff/homelab.git
git push -u origin main
```

## 2. Komodo Core + NAS agent

**Change before running:** after `cp`, edit `.env` and replace every `CHANGE_ME` (including `KOMODO_ALLOWED_SOURCES` with your admin PC and Orange Pi IPs). Generate the DB password, webhook secret and JWT secret with `openssl rand -hex 24` (run it three times). Keep the webhook secret handy for step 6.

```bash
# on the NAS
docker network create homelab-komodo 2>/dev/null || true
cd ~/bootstrap/komodo
cp env.example .env
nano .env
docker compose up -d
./export-ca.sh                    # writes ./komodo-root-ca.crt
set -a && source .env && set +a
sudo -E ./firewall.sh             # DOCKER-USER allowlist for :9120
```

On every machine that will open the UI (and on the Orange Pi), point the TLS hostname at the NAS:

```bash
# Linux / macOS — use the NAS IP from hosts.toml
echo "192.168.1.96 komodo.lan" | sudo tee -a /etc/hosts
```

Open **https://komodo.lan:9120** (not http, and not the raw IP — the cert is issued for `komodo.lan`). The first visit warns until you trust Caddy's internal CA: install `komodo-root-ca.crt` in your OS/browser trust store, or click through for a quick test. Log in with `KOMODO_INIT_ADMIN_USERNAME` / `_PASSWORD`. Under **Servers**, `nas` should show **OK** within a minute.

`firewall.sh` inserts iptables rules in `DOCKER-USER` so only `KOMODO_ALLOWED_SOURCES` can open TCP 9120 on `KOMODO_BIND_ADDRESS`. Re-run after reboot unless you persist iptables (OMV iptables plugin or a systemd unit that calls this script).

## 3. Give Komodo read access to the repo

Komodo → Settings → Providers → add a **git** account:

- Domain: `192.168.1.96:3000`
- Username: `komodo`
- Token: the `komodo` token from step 1

The stack files and the sync both set HTTPS off, so clones use `http://`. If clones fail with a TLS error, define the provider in a mounted `core.config.toml` instead (`[[git_provider]]` with `https = false`); see https://komo.do/docs/configuration/providers.

## 4. Orange Pi agent

In Komodo → Settings → Onboarding, create an **onboarding key** and copy it (starts with `O-`).

**Change before running:** replace `O-PASTE-YOUR-KEY` with that key. `--connect-as` must stay `orangepi` to match `hosts.toml` (or change both).

```bash
# on the Orange Pi
docker --version || curl -fsSL https://get.docker.com | sudo sh
sudo mkdir -p /srv/appdata

# Trust the same CA the NAS exported (scp komodo-root-ca.crt over first).
sudo cp komodo-root-ca.crt /usr/local/share/ca-certificates/komodo-root-ca.crt
sudo update-ca-certificates

# Same hosts entry as on your admin PC (NAS IP + komodo.lan).
echo "192.168.1.96 komodo.lan" | sudo tee -a /etc/hosts

curl -sSL https://raw.githubusercontent.com/moghtech/komodo/main/scripts/setup-periphery.py \
  | sudo python3 - \
  --core-address="wss://komodo.lan:9120" \
  --connect-as="orangepi" \
  --onboarding-key="O-PASTE-YOUR-KEY"

sudo systemctl enable periphery
```

Use `wss://komodo.lan:9120` (TLS). The NAS's own Periphery container still uses `ws://core:9120` on the compose network.

`orangepi` should appear under **Servers** and show **OK**.

## 5. Create the sync (Komodo reads `komodo/` from the repo)

Komodo → Syncs → **New**, name it exactly `homelab` (the procedure refers to it by name):

| Field | Value |
|---|---|
| Git provider | `192.168.1.96:3000`, HTTPS **off**, account `komodo` |
| Repo / branch | `jeff/homelab` / `main` |
| Resource path | `komodo` |
| Match tags | `git` |
| Delete unmatched resources | **on** (only affects `git`-tagged resources) |

Click **Execute** (or Run Sync). It should propose creating the `deploy-on-push` procedure and the `hello` and `hello-static` stacks. Confirm.

Then open Procedures → `deploy-on-push` → **Run** once by hand. Both smoke tests should come up:

- http://192.168.1.96:8100 returns JSON from the NAS
- http://<orangepi-ip>:8100 shows "Hello from the Orange Pi"

## 6. Webhook: Forgejo → Komodo

Repo → Settings → Webhooks → Add webhook → **Forgejo**:

| Field | Value |
|---|---|
| Target URL | `http://core:9120/listener/github/procedure/deploy-on-push/main` |
| HTTP method / content type | POST / `application/json` |
| Secret | `KOMODO_WEBHOOK_SECRET` from `.env` |
| Trigger | Push events |
| Branch filter | `main` |

The webhook URL uses the Docker DNS name `core` on the shared `homelab-komodo` network (plain HTTP inside the network). LAN browsers still use `https://komodo.lan:9120`. If Forgejo was created before that network existed, recreate it: `docker network create homelab-komodo; cd ~/bootstrap/forgejo && docker compose up -d`.

Komodo checks the signature using its GitHub-style listener, which also accepts Forgejo's webhooks. Use **Test delivery** and check that the procedure runs in Komodo.

If delivery fails with "webhook can only call allowed HTTP servers", the `FORGEJO__webhook__ALLOWED_HOST_LIST` setting in the Forgejo compose didn't apply. Recreate the container.

## 7. Protect `main`

Repo → Settings → Branches → add a protection rule for `main`:

- Restrict pushes to `jeff` only (the `agent` user can push other branches but not `main`).
- Require a pull request to merge.
- Later, once step 10 is done: require the `validate` status check.

This rule is what makes "merge = deploy" safe.

## 8. Point the Cursor agent at the repo

In the Incus container where the Cursor agent runs.

**Change before running:** `AGENT_TOKEN` is the `agent` token from step 1. The token ends up in `.git/config` inside the container, which is acceptable because it can only push non-`main` branches.

```bash
sudo apt-get install -y git python3 python3-yaml
git config --global user.name "cursor-agent"
git config --global user.email "agent@homelab.lan"
git clone http://agent:AGENT_TOKEN@192.168.1.96:3000/jeff/homelab.git
echo 'export FORGEJO_TOKEN=AGENT_TOKEN' >> ~/.bashrc
```

The container must be able to reach `192.168.1.96:3000`. Check with `curl -I http://192.168.1.96:3000`. Agents pick up `AGENTS.md` and `.cursor/rules/` automatically.

## 9. End-to-end test

Ask the agent: *"Change the GREETING of the hello service to 'deployed by an agent' and open a PR."* Review it, merge it, and within about a minute http://192.168.1.96:8100 should show the new greeting. Komodo → Procedures → `deploy-on-push` shows the run.

## 10. Optional: PR checks with a Forgejo runner

`.forgejo/workflows/validate.yml` runs `validate.py` on every PR. It needs a Forgejo Actions runner with the `docker` label: https://forgejo.org/docs/latest/admin/actions/runner-installation/

Run the runner with its **own** Docker-in-Docker daemon (the documented setup), **not** the NAS's `/var/run/docker.sock`. PR jobs run code from agent-pushed branches, and that code must never get root on a host. Once it works, add `validate` as a required status check in step 7.
