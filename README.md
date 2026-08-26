# EMQX MQTT Broker — Docker / Podman Deployment

One-click deployment of **EMQX MQTT Broker** using Docker Compose or Podman Compose.
EMQX is the world's leading open-source distributed MQTT broker, designed for IoT,
M2M and mobile applications and capable of handling millions of concurrent
connections.

Parity with the WoowTech HA add-on [`Woow_ha_emqx`](https://github.com/WOOWTECH/Woow_ha_emqx)
v5.9.0 — same EMQX version (`5.8.9`), same optional ngrok TCP tunnel behavior.

[中文版說明見下方](#中文)

## Other deployment platforms | 其他部署平台

- **K3s / Kubernetes (Helm chart)** → [Woow_k3s_emqx](https://github.com/WOOWTECH/Woow_k3s_emqx)
- **Home Assistant add-on** → [Woow_ha_emqx](https://github.com/WOOWTECH/Woow_ha_emqx)

---

## English

### Overview

Verified environments:

- **EMQX 5.8.9** (`docker.io/emqx/emqx:5.8.9`, matches HA add-on bundle)
- **Podman 5.x** rootless on `podman-mcp.woowtech.io` (host `192.168.2.191`)
- **Podman 4.9.3** + `podman-compose` 1.0.6
- **Docker Compose v2.x** on Ubuntu / Linux

### Architecture

```
┌────────────────────────────────────────────────┐
│                EMQX Broker v5.8.9              │
│  ┌────────────────────────────────────────────┐│
│  │  MQTT TCP:       1883                      ││
│  │  MQTT SSL/TLS:   8883                      ││
│  │  WebSocket:      8083                      ││
│  │  WebSocket SSL:  8084                      ││
│  │  Dashboard UI:   18083                     ││
│  └────────────────────────────────────────────┘│
│  Volumes:                                      │
│  ├── woow_emqx_data (config + runtime)         │
│  └── woow_emqx_log  (logs)                     │
└────────────────────────────────────────────────┘
             ▲                       ▲
             │ MQTT                  │ (optional)
   ┌─────────┴─────────┐   ┌─────────┴──────────┐
   │  IoT devices /    │   │  ngrok TCP tunnel  │
   │  sensors          │   │  (profile: ngrok)  │
   └───────────────────┘   └────────────────────┘
```

### Requirements

| Item | Minimum |
|------|---------|
| Container engine | Docker 20.10+ or Podman 4.0+ |
| Compose tool     | Docker Compose 2.0+ or `podman-compose` 1.0.6+ |
| Memory           | 512 MB (1 GB+ recommended) |
| Ports            | 1883, 8883, 8083, 8084, 18083 |

### Project structure

```
Woow_podman_emqx/
├── docker-compose.yml        # Compose service definition (EMQX + optional ngrok sidecar)
├── .env.example              # Environment variable template (copy to .env)
├── .gitignore                # Excludes .env and other sensitive files
├── README.md                 # This bilingual guide
├── CHANGELOG.md              # Version history
├── DEPLOY_SKILL.md           # AI rapid-deployment skill guide
└── podman-quadlet/           # Systemd Quadlet units for `.191` rootless auto-start
    ├── README.md
    ├── emqx.network
    ├── emqx.container
    └── emqx-ngrok.container
```

### Quick start

```bash
git clone https://github.com/WOOWTECH/Woow_podman_emqx.git
cd Woow_podman_emqx
cp .env.example .env
# Edit .env — at minimum change EMQX_DASHBOARD_PASSWORD

# Docker
docker compose up -d

# or Podman
podman-compose up -d
```

Wait ~30 seconds for EMQX to boot, then verify:

```bash
docker compose ps                        # STATUS: healthy
docker exec woow-emqx emqx ctl status    # Node 'emqx@127.0.0.1' 5.8.9 is started
curl -s -o /dev/null -w "%{http_code}" http://localhost:18083   # 200
```

Open **http://localhost:18083** and log in with `admin` / `public` (or the
password you set in `.env`).

### ngrok TCP tunnel (optional)

Expose raw MQTT (port 1883) as a public TCP tunnel via ngrok. Mirrors the
HA add-on behavior:

- **Only tunnels 1883** (raw MQTT). WebSocket (8083) is out of scope — use
  Cloudflare Tunnel for that.
- The `ngrok-announce` one-shot polls the local ngrok API and prints the
  resolved public URL to `docker compose logs ngrok-announce`.

Setup:

```bash
# 1. Fill in your ngrok authtoken in .env
sed -i 's/^NGROK_AUTHTOKEN=$/NGROK_AUTHTOKEN=YOUR_TOKEN_HERE/' .env

# 2. Optional: pin a reserved TCP address so the public endpoint survives restarts
#    (Reserve one under https://dashboard.ngrok.com/cloud-edge/tcp-addresses first)
#    NGROK_TCP_ADDR=1.tcp.ngrok.io:12345

# 3. Bring up EMQX + ngrok + ngrok-announce
docker compose --profile ngrok up -d

# 4. Read the public URL from the announce container
docker compose logs ngrok-announce
# >>> MQTT ngrok: tcp://1.tcp.ngrok.io:12345
```

Turn it off:

```bash
docker compose --profile ngrok down
# or just remove ngrok while keeping EMQX
docker compose rm -sf ngrok ngrok-announce
```

### Deploy on `podman-mcp.woowtech.io` (host `192.168.2.191`) — rootless

This host runs rootless podman as `woowtech-ai-coder` (uid 1000) with
`systemd --user` and `loginctl enable-linger` on. Two integration options:

**Option A — `podman-compose` on demand (quickest):**

```bash
ssh woowtech-ai-coder@192.168.2.191
git clone https://github.com/WOOWTECH/Woow_podman_emqx.git ~/Woow_podman_emqx
cd ~/Woow_podman_emqx
cp .env.example .env && nano .env   # set EMQX_DASHBOARD_PASSWORD
podman-compose up -d
```

**Option B — systemd Quadlet auto-start (survives reboot):**

Copy the four unit files under `podman-quadlet/` into
`~/.config/containers/systemd/`, then `systemctl --user daemon-reload`.
Full instructions and env-file templates: [`podman-quadlet/README.md`](podman-quadlet/README.md).

Known rootless-podman gotchas on this host (from prior deploys):

1. Registry qualifier is mandatory — `unqualified-search-registries` may not
   include Docker Hub. All images in `docker-compose.yml` use the explicit
   `docker.io/...` prefix.
2. Ports 1883/8883/8083/8084/18083 are all >1024 → no `cap_net_bind_service`
   needed. Ports <1024 would require `sysctl net.ipv4.ip_unprivileged_port_start=X`.
3. Rootless podman cannot bind to the host's default `127.0.0.1` interface if
   another user's container already holds the port — check with
   `ss -tlnp` before `up`.

### Deploy to Portainer

Deploy this project instantly using Portainer's Stack feature with our GitHub
repository URL.

[![Deploy to Portainer](https://img.shields.io/badge/Deploy_to-Portainer-13BEF9?style=for-the-badge&logo=portainer&logoColor=white)](#deploy-to-portainer)

#### Via Git Repository (recommended)

1. Log in to your Portainer dashboard
2. Navigate to **Stacks** → **Add stack**
3. Select **Repository**
4. Fill in the following:

   | Field | Value |
   |-------|-------|
   | **Repository URL** | `https://github.com/WOOWTECH/Woow_podman_emqx` |
   | **Repository reference** | `refs/heads/main` |
   | **Compose path** | `docker-compose.yml` |

5. Click **Deploy the stack**

> Note: Portainer's Stack feature does **not** currently pass compose profiles.
> The ngrok sidecar (`--profile ngrok`) must be enabled from CLI, not
> Portainer UI.

### Key environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `EMQX_VERSION`             | `5.8.9`  | EMQX image tag (aligned with HA add-on) |
| `EMQX_DASHBOARD_USER`      | `admin`  | Dashboard username |
| `EMQX_DASHBOARD_PASSWORD`  | `public` | Dashboard password (**change this**) |
| `EMQX_DASHBOARD_PORT`      | `18083`  | Dashboard web UI port |
| `MQTT_TCP_PORT`            | `1883`   | Plain MQTT |
| `MQTT_SSL_PORT`            | `8883`   | MQTT over TLS |
| `MQTT_WS_PORT`             | `8083`   | MQTT over WebSocket |
| `MQTT_WSS_PORT`            | `8084`   | MQTT over Secure WebSocket |
| `EMQX_HOST`                | `127.0.0.1` | Node host / IP (cluster mode) |
| `EMQX_ALLOW_ANONYMOUS`     | `true`   | Allow anonymous MQTT clients |
| `NGROK_AUTHTOKEN`          | *(empty)* | Required when `--profile ngrok` is used |
| `NGROK_TCP_ADDR`           | *(empty)* | Optional reserved TCP address (else auto-assigned) |
| `COMPOSE_PROJECT_NAME`     | `woow`   | Prefix for container / volume / network names |

### Port reference

| Port  | Protocol       | Purpose                    |
|-------|----------------|----------------------------|
| 1883  | MQTT TCP       | Standard MQTT connection   |
| 8883  | MQTT SSL       | TLS-encrypted MQTT         |
| 8083  | WebSocket      | MQTT over WebSocket        |
| 8084  | WebSocket SSL  | MQTT over WSS              |
| 18083 | HTTP           | Dashboard management UI    |

### Common operations

```bash
# Service management
docker compose up -d
docker compose down
docker compose restart
docker compose logs -f emqx

# EMQX management
docker compose exec emqx emqx ctl status
docker compose exec emqx emqx ctl clients list
docker compose exec emqx emqx ctl topics list
docker compose exec emqx emqx ctl cluster status
```

> **Podman users**: replace `docker compose` with `podman-compose` and
> `docker exec` with `podman exec`.

### MQTT connectivity test

```bash
# Install mosquitto client tools
sudo apt install mosquitto-clients   # Debian / Ubuntu
brew install mosquitto               # macOS
apk add mosquitto-clients            # Alpine

# Terminal 1: subscribe
mosquitto_sub -h localhost -p 1883 -t "test/topic" -v

# Terminal 2: publish
mosquitto_pub -h localhost -p 1883 -t "test/topic" -m "Hello EMQX!"

# With authentication (once anonymous is disabled)
mosquitto_sub -h localhost -p 1883 -t "test/#" -u "user" -P "pass" -v
```

### Persistence

Data is stored in named volumes and survives container removal:

- `woow_emqx_data` — configuration, rule engine, authentication data
- `woow_emqx_log` — runtime logs

(Volume names are prefixed by `COMPOSE_PROJECT_NAME`; default `woow`.)

Backup / restore:

```bash
# Backup
docker run --rm -v woow_emqx_data:/data -v $(pwd):/backup alpine \
  tar czf /backup/emqx_data_backup.tar.gz /data

# Restore
docker run --rm -v woow_emqx_data:/data -v $(pwd):/backup alpine \
  tar xzf /backup/emqx_data_backup.tar.gz -C /
```

### Complete removal

```bash
docker compose down       # keeps volumes
docker compose down -v    # removes volumes as well
```

### Production notes

1. Change `EMQX_DASHBOARD_PASSWORD` to a strong password.
2. Set `EMQX_ALLOW_ANONYMOUS=false` and configure authentication in the Dashboard.
3. Configure TLS certificates for port 8883.
4. Restrict ports at the firewall to trusted IPs — the default binds `0.0.0.0`
   (LAN-reachable). For lockdown, prefix each port with `127.0.0.1:` in `.env`.
5. Schedule regular backups of `woow_emqx_data`.
6. Add `deploy.resources.limits` in `docker-compose.yml` if needed.

### Troubleshooting

| Problem | Likely cause | Fix |
|---------|--------------|-----|
| Container keeps restarting | Port in use | `ss -tlnp \| grep -E '1883\|8883\|8083\|8084\|18083'` |
| Dashboard unreachable | Not ready yet | Wait 30 s, check `docker compose ps` for `healthy` |
| MQTT refused | Service not running | Check container status and firewall |
| Login fails | Stale data | `docker compose down -v && docker compose up -d` |
| `ngrok` exits `ERR_NGROK_105` | Missing / invalid authtoken | Set `NGROK_AUTHTOKEN` in `.env` |
| `ngrok-announce` prints timeout | ngrok tunnel not up in 120 s | Read `docker compose logs ngrok` for the real error |
| Rootless podman: image pull `403` | Unqualified name resolved to `docker.io/library/...` | Images already use `docker.io/emqx/emqx` — check `/etc/containers/registries.conf` |

---

## 中文

### 簡介

本專案提供使用 Docker Compose 或 Podman Compose 一鍵部署 **EMQX MQTT Broker**
的方案。EMQX 是全球領先的開源分散式 MQTT 訊息代理，專為 IoT、M2M 與行動
應用設計，可支援數百萬級並發連接。

版本對齊 WoowTech HA add-on [`Woow_ha_emqx`](https://github.com/WOOWTECH/Woow_ha_emqx)
v5.9.0 — 相同 EMQX 版本（`5.8.9`），相同的選配 ngrok TCP tunnel 行為。

已驗證環境:

- **EMQX 5.8.9** (`docker.io/emqx/emqx:5.8.9`)
- **Podman 5.x** rootless on `podman-mcp.woowtech.io`（`192.168.2.191`）
- **Podman 4.9.3** + `podman-compose` 1.0.6
- **Docker Compose v2.x** on Ubuntu / Linux

### 快速開始

```bash
git clone https://github.com/WOOWTECH/Woow_podman_emqx.git
cd Woow_podman_emqx
cp .env.example .env
# 編輯 .env，至少修改 EMQX_DASHBOARD_PASSWORD

docker compose up -d
# 或 Podman
podman-compose up -d
```

等待約 30 秒後開啟瀏覽器訪問 **http://localhost:18083**，以 `admin` / `public`
（或你在 `.env` 中設定的密碼）登入。

### ngrok TCP 通道（選用）

把 raw MQTT（1883）透過 ngrok 開為公開 TCP 通道，並自動印出公開網址。
對齊 HA add-on 行為：

- **只 tunnel 1883**（raw MQTT）。WebSocket（8083）不在範圍內，請用 Cloudflare Tunnel。
- `ngrok-announce` one-shot 容器會 poll 本地 ngrok API 並把 public URL 印到 log。

啟用：

```bash
# 1. 在 .env 填入 ngrok authtoken
sed -i 's/^NGROK_AUTHTOKEN=$/NGROK_AUTHTOKEN=你的_token/' .env

# 2. 選填：指定保留的 TCP 位址（重啟後端點才不會變）
#    先到 https://dashboard.ngrok.com/cloud-edge/tcp-addresses 保留
#    NGROK_TCP_ADDR=1.tcp.ngrok.io:12345

# 3. 啟動 EMQX + ngrok + ngrok-announce
docker compose --profile ngrok up -d

# 4. 從 announce 容器讀取 public URL
docker compose logs ngrok-announce
# >>> MQTT ngrok: tcp://1.tcp.ngrok.io:12345
```

關閉：

```bash
docker compose --profile ngrok down
# 或保留 EMQX，只移除 ngrok
docker compose rm -sf ngrok ngrok-announce
```

### 部署到 `podman-mcp.woowtech.io`（`192.168.2.191`）— rootless

該主機以 `woowtech-ai-coder`（uid 1000）跑 rootless podman、`systemd --user`
+ `loginctl enable-linger`。兩種整合方式：

**方式 A — 直接跑 `podman-compose`：**

```bash
ssh woowtech-ai-coder@192.168.2.191
git clone https://github.com/WOOWTECH/Woow_podman_emqx.git ~/Woow_podman_emqx
cd ~/Woow_podman_emqx
cp .env.example .env && nano .env   # 設定 EMQX_DASHBOARD_PASSWORD
podman-compose up -d
```

**方式 B — systemd Quadlet 自動啟動（開機自起）：**

把 `podman-quadlet/` 下的四個 unit 檔複製到 `~/.config/containers/systemd/`，
執行 `systemctl --user daemon-reload`。完整指令與 env-file 範例見
[`podman-quadlet/README.md`](podman-quadlet/README.md)。

Rootless podman 常見坑（來自這台主機過往部署經驗）：

1. **必加 registry qualifier** — `unqualified-search-registries` 未必包含
   Docker Hub。所有 image 都已加 `docker.io/...` 前綴。
2. **本專案埠都 >1024**，不需 `cap_net_bind_service`；若你要用 <1024 埠，
   需 `sysctl net.ipv4.ip_unprivileged_port_start=X`。
3. **多使用者同機注意埠占用** — Rootless podman 不會跨 user 檢查 port
   衝突，`up` 前先 `ss -tlnp` 掃過。

### 生產環境建議

1. 修改 `EMQX_DASHBOARD_PASSWORD` 為強密碼。
2. 設定 `EMQX_ALLOW_ANONYMOUS=false`，並在 Dashboard 啟用驗證。
3. 為 8883 埠設定 TLS 憑證。
4. 預設埠綁到 `0.0.0.0`（LAN 可連）。要鎖 localhost 請在 `.env` 埠前
   加上 `127.0.0.1:`（例如 `MQTT_TCP_PORT=127.0.0.1:1883`）。
5. 定期備份 `woow_emqx_data` volume。

其餘章節（Portainer / MQTT 測試 / 備份還原 / Troubleshooting）與英文版相同。

---

## Migration note | 遷移說明

This repository was split out of the retired monorepo
`WOOWTECH/Woow_eqmx_docker_compose_all` (note the typo `eqmx` in the old name)
during the WOOWTECH repo restructure. The old repository has been archived and
is no longer updated — use this repository for Podman / Docker Compose
deployments, and the sibling repositories linked at the top for K3s and
Home Assistant.

本倉庫由已封存的舊倉庫 `WOOWTECH/Woow_eqmx_docker_compose_all`（舊名有拼字
`eqmx`）拆分而來。舊倉庫已封存不再更新，請改用本倉庫進行 Podman / Docker
Compose 部署，K3s 與 Home Assistant 請使用文件上方列出的姊妹倉庫。
