#!/usr/bin/env bash
# scripts/migrate-legacy.sh: move the compose-era EMQX deployment (podman-compose project
# woow_podman_emqx: container woow-emqx, volumes woow_emqx_data and woow_emqx_log, network
# woow_emqx_network) to the Quadlet units of this repo. The two volumes and the network are
# adopted exactly where they are - nothing is copied - and the adoption is proved after the
# install by comparing each volume's mountpoint, inode and CreatedAt with the values read
# before the cutover.
#
#   scripts/migrate-legacy.sh [--legacy-dir DIR] [--suffix YYYYMMDD] [--keep-dashboard-password]
#                             [--prepare-only | --dry-run] [--no-auto-rollback] [--yes]
#   scripts/migrate-legacy.sh --rollback [--yes]
#   scripts/migrate-legacy.sh --status
#
#   --legacy-dir DIR   the compose checkout (default: ~/Woow_podman_emqx). Only read: its .env
#                      and the compose files are copied into the backup.
#   --container NAME   the legacy container (default: woow-emqx)
#   --suffix S         the legacy container becomes <name>-legacy-S (default: today). Used on
#                      the rename path only; see "Rollback shape" below.
#   --keep-dashboard-password
#                      leave the dashboard admin password as the legacy one. By default the cutover
#                      sets it to the value of the woow-emqx-dashboard-password secret, because EMQX
#                      seeds EMQX_DASHBOARD__DEFAULT_PASSWORD only into an *empty* data volume: on
#                      an adopted volume the generated secret is inert, the old password is still in
#                      force, and tests/smoke.sh check A4 (log in with the recorded secret) fails.
#                      With --keep-dashboard-password the cutover skips smoke's A4 instead and says
#                      how to align them later.
#   --prepare-only     steps 1-2 only, no downtime: checks, hot backup, and the rollback copy
#   --dry-run          step 1 plus a render of the units; changes nothing
#   --no-auto-rollback leave a failed cutover in place for inspection
#   --rollback         undo the cutover: remove the Quadlet units (the volumes and the network
#                      are kept), bring the legacy container back and start it
#
# Rollback shape (STANDARD 7a): woow-emqx is the one container in the fleet whose restart policy
# is `always`, and on woowtechopenclaw the user unit podman-restart.service is enabled - at boot
# it runs `podman start --all --filter restart-policy=always`. A renamed-and-stopped woow-emqx
# would therefore revive at the next boot and fight the new Quadlet container for its name, its
# five ports and both volumes, and podman 4.9.3 cannot clear a restart policy in place (podman
# update is cgroup-only). So on such a host the legacy container is captured into the backup
# directory and removed, and --rollback recreates it with ql_recreate_container, restart policy
# and all. Where podman-restart.service is disabled the cheaper rename path is used instead.
# ql_rollback_strategy asks this host's real state, never its name; --dry-run reports which path
# a cutover would take. The capture is taken in step 2, before any downtime.
#
# Steps:  1 pre-flight checks (read-only)
#         2 hot backup of both volumes, inspect, compose files, and the rollback copy
#         3 stop the legacy container, cold export, retire it (rename or capture+remove)
#         4 scripts/install.sh adopts woow_emqx_data, woow_emqx_log and woow_emqx_network
#         5 prove the adoption, tests/smoke.sh, compare with the pre-cutover snapshot
#         6 --rollback when needed
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"
# shellcheck source=legacy-common.sh
. "$REPO/scripts/legacy-common.sh"

APP_STATE_DIR=$(app_state_dir)
STATE=$APP_STATE_DIR/migration.state
# The names the Quadlet units adopt. Changing one here without changing quadlet/*.volume and
# quadlet/*.network would start the new stack on empty data, which is the failure this guards.
DATA_VOLUME=woow_emqx_data
LOG_VOLUME=woow_emqx_log
LEGACY_NETWORK=woow_emqx_network
# The podman-compose project label the legacy container must carry (the directory it was deployed
# from). A same-named container from any other project is refused, not retired.
LEGACY_PROJECT=woow_podman_emqx
NODE_NAME=emqx@127.0.0.1
UNIT=emqx.service

