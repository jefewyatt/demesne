# homelab

Every service in the homelab, defined as code. Coding agents (Cursor, etc.) change this repo; merging to `main` deploys.

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
```

Agents never hold deploy credentials or Docker access. Only `main` deploys, and only Jeff can merge to `main`. Each host builds its own images natively, so there is no cross-compiling and no registry.

## Layout

| Path | What |
|---|---|
| `hosts/<host>/<service>/` | The service: `compose.yaml`, plus `Dockerfile`/`src/` if built from source, and a `README.md`. **The directory decides the machine.** |
| `komodo/stacks/<host>/<service>.toml` | Komodo stack definition (one per file, so parallel agents don't collide). |
| `komodo/procedures.toml` | The `deploy-on-push` procedure the webhook triggers. |
| `hosts.toml` | Machines, git settings, reserved ports. Read by both scripts. |
| `scripts/new_service.py` | Scaffolds a service + stack file with correct settings. |
| `scripts/validate.py` | Enforces the conventions in `AGENTS.md`. Agents run it before every PR; CI runs it on PRs. |
| `AGENTS.md`, `.cursor/rules/` | Instructions for coding agents. |
| `bootstrap/` | One-time setup of Forgejo and Komodo. Not deployed by Komodo. |
| `hosts/*/hello*` | Two smoke-test services (one built from source on the NAS, one prebuilt on the Orange Pi). Delete once the pipeline is proven. |

## How a merge becomes a deploy

Each stack is tagged with a deploy strategy:

| Tag | When Komodo redeploys | Use for |
|---|---|---|
| `redeploy-if-changed` | Only when `compose.yaml` (or a file listed in `config_files`) differs from what's deployed | Stacks that only use pinned prebuilt images |
| `redeploy-always` | Every merge: `compose build` + `compose up` | Stacks built from source. Komodo can't see source changes, so it always rebuilds. Unchanged code hits the build cache, the image ID doesn't change, and compose leaves the container alone. |

Ownership is per stack: Komodo owns everything under `hosts/`. Forgejo and Komodo itself are run by hand from `bootstrap/`. Don't manage Komodo-owned stacks from the OMV Compose plugin, and don't add the bootstrap stacks to Komodo.

## Day to day

- **Ask an agent for a change.** It works on a branch, runs `validate.py`, and opens a PR.
- **Review and merge.** If the PR lists secrets, create them first in Komodo → Settings → Variables (mark as secret).
- **Watch it land.** Komodo → Procedures → `deploy-on-push` shows each run; each stack shows build and compose logs.
- **Roll back.** Revert the commit and merge the revert. Data under `APPDATA` isn't touched by deploys.

## Removing a service

1. In Komodo, open the stack and click **Destroy** (stops and removes its containers).
2. Merge a PR deleting `hosts/<host>/<service>/` and `komodo/stacks/<host>/<service>.toml`. The sync then deletes the stack resource.
3. Delete its `APPDATA` directory by hand if you don't want the data.

## First-time setup

See [`bootstrap/README.md`](bootstrap/README.md).
