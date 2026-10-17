# hello (nas)

Pipeline smoke test: a stdlib-only Python HTTP service built from source on the NAS.

- **URL:** http://192.168.1.96:8100 (`/healthz` for the health check)
- **Deploy strategy:** `redeploy-always` (built from source)
- **Secrets:** none
- **Persistent data:** none

Safe to delete once the pipeline is proven. Destroy the stack in Komodo first, then remove `hosts/nas/hello/` and `komodo/stacks/nas/hello.toml` in a PR.
