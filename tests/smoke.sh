#!/usr/bin/env bash
# tests/smoke.sh: post-install checks for Woow EMQX, run on the host where it is installed (install.sh
# and upgrade.sh call it too). Read-only apart from throwaway MQTT client containers
# (eclipse-mosquitto, pinned) and a retained test message that is cleared again.
#
#   tests/smoke.sh [--quick] [--no-mqtt]
#
#   --quick    units, health, published ports and dashboard login only
#   --no-mqtt  skip the MQTT client checks (hosts that cannot pull the client image)
#
# Secrets are read with `podman secret inspect --showsecret` into variables and compared in-process;
# nothing secret is printed, and passwords reach curl and the MQTT clients through 0600 files.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../scripts/lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=../scripts/common.sh
. "$REPO/scripts/common.sh"
export QL_LOG_PREFIX=smoke
MOSQUITTO_IMAGE=docker.io/library/eclipse-mosquitto:2.0.22@sha256:212f89e1eaeb2c322d6441b64396e3346026674db8fa9c27beac293405c32b3c

quick=0 mqtt=1
while (($#)); do
  case $1 in
    --quick) quick=1 ;;
    --no-mqtt) mqtt=0 ;;
    -h | --help) sed -n '2,13p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done

npass=0 nfail=0 nwarn=0
pass() { printf 'PASS %s\n' "$*"; npass=$((npass + 1)); }
fail() { printf 'FAIL %s\n' "$*"; nfail=$((nfail + 1)); }
warn() { printf 'WARN %s\n' "$*"; nwarn=$((nwarn + 1)); }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/emqx-smoke.XXXXXX")
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

[[ -f $ENV_FILE ]] || ql_die "$ENV_FILE not found; is EMQX installed?"
app_env_load
bind=$(ql_env_get WOOW_EMQX_BIND)
host=$(app_local_host "$bind")
dash=$(ql_env_get WOOW_EMQX_PORT_DASHBOARD)
mqtt_user=$(ql_env_get WOOW_EMQX_MQTT_USER)
with_ngrok=$(ql_env_get WOOW_EMQX_NGROK 0)

# A1 units
if systemctl --user is-active --quiet emqx.service; then pass "A1 emqx.service is active"; else fail "A1 emqx.service is not active"; fi
if [[ $with_ngrok == 1 ]]; then
  if systemctl --user is-active --quiet emqx-ngrok.service; then pass "A1 emqx-ngrok.service is active"; else fail "A1 emqx-ngrok.service is not active"; fi
fi

# A2 health (the podman health timer runs under Quadlet)
if ql_wait_container_healthy woow-emqx 180 2>/dev/null; then pass "A2 woow-emqx is healthy"; else fail "A2 woow-emqx is not healthy"; fi

# A3 exactly the five configured ports, on the configured address
ports=$(podman port woow-emqx 2>/dev/null || true)
nports=$(grep -c . <<<"$ports" || true)
bad=''
for spec in MQTT:1883 MQTTS:8883 WS:8083 WSS:8084 DASHBOARD:18083; do
  hp=$(ql_env_get "WOOW_EMQX_PORT_${spec%%:*}")
  line=$(grep -E "^${spec#*:}/tcp -> " <<<"$ports" || true)
  if [[ $bind == all ]]; then
    re="-> (0\.0\.0\.0|\[::\]|::):$hp\$"
    [[ $line =~ $re ]] || bad+=" ${spec#*:}"
  else
    [[ $line == "${spec#*:}/tcp -> $bind:$hp" ]] || bad+=" ${spec#*:}"
  fi
done
if [[ -z $bad && $nports == 5 ]]; then pass "A3 five ports published on ${bind}"; else fail "A3 published ports differ from the settings (container ports:${bad:- count $nports})"; fi

# A4 dashboard login with the generated password; the well-known default is rejected
json_str() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }
login() { curl -s -o /dev/null -w '%{http_code}' -m 10 -H 'Content-Type: application/json' --data @"$1" "http://$host:$dash/api/v5/login" 2>/dev/null || true; }
dash_pw=$(app_secret_read woow-emqx-dashboard-password || true)
if [[ -z $dash_pw ]]; then
  fail "A4 secret woow-emqx-dashboard-password is missing"
else
  (umask 077 && printf '{"username":"admin","password":%s}' "$(json_str "$dash_pw")" >"$TMP/login.json")
  printf '{"username":"admin","password":"public"}' >"$TMP/default.json"
  code=$(login "$TMP/login.json")
  if [[ $code == 200 ]]; then
    pass "A4 dashboard login with the generated password"
  else
    fail "A4 dashboard login returned HTTP $code (on an adopted volume the admin password predates the secret; see README)"
  fi
  code=$(login "$TMP/default.json")
  if [[ $code == 401 ]]; then pass "A4 admin/public is rejected"; else fail "A4 admin/public returned HTTP $code, want 401"; fi
  rm -f "$TMP/login.json"
fi

