# AGENTS.md: rules for coding agents working in this repo

This repo is the single source of truth for every service running in Jeff's homelab.
**Merging to `main` deploys.** Komodo watches `main`, syncs `komodo/`, and runs
`docker compose up` on the right machine. Nothing else deploys anything.

## Your role

- Work on a branch. Never push to `main` (it's protected anyway).
- Open a pull request when the work is ready. Jeff reviews and merges; the merge is the deploy.
- You never run deploy commands against the hosts, never touch the Docker socket, and never edit things on the machines directly. If something needs to happen on a host, put it in the repo or write it in the PR description as a manual step for Jeff.
- Before opening or updating a PR, run `python scripts/validate.py` and fix every ERROR. Mention any WARN lines in the PR description.

## Machines

`hosts.toml` is authoritative. Summary:

| Host key   | Arch    | What it is                                  | Persistent data root |
|------------|---------|---------------------------------------------|----------------------|
| `nas`      | amd64   | OMV8 NAS, Intel N150, ZFS pool at `/tank`   | `/tank/appdata`      |
| `orangepi` | arm64   | Orange Pi 6 Plus, Ubuntu 24.04              | `/srv/appdata`       |

Images build **natively on the host that runs them**. A service under `hosts/orangepi/` must work on **arm64**: check that any prebuilt image publishes an arm64 variant (`python scripts/validate.py --check-images` does this if docker is available), and don't assume x86-only binaries or wheels in Dockerfiles.

Heavy, storage-bound or always-on services go on `nas`. Experiments, AI/NPU work and things tied to the Orange Pi's hardware go on `orangepi`. If unsure, ask in the PR.

## Layout

```
hosts/<host>/<service>/compose.yaml     what runs (plus Dockerfile, src/, README.md)
komodo/stacks/<host>/<service>.toml     how Komodo deploys it (one stack per file)
komodo/procedures.toml                  the deploy-on-push procedure: do not edit
hosts.toml                              machines, git settings, reserved ports
scripts/new_service.py                  scaffold a new service
scripts/validate.py                     convention checker; must pass
bootstrap/                              one-time infra setup (Forgejo, Komodo): do not edit
```

The directory a service lives in decides which machine it runs on. Moving a service between hosts means moving its directory **and** its stack file, and Jeff destroying the old stack in Komodo (say so in the PR).

## Adding a service

1. Scaffold it:
   ```
   python scripts/new_service.py <host> <name> --build [--container-port N]
   python scripts/new_service.py <host> <name> --image <image:pinned-tag> [--port HOST:CONTAINER]
   ```
   Host ports are auto-assigned from 8100 upward unless you pass `--port`.
2. Replace every `TODO(new_service)` line: description, healthcheck, Dockerfile.
3. Fill in the service's `README.md`: purpose, URL, secrets Jeff must create, data paths.
4. `python scripts/validate.py` must report 0 errors.

Service names are lowercase-with-dashes and unique across all hosts. The stack name equals the directory name.

## Compose rules (enforced by validate.py)

- **Pinned images.** `nginx:1.28-alpine`, not `nginx` or `nginx:latest`. Floating tags make deploys non-reproducible.
- **`restart: unless-stopped`** on every long-running service.
- **A real healthcheck** on every long-running service, using a tool that exists inside the image.
- **Persistent data under `${APPDATA}`** (e.g. `${APPDATA}/db:/var/lib/postgresql/data`). `APPDATA` is set per stack to `<host appdata root>/<service>`. Named volumes trigger a warning because they live outside the backed-up tree.
- **Repo files mounted into containers** (`./nginx.conf:/etc/nginx/nginx.conf`) must stay inside the service directory. For `redeploy-if-changed` stacks, list each one in the stack's `config_files` or edits will never deploy. Mounting a whole repo directory requires `redeploy-always`. Prefer inline `configs: { name: { content: | ... } }` for small config.
- **Unique host ports per host**, and none of the host's `reserved_ports`.
- **Off by default:** `privileged`, `network_mode: host`, `pid: host`, Docker socket mounts, host paths outside `${APPDATA}`, `devices`, `cap_add`, and services without a healthcheck. If one is genuinely needed, declare it with a reason so it gets reviewed:
  ```yaml
  x-homelab:
    allow:
      devices: "Orange Pi NPU (/dev/...) for inference"
  ```
- Don't set top-level `name:`. Komodo sets the project name from the stack name.

## Build-from-source services

- Tag the stack `redeploy-always` with `run_build = true` and `auto_pull = false` (the scaffold does this). Komodo can't detect source changes, so these stacks rebuild on every merge; unchanged builds hit the cache and their containers aren't recreated.
- Dockerfile: pinned base image tag, multi-stage when there's a compile step, run as a non-root `USER`, no secrets baked in, and keep the build context small (add a `.dockerignore`).
- Give the image a local name: `image: homelab/<service>:local` next to `build: .`.

## Secrets and config

- **Never commit secrets.** Not in compose files, Dockerfiles, `.env` files, or code.
- Reference them through the stack's `environment` block as Komodo secrets, and through `${VAR}` in compose:
  ```toml
  environment = """
  APPDATA = /tank/appdata/myservice
  DB_PASSWORD = [[MYSERVICE_DB_PASSWORD]]
  """
  ```
  ```yaml
  environment:
    POSTGRES_PASSWORD: ${DB_PASSWORD}
  ```
- List each new `[[SECRET_NAME]]` in the service README and the PR description. Jeff creates them in Komodo before merging.
- Non-secret config can go directly in compose `environment:` or the stack `environment` block.

## Removing a service

Don't just delete the files. In the PR, ask Jeff to **Destroy** the stack in Komodo first (deleting the files removes the stack from Komodo but leaves the containers running). Never delete anything under an `APPDATA` path.

## Pull requests

Use this description template:

```
## What
<one paragraph>

## Where
host: <nas|orangepi>   stack: <name>   URL: http://<ip>:<port>

## Before merging (Jeff)
- [ ] Create Komodo secrets: <list or "none">
- [ ] Manual steps on the host: <list or "none">

## Validation
python scripts/validate.py → <paste summary line and any WARN lines>
```

To open a PR from the command line (Forgejo API; `FORGEJO_TOKEN` is the agent's token):

```bash
curl -sS -X POST "http://192.168.1.96:3000/api/v1/repos/jeff/homelab/pulls" \
  -H "Authorization: token $FORGEJO_TOKEN" -H "Content-Type: application/json" \
  -d '{"base":"main","head":"<your-branch>","title":"<title>","body":"<description>"}'
```

## Files you must not edit unless Jeff explicitly asks

`komodo/procedures.toml`, `bootstrap/**`, `.forgejo/**`, `scripts/validate.py` (to loosen a rule), and `hosts.toml`.
