# Rehearsal of `scripts/migrate-legacy.sh` on toypark1234, 2026-09-14

Evidence for the P6 migration script. Nothing in this file is a plan: every line below is output
from a real run. `woowtechopenclaw` was **not** touched — it was read, read-only, for the facts the
script depends on (image id, restart policy, published ports, node name, writable-layer size).

## What was stood up

The compose deployment of this repository's own `compose-final` tag, in `~/p6-rehearsal-emqx`, with
the untracked `docker-compose.autostart.yml` overlay that openclaw carries (`{emqx: {restart:
always}}`) — so the rehearsal container really has the restart policy that makes this stack the hard
one. Isolated high ports, all on `127.0.0.1` as openclaw publishes them:

| | openclaw | rehearsal |
|---|---|---|
| MQTT / MQTTS / WS / WSS / dashboard | 1883 / 8883 / 8083 / 8084 / 18083 | 41883 / 48883 / 48083 / 48084 / 41808 |
| container, volumes, network | `woow-emqx`, `woow_emqx_data`, `woow_emqx_log`, `woow_emqx_network` | the same (toypark had none of those names) |
| image | `docker.io/emqx/emqx:5.8.9` id `3f60addfad2b` | the same id |
| restart policy | `always` | `always` |
| node name | `emqx@127.0.0.1` | `emqx@127.0.0.1` |
| writable layer (`.SizeRw`) | 11 336 B | 11 337 B |

```
woow-emqx|Up 27 seconds (starting)|docker.io/emqx/emqx:5.8.9
policy=always node=emqx@127.0.0.1
SizeRw=11337
woow_emqx_log|/opt/emqx/log
woow_emqx_data|/opt/emqx/data
dashboard HTTP 200 after 10s
Node 'emqx@127.0.0.1' 5.8.9 is started
```

## How the `capture` path was reached without touching `podman-restart.service`

toypark's `podman-restart.service` is **disabled** and was left that way — `systemctl --user
is-enabled podman-restart.service` still answers `disabled` on that host. `ql_podman_restart_enabled`
is the single place the library asks that question, so the decision boundary was shimmed: a wrapper
first on `PATH` that answers exactly

```sh
[ "$1" = --user ] && [ "$2" = is-enabled ] && [ "$3" = podman-restart.service ] && { echo enabled; exit 0; }
exec /usr/bin/systemctl "$@"
```

and passes every other `systemctl` call straight through to the real binary. Everything else in the
run was real: a real container with a real `always` policy, a real `ql_capture_container`, a real
`podman rm`, a real `ql_recreate_container`.

The first `--dry-run` was taken **without** the shim, to show the decision really is host-driven:

```
migrate-legacy.sh: podman-restart.service is not enabled for this user, so renaming and leaving
the legacy container(s) stopped is safe
... The cutover would stop woow-emqx, rename it to woow-emqx-legacy-20260914 and install:
```

and the second **with** it:

```
WARNING: podman-restart.service is enabled for this user: at boot it runs 'podman start --all
--filter restart-policy=always', which would revive woow-emqx(always) next to the new Quadlet
container(s)
WARNING: podman 4.9.3 cannot change a restart policy in place (podman update is cgroup-only), so
renaming is not enough here: capture the container(s) and remove them
woow-emqx: writable layer is 11337 bytes; nothing worth committing
... The cutover would stop woow-emqx, capture it into the backup directory (without --commit) and
remove it, because podman-restart.service would revive a renamed copy here, and then install:
```

## `--prepare-only`: the capture is written while the broker still serves

```
exported volume woow_emqx_data -> .../migrate-20260914-023532/woow_emqx_data-...tar (84K)
exported volume woow_emqx_log  -> .../woow_emqx_log-...tar (4.0K)
woow-emqx: writable layer is 11337 bytes; nothing worth committing
captured container woow-emqx -> .../legacy-container/woow-emqx (policy=always,
  image=docker.io/emqx/emqx:5.8.9, recreatable=1)
--- the broker is still serving during prepare ---
dashboard HTTP 200
woow-emqx|Up 3 minutes (healthy)
```

The capture directory is 0700 with 0600 files (the inspect carries the dashboard password):

```
IMAGE_REF=docker.io/emqx/emqx:5.8.9
IMAGE_ID=3f60addfad2bfc6c09400aa48cfbc1b2b2aab04fb6a64d6392c016e02d7fb57b
RESTART_POLICY=always
COMMIT_IMAGE=
RECREATABLE=1
IMAGE_ARGV_INDEX=57
```

## Cutover: the adoption is proved, not assumed

```
adopted woow_emqx_data in place: mountpoint|CreatedAt|inode unchanged
  (/home/toypark1234/.local/share/containers/storage/volumes/woow_emqx_data/_data
   |2026-09-14 02:32:00.389631511 +0800 CST|1049717)
adopted woow_emqx_log in place: mountpoint|CreatedAt|inode unchanged
  (.../woow_emqx_log/_data|2026-09-14 02:32:00.700892189 +0800 CST|1049719)
