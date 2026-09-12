#!/usr/bin/env bash
# scripts/upgrade.sh: upgrade Woow EMQX to the versions pinned in this checkout, with automatic
# rollback of the units when the upgrade fails.
#
#   git pull && scripts/upgrade.sh [--cold] [--no-backup]
#
# Steps: backup (hot, or --cold) -> save the installed units -> scripts/install.sh (pulls the new
# pinned images before any unit changes, restarts what changed) -> tests/smoke.sh. When install or
# smoke fails, the saved units are put back, the broker is restarted on the previous image, and the
# script exits non-zero. Data written by a newer EMQX is not rolled back automatically: restore the
# pre-upgrade backup with scripts/restore.sh if a major-version upgrade has to be undone.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"

backup_args=() no_backup=0
while (($#)); do
  case $1 in
    --cold) backup_args+=(--cold) ;;
    --no-backup) no_backup=1 ;;
    -h | --help) sed -n '2,11p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_preflight "$PODMAN_MIN"
[[ -f $ENV_FILE ]] || ql_die "$ENV_FILE does not exist: run scripts/install.sh first"
app_lock

snap=$(app_new_backup_dir upgrade)
if ((no_backup == 0)); then
  data=$("$REPO/scripts/backup.sh" "${backup_args[@]}") || ql_die "backup failed; nothing was changed"
  ql_info "pre-upgrade data backup: $data"
fi
app_snapshot "$snap/units"
podman inspect --format '{{.Name}} {{.ImageName}} {{.Image}}' woow-emqx woow-emqx-ngrok >"$snap/images.txt" 2>/dev/null || true

if "$REPO/scripts/install.sh" --no-smoke && "$REPO/tests/smoke.sh"; then
  ql_info "upgrade complete (unit snapshot: $snap)"
  exit 0
fi

ql_warn "upgrade failed; rolling back to the units saved in $snap/units"
app_snapshot_restore "$snap/units" || ql_die "rollback failed: no usable snapshot. Inspect $snap and journalctl --user -u emqx.service"
units=(emqx.service)
[[ -f $HOME/.config/containers/systemd/emqx-ngrok.container ]] && units+=(emqx-ngrok.service)
systemctl --user restart "${units[@]}" || true
if ql_wait_container_healthy woow-emqx 180 && "$REPO/tests/smoke.sh" --quick; then
  ql_die "upgrade failed and was rolled back; the previous version is running again"
fi
ql_die "upgrade failed and the rollback is unhealthy too. Restore data with scripts/restore.sh (backup: ${data:-none})"
