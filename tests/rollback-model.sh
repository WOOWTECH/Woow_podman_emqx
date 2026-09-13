#!/usr/bin/env bash
# tests/rollback-model.sh: pins the rollback model and the adoption proof that
# scripts/migrate-legacy.sh relies on (STANDARD 7a). The helpers it exercises live in
# scripts/legacy-common.sh - app_legacy_commit_wanted, app_legacy_capture, app_legacy_retire,
# app_legacy_restore and app_volume_identity - and they are the only code that decides between
# "rename and leave stopped" and "capture and remove", and the only code that can tell an adopted
# volume from a freshly created one. Pinning them pins the cutover and the rollback.
#
#   tests/rollback-model.sh [name-filter]
#
# podman and systemctl are the doubles in tests/shims, placed first on PATH; every test gets its own
# HOME and shim state. No container is created and the real user manager is never touched. Two host
# shapes are modelled:
#   toypark1234       podman-restart.service disabled -> rename, which is what the seven live
#                     migrations do today
#   woowtechopenclaw  podman-restart.service enabled and woow-emqx's restart policy is exactly
#                     `always` -> capture and remove, because a renamed copy would revive at the
#                     next boot and fight the Quadlet container for its name, its five ports and
#                     both volumes
#
# Every test runs in its own subshell on purpose (isolated HOME, shim state, env), so the
# "modified in a subshell" notes do not apply here:
# shellcheck disable=SC2030,SC2031
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
SHIMS=$HERE/shims
FILTER=${1:-}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/emqx-rollback-tests.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
npass=0 nfail=0
FAILED=()

die_t() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
eq() { [[ $1 == "$2" ]] || die_t "${3:-value}: expected [$2] got [$1]"; }
has() { [[ $1 == *"$2"* ]] || die_t "${3:-output} lacks [$2] in:"$'\n'"$1"; }
hasnt() { [[ $1 != *"$2"* ]] || die_t "${3:-output} must not contain [$2] in:"$'\n'"$1"; }
calls() { cat "$SHIM_STATE/calls"; }
ncalls() { grep -cF -- "$1" "$SHIM_STATE/calls" || true; }
OUT=''
expect_ok() { OUT=$( ("$@") 2>&1) || die_t "expected success of: $*"$'\n'"$OUT"; }
expect_fail() { if OUT=$( ("$@") 2>&1); then die_t "expected failure of: $*"$'\n'"$OUT"; fi; }

# ---- fixtures ---------------------------------------------------------------------------
# mk_emqx <policy> [rw bytes]: the live woow-emqx of woowtechopenclaw, as podman-compose left it.
# Its CreateCommand is a `podman run` carrying -d and no --restart (compose keeps the policy on the
# container object only), and its writable layer is the 11 336 bytes measured on that host.
mk_emqx() {
  local policy=$1 rw=${2:-11336} name=woow-emqx image=docker.io/emqx/emqx:5.8.9 d
  d=$SHIM_STATE/containers/$name
  mkdir -p "$d" "$SHIM_STATE/image-ids"
  printf '%s' "$policy" >"$d/policy"
  printf '0' >"$d/retries"
  printf 'cid-%s' "$name" >"$d/id"
  printf '%s' "$image" >"$d/image"
  printf 'imgid-emqx' >"$d/image_id"
  printf 'imgid-emqx' >"$SHIM_STATE/image-ids/${image//[\/:@]/_}"
  printf 'bridge' >"$d/netmode"
  printf 'false' >"$d/autoremove"
  printf 'woow_podman_emqx' >"$d/project"
  printf 'emqx' >"$d/service"
  printf '%s' "$rw" >"$d/sizerw"
  printf 'volume|woow_emqx_data|/vol/woow_emqx_data|/opt/emqx/data|true|rprivate\nvolume|woow_emqx_log|/vol/woow_emqx_log|/opt/emqx/log|true|rprivate\n' >"$d/mounts"
  printf 'woow_emqx_network|emqx cid-%s |10.89.4.2|aa:bb:cc:dd:ee:04\n' "$name" >"$d/networks"
  printf '1883/tcp|127.0.0.1:1883 \n18083/tcp|127.0.0.1:18083 \n' >"$d/ports"
  printf 'io.podman.compose.project=woow_podman_emqx\n' >"$d/labels"
  : >"$d/label"
  printf '%s\0' /usr/bin/podman run "--name=$name" -d \
    --label io.podman.compose.project=woow_podman_emqx \
    -v woow_emqx_data:/opt/emqx/data -v woow_emqx_log:/opt/emqx/log \
    --net woow_emqx_network --hostname emqx -p 127.0.0.1:1883:1883 -p 127.0.0.1:18083:18083 \
    "$image" >"$d/createcommand.argv0"
}
# mk_api_created <policy>: created through the podman API (docker-compose over the socket, podman
# play): the CreateCommand is empty, so nothing can be replayed.
mk_api_created() {
  mk_emqx "$1"
  : >"$SHIM_STATE/containers/woow-emqx/createcommand.argv0"
}
enable_restart_unit() { # what woowtechopenclaw looks like
  mkdir -p "$SHIM_STATE/units/podman-restart.service"
  echo enabled >"$SHIM_STATE/units/podman-restart.service/UnitFileState"
}
# mk_volume <name>: a real directory plus the mountpoint|CreatedAt row the shim's volume inspect
# returns, so app_volume_identity can stat it for an inode.
mk_volume() {
  local v=$1 mp=$T/vols/$1
  mkdir -p "$mp" "$SHIM_STATE/vol-owner" "$SHIM_STATE/volumes/$v"
  printf '%s|2026-08-27 00:13:41.38783555 +0800 CST' "$mp" >"$SHIM_STATE/vol-owner/$v"
}

