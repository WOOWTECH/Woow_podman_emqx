#!/usr/bin/env bash
# tests/smoke-a4.sh: regression test for the bug found on a live migration attempt on
# woowtechopenclaw - scripts/migrate-legacy.sh's step 5 (post-cutover verification) called
# tests/smoke.sh without a way to tell it the dashboard password was intentionally kept from the
# legacy deployment (--keep-dashboard-password), so smoke's A4 tried to log in with the *generated*
# secret, got 401, and a cutover that had actually succeeded was auto-rolled-back.
#
# This drives the real tests/smoke.sh binary against small stand-ins for podman, systemctl and
# curl (not the tests/shims/ doubles: those model legacy-common.sh's container-management calls,
# not smoke.sh's health/port/HTTP checks). No container is created and no network call leaves the
# host.
#
#   tests/smoke-a4.sh [name-filter]
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
FILTER=${1:-}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/emqx-smoke-a4.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
npass=0 nfail=0
FAILED=()

die_t() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
has() { [[ $1 == *"$2"* ]] || die_t "${3:-output} lacks [$2] in:"$'\n'"$1"; }
hasnt() { [[ $1 != *"$2"* ]] || die_t "${3:-output} must not contain [$2] in:"$'\n'"$1"; }

# ---- stand-ins ----------------------------------------------------------------------------
# write_stubs <dir>: podman/systemctl/curl doubles, controlled entirely by env vars so each test
# below just sets SMOKE_* before calling smoke.sh. Defaults model a healthy, fully-reachable
# broker whose dashboard login succeeds with the generated secret - i.e. the "everything is fine,
# freshly generated password" case - so a test only has to override what it means to vary.
write_stubs() {
  local bin=$1
  mkdir -p "$bin"
  cat >"$bin/podman" <<'PODMAN'
#!/usr/bin/env bash
set -u
cmd=${1:-}; shift || true
case $cmd in
  inspect)
    fmt=''
    while (($#)); do
      case $1 in
        --format | -f) fmt=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    if [[ $fmt == *State.Status* ]]; then
      if [[ ${SMOKE_HEALTHY:-1} == 1 ]]; then
        echo "running|hc|healthy|2026-09-14T00:00:00Z"
      else
        echo "exited|hc||2026-09-14T00:00:00Z"
      fi
    fi
    exit 0 ;;
  port)
    if [[ ${SMOKE_PORTS_OK:-1} == 1 ]]; then
      printf '1883/tcp -> 127.0.0.1:1883\n8883/tcp -> 127.0.0.1:8883\n8083/tcp -> 127.0.0.1:8083\n8084/tcp -> 127.0.0.1:8084\n18083/tcp -> 127.0.0.1:18083\n'
    fi
    exit 0 ;;
  secret)
    sub=${1:-}; shift || true
    case $sub in
      inspect) printf '%s\n' "${SMOKE_DASH_SECRET:-generated-secret-pw}" ;;
    esac
    exit 0 ;;
  exec)
    # A7 (bootstrap CSV perms / base.hocon RO) and A8 (journal/log grep) are not exercised by
    # this test; a permissive default keeps them out of the way of the A1-A4 assertions below.
    echo '400 emqx'; exit 0 ;;
  logs) exit 0 ;;
  *) exit 0 ;;
esac
PODMAN
  cat >"$bin/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
set -u
[[ ${1:-} == --user ]] || exit 99
shift
cmd=${1:-}; shift || true
case $cmd in
  is-active)
    quiet=0
    [[ ${1:-} == --quiet ]] && { quiet=1; shift; }
    if [[ ${SMOKE_SVC_ACTIVE:-1} == 1 ]]; then
      ((quiet)) || echo active
      exit 0
    else
      ((quiet)) || echo inactive
      exit 3
    fi ;;
  *) exit 0 ;;
esac
SYSTEMCTL
  cat >"$bin/curl" <<'CURL'
#!/usr/bin/env bash
set -u
file=''
for a in "$@"; do
  case $a in
    @*) file=${a#@} ;;
  esac
done
case $file in
  *login.json) printf '%s' "${SMOKE_LOGIN_CODE:-200}" ;;
  *default.json) printf '%s' "${SMOKE_DEFAULT_CODE:-401}" ;;
  *) printf '000' ;;
esac
CURL
  cat >"$bin/journalctl" <<'JOURNALCTL'
#!/usr/bin/env bash
exit 0
JOURNALCTL
  chmod +x "$bin/podman" "$bin/systemctl" "$bin/curl" "$bin/journalctl"
}

# write_env_file <home>: an installed config/emqx.env matching the ports the podman stub reports.
write_env_file() {
  mkdir -p "$1/.config/emqx"
  cat >"$1/.config/emqx/emqx.env" <<'ENVF'
EMQX_LOG__CONSOLE__LEVEL=warning
WOOW_EMQX_BIND=127.0.0.1
WOOW_EMQX_PORT_MQTT=1883
WOOW_EMQX_PORT_MQTTS=8883
WOOW_EMQX_PORT_WS=8083
WOOW_EMQX_PORT_WSS=8084
WOOW_EMQX_PORT_DASHBOARD=18083
WOOW_EMQX_MQTT_USER=woow
WOOW_EMQX_NGROK=0
WOOW_EMQX_NGROK_REMOTE_ADDR=
ENVF
}

# ---- scenarios ------------------------------------------------------------------------------

