#!/usr/bin/env bash
# scripts/uninstall.sh: remove the Woow EMQX Quadlet units. Keeps all data by default.
#
#   scripts/uninstall.sh                  stop and remove the units; keep volumes, network, secrets,
#                                         images, ~/.config/emqx and every backup
#   scripts/uninstall.sh --purge [--yes]  also delete the volumes, the network, the woow-emqx-*
#                                         secrets and ~/.config/emqx, after a final backup of the
#                                         data volume and the env file into ~/.local/share/woow-backups/emqx
#   scripts/uninstall.sh --dry-run        report what would be removed
#
# --purge is the only way this repo deletes data. Images and backups are never deleted.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"

purge=0 yes=0
while (($#)); do
  case $1 in
    --purge) purge=1 ;;
    --yes) yes=1 ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    -h | --help) sed -n '2,11p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_require_rootless
ql_lock "$APP"
if ((!purge)); then
  ql_uninstall_units "$APP"
  exit 0
fi

app_confirm "$APP" "$yes" "--purge deletes the EMQX volumes, network, secrets and settings"
if [[ ${QL_DRY_RUN:-0} != 1 ]]; then
  final=$(app_new_backup_dir final)
  systemctl --user stop emqx-ngrok.service emqx.service >/dev/null 2>&1 || true
  if podman volume exists woow_emqx_data; then ql_backup_volume woow_emqx_data "$final" >/dev/null; fi
  if [[ -f $ENV_FILE ]]; then install -m 600 -- "$ENV_FILE" "$final/${ENV_FILE##*/}"; fi
  ql_info "final backup: $final"
fi
ql_uninstall_units "$APP" --purge
if [[ ${QL_DRY_RUN:-0} == 1 ]]; then
  ql_info "[dry-run] --purge would also remove $HOME/.config/$APP"
else
  rm -rf -- "$HOME/.config/$APP"
  ql_info "removed $HOME/.config/$APP (a copy of the env file is in the final backup)"
fi