mode=migrate legacy_dir=$HOME/Woow_podman_emqx container=woow-emqx suffix=$(date +%Y%m%d) dash_aligned=0
keep_dash=0 auto_rollback=1 yes=0
while (($#)); do
  case $1 in
    --legacy-dir) legacy_dir=${2:?--legacy-dir needs a directory}; shift ;;
    --container) container=${2:?--container needs a name}; shift ;;
    --suffix) suffix=${2:?--suffix needs a value}; shift ;;
    --keep-dashboard-password) keep_dash=1 ;;
    --prepare-only) mode=prepare ;;
    --dry-run) mode=dry-run ;;
    --no-auto-rollback) auto_rollback=0 ;;
    --rollback) mode=rollback ;;
    --status) mode=status ;;
    --yes) yes=1 ;;
    -h | --help) sed -n '2,48p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_assert_match --suffix "$suffix" '[A-Za-z0-9._-]+'
ql_assert_match --container "$container" '[A-Za-z0-9][A-Za-z0-9_.-]*'
LEGACY_CONTAINERS=("$container")

# ---- a small state file: what the cutover did, so --rollback needs no arguments ---------------
state_get() { if [[ -f $STATE ]]; then sed -n "s/^$1=//p" "$STATE" | tail -n1; fi; }
state_set() {
  local tmp
  (umask 077 && mkdir -p "$APP_STATE_DIR")
  tmp=$(mktemp "$APP_STATE_DIR/.migration.XXXXXX")
  { if [[ -f $STATE ]]; then grep -v "^$1=" "$STATE" || true; fi; printf '%s=%s\n' "$1" "$2"; } >"$tmp"
  mv -f "$tmp" "$STATE"
}

if [[ $mode == status ]]; then
  if [[ -f $STATE ]]; then cat "$STATE"; else echo "no migration recorded in $STATE"; fi
  exit 0
fi

ql_preflight "$PODMAN_MIN"
ql_lock "$APP"
unit_exists() { [[ -n $(systemctl --user show -p FragmentPath --value "$1" 2>/dev/null) ]]; }
quadlet_installed() { [[ -s $APP_STATE_DIR/manifest ]] && unit_exists "$UNIT"; }
running() { [[ $(podman inspect --format '{{.State.Status}}' "$1" 2>/dev/null) == running ]]; }
now_s() { date +%s; }

# set_dashboard_password: put the woow-emqx-dashboard-password secret into the broker's own user
# database. The value goes in over stdin and is read by a shell inside the container, so it never
# appears in this host's process list.
set_dashboard_password() {
  local pw
  pw=$(app_secret_read woow-emqx-dashboard-password) || return 1
  [[ -n $pw ]] || return 1
  printf '%s' "$pw" | podman exec -i "$container" sh -c \
    'read -r p; emqx ctl admins passwd admin "$p" >/dev/null' 2>/dev/null
}

# =============================================================================================
# 6. rollback
# =============================================================================================
rollback() {
  local status sfx bk c port
  status=$(state_get STATUS) sfx=$(state_get SUFFIX) bk=$(state_get BACKUP)
  [[ $status == cutover || $status == "done" ]] || ql_die "nothing to roll back (migration status: ${status:-none})"
  app_confirm ROLLBACK "$yes" "--rollback removes the EMQX Quadlet units and brings the legacy container back"
  ql_info "stopping and removing the Quadlet units (both volumes, the network and the secrets are kept)"
  ql_uninstall_units "$APP"
  rm -f -- "$APP_STATE_DIR/applied-env.sha256"
  for c in "${LEGACY_CONTAINERS[@]}"; do
    if podman container exists "$c"; then
      [[ $(podman inspect --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "$c") == "$UNIT" ]] \
        || ql_die "container $c exists and is not a Quadlet leftover; resolve it by hand"
      podman rm -f "$c" >/dev/null
    fi
  done
  # renamed back, or recreated from the capture the cutover took - whichever the host needed
  app_legacy_restore "$sfx" "$bk" "${LEGACY_CONTAINERS[@]}"
  podman start "${LEGACY_CONTAINERS[@]}" >/dev/null || ql_die "could not start the legacy container again"
  port=$(state_get LEGACY_PORT_DASHBOARD)
  ql_wait_http "http://127.0.0.1:${port:-18083}/" '200' 180 \
    || ql_die "the legacy EMQX dashboard did not answer on 127.0.0.1:${port:-18083} after the rollback"
  state_set STATUS rolled-back
  ql_info "rolled back: the legacy EMQX runs again. Backup of the attempt: $bk"
  ql_info "the volumes were adopted in place and never rewritten, so no data restore is needed;"
  ql_info "the cold exports in $bk are there only if the data itself were damaged (README, 'Rollback')"
}

