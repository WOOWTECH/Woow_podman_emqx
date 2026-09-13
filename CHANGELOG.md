# Changelog

## 6.0.0 — 2026-09-12 (BREAKING)

Quadlet + systemd is now the only deployment in this repo.

- **Quadlet units** (`quadlet/`) for rootless podman 4.9+, installed by `scripts/install.sh`. They
  start at boot through linger and restart when the broker crashes. The old compose stack had no boot
  recovery on rootless podman: `restart: unless-stopped` is not restarted by `podman-restart.service`.
- **Anonymous MQTT is off by default** (BREAKING for clients without credentials). EMQX 5 has no
  allow-anonymous switch: a client is anonymous whenever the authentication chain is empty, and
  `EMQX_ALLOW_ANONYMOUS` never worked in 5.x. `config/base.hocon` now declares a built-in-database
  authenticator. The first MQTT user (`WOOW_EMQX_MQTT_USER`, default `woow`) is seeded from a podman
  secret. To allow anonymous clients on a closed network, disable the authenticator in the Dashboard.
- **Generated credentials in podman secrets:** `woow-emqx-dashboard-password`,
  `woow-emqx-mqtt-password` (+ `woow-emqx-mqtt-bootstrap`), `woow-emqx-ngrok-authtoken`. No
  `admin` / `public` default any more.
- **Ports bind 127.0.0.1** by default. `WOOW_EMQX_BIND` and `WOOW_EMQX_PORT_*` in
  `~/.config/emqx/emqx.env` are rendered into the units at install time.
- **Images pinned by digest:** emqx 5.8.9, ngrok 3.39.11-debian (was the floating `:3`).
- **Scripts:** `install.sh`, `upgrade.sh` (unit rollback on failure), `uninstall.sh` (`--purge` is the
  only way to delete data), `backup.sh`, `restore.sh`, `ngrok-url.sh`.
- **Tests and CI:** `tests/dryrun.sh` (Quadlet 4.9.3 dry-run and `systemd-analyze verify`),
  `tests/smoke.sh` (installed-host checks), `tests/lint-repo.sh`, and two GitHub workflows.
- **Removed:** `docker-compose.yml`, `docker-compose.ngrok.yml`, `.env.example`, `podman-quadlet/`
  (its units could not start: `EnvironmentFile=-…` and a hard-coded `public` password), the Portainer
  instructions, and the `.191`-specific "Option A/B". Docker users stay on the `compose-final` tag.

Container, volume and network names are unchanged (`woow-emqx`, `woow_emqx_data`, `woow_emqx_log`,
`woow_emqx_network`), so an existing compose host adopts its data in place. See the README section
"Migrating an existing compose deployment".

## v5.9.0 — 2026-08-26

Parity release with `Woow_ha_emqx` v5.9.0 (HA add-on).

- **Pin EMQX to `5.8.9`** (was floating `latest`). Matches the version bundled in the HA add-on Dockerfile.
- **Built-in ngrok TCP tunnel (opt-in)** — mirrors the HA add-on's ngrok integration.
  - New sidecar service `ngrok` (image `ngrok/ngrok:3`) tunnels raw MQTT (1883).
  - New one-shot `ngrok-announce` polls `http://ngrok:4040/api/tunnels` and logs the public URL (60 × 2s), matching the HA `ngrok-announce` s6 service.
  - Delivered as an overlay file `docker-compose.ngrok.yml` (opt-in via `-f docker-compose.yml -f docker-compose.ngrok.yml`). Compose profiles were rejected because `podman-compose 1.0.6` starts profile services unconditionally, causing crash-loops when `NGROK_AUTHTOKEN` is empty.
  - New env var: `NGROK_AUTHTOKEN`. Reserved TCP address is set by editing the overlay file's `command:` line (not via env — podman-compose 1.0.6 does not honor `${VAR:+...}` conditional expansion).
  - 8083 (MQTT-over-WebSocket) remains out of scope — use Cloudflare Tunnel.
- **Deploy target `.191` (`podman-mcp.woowtech.io`, rootless podman)** — added README section and Quadlet units under `podman-quadlet/` for systemd `--user` auto-start with `loginctl enable-linger`.
- `container_name`, volume names and network name now respect `COMPOSE_PROJECT_NAME` (default `woow`) — avoids collisions when running multiple stacks on the same host.
- Removed the deprecated `version: '3.8'` top-level key from `docker-compose.yml`.
- Fixed EMQX version reference in `README.md` (was `6.0.0`, now `5.8.9`).

## v0.1.0 — 2026-08-05

- Initial split from `Woow_eqmx_docker_compose_all` (branch `podman`, note typo `eqmx` in old repo).
- `emqx/emqx:latest`, ports 1883 / 8883 / 8083 / 8084 / 18083, named volumes `emqx_data` / `emqx_log`.