# set_project <container> <value>: change the compose project a container claims to belong to.
# Both files matter: `project` is what the shim returns for the capture's multi-field template, and
# `labels` is what it returns for ANY {{...Config.Labels...}} format (the double returns the whole
# labels file rather than indexing one key), which is what app_check_not_foreign asks for.
set_project() {
  printf '%s' "$2" >"$SHIM_STATE/containers/$1/project"
  printf '%s' "$2" >"$SHIM_STATE/containers/$1/labels"
}

# ---- the toypark shape: rename, and nothing else ------------------------------------------
t_disabled_restart_unit_keeps_the_rename_path() {
  mk_emqx unless-stopped
  eq "$(ql_rollback_strategy woow-emqx 2>/dev/null)" rename "strategy on a toypark-like host"
  expect_ok app_legacy_retire rename 20260914 "$T/bk" woow-emqx
  has "$OUT" "renamed woow-emqx -> woow-emqx-legacy-20260914"
  eq "$(ncalls 'podman rm ')" 0 "nothing is removed on the rename path"
  eq "$(ncalls 'podman commit')" 0 "nothing is committed on the rename path"
  [[ ! -d $T/bk/legacy-container ]] || die_t "the rename path must not write a capture"
  podman container exists woow-emqx-legacy-20260914 || die_t "the renamed container is missing"
  expect_ok app_legacy_restore 20260914 "$T/bk" woow-emqx
  has "$OUT" "renamed woow-emqx-legacy-20260914 -> woow-emqx"
  podman container exists woow-emqx || die_t "the rollback did not bring woow-emqx back"
  eq "$(ncalls 'podman create')" 0 "a renamed container is not recreated"
}

t_always_policy_with_a_disabled_unit_is_still_rename() {
  # emqx is `always` on every host; only the restart unit's state makes that dangerous.
  mk_emqx always
  eq "$(ql_rollback_strategy woow-emqx 2>/dev/null)" rename "a disabled unit never revives anything"
}

# ---- the openclaw shape: capture, then remove ---------------------------------------------
t_enabled_restart_unit_and_always_policy_takes_the_capture_path() {
  enable_restart_unit
  mk_emqx always
  eq "$(ql_rollback_strategy woow-emqx 2>/dev/null)" capture "strategy on an openclaw-like host"
  expect_ok app_legacy_capture "$T/bk" woow-emqx
  [[ -s $T/bk/legacy-container/woow-emqx/meta ]] || die_t "no capture of woow-emqx"
  eq "$(sed -n 's/^RECREATABLE=//p' "$T/bk/legacy-container/woow-emqx/meta")" 1 "woow-emqx is recreatable"
  eq "$(sed -n 's/^RESTART_POLICY=//p' "$T/bk/legacy-container/woow-emqx/meta")" always "the policy is recorded"
  # capturing is read-only: the legacy broker is still serving at this point
  eq "$(ncalls 'podman rm ')" 0 "the capture removes nothing"
  eq "$(ncalls 'podman rename')" 0 "the capture renames nothing"
  expect_ok app_legacy_retire capture 20260914 "$T/bk" woow-emqx
  has "$OUT" "removed woow-emqx;"
  eq "$(ncalls 'podman rename')" 0 "the capture path must not rename"
  podman container exists woow-emqx && die_t "woow-emqx was not removed"
  podman container exists woow-emqx-legacy-20260914 && die_t "the capture path must not leave a renamed copy"
  return 0
}

