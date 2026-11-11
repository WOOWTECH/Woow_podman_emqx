#!/bin/sh
# shellcheck shell=sh
# ngrok.sh — the tenant's ngrok agent, supervised (container `ngrok`).
#
# Public raw MQTT: the agent forwards an ngrok TCP endpoint to the broker
# ($WOOW_NGROK_UPSTREAM — the loopback PROXY-protocol listener tcp:ngrok, or
# 1883 with ngrok.proxyProtocol=false; templates/statefulset.yaml).
#
# Address read-back contract (paas-operator reads this container's log):
#   * `WOOW_MQTT_PUBLIC_URL=tcp://host:port` — polled every 5 s until the first
#     address shows up, then re-printed every $WOOW_ANNOUNCE_INTERVAL seconds,
#     so log rotation can never lose it;
#   * `WOOW_MQTT_PUBLIC_URL=` (empty) RETRACTS it (no token, agent down) — the
#     platform keeps the LAST line;
#   * why there is no address (woow_paas_platform #1559): ngrok's own
#     `ERROR:  ERR_NGROK_<n>` line, and the sentence `ngrok authtoken is not set`
#     (code NO_AUTHTOKEN). The operator matches both verbatim: do not reword.
#
# The agent's own output reaches the log ONLY through ngrok-redact.awk
# (woow_paas_platform #1613): ngrok echoes the authtoken back on every
# authentication failure ("Your authtoken: …", ERR_NGROK_105 for any malformed
# token), and the container log is readable by everyone who may read Pod logs.
# No filter → the output is dropped, never shown unfiltered.
#
# Tenant input (ngrok.remoteAddr) arrives in the ENVIRONMENT and is validated
# here. It is never templated into a shell command: up to chart 0.1.6 it was,
# and a value such as `x; <command>` ran in this container.
#
# The container must NEVER exit because the agent did. A wrong authtoken (or an
# expired account, or a reserved address the account does not own) makes
# `ngrok` exit at once; if that ended the container, Kubernetes would restart it
# into CrashLoopBackOff, the POD would turn NotReady and the Service would drop
# the whole broker — dashboard and in-cluster MQTT included — over a typo in an
# optional field (seen in dev-sandbox). So the agent is retried with exponential
# back-off, and every exit retracts the address first.
#
# POSIX sh + busybox (ngrok alpine image); also runs under dash in the chart's
# tests. Deliberately no `set -e`: a failing probe must not end the supervisor.
set -u

upstream=${WOOW_NGROK_UPSTREAM:-127.0.0.1:1884}
interval=${WOOW_ANNOUNCE_INTERVAL:-60}
max_backoff=${WOOW_MAX_BACKOFF:-600}
redact_awk=${WOOW_NGROK_REDACT:-/opt/woow/ngrok-redact.awk}
api=${WOOW_NGROK_API:-127.0.0.1:4040}
case $interval in '' | *[!0-9]* | 0) interval=60 ;; esac
case $max_backoff in '' | *[!0-9]* | 0) max_backoff=600 ;; esac
case $upstream in '' | *[!0-9a-z.:]*) upstream=127.0.0.1:1884 ;; esac
nl='
'

if [ -z "${NGROK_AUTHTOKEN:-}" ]; then
  # Public MQTT switched on without a token: say so, retract any old address,
  # and idle — never fail the release or the pod.
  echo "WOOW_MQTT_PUBLIC_URL="
  echo "ngrok authtoken is not set: enter your own ngrok authtoken in the service settings to get a public MQTT address"
  exec sleep 2147483647
fi

case $NGROK_AUTHTOKEN in
  *"$nl"*)
    # A token spanning several lines is never valid, and the agent would echo
    # it back over several log lines (the filter works line by line). Never
    # start the agent with it; report the code ngrok gives every malformed
    # token (ERR_NGROK_105, measured with 3.39.11) so the platform can say why.
    echo "WOOW_MQTT_PUBLIC_URL="
    echo "ngrok authtoken contains a line break, so it cannot be a valid authtoken: the agent is not started. Copy the authtoken again from the ngrok dashboard (Your Authtoken) into the service settings."
    echo "ERROR:  ERR_NGROK_105"
    exec sleep 2147483647
    ;;
