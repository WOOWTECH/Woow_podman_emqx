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
   `--rollback` is refused. The vendored library was not edited (decision D8); everything in this
   repo's migration that could start a container went through `app_unlocked`, which closed the
   descriptor for that command. **The real fix belongs in quadlet-lib.**

   **Fixed upstream.** quadlet-lib 1.5.0 removes the descriptor altogether: the lock is now the
   directory `<state>/<app>/lock.d` holding an owner record of boot id, pid and pid start time, and
   "held" means that owner is still running, so a crashed lock is taken over rather than waited on.
   `QL_LOCK_FD` remains only as an always-empty variable, which makes `app_unlocked` a no-op, so the
   wrapper and its call sites are gone from this branch and the tests below pin 1.5.0's contract
   instead of the wrapper. See "Re-rehearsed against quadlet-lib 1.5.0".

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

## Re-rehearsed against quadlet-lib 1.5.0

The whole rehearsal above was run again on toypark1234 on 2026-09-14 after `main` moved to
quadlet-lib 1.5.0 and `app_unlocked` was removed, because the lock change touches exactly the path
the rehearsal exercises. Same shape: this repo's `compose-final` tag in `~/p6-rebase-emqx` with the
`restart: always` overlay, openclaw's object names, the same isolated high ports, and the same
`systemctl is-enabled` shim to reach the capture path on a host whose `podman-restart.service` is
genuinely disabled.

```
woow-emqx|Up 37 seconds (healthy)|docker.io/emqx/emqx:5.8.9
policy=always project=woow_podman_emqx   SizeRw=11294
--dry-run without the shim -> rename ; with the shim -> capture and remove
--prepare-only: both volumes exported, container captured, dashboard still HTTP 200
cutover      : volumes adopted in place (inode 1352576 / 1354172 unchanged), 10 passed 0 failed,
               measured downtime 42s
--rollback   : recreated woow-emqx with restart policy always, dashboard 200, 15s, units gone
forward again: 10 passed 0 failed, downtime 42s
third run    : "already migrated ... Nothing to do", rc=0
```

The point of the re-run was the lock, and it is the one thing that behaves differently:

```
--- lock state after every stage ---
lock.d absent ; processes holding an fd into the emqx state dir: NONE
```

Under 1.4.0 this directory's predecessor was held open by `conmon` and `rootlessport` for the life
of the container, which is what refused `--rollback`. There is now no descriptor to inherit, and
`--rollback` ran from a separate invocation with the new broker still up.

One thing the new contract makes visible: `scripts/migrate-legacy.sh` sets `trap 'rm -rf "$WORK"'
EXIT` after it has taken the lock, which replaces the release handler `ql_lock` chained onto that
trap, so the lock directory is left behind on the `--dry-run` / `--prepare-only` paths and the next
run reports

```
WARNING: emqx: taking over the lock left behind by pid 1886000, which is no longer running
```

That is 1.5.0 working as designed (a dead owner is taken over, never waited on) and it blocks
nothing, but it is noise: `scripts/install.sh` has the same lock-then-`trap` ordering. Setting the
trap before the lock, or adding `ql_unlock` to the trap body, would remove the warning. Left as is
here because `install.sh`'s ordering is main's, not this branch's.

## Tests

`tests/rollback-model.sh` after the 1.5.0 merge. The six lock tests replace
`t_app_unlocked_closes_the_inherited_lock_descriptor` (which asserted that `ql_lock` publishes
`QL_LOCK_FD` and that a plain child inherits the descriptor - both false by design in 1.5.0, so it
failed on the new main) and `t_everything_that_starts_a_container_runs_through_app_unlocked`. Each
of the six was red-checked against a deliberately broken copy of the library: `QL_LOCK_FD`
republished, a dead owner treated as alive, a live owner treated as dead, `QL_LOCK_HELD` not
published, and the lock never released. All six had to fail, and the last of those reproduced the
original error verbatim - `another install/upgrade/uninstall of emqx is running`.

```
$ bash tests/rollback-model.sh
ok    t_a_child_script_reuses_the_lock_its_caller_holds
ok    t_a_container_from_another_compose_project_is_refused
ok    t_a_container_that_grew_a_writable_layer_is_committed
ok    t_a_container_with_no_compose_label_is_warned_about_not_refused
ok    t_a_crashed_run_does_not_block_the_lock_for_ever
ok    t_a_rollback_can_take_the_lock_after_an_earlier_run_left_processes_behind
ok    t_a_second_live_run_is_still_refused
ok    t_always_policy_with_a_disabled_unit_is_still_rename
ok    t_an_unmeasurable_writable_layer_warns_instead_of_committing_silently
ok    t_capture_is_idempotent_between_prepare_only_and_the_cutover
ok    t_capture_refuses_a_container_the_library_cannot_replay
ok    t_disabled_restart_unit_keeps_the_rename_path
ok    t_emqx_writable_layer_is_too_small_to_commit
ok    t_enabled_restart_unit_and_always_policy_takes_the_capture_path
ok    t_migrate_legacy_asks_the_host_instead_of_refusing
ok    t_no_1_4_0_lock_workaround_survives_in_the_scripts
ok    t_retire_refuses_to_remove_without_a_capture
ok    t_the_capture_is_taken_before_any_downtime
ok    t_the_capture_path_never_removes_the_volumes
ok    t_the_lock_keeps_no_descriptor_for_a_child_to_inherit
ok    t_the_migration_checks_the_project_label_before_touching_anything
ok    t_the_rollback_recreates_the_captured_broker_with_restart_policy_always
ok    t_the_units_adopt_the_compose_era_names
ok    t_volume_identity_changes_when_the_volume_is_not_the_same_one
ok    t_volume_identity_fails_loudly_for_a_volume_that_is_gone
ok    t_volume_identity_is_mountpoint_createdat_and_inode

26 passed, 0 failed
```