t_the_capture_path_never_removes_the_volumes() {
  enable_restart_unit
  mk_emqx always
  expect_ok app_legacy_capture "$T/bk" woow-emqx
  expect_ok app_legacy_retire capture 20260914 "$T/bk" woow-emqx
  hasnt "$(calls)" "podman rm -v" "rm -v would delete the anonymous volumes the capture expects back"
  hasnt "$(calls)" "podman rm --volumes" "rm --volumes would delete the anonymous volumes"
  hasnt "$(calls)" "volume rm" "the migration never removes a volume"
}

t_the_rollback_recreates_the_captured_broker_with_restart_policy_always() {
  enable_restart_unit
  mk_emqx always
  expect_ok app_legacy_capture "$T/bk" woow-emqx
  expect_ok app_legacy_retire capture "" "$T/bk" woow-emqx
  expect_ok app_legacy_restore "" "$T/bk" woow-emqx
  has "$OUT" "recreated woow-emqx"
  podman container exists woow-emqx || die_t "the rollback did not recreate woow-emqx"
  # podman 4.9.3 cannot change a restart policy after create, so the recreate must re-add it:
  # a container that came back as `no` would not be the container that was removed.
  eq "$(ql_container_restart_policy woow-emqx)" always "the original restart policy comes back"
}

t_capture_refuses_a_container_the_library_cannot_replay() {
  enable_restart_unit
  mk_api_created always
  expect_fail app_legacy_capture "$T/bk" woow-emqx
  has "$OUT" "podman API"
  eq "$(ncalls 'podman rm ')" 0 "a refused capture removes nothing"
}

t_retire_refuses_to_remove_without_a_capture() {
  enable_restart_unit
  mk_emqx always
  expect_fail app_legacy_retire capture 20260914 "$T/bk" woow-emqx
  has "$OUT" "no rollback copy of woow-emqx"
  eq "$(ncalls 'podman rm ')" 0 "nothing is removed without a capture"
}

t_capture_is_idempotent_between_prepare_only_and_the_cutover() {
  enable_restart_unit
  mk_emqx always
  expect_ok app_legacy_capture "$T/bk" woow-emqx   # --prepare-only
  expect_ok app_legacy_capture "$T/bk" woow-emqx   # the cutover reuses the same backup dir
  has "$OUT" "already in"
  eq "$(ncalls 'podman commit')" 0 "a second capture re-commits nothing"
}

# ---- the writable-layer decision -----------------------------------------------------------
t_emqx_writable_layer_is_too_small_to_commit() {
  # The live woow-emqx measures 11 336 bytes: EMQX writes into its two volumes, not into its own
  # container, so the capture must not pay for a commit.
  enable_restart_unit
  mk_emqx always
  eq "$(app_legacy_rw_bytes woow-emqx)" 11336 "the measured writable layer"
  expect_fail app_legacy_commit_wanted woow-emqx
  has "$OUT" "nothing worth committing"
  expect_ok app_legacy_capture "$T/bk" woow-emqx
  eq "$(ncalls 'podman commit')" 0 "emqx is captured without --commit"
  eq "$(sed -n 's/^COMMIT_IMAGE=//p' "$T/bk/legacy-container/woow-emqx/meta")" '' "no committed image is recorded"
}

t_a_container_that_grew_a_writable_layer_is_committed() {
  # Same code path hermes needs: over LEGACY_COMMIT_RW_BYTES the capture commits first, so the
  # files written inside the container come back on --rollback.
  enable_restart_unit
  mk_emqx always 42672686
  expect_ok app_legacy_commit_wanted woow-emqx
  has "$OUT" "42672686 bytes"
  expect_ok app_legacy_capture "$T/bk" woow-emqx
  eq "$(ncalls 'podman commit')" 1 "the writable layer is committed once"
  [[ -n $(sed -n 's/^COMMIT_IMAGE=//p' "$T/bk/legacy-container/woow-emqx/meta") ]] \
    || die_t "the capture did not record a committed image"
}

t_an_unmeasurable_writable_layer_warns_instead_of_committing_silently() {
  enable_restart_unit
  expect_fail app_legacy_commit_wanted woow-emqx   # no such container: SizeRw is unknown
  has "$OUT" "cannot measure the writable layer"
}

