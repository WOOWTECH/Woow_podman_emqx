# EMQX MQTT broker on rootless Podman (Quadlet + systemd)

[繁體中文](README_zh-TW.md)

This repo runs the **EMQX 5.8.9** MQTT broker as rootless Podman
[Quadlet](https://docs.podman.io/en/v4.9.3/markdown/podman-systemd.unit.5.html) units under
`systemd --user`. The broker starts at boot through linger, restarts when it crashes, and gets its
per-host settings from one env file.

Other platforms:
[Woow_k3s_emqx](https://github.com/WOOWTECH/Woow_k3s_emqx) (Kubernetes / Helm) ·
[Woow_ha_emqx](https://github.com/WOOWTECH/Woow_ha_emqx) (Home Assistant add-on)

> **Docker or podman-compose users:** release 6.0.0 removed the compose files. The last compose
> version is kept at the tag
> [`compose-final`](https://github.com/WOOWTECH/Woow_podman_emqx/tree/compose-final)
> (`git clone -b compose-final https://github.com/WOOWTECH/Woow_podman_emqx.git`). That tag is not
> maintained and keeps the old defaults: anonymous MQTT is accepted and the dashboard login is
> `admin` / `public`. Change both before you use it.

## What gets installed

| Item | Name | Notes |
|---|---|---|
| Broker container | `woow-emqx` (unit `emqx.service`) | `docker.io/emqx/emqx:5.8.9`, pinned by digest |
| Network | `woow_emqx_network` (unit `emqx-network.service`) | private bridge |
| Volumes | `woow_emqx_data`, `woow_emqx_log` | the same names the compose stack used, so existing data is adopted |
| Optional tunnel | `woow-emqx-ngrok` (unit `emqx-ngrok.service`) | only with `--with-ngrok` |
| Settings | `~/.config/emqx/emqx.env` (0600), `~/.config/emqx/base.hocon` | created by `scripts/install.sh` |
| Credentials | podman secrets `woow-emqx-*` | generated at install time; never stored in files |

Security defaults:

- **Anonymous MQTT is off.** `config/base.hocon` declares a built-in-database authenticator, and the
  first MQTT user is seeded from a podman secret.
- **The dashboard password is generated.** There is no `admin` / `public` login.
- **Every port binds 127.0.0.1.** Set `WOOW_EMQX_BIND` for a LAN broker.

> **Why anonymous access is off.** EMQX 5 has no allow-anonymous switch for MQTT. A client is treated
> as anonymous whenever the authentication chain is empty, and the `EMQX_ALLOW_ANONYMOUS` variable
> from the EMQX 4 era is silently ignored. So every earlier install of this repo accepted anonymous
> clients, even with that variable set to `false`. Declaring one authenticator is what turns anonymous
> access off.

## Requirements

- Linux with systemd and cgroup v2. Tested on Ubuntu 24.04.
- Podman 4.9 or newer, rootless. Tested with 4.9.3, which is the version in Ubuntu 24.04.
- A normal login session for the user who owns the containers (ssh or console, not `su` or `sudo -u`).
- Linger for that user. `install.sh` enables it; when polkit refuses, it prints the one `sudo` command
  to run.
- Free ports: 1883, 8883, 8083, 8084, 18083. Each one can be moved.
- About 250 MB of disk for the image and about 50 MB of RAM when idle.

## Install

```bash
git clone https://github.com/WOOWTECH/Woow_podman_emqx.git
cd Woow_podman_emqx
scripts/install.sh               # first run: creates ~/.config/emqx/emqx.env and stops so you can review it
nano ~/.config/emqx/emqx.env     # optional: bind address, ports, MQTT user name
scripts/install.sh               # render, validate, pull, create secrets, start, run tests/smoke.sh
```

`install.sh` runs these steps in order. Nothing is installed until rendering and the Quadlet dry-run
pass.

1. Preflight checks, then linger.
2. The env file.
3. The legacy-container guard.
4. Render the units, then run the Quadlet dry-run and `systemd-analyze verify`.
5. Pull the images.
6. Create the podman secrets.
7. Install the units, and restart only the units that changed.
8. Wait for the health check, then run `tests/smoke.sh`.

Useful options:

| Option | Effect |
|---|---|
| `--accept-defaults` | On the first run, keep going with the example settings instead of stopping. |
| `--set KEY=VALUE` | Store a setting in the env file first. You can repeat it. Only keys from `config/emqx.env.example` are accepted, and credentials never are. |
| `--with-ngrok` / `--without-ngrok` | Add or remove the ngrok tunnel. See [ngrok](#ngrok-tcp-tunnel-optional). |
| `--dry-run` | Render and validate, and show what would change, without touching anything. |
| `--no-start`, `--no-smoke` | Install without starting; skip the smoke test. |

A non-interactive install on moved ports, for example on a host where the standard ports are taken:

```bash
scripts/install.sh --set WOOW_EMQX_PORT_MQTT=21883 --set WOOW_EMQX_PORT_DASHBOARD=28083
```

Running `install.sh` again is safe. With nothing changed, it restarts nothing.

## Configure

Edit `~/.config/emqx/emqx.env`, then run `scripts/install.sh` again. It re-renders the units and
restarts the broker only when something it reads has changed.

| Key | Default | Meaning |
|---|---|---|
| `WOOW_EMQX_BIND` | `127.0.0.1` | Address the ports are published on: `127.0.0.1`, an IPv4 address of this host, or `all` (IPv4 and IPv6). |
| `WOOW_EMQX_PORT_MQTT` | `1883` | MQTT over TCP |
| `WOOW_EMQX_PORT_MQTTS` | `8883` | MQTT over TLS (EMQX's bundled self-signed certificate) |
| `WOOW_EMQX_PORT_WS` / `_WSS` | `8083` / `8084` | MQTT over WebSocket / secure WebSocket |
| `WOOW_EMQX_PORT_DASHBOARD` | `18083` | Dashboard and REST API |
| `WOOW_EMQX_MQTT_USER` | `woow` | MQTT user seeded on first start |
| `WOOW_EMQX_NGROK` | `0` | `1` runs the ngrok tunnel (set by `--with-ngrok`) |
| `WOOW_EMQX_NGROK_REMOTE_ADDR` | empty | Reserved ngrok TCP address, for example `1.tcp.ngrok.io:12345` |
| `EMQX_*` | | Any EMQX setting, passed to the broker unchanged (`EMQX_LOG__CONSOLE__LEVEL=info`, ...) |

The env file must not hold credentials. `install.sh` refuses keys ending in `PASSWORD`, `SECRET`,
`TOKEN` or `_KEY` that have a value.

### Secrets

| Podman secret | Used for | How it reaches EMQX |
|---|---|---|
| `woow-emqx-dashboard-password` | Dashboard user `admin` | env `EMQX_DASHBOARD__DEFAULT_PASSWORD`. EMQX reads it only on the first boot of an empty data volume. |
| `woow-emqx-mqtt-password` | MQTT user `WOOW_EMQX_MQTT_USER` | Not mounted. It is the source of the bootstrap file below. |
| `woow-emqx-mqtt-bootstrap` | Seeds the MQTT user | A 0400 file for the `emqx` user. EMQX imports it when the authenticator starts and never overwrites an existing user. |
| `woow-emqx-ngrok-authtoken` | ngrok | env `NGROK_AUTHTOKEN` for the tunnel container, created with `--with-ngrok` only |

Read a value in a private terminal:

```bash
podman secret inspect --showsecret --format '{{.SecretData}}' woow-emqx-dashboard-password
```

To rotate the dashboard password, change it in the Dashboard first (user menu > Change password),
then update the recorded copy. `read -s` and `printf` keep the value out of your shell history and
out of any process's arguments:

```bash
read -rs -p 'new dashboard password: ' p; printf '%s' "$p" | podman secret create --replace woow-emqx-dashboard-password -; unset p
```

To rotate the MQTT password, change it in the Dashboard (Authentication > Built-in Database > Users),
then replace `woow-emqx-mqtt-password` the same way and run `scripts/install.sh`. The bootstrap file
is updated too. The import never overwrites an existing user, so the Dashboard change is what counts.

## Connect

- **Dashboard:** `http://127.0.0.1:18083/`, user `admin`, password from the secret above. From
  another machine, use `ssh -L 18083:127.0.0.1:18083 <host>`, the Cloudflare tunnel, or NPM.
- **MQTT test** with the seeded user. The password goes through a 0600 options file, not the
  command line:

  ```bash
  mkdir -p -m 700 ~/.config/woow-mqtt
  (umask 077; printf -- '-u woow\n-P %s\n' \
    "$(podman secret inspect --showsecret --format '{{.SecretData}}' woow-emqx-mqtt-password)" >~/.config/woow-mqtt/mosquitto_pub)
  XDG_CONFIG_HOME=~/.config/woow-mqtt mosquitto_pub -h 127.0.0.1 -p 1883 -t test/topic -m hello
  ```

- **Anonymous clients are refused** with `Connection Refused: not authorised`. That is expected. To
  deliberately allow anonymous access on a closed network, disable the authenticator in the Dashboard.
  The change is stored in `cluster.hocon`, which outranks `base.hocon`.
- **Check everything:** `tests/smoke.sh` (use `--quick` to skip the MQTT client checks).

## ngrok TCP tunnel (optional)

This tunnel publishes raw MQTT (1883) on the internet. It is safe only because authentication is
enforced, and `install.sh` stops the tunnel whenever the smoke test fails.

```bash
NGROK_AUTHTOKEN=<your-token> scripts/install.sh --with-ngrok   # or omit the variable and type it at the hidden prompt
scripts/ngrok-url.sh                                           # tcp://N.tcp.ngrok.io:PORT
scripts/install.sh --without-ngrok                             # remove the tunnel again
```

For a stable address, reserve one in the ngrok dashboard and set `WOOW_EMQX_NGROK_REMOTE_ADDR`.
WebSocket (8083) is not tunneled; use the Cloudflare tunnel for that.

## Upgrade

The image versions are pinned in this repo. To upgrade, pull the repo and run the upgrade script:

```bash
git pull
scripts/upgrade.sh            # add --cold before an EMQX major-version upgrade
```

`upgrade.sh` does the following:

1. Takes a backup.
2. Saves the installed units.
3. Runs `install.sh`, which pulls the new images before touching any unit.
4. Runs the smoke test.

If step 3 or 4 fails, it puts the previous units back and restarts the broker on the previous image.
Data that a newer EMQX has already migrated is not rolled back automatically. Restore the pre-upgrade
backup with `restore.sh` if you have to go back across a major version.

## Backup and restore

```bash
scripts/backup.sh             # hot: emqx ctl data export (config, users, rules, retained messages)
scripts/backup.sh --cold      # plus a full export of the woow_emqx_data volume (brief downtime)
scripts/restore.sh --archive ~/.local/share/woow-backups/emqx/backup-<ts>/emqx-export-<...>.tar.gz --confirm-restore emqx
scripts/restore.sh --archive ~/.local/share/woow-backups/emqx/backup-<ts>/woow_emqx_data-<ts>.tar --confirm-restore emqx
```

Backups go to `~/.local/share/woow-backups/emqx/`: files are 0600, directories 0700, with a
`SHA256SUMS` file. A logical export is imported into the running broker. A volume export replaces
the data volume after a pre-restore copy is taken.

## Uninstall

```bash
scripts/uninstall.sh                 # remove the units; keep volumes, network, secrets, settings and backups
scripts/uninstall.sh --purge         # also delete volumes, network, secrets and ~/.config/emqx (asks you to type "emqx")
```

`--purge` is the only command that deletes data, and it takes a final backup of the data volume and
the env file first. Images and backups are never deleted.

## Migrating an existing compose deployment

The Quadlet units use the compose names (container `woow-emqx`, volumes `woow_emqx_data` and
`woow_emqx_log`, network `woow_emqx_network`, node name `emqx@127.0.0.1`), so the migration adopts the
data in place.

1. **Back up.** Run `podman exec woow-emqx emqx ctl data export` and copy the file out. Also run
   `podman volume export woow_emqx_data -o woow_emqx_data.tar` and save
   `podman inspect woow-emqx > legacy-inspect.json`.
2. **Seed the secrets from the old `.env`** so the recorded copies match reality. Pipe them in; never
   echo them.
   - `grep '^EMQX_DASHBOARD_PASSWORD=' .env | cut -d= -f2- | tr -d '\n' | podman secret create woow-emqx-dashboard-password -`
   - Do the same for the MQTT user's password into `woow-emqx-mqtt-password`, and set
     `WOOW_EMQX_MQTT_USER`.
3. **Remove the compose container:** `podman stop woow-emqx && podman rm woow-emqx`.
   - If it was started with `restart: always`, do not just rename it. With `podman-restart.service`
     enabled it would start again at every boot and fight for the ports, and podman 4.9 cannot change
     a container's restart policy.
   - Otherwise, `install.sh` refuses to replace a container it does not manage and prints a
     `podman rename` command. You can keep the old container that way for rollback.
4. **Install:** `scripts/install.sh`, then `tests/smoke.sh`. A dashboard or Dashboard-created
   authenticator in the volume's `cluster.hocon` outranks `base.hocon`, so the existing users and
   settings stay.
5. **Roll back if needed:** `scripts/uninstall.sh`, then start the old compose project again from
   the `compose-final` checkout. Both paths use the same volumes.

## Files

```
quadlet/                 Quadlet units with @@VAR@@ tokens; quadlet/render-vars lists the allowed variables
quadlet/optional/        the ngrok tunnel unit
config/emqx.env.example  template for ~/.config/emqx/emqx.env
config/base.hocon        authenticator defaults, installed to ~/.config/emqx/base.hocon
scripts/                 install, upgrade, uninstall, backup, restore, ngrok-url
scripts/render-args.sh   values computed from the env file (shared by install.sh and tests/dryrun.sh)
scripts/lib/             vendored quadlet-lib (do not edit; CI checks its hash)
tests/dryrun.sh          render + Quadlet 4.9.3 dry-run + systemd-analyze verify (CI and local)
tests/smoke.sh           post-install checks on a host
tests/lint-repo.sh       credential scan, compose removal, README and EMQX invariants (CI)
```

Development checks, all static, no containers: `bash tests/dryrun.sh`,
`shellcheck -x scripts/*.sh tests/*.sh`, `tests/lint-repo.sh`.

## Troubleshooting

| Symptom | Check |
|---|---|
| `install.sh` says a container exists and is not managed | Stop whatever runs it (compose, a hand-written unit), then use the printed `podman rename`, or remove it (see migration). |
| `emqx.service` fails right after install | `journalctl --user -u emqx.service -n 100` and `podman logs woow-emqx`. A port in use shows up here: check `ss -tlnp`. |
| Dashboard login fails on an adopted volume | The admin password lives in the data volume. The secret only matters on an empty volume. |
| MQTT clients get "not authorised" | Anonymous access is off. Use a user from the built-in database (Dashboard > Authentication). |
| Units are gone after logout or reboot | `loginctl show-user $USER -p Linger` must say `yes`. |
| `systemctl --user` fails over `su` or `sudo` | Log in as the user over ssh or the console, or `export XDG_RUNTIME_DIR=/run/user/$(id -u)`. |
