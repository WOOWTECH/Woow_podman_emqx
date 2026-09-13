# shellcheck shell=bash
# tests/dryrun.local.sh: EMQX-specific variants and assertions. Sourced at the end of tests/dryrun.sh
# (vendored), which provides run_variant, render_variant, $WORK, $REPO, $base, $optional, $failures.
# shellcheck disable=SC2154 # the variables above are defined by tests/dryrun.sh

# The optional ngrok unit with a reserved address and every port on all interfaces.
run_variant lan+ngrok "$REPO/tests/fixtures/lan.env" "${base[@]}" "${optional[@]}"

check() { # check <description> <command...>
  if "${@:2}"; then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi
}
has_line() { grep -qxF -- "$3" "$WORK/$1/out/$2"; }

check "example publishes MQTT on 127.0.0.1" has_line example emqx.container 'PublishPort=127.0.0.1:1883:1883'
check "example publishes the dashboard on 127.0.0.1" has_line example emqx.container 'PublishPort=127.0.0.1:18083:18083'
check "BIND=all omits the host address" has_line fixture-lan emqx.container 'PublishPort=21883:1883'
check "moved ports are rendered" has_line fixture-ports-moved emqx.container 'PublishPort=127.0.0.1:28183:18083'
check "ngrok without a reserved address" has_line example+optional emqx-ngrok.container 'Exec=tcp woow-emqx:1883 --log stdout'
check "ngrok with a reserved address" has_line lan+ngrok emqx-ngrok.container \
  'Exec=tcp woow-emqx:1883 --log stdout --remote-addr=1.tcp.ngrok.io:12345'
check "base.hocon declares the built-in-db authenticator (anonymous off)" \
  grep -qE '^[[:space:]]*backend = built_in_database' "$REPO/config/base.hocon"
check "no unit or config sets the EMQX 4 allow-anonymous variable" \
  bash -c "! grep -rqE 'EMQX_ALLOW_ANONYMOUS' '$REPO/quadlet' '$REPO/config'"

# Invalid knobs must stop the render before any file is written.
reject() { # reject <description> <KEY> <bad value>
  local env=$WORK/bad-$2.env
  sed "s|^$2=.*|$2=$3|" "$REPO/config/emqx.env.example" >"$env"
  mkdir -p "$WORK/bad-$2/src" "$WORK/bad-$2/out"
  cp -p -- "${base[@]}" "$WORK/bad-$2/src/"
  if (render_variant "$WORK/bad-$2/src" "$env" "$WORK/bad-$2/out") >/dev/null 2>&1; then
    echo "FAIL $1 was accepted"
    failures=$((failures + 1))
  else
    echo "ok   $1 is refused"
  fi
}
reject "a bind address with shell metacharacters" WOOW_EMQX_BIND '127.0.0.1;touch /tmp/x'
reject "a port out of range" WOOW_EMQX_PORT_MQTT 70000
reject "a port used by two knobs" WOOW_EMQX_PORT_WS 1883