if [[ $mode == rollback ]]; then
  rollback
  exit 0
fi

# =============================================================================================
# 1. pre-flight checks (read-only) - every one of these refuses rather than guesses
# =============================================================================================
ql_info "step 1/5: pre-flight checks"
# Idempotent: a completed migration is a no-op, not an error.
if [[ $(state_get STATUS) == "done" ]]; then
  if quadlet_installed && running "$container"; then
    ql_info "already migrated on $(state_get DONE_AT): $UNIT is installed and $container is running. Nothing to do"
    ql_info "  scripts/migrate-legacy.sh --status    what the cutover recorded"
    ql_info "  scripts/migrate-legacy.sh --rollback  undo it"
    exit 0
  fi
  ql_die "a completed migration is recorded in $STATE but $UNIT is not installed or $container is not running; inspect before doing anything else"
fi
[[ $(state_get STATUS) != cutover ]] || ql_die "a cutover is in progress in $STATE (use --status, or --rollback)"

podman container exists "$container" || ql_die "legacy container $container not found; nothing to migrate"
label=$(podman inspect --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "$container")
[[ $label != "$UNIT" ]] || ql_die "$container is already managed by Quadlet ($label); this host needs no migration"
app_check_not_foreign "$container" "$LEGACY_PROJECT"
running "$container" || ql_die "legacy container $container is not running; start the legacy stack first (the backup and the snapshot are taken hot)"
if quadlet_installed; then
  ql_die "the EMQX Quadlet units are already installed ($UNIT); this host needs no migration"
