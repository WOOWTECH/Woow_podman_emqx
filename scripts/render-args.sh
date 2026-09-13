# shellcheck shell=bash
# scripts/render-args.sh: values computed from ~/.config/emqx/emqx.env. Sourced by scripts/install.sh
# and tests/dryrun.sh, so CI renders exactly what a host gets.
#
# render_args <envfile>: QL_ENV is already loaded from <envfile>; sets RENDER_ARGS=(KEY=VALUE...).
# Dies on an invalid knob, so a typo never reaches a unit file.
render_args() {
  local bind prefix name port addr
  local -A seen=()
  bind=$(ql_env_get WOOW_EMQX_BIND)
  ql_assert_match WOOW_EMQX_BIND "$bind" 'all|[0-9]{1,3}(\.[0-9]{1,3}){3}'
  # "all" publishes on every address family (IPv4 and IPv6): omit the host IP.
  if [[ $bind == all ]]; then prefix=''; else prefix="$bind:"; fi
  # shellcheck disable=SC2034 # RENDER_ARGS is read by the caller
  RENDER_ARGS=()
  for name in MQTT MQTTS WS WSS DASHBOARD; do
    port=$(ql_env_get "WOOW_EMQX_PORT_$name")
    ql_assert_match "WOOW_EMQX_PORT_$name" "$port" '[1-9][0-9]{0,4}'
    ((port <= 65535)) || ql_die "WOOW_EMQX_PORT_$name: $port is not a TCP port"
    [[ -z ${seen[$port]+x} ]] || ql_die "WOOW_EMQX_PORT_$name: port $port is already used by WOOW_EMQX_PORT_${seen[$port]}"
    seen[$port]=$name
    RENDER_ARGS+=("EMQX_PUBLISH_$name=$prefix$port")
  done
  addr=$(ql_env_get WOOW_EMQX_NGROK_REMOTE_ADDR '')
  if [[ -n $addr ]]; then
    ql_assert_match WOOW_EMQX_NGROK_REMOTE_ADDR "$addr" '[A-Za-z0-9.-]+:[0-9]{1,5}'
    RENDER_ARGS+=("EMQX_NGROK_ARGS= --remote-addr=$addr")
  else
    RENDER_ARGS+=("EMQX_NGROK_ARGS=")
  fi
}