the dashboard admin password now matches the woow-emqx-dashboard-password secret
PASS A1 emqx.service is active
PASS A2 woow-emqx is healthy
PASS A3 five ports published on 127.0.0.1
PASS A4 dashboard login with the generated password
PASS A4 admin/public is rejected
PASS A5 anonymous MQTT is refused (bad user name or password)
PASS A6 authenticated publish/subscribe as woow
PASS A7 bootstrap CSV is 0400 emqx
PASS A7 base.hocon is mounted read-only
WARN A8 podman inspect shows the env-type dashboard secret (podman behaviour; ...)
PASS A8 no secret in the journal, the container log or (for the MQTT password) podman inspect
10 passed, 0 failed, 1 warnings
before: status=Node 'emqx@127.0.0.1' 5.8.9 is started  connections=0 subscriptions=0 retained=0
after:  status=Node 'emqx@127.0.0.1' 5.8.9 is started  connections=0 subscriptions=0 retained=0
measured downtime: 42s (from 'podman stop woow-emqx' to the Quadlet broker answering)
migration complete. woow-emqx was captured into .../legacy-container and removed, because
podman-restart.service is enabled here and a renamed copy with restart-policy=always would have
revived at the next boot.
```

The inodes are the same before and after — the same two directories, not new ones. A `.volume`
that had lost `VolumeName=` would have produced `systemd-emqx-data` with a different inode and a
different `CreatedAt`, and the cutover would have failed and rolled back.

## `--rollback`, on the capture path, from a separate invocation

```
emqx: units stopped and 5 installed file(s) removed
emqx: kept volumes (woow_emqx_log woow_emqx_data), networks (woow_emqx_network), secrets, images
recreated container woow-emqx from .../legacy-container/woow-emqx (restart policy always, stopped)
http://127.0.0.1:41808/ -> 200
rolled back: the legacy EMQX runs again.
rollback wall time: 14s
--- the legacy container is back, with its policy, and serving ---
woow-emqx|Up 9 seconds (starting)|podman-compose@compose.service
policy=always image=docker.io/emqx/emqx:5.8.9
legacy dashboard HTTP 200
Node 'emqx@127.0.0.1' 5.8.9 is started
--- the Quadlet units are gone ---
inactive
no emqx quadlet files left
```

`restart policy always` is the part that matters: podman 4.9.3 cannot set a policy after create, so
`ql_recreate_container` has to put it back into the replayed `podman create`, and a container that
came back as `no` would not be the container that was removed.

Then the stack was migrated **forward again** (same capture path, 10/10 smoke checks), and a third
run was a no-op:

```
already migrated on 2026-09-14T02:56:00+08:00: emqx.service is installed and woow-emqx is running.
Nothing to do
rc=0
```

## Two pre-existing bugs the rehearsal found

1. **`tests/smoke.sh` A5 could never pass.** It looked for `not authori` in the client output, but
   EMQX 5.8.9 refuses an empty username with CONNACK code 4:

   ```
   === anonymous publish (MQTT 3.1.1, the default) ===
   rc=4 / Connection error: Connection Refused: bad user name or password.
   === a WRONG password ===
   rc=4 / Connection error: Connection Refused: bad user name or password.
   === the same client WITH the right credentials ===
   rc=0
   === emqx ctl conf show authentication ===
   authentication = [ { backend = built_in_database  bootstrap_file = ...  enable = true ... } ]
   ```

   Anonymous is genuinely refused; only the classification was wrong. Fixed in this branch. An
   anonymous client that is *accepted* is still a FAIL.

2. **`ql_lock`'s file descriptor leaks into the containers the scripts start.** The second cutover
   died with `another install/upgrade/uninstall of emqx is running`. The lock is opened with
   `exec {fd}>lock`, which bash does not mark close-on-exec, so it is inherited:

   ```
   /proc/1504119 -> rootlessport
   /proc/1504161 -> rootlessport-child
   /proc/1504170 -> /usr/bin/conmon --api-version 1 -c 2fc181900fd4...
   ```

   and held for as long as the container runs. Two of toypark's twelve app locks were held that way
   (`emqx` and `odoo18`), so this is not specific to this repo. The worst consequence is that
   `--rollback` is refused. The vendored library is not edited (decision D8); everything in this
   repo's migration that can start a container goes through `app_unlocked`, which closes the
   descriptor for that command. **The real fix belongs in quadlet-lib.**

## Cleanup

```
uninstall.sh --purge --yes
  -> units stopped and 5 installed file(s) removed
  -> removed volume woow_emqx_log / woow_emqx_data, network woow_emqx_network,
     secrets woow-emqx-{dashboard-password,mqtt-bootstrap,mqtt-password}
containers: none / volumes: none / networks: none / secrets: none
Untagged: docker.io/emqx/emqx:5.8.9   (removed by exact reference, never a prune)
quadlet files: none / user units: none / config: none
failed units: (empty)
```

`~/p6-rehearsal-emqx`, `~/.config/emqx`, `~/.local/state/woow-quadlet/emqx` and
`~/.local/share/woow-backups/emqx` were removed. The 16 live Quadlet stacks were untouched
throughout and no `podman stop -a`, `system prune`, `system reset` or `volume prune` was ever run —
every removal named its object. The pre-existing stray network `podman_default` was left exactly as
found.

## Tests

`tests/rollback-model.sh`: **19 passed, 0 failed**, and all 19 were red-checked — each test was
re-run against a deliberately broken copy of the code it pins and had to fail. The exercise found a
weak test (it matched the script's header comment rather than a call site) and that test was
tightened.
