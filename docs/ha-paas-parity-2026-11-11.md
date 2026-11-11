# EMQX: HA add-on, PaaS and Podman alignment (2026-11-11)

## Sources and running PaaS

| Source | Revision inspected | What it runs |
|---|---|---|
| [WOOWTECH/Woow_ha_emqx](https://github.com/WOOWTECH/Woow_ha_emqx/tree/ac986561eec0d0033a542caaf63707c9e7fd23e4/emqx) | `ac986561eec0d0033a542caaf63707c9e7fd23e4` | Add-on 5.9.1, EMQX 5.8.9 |
| [PaaS Gitea chart](https://git-prod.woowtech.io/woow-paas/woow-paas-charts/src/commit/573e6c471c8f4d2e84bdc80ba959c98f4aed5f08/charts/emqx) | main `573e6c471c8f4d2e84bdc80ba959c98f4aed5f08` | Chart 0.1.11, EMQX 5.8.9 |
| [WOOWTECH/Woow_k3s_emqx](https://github.com/WOOWTECH/Woow_k3s_emqx) | older chart 2.1.0 | Historical reference; not the current tenant chart |

The Gitea source was retrieved from the Gitea API through a Kubernetes service port-forward on
cluster1, because the public hostname requires Cloudflare Access. The checked-out chart is in the
workspace at `research_sources/paas_emqx_source/charts/emqx/` (outside this repo). Cluster1 was
queried with its existing kubeconfig and a verified API-server address. Its live StatefulSets were:

| Namespace | Release | Chart | Status |
|---|---|---|---|
| `paas-ws-57fba9de` | `svc-be34b20d` | 0.1.11 | 1/1 ready |
| `paas-ws-7a3676a7` | `svc-03f99f01` | 0.1.7 | 1/1 ready; older release |

The live broker image digest matched this Podman repo's EMQX 5.8.9 digest. The PaaS chart, not the
historical public k3s chart, is the functional target. The separate EMQX administration MCP add-on
in `Woow_ha_mcp_addons` is a distinct application and is not included in this broker deployment.

## Feature mapping

| Capability | HA add-on / PaaS | Podman result |
|---|---|---|
| Broker and persistence | Both run EMQX 5.8.9; PaaS has separate data/log PVCs | Same broker digest, separate named data/log volumes, stable `emqx@127.0.0.1` node name |
| Dashboard | HA Supervisor ingress; PaaS nginx entrance on 18083 | Local nginx entrance on 18083; dashboard backend on 18093. Native HA ingress is architecture-specific. |
| MQTT WebSocket | PaaS `/mqtt` routes to a loopback WS listener | `/mqtt` upgrades to MQTT WS on 8093; existing direct 8083 remains for clients. |
| Authentication | PaaS rejects anonymous MQTT; dashboard first-boot password in a Secret | Built-in database authentication; anonymous MQTT denied; generated dashboard password in a Podman secret. Podman seeds one ordinary `woow` user for immediate local use; PaaS seeds none. |
| Topic authorization | PaaS 0.1.11 defaults to deny and grants `<username>/#` | Same default rule and wildcard/$ username guard; dashboard edits take precedence over the base defaults. |
| Retained messages | PaaS stores retained messages on disk | `retainer.backend.storage_type = disc` on the data volume. Durable client sessions are not offered by PaaS either. |
| Public HTTP hardening | PaaS hides status, API docs, scrape routes and throttles logins | Same 404 routes (including trailing slashes) and 10 requests/minute plus burst 5; Prometheus scraping requires API authentication. |
| ngrok raw MQTT | HA optional TCP tunnel; PaaS 3.39.11 sidecar with PROXY v2 and token redaction | Optional pinned 3.39.11 container, separate loopback PROXY listener, validated reserved address and redacted logs. No live external tunnel was started because this host has no ngrok token. |
| Credentials and recovery | PaaS secrets are outside Helm release history | Podman secrets are outside the repo and private env file; cold backup/restore now saves and verifies matching secrets. |
| Network isolation | PaaS has Kubernetes NetworkPolicy and same-namespace exceptions | Rootless Podman private bridge; host ports default to loopback. A LAN bind is an explicit host setting; Kubernetes NetworkPolicy has no direct Podman analogue. |
| TLS listeners | PaaS disables self-signed 8883/8084 by default | Both existing self-signed listeners remain published for backward compatibility; trusted public TLS needs an external reverse proxy or certificate configuration. |

The HA add-on exposes raw host-network listeners and supports `env_vars` plus optional ngrok; the
Podman env file accepts non-secret `EMQX_*` overrides and its ngrok container is opt-in. HA's legacy
`admin/public` and anonymous defaults were intentionally not carried into the Podman deployment.

## Verification on `woowtechopenclaw`

- Installed new rootless Quadlet units and generated a fresh data volume, node cookie and passwords.
  The prior Oct 31 deployment had no current Podman volume or secrets. The Sept 14 archives remain
  untouched and were not used to claim current-state recovery.
- `tests/dryrun.sh` passed five render variants, including optional ngrok. `tests/smoke.sh` passed
  16 checks, 0 failures, 1 Podman inspect warning after the restore rehearsal.
- The entrance served `/` with 200; `/status`, `/status/`, `/api/v5/status`,
  `/api/v5/status/`, `/api/v5/prometheus/stats` and `/api-docs` returned 404. `/mqtt` returned
  WebSocket 101 with subprotocol `mqtt`. Repeated wrong dashboard logins yielded 429 after the
  allowed burst.
- Anonymous MQTT was rejected; the generated ordinary user published and subscribed under
  `woow/#`; a subscription to another user's topic was explicitly denied. A retained message
  survived a broker restart.
- A cold backup contained a data archive, checksums and private secret copies. A cold restore
  replaced the data and secrets; both broker and entrance returned healthy, and the quick login
  check passed. The first rehearsal found a Podman inspect display newline captured in secret
  files; the backup writer was fixed and the rehearsal rerun successfully.
- The optional ngrok image and Quadlet rendered; a deliberately invalid dummy token was exercised
  without a public tunnel. This does **not** prove an internet tunnel or remote MQTT delivery.
- The fresh broker was bound to the host's wired LAN address `192.168.2.46`. UFW was configured to
  allow ports 18083, 1883, 8083, 8883 and 8084 only from `192.168.2.0/24` on `enp3s0`. A separate
  HAOS machine at `192.168.2.121` then received Dashboard HTTP 200 and completed a TCP connection
  to MQTT port 1883. The full 16-check smoke test passed again on the LAN bind.

The dashboard password is an environment-type Podman secret, and `podman inspect` exposes that value
to the same Unix user who can inspect the container. Restrict access to this user's Podman socket and
backup directory. Dashboard passwords set after first boot are stored by EMQX in its data volume;
changing the bootstrap Podman secret alone does not rotate an existing Dashboard password.
