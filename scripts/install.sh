#!/usr/bin/env bash
# scripts/install.sh: install or update Woow EMQX as rootless Quadlet units (podman >= 4.9,
# systemd --user, linger). Idempotent: a re-run with nothing changed restarts nothing.
#
#   scripts/install.sh [options]
#
#   --set KEY=VALUE    store a per-host setting in ~/.config/emqx/emqx.env first (repeatable), e.g.
#                      --set WOOW_EMQX_PORT_MQTT=21883. Only keys of config/emqx.env.example.
#   --with-ngrok       also run the ngrok TCP tunnel for 1883 (remembered as WOOW_EMQX_NGROK=1). The
#                      authtoken comes from $NGROK_AUTHTOKEN, or a hidden prompt on the first run.
#   --without-ngrok    stop and remove the ngrok tunnel (WOOW_EMQX_NGROK=0)
#   --accept-defaults  on the first run, continue with the example settings instead of stopping
#   --no-start         install the files and daemon-reload only
#   --no-smoke         skip tests/smoke.sh at the end
#   --dry-run          render and validate, report what would change, touch nothing
#
# Order of steps: preflight -> env -> guards -> render -> dry-run -> pull -> secrets -> install ->
# apply -> health -> smoke. Nothing is installed when rendering or the Quadlet dry-run fails.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"

sets=() ngrok='' accept=0 no_start=0 no_smoke=0
while (($#)); do
  case $1 in
    --set) (($# >= 2)) || ql_die "--set needs KEY=VALUE"; sets+=("$2"); shift ;;
    --set=*) sets+=("${1#--set=}") ;;
    --with-ngrok) ngrok=1 ;;
    --without-ngrok) ngrok=0 ;;
    --accept-defaults) accept=1 ;;
    --no-start) no_start=1 ;;
    --no-smoke) no_smoke=1 ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    -h | --help) sed -n '2,21p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
[[ -z $ngrok ]] || sets+=("WOOW_EMQX_NGROK=$ngrok")
dry=${QL_DRY_RUN:-0}

# ---- 1. host preflight ------------------------------------------------------------------------
ql_preflight "$PODMAN_MIN"
ql_enable_linger
app_lock