# ---- the adoption proof --------------------------------------------------------------------
t_volume_identity_is_mountpoint_createdat_and_inode() {
  mk_volume woow_emqx_data
  local id
  id=$(app_volume_identity woow_emqx_data) || die_t "app_volume_identity failed"
  has "$id" "$T/vols/woow_emqx_data" "the mountpoint"
  has "$id" "2026-08-27 00:13:41.38783555 +0800 CST" "the CreatedAt"
  eq "${id##*|}" "$(stat -c %i "$T/vols/woow_emqx_data")" "the inode"
}

t_volume_identity_changes_when_the_volume_is_not_the_same_one() {
  # This is the whole point of the proof: a .volume without VolumeName= would have made a new
  # systemd-emqx-data with a different directory and inode, and the migration has to notice.
  mk_volume woow_emqx_data
  mk_volume systemd-emqx-data
  [[ $(app_volume_identity woow_emqx_data) != $(app_volume_identity systemd-emqx-data) ]] \
    || die_t "two different volumes produced the same identity; the proof cannot fail"
}

t_volume_identity_fails_loudly_for_a_volume_that_is_gone() {
  expect_fail app_volume_identity woow_emqx_data
}

# ---- the script really goes through these helpers ------------------------------------------
t_migrate_legacy_asks_the_host_instead_of_refusing() {
  # Code only: every one of these names is also in the script's header comment, so a grep over the
  # whole file would pass even if nothing called them (the red-check caught exactly that).
  local code fn
  code=$(grep -vE '^[[:space:]]*#' "$REPO/scripts/migrate-legacy.sh")
  # the blanket refusal this replaces died on `is-enabled podman-restart.service` alone
  grep -q 'is-enabled podman-restart.service' <<<"$code" \
    && die_t "scripts/migrate-legacy.sh still refuses on podman-restart.service by itself"
  for fn in ql_rollback_strategy app_legacy_capture app_legacy_retire app_legacy_restore app_volume_identity; do
    grep -q "$fn" <<<"$code" || die_t "scripts/migrate-legacy.sh never calls $fn"
  done
  return 0
}

t_the_capture_is_taken_before_any_downtime() {
  # app_legacy_capture must appear before the first `podman stop` in the script: a container that
  # cannot be replayed has to be discovered while the legacy broker is still serving.
  local cap stop
  # shellcheck disable=SC2016 # the literal text of the call site, not an expansion
  cap=$(grep -n 'app_legacy_capture "\$bk"' "$REPO/scripts/migrate-legacy.sh" | head -n1 | cut -d: -f1)
  stop=$(grep -n 'podman stop' "$REPO/scripts/migrate-legacy.sh" | head -n1 | cut -d: -f1)
  [[ -n $cap && -n $stop ]] || die_t "could not find the capture ($cap) or the stop ($stop)"
  ((cap < stop)) || die_t "the capture (line $cap) is taken after the stop (line $stop): that is downtime spent on a check"
}

t_the_units_adopt_the_compose_era_names() {
  # The migration only works because the Quadlet files carry the legacy names. Without VolumeName=
  # Quadlet would call the volume systemd-emqx-data and the broker would boot on empty mnesia.
  grep -qx 'VolumeName=woow_emqx_data' "$REPO/quadlet/emqx-data.volume" || die_t "emqx-data.volume lost VolumeName=woow_emqx_data"
  grep -qx 'VolumeName=woow_emqx_log' "$REPO/quadlet/emqx-log.volume" || die_t "emqx-log.volume lost VolumeName=woow_emqx_log"
  grep -qx 'NetworkName=woow_emqx_network' "$REPO/quadlet/emqx.network" || die_t "emqx.network lost NetworkName=woow_emqx_network"
  grep -qx 'Environment=EMQX_NODE__NAME=emqx@127.0.0.1' "$REPO/quadlet/emqx.container" \
    || die_t "the node name changed; mnesia lives under it inside the data volume"
  return 0
}

# ---- the app lock must not leak into the containers we start --------------------------------
t_app_unlocked_closes_the_inherited_lock_descriptor() {
  # ql_lock uses `exec {fd}>lock`, which bash does not mark close-on-exec, so conmon and
  # rootlessport inherit it and hold the flock for as long as the container runs - which blocked a
  # second run and, worse, --rollback. Verified live on toypark1234 (the emqx and odoo18 locks were
  # both held by an inherited descriptor). Everything that can start a container goes through
  # app_unlocked until the library closes it itself.
  ql_lock emqx
  [[ -n ${QL_LOCK_FD:-} ]] || die_t "ql_lock did not publish QL_LOCK_FD"
  # the descriptor is open for an ordinary child...
  eval "[[ -e /proc/self/fd/$QL_LOCK_FD ]]" || die_t "the lock descriptor is not open in this shell"
  local seen
  seen=$(app_unlocked bash -c "test -e /proc/self/fd/$QL_LOCK_FD && echo inherited || echo closed")
  eq "$seen" closed "the lock descriptor inside a command run through app_unlocked"
  seen=$(bash -c "test -e /proc/self/fd/$QL_LOCK_FD && echo inherited || echo closed")
  eq "$seen" inherited "without app_unlocked the descriptor is inherited (this is the bug)"
}

