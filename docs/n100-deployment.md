# Deployment reliability

The broker health probe now uses its local node /status endpoint, avoiding a second Erlang VM whose startup exceeded the probe budget on a busy N100. This does not expose a new listener. MQTT authentication and topic authorization require a separate publish/read test.

HA discovery access is opt-in: scripts/install.sh --set WOOW_EMQX_HA_DISCOVERY_USER=woow grants only that validated MQTT username access to homeassistant/#. Use the same account in Home Assistant. An empty value restores the unchanged default per-user ACL. It neither creates a superuser nor grants other users access. Existing Dashboard-managed authorization sources retain their normal precedence. The full appliance previously used the same account-scoped rule and passed a discovery/state readback plus fixture cleanup.

[Existing N100 deployment and functional evidence](https://github.com/WOOWTECH/Woow_ubuntu_version_control/blob/195dcda9357100a7821407e1c8469a349acc9831/distribution/docs/reboot-acceptance.md). Source fixes do not themselves restart an existing installation.
