#!/usr/bin/env bash
# scripts/ngrok-url.sh: print the public tcp:// address of the optional ngrok tunnel (from the journal
# of emqx-ngrok.service). Exits 1 when the tunnel has not reported an address yet.
set -euo pipefail
url=$(journalctl --user -u emqx-ngrok.service -o cat --no-pager 2>/dev/null | grep -oE 'url=tcp://[^ ]+' | tail -n1 || true)
[[ -n $url ]] || { echo "ngrok-url: no tunnel address yet (systemctl --user status emqx-ngrok.service)" >&2; exit 1; }
printf '%s\n' "${url#url=}"
