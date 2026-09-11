#!/usr/bin/env bash
# scripts/restore.sh: restore a Woow EMQX backup made by scripts/backup.sh.
#
#   scripts/restore.sh --archive FILE --confirm-restore emqx
#
#   emqx-export-*.tar.gz     logical export: imported into the running broker with `emqx ctl data
#                            import` (adds and updates config, users and rules; nothing is wiped)
#   woow_emqx_data-*.tar     cold volume export: the broker is stopped, a pre-restore cold backup is
#                            taken, the data volume is emptied and re-imported, the broker restarts
#
# The archive's SHA256SUMS entry is checked first when the file sits in a backup directory.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"

archive='' confirm=''
while (($#)); do
  case $1 in
    --archive) (($# >= 2)) || ql_die "--archive needs a path"; archive=$2; shift ;;
    --confirm-restore) (($# >= 2)) || ql_die "--confirm-restore needs the word $APP"; confirm=$2; shift ;;
    -h | --help) sed -n '2,13p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
[[ -n $archive && $confirm == "$APP" ]] || ql_die "usage: scripts/restore.sh --archive FILE --confirm-restore $APP"
archive=$(realpath -- "$archive")
[[ -f $archive && -s $archive ]] || ql_die "archive not found or empty: $archive"
ql_require_rootless
app_lock

sums=$(dirname -- "$archive")/SHA256SUMS
if [[ -f $sums ]] && grep -q "  ${archive##*/}\$" "$sums"; then
  (cd "$(dirname -- "$archive")" && grep "  ${archive##*/}\$" SHA256SUMS | sha256sum -c --quiet -) \
    || ql_die "checksum mismatch for $archive"
  ql_info "checksum ok: ${archive##*/}"
fi

case ${archive##*/} in
  emqx-export-*.tar.gz)
    [[ $(podman inspect --format '{{.State.Running}}' woow-emqx 2>/dev/null) == true ]] \
      || ql_die "woow-emqx must be running to import a logical export"
    name=${archive##*/}
    podman cp "$archive" "woow-emqx:/opt/emqx/data/backup/$name"
    # podman cp writes it as container root with mode 0600; the broker runs as emqx.
    podman exec -u 0 woow-emqx chown emqx:emqx "/opt/emqx/data/backup/$name"
    out=$(podman exec woow-emqx emqx ctl data import "/opt/emqx/data/backup/$name" 2>&1) \
      || ql_die "emqx ctl data import failed: $out"
    podman exec woow-emqx rm -f "/opt/emqx/data/backup/$name" || true
    ql_info "imported $name"
    ;;
  woow_emqx_data-*.tar)
    units=(emqx.service)
    if systemctl --user is-active --quiet emqx-ngrok.service; then units+=(emqx-ngrok.service); fi
    pre=$(app_new_backup_dir pre-restore)
    systemctl --user stop emqx.service
    ql_backup_volume woow_emqx_data "$pre" >/dev/null
    app_checksums "$pre"
    ql_info "pre-restore copy of the current data: $pre"
    mp=$(podman volume inspect --format '{{.Mountpoint}}' woow_emqx_data)
    [[ $mp == /* && $mp != / ]] || ql_die "unexpected mountpoint for woow_emqx_data: $mp"
    podman unshare find "$mp" -mindepth 1 -delete
    podman volume import woow_emqx_data "$archive" || ql_die "podman volume import failed; restore $pre/woow_emqx_data-*.tar the same way"
    systemctl --user start "${units[@]}"
    ;;
  *) ql_die "unknown archive type ${archive##*/} (want emqx-export-*.tar.gz or woow_emqx_data-*.tar)" ;;
esac
app_wait_healthy woow-emqx 180 emqx.service
"$REPO/tests/smoke.sh" --quick || ql_die "restored, but the quick smoke check failed"
ql_info "restore complete"
