# EMQX podman Quadlet units

Systemd `--user` units that let rootless podman run EMQX (and optionally the
ngrok TCP tunnel) as a systemd service on `podman-mcp.woowtech.io`
(`192.168.2.191`) or any other rootless podman host.

Requires: `podman >= 4.4` (Quadlet built in), `systemd --user` and
`loginctl enable-linger <user>` on the host.

## Files

| File | Purpose |
|------|---------|
| `emqx.network` | Shared bridge network `woow-emqx` |
| `emqx.container` | EMQX broker (always on) |
| `emqx-ngrok.container` | Optional ngrok TCP tunnel for raw MQTT 1883 |

## Install (rootless, on the target host)

```bash
mkdir -p ~/.config/containers/systemd
cp emqx.network        ~/.config/containers/systemd/
cp emqx.container      ~/.config/containers/systemd/

# Optional: only if you want ngrok
cp emqx-ngrok.container ~/.config/containers/systemd/

# Env override files (optional but recommended):
cat > ~/.config/containers/systemd/emqx.env <<'EOF'
EMQX_DASHBOARD__DEFAULT_PASSWORD=StrongPasswordHere
EMQX_ALLOW_ANONYMOUS=false
EOF
chmod 600 ~/.config/containers/systemd/emqx.env

# Only if you copied emqx-ngrok.container:
cat > ~/.config/containers/systemd/emqx-ngrok.env <<'EOF'
NGROK_AUTHTOKEN=your_ngrok_authtoken_here
# NGROK_TCP_ADDR=1.tcp.ngrok.io:12345   # optional reserved address
EOF
chmod 600 ~/.config/containers/systemd/emqx-ngrok.env

systemctl --user daemon-reload
systemctl --user start emqx.service
# Only if ngrok:
systemctl --user start emqx-ngrok.service
```

Verify:

```bash
systemctl --user status emqx.service
podman ps
podman exec woow-emqx emqx ctl status
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18083   # 200
```

Follow logs:

```bash
journalctl --user -u emqx.service -f
journalctl --user -u emqx-ngrok.service -f
```

## Stop / uninstall

```bash
systemctl --user stop emqx-ngrok.service emqx.service
rm ~/.config/containers/systemd/emqx*.container ~/.config/containers/systemd/emqx.network
systemctl --user daemon-reload

# Remove data (destructive):
podman volume rm woow-emqx-data woow-emqx-log
```

## Notes

- **Reserved ngrok TCP address**: Quadlet's `Exec=` does not expand env vars,
  so if you want `--remote-addr=<addr>` you must edit `emqx-ngrok.container`
  to hard-code it, e.g.
  `Exec=tcp emqx:1883 --remote-addr=1.tcp.ngrok.io:12345 --log stdout`.
- **Ports**: 1883/8883/8083/8084/18083 are all >1024, so rootless podman
  binds them without `cap_net_bind_service`. If you need <1024 ports, set
  `sysctl net.ipv4.ip_unprivileged_port_start=<port>`.
- **Auto-start on boot**: no `systemctl --user enable` needed — Quadlet units
  with `[Install] WantedBy=default.target` are wanted by the user default
  target once linger is on, but you may want to run
  `systemctl --user enable emqx.service` to be explicit.
- **Registry**: images use `docker.io/emqx/emqx` and `docker.io/ngrok/ngrok`
  full names to avoid rootless `unqualified-search-registries` resolution
  going to `docker.io/library/*`.