t_everything_that_starts_a_container_runs_through_app_unlocked() {
  local code line starts
  # shellcheck disable=SC2016 # literal call-site text, not an expansion
  starts='\$REPO/scripts/install\.sh|podman start |\$\{smoke\[@\]\}'
  # command lines only: ql_info/ql_warn/ql_die arguments merely name these things.
  code=$(grep -vE '^[[:space:]]*#|ql_(info|warn|die) ' "$REPO/scripts/migrate-legacy.sh")
  while IFS= read -r line; do
    [[ $line == *app_unlocked* ]] || die_t "starts a container without app_unlocked: $line"
  done < <(grep -E "$starts" <<<"$code")
  return 0
}

# ---- a same-named container that is not ours ------------------------------------------------
t_a_container_from_another_compose_project_is_refused() {
  # The migration retires containers by name, so a woow-emqx belonging to something else must stop
  # the run rather than be captured, renamed and replaced.
  mk_emqx unless-stopped
  set_project woow-emqx someone_elses_project
  expect_fail app_check_not_foreign woow-emqx woow_podman_emqx
  has "$OUT" "someone_elses_project"
  expect_ok app_check_not_foreign woow-emqx someone_elses_project
}

t_a_container_with_no_compose_label_is_warned_about_not_refused() {
  # A hand-made `podman run` equivalent is a legitimate shape; it gets a warning, not a refusal.
  mk_emqx unless-stopped
  set_project woow-emqx ""
  expect_ok app_check_not_foreign woow-emqx woow_podman_emqx
  has "$OUT" "no compose project label"
}

t_the_migration_checks_the_project_label_before_touching_anything() {
  local code
  code=$(grep -vE '^[[:space:]]*#|ql_(info|warn|die) ' "$REPO/scripts/migrate-legacy.sh")
  grep -q 'app_check_not_foreign' <<<"$code" || die_t "the migration never checks the compose project label"
  grep -q "^LEGACY_PROJECT=woow_podman_emqx$" "$REPO/scripts/migrate-legacy.sh" \
    || die_t "LEGACY_PROJECT is not the compose project openclaw uses"
  return 0
}

run() {
  local t=$1 log rc
  [[ -z $FILTER || $t == *"$FILTER"* ]] || return 0
  log=$ROOT/$t.log
  (
    set -euo pipefail
    T=$ROOT/$t
    mkdir -p "$T/home" "$T/state" "$T/run" "$T/bk" "$T/vols"
    export HOME=$T/home SHIM_STATE=$T/state XDG_RUNTIME_DIR=$T/run USER=tester TMPDIR=$T
    export PATH="$SHIMS:$PATH" QL_POLL_INTERVAL=0.05 QL_LOG_PREFIX=rollback-model
    unset QL_DRY_RUN QL_STATE_ROOT QL_QUADLET_DIR QL_CONFIG_ROOT
    : >"$SHIM_STATE/calls"
    [[ $(command -v podman) == "$SHIMS/podman" && $(command -v systemctl) == "$SHIMS/systemctl" ]] \
      || die_t "the shims are not first on PATH; refusing to run"
    # shellcheck source=../scripts/lib/quadlet-lib.sh
    . "$REPO/scripts/lib/quadlet-lib.sh"
    # shellcheck source=../scripts/common.sh
    . "$REPO/scripts/common.sh"
    # shellcheck source=../scripts/legacy-common.sh
    . "$REPO/scripts/legacy-common.sh"
    "$t"
  ) >"$log" 2>&1
  rc=$?
  if ((rc == 0)); then
    npass=$((npass + 1))
    printf 'ok    %s\n' "$t"
  else
    nfail=$((nfail + 1))
    FAILED+=("$t")
    printf 'FAIL  %s\n' "$t"
    tail -n 25 "$log" | sed 's/^/      | /'
  fi
}

for t in $(declare -F | sed -n 's/^declare -f \(t_.*\)$/\1/p'); do run "$t"; done
printf '\n%d passed, %d failed\n' "$npass" "$nfail"
((nfail == 0)) || { printf 'failed: %s\n' "${FAILED[*]}"; exit 1; }
