# EMQX MQTT Broker — Docker / Podman Deployment

One-click deployment of **EMQX MQTT Broker** using Docker Compose or Podman Compose.
EMQX is the world's leading open-source distributed MQTT broker, designed for IoT,
M2M and mobile applications and capable of handling millions of concurrent
connections.

[中文版說明見下方](#中文)

## Other deployment platforms | 其他部署平台

- **K3s / Kubernetes (Helm chart)** → [Woow_k3s_emqx](https://github.com/WOOWTECH/Woow_k3s_emqx)
- **Home Assistant add-on** → [Woow_ha_emqx](https://github.com/WOOWTECH/Woow_ha_emqx)

This repository contains **only the Docker / Podman Compose deployment**. For
Kubernetes or Home Assistant, use the sibling repositories above.

---

## English

### Overview

Verified environments:

- **EMQX 6.0.0** (`emqx/emqx:latest`)
- **Podman 4.9.3** + `podman-compose` 1.0.6
- **Docker Compose v2.x** on Ubuntu / Linux

### Architecture

```
┌──────────────────────────────────────────────┐
│              EMQX Broker v6.0.0              │
│  ┌──────────────────────────────────────────┐│
│  │  MQTT TCP:       1883                    ││
│  │  MQTT SSL/TLS:   8883                    ││
│  │  WebSocket:      8083                    ││
│  │  WebSocket SSL:  8084                    ││
│  │  Dashboard UI:   18083                   ││
│  └──────────────────────────────────────────┘│
│  Volumes:                                    │
│  ├── emqx_data (config + runtime data)       │
│  └── emqx_log  (logs)                        │
└──────────────────────────────────────────────┘
               ▲
               │ MQTT
     ┌─────────┴─────────┐
     │  IoT devices /    │
     │  sensors          │
     └───────────────────┘
```

### Requirements

| Item | Minimum |
|------|---------|
| Container engine | Docker 20.10+ or Podman 4.0+ |
| Compose tool     | Docker Compose 2.0+ or `podman-compose` |
| Memory           | 512 MB (1 GB+ recommended) |
| Ports            | 1883, 8883, 8083, 8084, 18083 |

### Project structure

```
Woow_podman_emqx/
├── docker-compose.yml   # Compose service definition
├── .env.example         # Environment variable template (copy to .env)
├── .gitignore           # Excludes .env and other sensitive files
├── README.md            # This bilingual guide
└── DEPLOY_SKILL.md      # AI rapid-deployment skill guide
```

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

#### Via Web Editor

1. Copy the raw URL of `docker-compose.yml`:

   ```
   https://raw.githubusercontent.com/WOOWTECH/Woow_podman_emqx/main/docker-compose.yml
   ```

2. Log in to Portainer → **Stacks** → **Add stack** → **Web editor**
3. Fetch the file above with `curl` or your browser, paste into the editor
4. Set environment variables (see `.env.example`)
5. Click **Deploy the stack**

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
docker exec emqx emqx ctl status         # Node 'emqx@127.0.0.1' 6.0.0 is started
curl -s -o /dev/null -w "%{http_code}" http://localhost:18083   # 200
```

Open **http://localhost:18083** and log in with `admin` / `public` (or the
password you set in `.env`).

### Key environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `EMQX_VERSION`             | `latest` | EMQX image tag |
| `EMQX_DASHBOARD_USER`      | `admin`  | Dashboard username |
| `EMQX_DASHBOARD_PASSWORD`  | `public` | Dashboard password (**change this**) |
| `EMQX_DASHBOARD_PORT`      | `18083`  | Dashboard web UI port |
| `MQTT_TCP_PORT`            | `1883`   | Plain MQTT |
| `MQTT_SSL_PORT`            | `8883`   | MQTT over TLS |
| `MQTT_WS_PORT`             | `8083`   | MQTT over WebSocket |
| `MQTT_WSS_PORT`            | `8084`   | MQTT over Secure WebSocket |
| `EMQX_HOST`                | `127.0.0.1` | Node host / IP |
| `EMQX_ALLOW_ANONYMOUS`     | `true`   | Allow anonymous MQTT clients |

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

- `emqx_data` — configuration, rule engine, authentication data
- `emqx_log` — runtime logs

Backup / restore:

```bash
# Backup
docker run --rm -v emqx_data:/data -v $(pwd):/backup alpine \
  tar czf /backup/emqx_data_backup.tar.gz /data

# Restore
docker run --rm -v emqx_data:/data -v $(pwd):/backup alpine \
  tar xzf /backup/emqx_data_backup.tar.gz -C /
```

### Complete removal

```bash
docker compose down       # keeps volumes
docker compose down -v    # removes volumes as well
```

### Production notes

1. Change `EMQX_DASHBOARD_PASSWORD` to a strong password
2. Set `EMQX_ALLOW_ANONYMOUS=false` and configure authentication in the Dashboard
3. Configure TLS certificates for port 8883
4. Restrict ports at the firewall to trusted IPs
5. Schedule regular backups of the `emqx_data` volume
6. Add `deploy.resources.limits` in `docker-compose.yml` if needed

### Troubleshooting

| Problem | Likely cause | Fix |
|---------|--------------|-----|
| Container keeps restarting | Port in use | `ss -tlnp \| grep -E '1883\|8883\|8083\|8084\|18083'` |
| Dashboard unreachable | Not ready yet | Wait 30 s, check `docker compose ps` for `healthy` |
| MQTT refused | Service not running | Check container status and firewall |
| Login fails | Stale data | `docker compose down -v && docker compose up -d` |

---

## 中文

### 簡介

本專案提供使用 Docker Compose 或 Podman Compose 一鍵部署 **EMQX MQTT Broker**
的方案。EMQX 是全球領先的開源分散式 MQTT 訊息代理,專為 IoT、M2M 與行動
應用設計,可支援數百萬級並發連接。

已驗證環境:

- **EMQX 6.0.0** (`emqx/emqx:latest`)
- **Podman 4.9.3** + `podman-compose` 1.0.6
- **Docker Compose v2.x** on Ubuntu / Linux

### 快速開始

```bash
git clone https://github.com/WOOWTECH/Woow_podman_emqx.git
cd Woow_podman_emqx
cp .env.example .env
# 編輯 .env,至少修改 EMQX_DASHBOARD_PASSWORD

docker compose up -d
# 或 Podman
podman-compose up -d
```

等待約 30 秒後開啟瀏覽器訪問 **http://localhost:18083**,以 `admin` / `public`
(或你在 `.env` 中設定的密碼) 登入。

### 一鍵部署至 Portainer

使用 Portainer 的 Stack 功能,可透過 GitHub Repository 網址快速部署。

| 欄位 | 值 |
|------|-----|
| **Repository URL** | `https://github.com/WOOWTECH/Woow_podman_emqx` |
| **Repository reference** | `refs/heads/main` |
| **Compose path** | `docker-compose.yml` |

### 生產環境建議

1. 修改 `EMQX_DASHBOARD_PASSWORD` 為強密碼
2. 設定 `EMQX_ALLOW_ANONYMOUS=false`,並在 Dashboard 啟用驗證
3. 為 8883 埠設定 TLS 憑證
4. 僅在防火牆開放必要埠給信任的 IP
5. 定期備份 `emqx_data` volume

其他章節與英文版相同,詳見上方。

---

## Migration note | 遷移說明

This repository was split out of the retired monorepo
`WOOWTECH/Woow_eqmx_docker_compose_all` (note the typo `eqmx` in the old name)
during the WOOWTECH repo restructure. The old repository has been archived and
is no longer updated — use this repository for Podman / Docker Compose
deployments, and the sibling repositories linked at the top for K3s and
Home Assistant.

本倉庫由已封存的舊倉庫 `WOOWTECH/Woow_eqmx_docker_compose_all` (舊名有拼字
`eqmx`) 拆分而來。舊倉庫已封存不再更新,請改用本倉庫進行 Podman / Docker
Compose 部署,K3s 與 Home Assistant 請使用文件上方列出的姊妹倉庫。