esac

# woow_remote_addr VALUE — the tenant's reserved TCP address as host:port.
# Accepts what people paste ("tcp://1.tcp.ngrok.io:12345/", upper case,
# surrounding blanks). Prints host:port and returns 0, or returns 1.
woow_remote_addr() {
  _v=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d ' \t\r\n')
  _v=${_v#tcp://}
  _v=${_v%/}
  case $_v in
    '' | *[!a-z0-9.:-]* | *:*:* | :* | *: | *..* | .* | *.:* | -* | *-:*) return 1 ;;
    *:*) : ;;
    *) return 1 ;;
  esac
  _host=${_v%:*}
  _port=${_v##*:}
  case $_host in *.*) : ;; *) return 1 ;; esac
  [ "${#_host}" -le 253 ] || return 1
  case $_port in '' | *[!0-9]*) return 1 ;; esac
  [ "${#_port}" -le 5 ] || return 1
  [ "$_port" -ge 1 ] && [ "$_port" -le 65535 ] || return 1
  printf '%s' "$_v"
}

remote=""
if [ -n "${NGROK_REMOTE_ADDR:-}" ]; then
  if ! remote=$(woow_remote_addr "$NGROK_REMOTE_ADDR"); then
    remote=""
    echo "ngrok.remoteAddr is not a host:port address (for example 1.tcp.ngrok.io:12345), ignored: ngrok assigns a random address"
  fi
fi
pp=""
if [ "${WOOW_NGROK_PROXY_PROTOCOL:-false}" = "true" ]; then
  pp="--upstream-proxy-protocol=2"
fi

filter_ok=0
if [ -r "$redact_awk" ] && command -v awk >/dev/null 2>&1; then
  filter_ok=1
else
  echo "ngrok agent output is not shown: the redaction filter ($redact_awk) is missing"
fi
fifo="${TMPDIR:-/tmp}/ngrok-agent.$$"

backoff=10
while :; do
  out=/dev/null # no filter / no FIFO → drop the agent's output rather than leak it
  filter=""
  rm -f "$fifo"
  if [ "$filter_ok" = 1 ] && mkfifo "$fifo" 2>/dev/null; then
    out=$fifo
    awk -f "$redact_awk" <"$fifo" &
    filter=$!
  fi
  # --log-level warn: failures only (the ERROR block on stderr is printed at
  # every level); no per-connection lines that would push the address out of
  # the tail the platform reads.
  # shellcheck disable=SC2086 # $pp is one optional flag, never tenant text
  if [ -n "$remote" ]; then
    ngrok tcp "$upstream" $pp "--remote-addr=$remote" --log stdout --log-level warn >"$out" 2>&1 &
  else
    ngrok tcp "$upstream" $pp --log stdout --log-level warn >"$out" 2>&1 &
  fi
  agent=$!
  # Poll fast until the first address shows up, then settle on the interval.
  delay=5
  while kill -0 "$agent" 2>/dev/null; do
    url=$(wget -qO- -T 3 "http://${api}/api/tunnels" 2>/dev/null \
      | sed -n 's|.*"public_url":"\(tcp://[^"]*\)".*|\1|p' | head -n1)
    if [ -n "${url:-}" ]; then
      echo "WOOW_MQTT_PUBLIC_URL=${url}"
      delay=$interval
      backoff=10
    fi
    sleep "$delay"
  done
  wait "$agent" || true
  # let the filter drain the agent's last lines before announcing
  if [ -n "$filter" ]; then wait "$filter" 2>/dev/null || true; fi
  rm -f "$fifo"
  echo "WOOW_MQTT_PUBLIC_URL="
  echo "ngrok agent exited; retrying in ${backoff}s (check the authtoken and reserved address in the service settings)"
  sleep "$backoff"
  backoff=$((backoff * 2))
  if [ "$backoff" -gt "$max_backoff" ]; then backoff=$max_backoff; fi
done
