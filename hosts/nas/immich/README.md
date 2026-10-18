# immich (nas)

Immich v3.2.2 on the NAS, already running from a hand-started compose at `/tank/appdata/immich/compose.yml`. This stack is that same set of containers so a merge to `main` lets Komodo own it. The tag sidecar is not part of this stack.

- **URL:** http://192.168.1.96:2283
- **Deploy strategy:** `redeploy-if-changed` (pinned prebuilt images)
- **Secrets:** `[[IMMICH_DB_PASSWORD]]` — Jeff creates this in Komodo → Settings → Variables, marked secret, before merging. The value is the password the running Postgres already uses (the `DB_PASSWORD` in `/tank/appdata/immich/.env`). A new password will not open the existing database.
- **Persistent data:**
  - Library: `/tank/immich/library` (`UPLOAD_LOCATION`, ZFS)
  - Postgres: `/var/lib/immich/postgres` (`DB_DATA_LOCATION`, boot NVMe)
  - ML model cache: named volume `model-cache` (compose project `immich`)
  - `APPDATA` is `/tank/appdata/immich` because every stack sets it. Photos and the database are not stored there.

Do not set `DB_SKIP_MIGRATIONS`. Do not manage this stack from the OMV Compose plugin once Komodo owns it.

Container names match the running stack: `immich_server`, `immich_machine_learning`, `immich_redis`, `immich_postgres`. Images: `ghcr.io/immich-app/immich-server:v3.2.2`, `ghcr.io/immich-app/immich-machine-learning:v3.2.2-openvino`, `valkey/valkey:9`, `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`. Port 2283. `/dev/dri` is passed to the server (Quick Sync) and the machine-learning container (OpenVINO).