# The bug, reproduced: --keep-dashboard-password means the real admin password is the legacy one,
# so a login attempt with the generated secret (what smoke.sh's A4 always tried, pre-fix) gets 401.
# Without a way to tell smoke.sh to skip that check, the cutover's own step 5 fails and auto-rolls
# back a cutover that had actually succeeded.
t_red_pre_fix_keep_dash_password_without_a_skip_flag_fails_a4() {
  export SMOKE_LOGIN_CODE=401 SMOKE_DEFAULT_CODE=401 # the legacy password is neither the generated
  # secret nor the well-known default - exactly what --keep-dashboard-password leaves in force
  if OUT=$("$REPO/tests/smoke.sh" --quick --no-mqtt 2>&1); then rc=0; else rc=$?; fi
  ((rc != 0)) || die_t "expected tests/smoke.sh --quick --no-mqtt (no skip flag) to fail on A4"
  has "$OUT" "FAIL A4 dashboard login returned HTTP 401"
}

# The fix, green: migrate-legacy.sh's real invocation for --keep-dashboard-password now passes
# --skip-dashboard-login too, and A4 is a WARN, not a FAIL - no false rollback.
t_green_post_fix_keep_dash_password_with_skip_flag_passes() {
  export SMOKE_LOGIN_CODE=401 SMOKE_DEFAULT_CODE=401
  if OUT=$("$REPO/tests/smoke.sh" --quick --no-mqtt --skip-dashboard-login 2>&1); then rc=0; else rc=$?; fi
  ((rc == 0)) || die_t "expected tests/smoke.sh --quick --no-mqtt --skip-dashboard-login to pass"$'\n'"$OUT"
  has "$OUT" "WARN A4 dashboard login skipped (--skip-dashboard-login)"
  hasnt "$OUT" "FAIL A4"
}

# The exact command line migrate-legacy.sh now runs in --keep-dashboard-password mode: pins the
# fix at the call site, not just in smoke.sh's own flag parsing.
t_migrate_legacy_passes_skip_dashboard_login_when_keeping_the_password() {
  grep -q -- '--skip-dashboard-login' "$REPO/scripts/migrate-legacy.sh" \
    || die_t "scripts/migrate-legacy.sh never passes --skip-dashboard-login to tests/smoke.sh"
  grep -n 'smoke=(' "$REPO/scripts/migrate-legacy.sh" | grep -q -- '--skip-dashboard-login' \
    || die_t "the keep_dash smoke=() array does not carry --skip-dashboard-login"
}

# A genuine failure - the broker's own unit is not active - must still fail and still be visible
# with --skip-dashboard-login set: the flag must not become a blanket "assume success".
t_red_genuine_failure_still_fails_without_the_skip_flag() {
  export SMOKE_SVC_ACTIVE=0 SMOKE_LOGIN_CODE=200 SMOKE_DEFAULT_CODE=401
  if OUT=$("$REPO/tests/smoke.sh" --quick --no-mqtt 2>&1); then rc=0; else rc=$?; fi
  ((rc != 0)) || die_t "expected a real failure (emqx.service inactive) to fail smoke.sh"
  has "$OUT" "FAIL A1 emqx.service is not active"
}

t_green_genuine_failure_still_fails_even_with_the_skip_flag() {
  export SMOKE_SVC_ACTIVE=0 SMOKE_LOGIN_CODE=200 SMOKE_DEFAULT_CODE=401
  if OUT=$("$REPO/tests/smoke.sh" --quick --no-mqtt --skip-dashboard-login 2>&1); then rc=0; else rc=$?; fi
  ((rc != 0)) || die_t "the skip flag must not paper over a genuine failure (emqx.service inactive)"
  has "$OUT" "FAIL A1 emqx.service is not active"
}

# Sanity: the freshly-generated-password path (the default cutover, no --keep-dashboard-password)
# is unaffected by the new flag when it is not passed.
t_default_path_without_keep_dashboard_password_is_unaffected() {
  export SMOKE_LOGIN_CODE=200 SMOKE_DEFAULT_CODE=401
  if OUT=$("$REPO/tests/smoke.sh" --quick --no-mqtt 2>&1); then rc=0; else rc=$?; fi
  ((rc == 0)) || die_t "expected the ordinary (generated-password) path to pass"$'\n'"$OUT"
  has "$OUT" "PASS A4 dashboard login with the generated password"
}

run() {
  local t=$1 log rc
  [[ -z $FILTER || $t == *"$FILTER"* ]] || return 0
  log=$ROOT/$t.log
  (
    set -euo pipefail
    T=$ROOT/$t
    mkdir -p "$T/home/.config" "$T/bin"
    write_stubs "$T/bin"
    write_env_file "$T/home"
    export HOME=$T/home
    export PATH="$T/bin:$PATH"
    export QL_POLL_INTERVAL=0.05
    unset SMOKE_HEALTHY SMOKE_PORTS_OK SMOKE_SVC_ACTIVE SMOKE_LOGIN_CODE SMOKE_DASH_SECRET SMOKE_DEFAULT_CODE
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
    tail -n 40 "$log" | sed 's/^/      | /'
  fi
}

for t in $(declare -F | sed -n 's/^declare -f \(t_.*\)$/\1/p'); do run "$t"; done
printf '\n%d passed, %d failed\n' "$npass" "$nfail"
((nfail == 0)) || { printf 'failed: %s\n' "${FAILED[*]}"; exit 1; }
