#!/usr/bin/env bash
# scripts/backup.sh: back up Woow EMQX into ~/.local/share/woow-backups/emqx/backup-<timestamp>/.
#
#   scripts/backup.sh          hot: `emqx ctl data export` (cluster config, built-in-db users, rules,
#                              retained messages) copied out of the running broker. No downtime.
#   scripts/backup.sh --cold   also stop the broker and export the whole woow_emqx_data volume
#                              (podman volume export), then start it again. Use before upgrades that
#                              cross an EMQX major version.
#
# Prints the backup directory on stdout. Files are 0600 in 0700 directories, with SHA256SUMS.
# Restore with scripts/restore.sh --archive <file> --confirm-restore emqx.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"

cold=0
while (($#)); do
  case $1 in
    --cold) cold=1 ;;
    -h | --help) sed -n '2,12p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_require_rootless
app_lock
[[ $(podman inspect --format '{{.State.Running}}' woow-emqx 2>/dev/null) == true ]] \
  || ql_die "woow-emqx is not running (systemctl --user start emqx.service)"

dest=$(app_new_backup_dir backup)
# 1. logical export from the running broker
out=$(podman exec woow-emqx emqx ctl data export 2>&1) || ql_die "emqx ctl data export failed: $out"
name=$(grep -oE 'emqx-export-[A-Za-z0-9_.:-]+\.tar\.gz' <<<"$out" | tail -n1 || true)
[[ -n $name ]] || ql_die "could not find the export file name in: $out"
(umask 077 && podman cp "woow-emqx:/opt/emqx/data/backup/$name" "$dest/$name") || ql_die "podman cp of $name failed"
chmod 600 "$dest/$name"
[[ -s $dest/$name ]] || ql_die "the export $name is empty"
podman exec woow-emqx rm -f "/opt/emqx/data/backup/$name" || ql_warn "could not remove $name from the data volume"
ql_info "exported the broker data -> $dest/$name"

# 2. optional cold copy of the whole data volume
if ((cold)); then
  units=(emqx.service)
  if systemctl --user is-active --quiet emqx-ngrok.service; then units+=(emqx-ngrok.service); fi
  systemctl --user stop emqx.service
  start_again() { systemctl --user start "${units[@]}" || ql_warn "could not start ${units[*]} again"; }
  trap start_again EXIT
  ql_backup_volume woow_emqx_data "$dest" >/dev/null
  trap - EXIT
  start_again
  app_wait_healthy woow-emqx 180 emqx.service
fi
podman image inspect --format '{{.Id}} {{index .RepoDigests 0}}' "$(podman inspect --format '{{.ImageName}}' woow-emqx)" \
  >"$dest/image.txt" 2>/dev/null || true
app_checksums "$dest"
ql_info "backup complete: $dest"
printf '%s\n' "$dest"