fi
for f in "$REPO"/quadlet/*.container "$REPO"/quadlet/*.volume "$REPO"/quadlet/*.network; do
  u=$(ql_unit_for "$f")
  [[ -z $u ]] || ql_check_unit_shadow "$u" "$APP"
done

# -- the data really is where this repo expects it, and nothing else writes to it ---------------
mounts_of() { podman inspect --format '{{range .Mounts}}{{.Name}}|{{.Destination}}{{println}}{{end}}' "$1"; }
legacy_mounts=$(mounts_of "$container")
grep -qx "$DATA_VOLUME|/opt/emqx/data" <<<"$legacy_mounts" \
  || ql_die "$container does not mount the volume $DATA_VOLUME at /opt/emqx/data; this repo's quadlet/emqx-data.volume only adopts that name"
grep -qx "$LOG_VOLUME|/opt/emqx/log" <<<"$legacy_mounts" \
  || ql_die "$container does not mount the volume $LOG_VOLUME at /opt/emqx/log; this repo's quadlet/emqx-log.volume only adopts that name"
for v in "$DATA_VOLUME" "$LOG_VOLUME"; do
  podman volume exists "$v" || ql_die "volume $v does not exist"
  other=$(podman ps --format '{{.Names}}' --filter "volume=$v" | grep -vxF "$container" || true)
  [[ -z $other ]] || ql_die "another running container also uses $v: $other. Two writers on the same data; resolve that first"
done
DATA_ID_BEFORE=$(app_volume_identity "$DATA_VOLUME") || ql_die "cannot inspect volume $DATA_VOLUME"
LOG_ID_BEFORE=$(app_volume_identity "$LOG_VOLUME") || ql_die "cannot inspect volume $LOG_VOLUME"

# -- the node name is part of the mnesia path inside the data volume ----------------------------
legacy_node=$(podman inspect --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "EMQX_NODE__NAME"}}{{index (split . "=") 1}}{{end}}{{end}}' "$container")
[[ ${legacy_node:-$NODE_NAME} == "$NODE_NAME" ]] \
  || ql_die "the legacy broker runs node '$legacy_node' but quadlet/emqx.container pins '$NODE_NAME'. mnesia lives under the node name inside $DATA_VOLUME, so the new container would start on an empty database. Align the unit first"

# -- same EMQX version: migrate first, upgrade afterwards ---------------------------------------
pinned_image=$(sed -n 's/^Image=//p' "$REPO/quadlet/emqx.container")
legacy_image_id=$(podman inspect --format '{{.Image}}' "$container")
pinned_id=$(podman image inspect --format '{{.Id}}' "$pinned_image" 2>/dev/null || true)
if [[ -z $pinned_id ]]; then
  ql_info "the pinned image is not present yet; scripts/install.sh pulls it (digest: ${pinned_image#*@})"
elif [[ $pinned_id != "$legacy_image_id" ]]; then
  ql_die "the legacy broker runs image $legacy_image_id but this checkout pins $pinned_image ($pinned_id). Migrate at the same version, then run scripts/upgrade.sh"
fi

# -- the network this repo adopts ---------------------------------------------------------------
podman network exists "$LEGACY_NETWORK" || ql_die "network $LEGACY_NETWORK does not exist; quadlet/emqx.network adopts exactly that name"
grep -qx "$LEGACY_NETWORK" < <(podman inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{println}}{{end}}' "$container") \
  || ql_warn "$container is not attached to $LEGACY_NETWORK; the Quadlet unit will attach the new container to it anyway"

# -- the published ports, read from the container (never guessed) -------------------------------
# .HostIP is the Go field name; the JSON tag is HostIp and using that spelling makes the whole
# template fail with exit 125 and no output (STANDARD section 8).
declare -A LEGACY_PORT=() LEGACY_BIND=()
while IFS='|' read -r cport hip hport; do
  [[ -n $cport ]] || continue
  LEGACY_PORT[${cport%%/*}]=$hport
  LEGACY_BIND[${cport%%/*}]=$hip
done < <(podman inspect --format '{{range $p, $bs := .NetworkSettings.Ports}}{{range $bs}}{{$p}}|{{.HostIP}}|{{.HostPort}}{{println}}{{end}}{{end}}' "$container")
((${#LEGACY_PORT[@]})) || ql_die "could not read the published ports of $container"
declare -A KNOB=([1883]=MQTT [8883]=MQTTS [8083]=WS [8084]=WSS [18083]=DASHBOARD)
sets=() binds=''
for cport in 1883 8883 8083 8084 18083; do
  hport=${LEGACY_PORT[$cport]:-}
  [[ -n $hport ]] || ql_die "$container does not publish container port $cport; this repo's unit publishes all five"
  sets+=("WOOW_EMQX_PORT_${KNOB[$cport]}=$hport")
  binds+="${LEGACY_BIND[$cport]:-0.0.0.0} "
done
# One bind address for all five, because the env file has a single WOOW_EMQX_BIND knob.
bind=$(tr ' ' '\n' <<<"$binds" | grep -v '^$' | sort -u)
[[ $bind != *$'\n'* ]] \
  || ql_die "$container publishes its ports on more than one address ($(tr '\n' ' ' <<<"$bind")); WOOW_EMQX_BIND takes a single value. Set the ports by hand with scripts/install.sh --set"
if [[ $bind == 0.0.0.0 || -z $bind ]]; then bind=all; fi
sets+=("WOOW_EMQX_BIND=$bind")
DASH_PORT=${LEGACY_PORT[18083]}
ql_info "legacy publish: bind $bind, ports $(for c in 1883 8883 8083 8084 18083; do printf '%s ' "${LEGACY_PORT[$c]}"; done)"

# -- every port the new stack will bind must be free, or held by the legacy stack ---------------
port_owner_is_legacy() {
  # Rootless podman publishes through a helper process, so a port cannot be attributed to a
  # container by pid. What can be checked is that the legacy container publishes it too.
  local p=$1 c
  for c in 1883 8883 8083 8084 18083; do [[ ${LEGACY_PORT[$c]:-} == "$p" ]] && return 0; done
  return 1
}
for cport in 1883 8883 8083 8084 18083; do
  hport=${LEGACY_PORT[$cport]}
  port_owner_is_legacy "$hport" && continue
  ! ss -ltnH "sport = :$hport" 2>/dev/null | grep -q . || ql_die "port $hport is in use by something that is not the legacy EMQX"
done

# -- how the legacy container is kept for --rollback (asked of the host, never of its name) -----
STRATEGY=$(ql_rollback_strategy "${LEGACY_CONTAINERS[@]}")
if [[ $STRATEGY == rename ]]; then
  for c in "${LEGACY_CONTAINERS[@]}"; do
    ! podman container exists "$c-legacy-$suffix" || ql_die "$c-legacy-$suffix already exists; pick another --suffix"
  done
fi

# -- a functional snapshot to compare against afterwards ----------------------------------------
emqx_ctl() { podman exec "$1" emqx ctl "${@:2}" 2>/dev/null || true; }
snapshot() {
  local c=$1
  printf 'status=%s\n' "$(emqx_ctl "$c" status | tr '\n' ' ')"
  printf 'connections=%s\n' "$(emqx_ctl "$c" broker stats | sed -n 's/^connections.count *: *//p' | head -n1)"
  printf 'subscriptions=%s\n' "$(emqx_ctl "$c" broker stats | sed -n 's/^subscriptions.count *: *//p' | head -n1)"
  printf 'retained=%s\n' "$(emqx_ctl "$c" broker stats | sed -n 's/^retained.count *: *//p' | head -n1)"
}
PRE_SNAPSHOT=$(snapshot "$container")
ql_info "legacy snapshot: $(tr '\n' ' ' <<<"$PRE_SNAPSHOT")"
grep -q '^connections=0$' <<<"$PRE_SNAPSHOT" \
  || ql_warn "MQTT clients are connected right now; they will reconnect after the cutover, and the new base.hocon adds a built-in-database authenticator - a client that connected anonymously will be rejected. See README, 'Migrating an existing compose deployment'"

