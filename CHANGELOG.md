# Changelog

## v5.9.0 — 2026-08-26

Parity release with `Woow_ha_emqx` v5.9.0 (HA add-on).

- **Pin EMQX to `5.8.9`** (was floating `latest`). Matches the version bundled in the HA add-on Dockerfile.
- **Built-in ngrok TCP tunnel (opt-in)** — mirrors the HA add-on's ngrok integration.
  - New sidecar service `ngrok` (image `ngrok/ngrok:3`) tunnels raw MQTT (1883).
  - New one-shot `ngrok-announce` polls `http://ngrok:4040/api/tunnels` and logs the public URL (60 × 2s), matching the HA `ngrok-announce` s6 service.
  - Both services live behind the `ngrok` compose profile — default `up` still starts only EMQX.
  - New env vars: `NGROK_AUTHTOKEN`, `NGROK_TCP_ADDR` (reserved address, optional).
  - 8083 (MQTT-over-WebSocket) remains out of scope — use Cloudflare Tunnel.
- **Deploy target `.191` (`podman-mcp.woowtech.io`, rootless podman)** — added README section and Quadlet units under `podman-quadlet/` for systemd `--user` auto-start with `loginctl enable-linger`.
- `container_name`, volume names and network name now respect `COMPOSE_PROJECT_NAME` (default `woow`) — avoids collisions when running multiple stacks on the same host.
- Removed the deprecated `version: '3.8'` top-level key from `docker-compose.yml`.
- Fixed EMQX version reference in `README.md` (was `6.0.0`, now `5.8.9`).

## v0.1.0 — 2026-08-05

- Initial split from `Woow_eqmx_docker_compose_all` (branch `podman`, note typo `eqmx` in old repo).
- `emqx/emqx:latest`, ports 1883 / 8883 / 8083 / 8084 / 18083, named volumes `emqx_data` / `emqx_log`.