# ---- 2. per-host settings (rendered at install time; never stored in the repo) -----------------
ql_env_ensure "$ENV_EXAMPLE" "$ENV_FILE"
if [[ $QL_ENV_CREATED == 1 && $accept == 0 && ${#sets[@]} == 0 ]]; then
  ql_info "review $ENV_FILE, then run $0 again (or pass --accept-defaults)"
  exit 0
fi
((${#sets[@]} == 0)) || app_apply_sets "${sets[@]}"
app_env_load
app_env_overlay "${sets[@]}"
app_refuse_env_secrets
with_ngrok=$(ql_env_get WOOW_EMQX_NGROK 0)
ql_assert_match WOOW_EMQX_NGROK "$with_ngrok" '0|1'
mqtt_user=$(ql_env_get WOOW_EMQX_MQTT_USER)
ql_assert_match WOOW_EMQX_MQTT_USER "$mqtt_user" '[A-Za-z0-9][A-Za-z0-9_.-]{0,63}'

# ---- 3. legacy guards -------------------------------------------------------------------------
app_guard_containers

# ---- 4. stage the selected sources, render, validate -------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/$APP-install.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src" "$WORK/out/config"
cp -p "$REPO"/quadlet/*.container "$REPO"/quadlet/*.volume "$REPO"/quadlet/*.network "$WORK/src/"
units=(emqx.service)
if [[ $with_ngrok == 1 ]]; then
  cp -p "$REPO/quadlet/optional/emqx-ngrok.container" "$WORK/src/"
  units+=(emqx-ngrok.service)
fi
RENDER_ARGS=()
# shellcheck source=render-args.sh
. "$REPO/scripts/render-args.sh"
render_args "$RENDER_ENV"
ql_render "$WORK/src" "$RENDER_ENV" "$REPO/quadlet/render-vars" "$WORK/out" "${RENDER_ARGS[@]}"
cp -p "$REPO/config/base.hocon" "$WORK/out/config/base.hocon"
ql_dryrun "$WORK/out" --verify --ref-dir "$HOME/.config/containers/systemd" \
  || ql_die "the rendered units failed the Quadlet dry-run; nothing was installed"
for f in "$WORK/out"/*; do
  u=$(ql_unit_for "$f")
  [[ -z $u ]] || ql_check_unit_shadow "$u" "$APP"
done

# ---- 5. images and secrets, before any unit changes -------------------------------------------
ql_pull_images "$WORK/out"
restart_main=0
ql_secret_ensure woow-emqx-dashboard-password random:32
ql_secret_ensure woow-emqx-mqtt-password random:32
if [[ $dry == 1 ]] && ! podman secret exists woow-emqx-mqtt-password; then
  ql_info "[dry-run] would create secret woow-emqx-mqtt-bootstrap (MQTT user $mqtt_user)"
else
  # The bootstrap CSV is derived from the MQTT password secret. EMQX imports it when the
  # authenticator starts and never overwrites a user that already exists.
  mqtt_pw=$(app_secret_read woow-emqx-mqtt-password) || ql_die "cannot read secret woow-emqx-mqtt-password"
  [[ -n $mqtt_pw ]] || ql_die "secret woow-emqx-mqtt-password is empty"
  # shellcheck disable=SC2034 # read by ql_secret_ensure env:EMQX_BOOTSTRAP_CSV
  EMQX_BOOTSTRAP_CSV="user_id,password,is_superuser"$'\n'"$mqtt_user,$mqtt_pw,false"
  unset mqtt_pw
  QL_SECRET_CHANGED=0
  ql_secret_ensure woow-emqx-mqtt-bootstrap env:EMQX_BOOTSTRAP_CSV --update
  unset EMQX_BOOTSTRAP_CSV
  [[ $QL_SECRET_CHANGED == 0 ]] || restart_main=1
fi
if [[ $with_ngrok == 1 ]]; then
  if podman secret exists woow-emqx-ngrok-authtoken; then
    if [[ -n ${NGROK_AUTHTOKEN:-} ]]; then
      QL_SECRET_CHANGED=0
      ql_secret_ensure woow-emqx-ngrok-authtoken env:NGROK_AUTHTOKEN --update
      [[ $QL_SECRET_CHANGED == 0 ]] || ql_mark_changed "$APP" emqx-ngrok.service
    else
      ql_info "secret woow-emqx-ngrok-authtoken exists (kept)"
    fi
  elif [[ $dry == 1 ]]; then
    ql_info "[dry-run] would create secret woow-emqx-ngrok-authtoken"
  else
    if [[ -z ${NGROK_AUTHTOKEN:-} ]]; then
      [[ -t 0 ]] || ql_die "--with-ngrok needs NGROK_AUTHTOKEN in the environment (or an interactive terminal)"
      read -r -s -p "ngrok authtoken (input hidden): " NGROK_AUTHTOKEN
      echo >&2
    fi
    ql_secret_ensure woow-emqx-ngrok-authtoken env:NGROK_AUTHTOKEN
  fi
fi
unset NGROK_AUTHTOKEN

# ---- 6. install changed files, then start / restart only what changed -------------------------
changed=$(ql_install_files "$WORK/out" "$APP" --prune)
[[ -z $changed ]] || ql_info "changed: $(tr '\n' ' ' <<<"$changed")"
grep -qx 'config/base.hocon' <<<"$changed" && restart_main=1
app_env_changed && restart_main=1
if [[ $dry == 1 ]]; then
  ((restart_main)) && ql_info "[dry-run] would restart emqx.service (settings or secrets changed)"
  ql_info "dry-run complete; nothing was changed"
  exit 0
fi
((restart_main == 0)) || ql_mark_changed "$APP" emqx.service
if ((no_start)); then
  systemctl --user daemon-reload
  ql_info "installed; not started (--no-start). Start with: systemctl --user start ${units[*]}"
  exit 0
fi
ql_apply_units "$APP" "${units[@]}"

# ---- 7. health and smoke ----------------------------------------------------------------------
app_wait_healthy woow-emqx 180 emqx.service
host=$(app_local_host "$(ql_env_get WOOW_EMQX_BIND)")
dash_port=$(ql_env_get WOOW_EMQX_PORT_DASHBOARD)
ql_wait_http "http://$host:$dash_port/" '200' 120 || ql_die "the dashboard does not answer on $host:$dash_port"
app_env_record
if ((no_smoke == 0)); then
  if ! "$REPO/tests/smoke.sh"; then
    if [[ $with_ngrok == 1 ]]; then
      systemctl --user stop emqx-ngrok.service || true
      ql_warn "stopped emqx-ngrok.service: the broker must not be tunneled while a smoke check fails"
    fi
    ql_die "tests/smoke.sh failed; see the FAIL lines above"
  fi
fi

cat >&2 <<EOF
$APP is installed and healthy.
  Dashboard  http://$host:$dash_port/   user admin
  MQTT       $host:$(ql_env_get WOOW_EMQX_PORT_MQTT)   user $mqtt_user
  Passwords  (private terminal) podman secret inspect --showsecret --format '{{.SecretData}}' woow-emqx-dashboard-password
             (private terminal) podman secret inspect --showsecret --format '{{.SecretData}}' woow-emqx-mqtt-password
  Settings   $ENV_FILE (edit, then run scripts/install.sh again)
EOF
[[ $with_ngrok == 0 ]] || printf '  ngrok      %s/scripts/ngrok-url.sh\n' "$REPO" >&2