legacy_dir_ok=0
if [[ -d $legacy_dir ]]; then legacy_dir=$(cd -- "$legacy_dir" && pwd -P) && legacy_dir_ok=1
else ql_warn "no legacy checkout at $legacy_dir; its .env and compose files will not be in the backup"
fi

if [[ $mode == dry-run ]]; then
  # Render and validate against a scratch env file rather than calling install.sh --dry-run: that
  # would create and edit ~/.config/emqx/emqx.env (ql_env_ensure and --set are not dry-run aware),
  # and a --dry-run that writes to the host is not a dry run.
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/$APP-migrate.XXXXXX")
  ql_cleanup work rm -rf "$WORK"
  mkdir -p "$WORK/src" "$WORK/out/config"
  if [[ -f $ENV_FILE ]]; then cp -p -- "$ENV_FILE" "$WORK/$APP.env"; else install -m 600 -- "$ENV_EXAMPLE" "$WORK/$APP.env"; fi
  for kv in "${sets[@]}"; do ql_env_set "$WORK/$APP.env" "${kv%%=*}" "${kv#*=}"; done
  QL_ENV_MODE_CHECK=0 ql_env_load "$WORK/$APP.env"
  cp -p "$REPO"/quadlet/*.container "$REPO"/quadlet/*.volume "$REPO"/quadlet/*.network "$WORK/src/"
  RENDER_ARGS=()
  # shellcheck source=render-args.sh
  . "$REPO/scripts/render-args.sh"
  render_args "$WORK/$APP.env"
  ql_render "$WORK/src" "$WORK/$APP.env" "$REPO/quadlet/render-vars" "$WORK/out" "${RENDER_ARGS[@]}"
  cp -p "$REPO/config/base.hocon" "$WORK/out/config/base.hocon"
  ql_dryrun "$WORK/out" --verify --ref-dir "$HOME/.config/containers/systemd" \
    || ql_die "the units do not render for this host; nothing was changed"
  if [[ $STRATEGY == capture ]]; then
    commit_note=without
    if app_legacy_commit_wanted "$container"; then commit_note=with; fi
    ql_info "dry-run: the checks pass and the units render. The cutover would stop $container, capture it into the backup directory ($commit_note --commit) and remove it, because podman-restart.service would revive a renamed copy here, and then install:"
  else
    ql_info "dry-run: the checks pass and the units render. The cutover would stop $container, rename it to $container-legacy-$suffix and then install:"
  fi
  printf '    %s\n' "${sets[@]}" >&2
  ql_info "volumes adopted in place: $DATA_VOLUME ($DATA_ID_BEFORE), $LOG_VOLUME ($LOG_ID_BEFORE)"
  exit 0
fi

# =============================================================================================
# 2. prepare (no downtime): settings, hot backup, and the rollback copy
# =============================================================================================
ql_info "step 2/5: settings, a hot backup and the rollback copy (no downtime)"
bk=$(state_get BACKUP)
if [[ $(state_get STATUS) != prepared || ! -d $bk ]]; then bk=$(app_new_backup_dir migrate); fi
podman inspect "${LEGACY_CONTAINERS[@]}" >"$bk/inspect.json"
chmod 600 "$bk/inspect.json"   # it carries the dashboard password of the legacy container
if ((legacy_dir_ok)); then
  for f in "$legacy_dir/.env" "$legacy_dir/docker-compose.yml" "$legacy_dir/docker-compose.autostart.yml"; do
    [[ -r $f ]] || continue
    (umask 077 && cp -p -- "$f" "$bk/legacy-$(basename "$f")")
  done
fi
printf '%s\n' "$PRE_SNAPSHOT" >"$bk/precheck.txt"
{
  printf 'volume=%s identity=%s\n' "$DATA_VOLUME" "$DATA_ID_BEFORE"
  printf 'volume=%s identity=%s\n' "$LOG_VOLUME" "$LOG_ID_BEFORE"
} >>"$bk/precheck.txt"
ql_backup_volume "$DATA_VOLUME" "$bk" >/dev/null
ql_backup_volume "$LOG_VOLUME" "$bk" >/dev/null
# On the capture path the rollback copy is written now, while the legacy stack still runs: a
# container whose create command cannot be replayed is refused here, before any downtime.
if [[ $STRATEGY == capture ]]; then app_legacy_capture "$bk" "${LEGACY_CONTAINERS[@]}"; fi
app_checksums "$bk"
state_set STRATEGY "$STRATEGY"
state_set STATUS prepared
state_set BACKUP "$bk"
state_set SUFFIX "$suffix"
state_set LEGACY_PORT_DASHBOARD "$DASH_PORT"
state_set DATA_IDENTITY "$DATA_ID_BEFORE"
state_set LOG_IDENTITY "$LOG_ID_BEFORE"
ql_info "hot backup: $bk"
if [[ $mode == prepare ]]; then
  ql_info "prepared. Run the cutover (downtime is about a minute) with the same options minus --prepare-only"
  exit 0
fi

# =============================================================================================
# 3. stop + cold export + retire (downtime starts here and is measured)
# =============================================================================================
app_confirm MIGRATE "$yes" "the cutover stops the MQTT broker for about a minute"
ql_info "step 3/5: stopping the legacy broker, cold export, retiring it ($STRATEGY)"
state_set STATUS cutover
DOWN_FROM=$(now_s)
podman stop -t 60 "$container" >/dev/null || ql_die "could not stop $container"
! running "$container" || ql_die "$container is still running"
ql_backup_volume "$DATA_VOLUME" "$bk" >/dev/null
ql_backup_volume "$LOG_VOLUME" "$bk" >/dev/null
app_legacy_retire "$STRATEGY" "$suffix" "$bk" "${LEGACY_CONTAINERS[@]}"
app_checksums "$bk"
ql_wait_until 60 "the published ports to be released" bash -c \
  "! ss -ltnH 'sport = :$DASH_PORT' 2>/dev/null | grep -q ." || ql_warn "port $DASH_PORT is still bound; the install may fail"

# =============================================================================================
# 4. install (adopts both volumes and the network by name)   5. prove, smoke, compare
# =============================================================================================
ql_info "step 4/5: scripts/install.sh"
failed=0
"$REPO/scripts/install.sh" --accept-defaults --no-smoke "${sets[@]/#/--set=}" || failed=1
DOWN_TO=$(now_s)
if ((!failed)); then
  ql_info "step 5/5: adoption proof, tests/smoke.sh and the comparison"
  # The proof the brief asks for: same mountpoint, same inode, same CreatedAt. A .volume without
  # VolumeName= would have produced systemd-emqx-data here, with a new inode and a new timestamp.
  for pair in "$DATA_VOLUME:$DATA_ID_BEFORE" "$LOG_VOLUME:$LOG_ID_BEFORE"; do
    v=${pair%%:*} want=${pair#*:}
    got=$(app_volume_identity "$v") || { ql_warn "volume $v disappeared"; failed=1; continue; }
    if [[ $got == "$want" ]]; then
      ql_info "adopted $v in place: mountpoint|CreatedAt|inode unchanged ($got)"
    else
      ql_warn "volume $v is NOT the one the legacy stack used: before [$want] after [$got]"
      failed=1
    fi
  done
  mounts_now=$(mounts_of "$container")
  grep -qx "$DATA_VOLUME|/opt/emqx/data" <<<"$mounts_now" || { ql_warn "the new container does not mount $DATA_VOLUME"; failed=1; }
  # EMQX seeds EMQX_DASHBOARD__DEFAULT_PASSWORD only into an empty data volume, so on an adopted one
  # the generated secret never reached the broker and the legacy password is still in force. Align
  # them here, before tests/smoke.sh checks exactly that (its A4).
  smoke=("$REPO/tests/smoke.sh")
  if ((failed == 0)); then
    if ((keep_dash)); then
      ql_warn "--keep-dashboard-password: the dashboard admin password is still the legacy one and does not match the woow-emqx-dashboard-password secret. Align them later with: podman exec $container emqx ctl admins passwd admin <new>"
      ql_warn "skipping the MQTT and dashboard-login part of tests/smoke.sh (its A4 would fail on that mismatch); run tests/smoke.sh by hand once the passwords agree"
      smoke=("$REPO/tests/smoke.sh" --quick --no-mqtt --skip-dashboard-login)
      dash_aligned=0
    elif set_dashboard_password; then
      ql_info "the dashboard admin password now matches the woow-emqx-dashboard-password secret"
      dash_aligned=1
    else
      ql_warn "could not set the dashboard admin password; the legacy one is still in force"
      failed=1
    fi
  fi
  ((failed)) || "${smoke[@]}" || failed=1
fi
if ((failed)); then
  if ((auto_rollback)); then
    ql_warn "the cutover failed; rolling back automatically (--no-auto-rollback keeps it for inspection)"
    yes=1 rollback
    ql_die "migration failed and was rolled back; the legacy broker runs again. Logs: journalctl --user -u $UNIT"
  fi
  ql_die "the cutover failed; the new units are left in place. Inspect, then run: $0 --rollback"
fi
POST_SNAPSHOT=$(snapshot "$container")
{ printf '\n--- after ---\n'; printf '%s\n' "$POST_SNAPSHOT"; } >>"$bk/precheck.txt"
app_checksums "$bk"
ql_info "before: $(tr '\n' ' ' <<<"$PRE_SNAPSHOT")"
ql_info "after:  $(tr '\n' ' ' <<<"$POST_SNAPSHOT")"

downtime=$((DOWN_TO - DOWN_FROM))
state_set DOWNTIME_S "$downtime"
state_set DONE_AT "$(date -Is)"
state_set STATUS "done"
ql_info "measured downtime: ${downtime}s (from 'podman stop $container' to the Quadlet broker answering)"
if ((dash_aligned)); then
  ql_info "dashboard: user admin, password = podman secret inspect --showsecret --format '{{.SecretData}}' woow-emqx-dashboard-password"
fi

if [[ $STRATEGY == capture ]]; then
  ql_info "migration complete. $container was captured into $bk/legacy-container and removed, because podman-restart.service is enabled here and a renamed copy with restart-policy=always would have revived at the next boot. Roll back with:"
else
  ql_info "migration complete. $container-legacy-$suffix is kept (stopped) for rollback:"
fi
ql_info "  $0 --rollback"
ql_info "after the soak period, clean up as described in README ('After the soak')"
