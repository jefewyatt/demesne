# hello-static (orangepi)

Pipeline smoke test: prebuilt `nginx:1.28-alpine` (multi-arch, so it runs on arm64) serving one inline page.

- **URL:** http://<orangepi-ip>:8100
- **Deploy strategy:** `redeploy-if-changed` (prebuilt image; content is inline in compose.yaml)
- **Secrets:** none
- **Persistent data:** none

Safe to delete once the pipeline is proven. Destroy the stack in Komodo first, then remove the files in a PR.