if ((quick)); then
  printf '%s passed, %s failed, %s warnings (quick)\n' "$npass" "$nfail" "$nwarn"
  ((nfail == 0))
  exit
fi

mqtt_pw=$(app_secret_read woow-emqx-mqtt-password || true)
if ((mqtt)); then
  run_client() { podman run --rm --pull=missing --network woow_emqx_network "$@" "$MOSQUITTO_IMAGE" "${cmd[@]}"; }
  # A5 anonymous MQTT is refused: THE key check of this repo
  cmd=(mosquitto_pub -h woow-emqx -p 1883 -t woow/smoke/anon -m x -q 1)
  if out=$(run_client 2>&1); then
    fail "A5 an anonymous MQTT client was accepted"
  elif grep -qi 'not authori' <<<"$out"; then
    pass "A5 anonymous MQTT is refused (not authorised)"
  else
    fail "A5 anonymous publish failed for another reason: $(tail -n1 <<<"$out")"
  fi
  # A6 authenticated round trip through a retained message (no timing race), then cleared
  if [[ -z $mqtt_pw ]]; then
    fail "A6 secret woow-emqx-mqtt-password is missing"
  else
    mkdir -m 700 "$TMP/cfg"
    for c in mosquitto_pub mosquitto_sub; do
      (umask 077 && printf -- '-u %s\n-P %s\n' "$mqtt_user" "$mqtt_pw" >"$TMP/cfg/$c")
    done
    topic=woow/smoke/$$-$RANDOM msg=hello-$$
    auth=(-e XDG_CONFIG_HOME=/cfg -v "$TMP/cfg:/cfg:ro")
    cmd=(mosquitto_pub -h woow-emqx -p 1883 -t "$topic" -m "$msg" -r -q 1)
    if run_client "${auth[@]}" >/dev/null 2>&1; then
      cmd=(mosquitto_sub -h woow-emqx -p 1883 -t "$topic" -C 1 -W 20)
      got=$(run_client "${auth[@]}" 2>/dev/null || true)
      if [[ $got == "$msg" ]]; then pass "A6 authenticated publish/subscribe as $mqtt_user"; else fail "A6 subscriber did not receive the test message"; fi
      cmd=(mosquitto_pub -h woow-emqx -p 1883 -t "$topic" -r -n -q 1)
      run_client "${auth[@]}" >/dev/null 2>&1 || warn "A6 could not clear the retained test message on $topic"
    else
      fail "A6 authenticated publish as $mqtt_user was refused"
    fi
    rm -rf "$TMP/cfg"
  fi
else
  warn "A5/A6 MQTT client checks skipped (--no-mqtt)"
fi

# A7 the bootstrap CSV is private to the broker, base.hocon is mounted read-only
perm=$(podman exec woow-emqx stat -c '%a %U' /opt/emqx/etc/woow-mqtt-bootstrap.csv 2>/dev/null || true)
if [[ $perm == '400 emqx' ]]; then pass "A7 bootstrap CSV is 0400 emqx"; else fail "A7 bootstrap CSV is '${perm:-missing}', want '400 emqx'"; fi
rw=$(podman inspect --format '{{range .Mounts}}{{if eq .Destination "/opt/emqx/etc/base.hocon"}}{{.RW}}{{end}}{{end}}' woow-emqx 2>/dev/null || true)
if [[ $rw == false ]]; then pass "A7 base.hocon is mounted read-only"; else fail "A7 base.hocon mount RW=${rw:-missing}"; fi

# A8 secret hygiene: compared in-process, nothing is printed
inspect=$(podman inspect woow-emqx 2>/dev/null || true)
journal=$(journalctl --user -u emqx.service -o cat --no-pager 2>/dev/null || true)
logs=$(podman logs --tail 2000 woow-emqx 2>&1 || true)
leak=0
if [[ -n $mqtt_pw && ( $inspect == *"$mqtt_pw"* || $journal == *"$mqtt_pw"* || $logs == *"$mqtt_pw"* ) ]]; then
  fail "A8 the MQTT password appears in podman inspect, the journal or the container log"
  leak=1
fi
if [[ -n $dash_pw && ( $journal == *"$dash_pw"* || $logs == *"$dash_pw"* ) ]]; then
  fail "A8 the dashboard password appears in the journal or the container log"
  leak=1
fi
if [[ -n $dash_pw && $inspect == *"$dash_pw"* ]]; then
  warn "A8 podman inspect shows the env-type dashboard secret (podman behaviour; it is only read on first boot)"
fi
((leak)) || pass "A8 no secret in the journal, the container log or (for the MQTT password) podman inspect"
unset dash_pw mqtt_pw inspect journal logs

if [[ $with_ngrok == 1 ]]; then
  if "$REPO/scripts/ngrok-url.sh" >/dev/null 2>&1; then pass "ngrok tunnel reported its address"; else warn "ngrok tunnel has not reported an address yet"; fi
fi

printf '%s passed, %s failed, %s warnings\n' "$npass" "$nfail" "$nwarn"
((nfail == 0))
