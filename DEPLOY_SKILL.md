# EMQX Docker Compose 部署 Skill / Deployment Skill

> 本檔案提供 AI 助手快速部署 EMQX 的完整指引。
> This file provides AI assistants a complete guide for rapid EMQX deployment.

---

## 前置條件 / Prerequisites

- Docker 20.10+ 或 Podman 4.0+
- Docker Compose 2.0+ 或 podman-compose
- 可用端口: 1883, 8883, 8083, 8084, 18083

## 部署步驟 / Deployment Steps

### Step 1: Clone 專案

```bash
git clone https://github.com/WOOWTECH/Woow_podman_emqx.git
cd Woow_podman_emqx
```

### Step 2: 建立環境配置

```bash
cp .env.example .env
```

如需修改密碼或端口，編輯 `.env`：
```bash
# 修改 Dashboard 密碼
sed -i 's/EMQX_DASHBOARD_PASSWORD=public/EMQX_DASHBOARD_PASSWORD=YourSecurePassword/' .env

# 或手動編輯
nano .env
```

### Step 3: 啟動服務

**Docker:**
```bash
docker compose up -d
```

**Podman:**
```bash
podman-compose up -d
```

### Step 4: 驗證部署

```bash
# 檢查容器狀態 (等待 healthy)
docker compose ps
# 或
podman-compose ps

# 檢查 EMQX 運行狀態
docker exec emqx emqx ctl status
# 或
podman exec emqx emqx ctl status

# 測試 Dashboard HTTP 回應
curl -s -o /dev/null -w "%{http_code}" http://localhost:18083
# 預期回應: 200
```

### Step 5: 登入 Dashboard

- URL: http://localhost:18083
- 帳號: admin
- 密碼: public (或 .env 中設定的密碼)

---

## 一鍵部署 / One-Liner Deploy

```bash
git clone https://github.com/WOOWTECH/Woow_podman_emqx.git && cd Woow_podman_emqx && cp .env.example .env && docker compose up -d
```

**Podman 版本:**
```bash
git clone https://github.com/WOOWTECH/Woow_podman_emqx.git && cd Woow_podman_emqx && cp .env.example .env && podman-compose up -d
```

---

## 端口對照表 / Port Reference

| 端口 Port | 協定 Protocol | 用途 Purpose |
|-----------|--------------|-------------|
| 1883 | MQTT TCP | 標準 MQTT 連接 / Standard MQTT |
| 8883 | MQTT SSL | 加密 MQTT 連接 / Encrypted MQTT |
| 8083 | WebSocket | MQTT over WS |
| 8084 | WebSocket SSL | MQTT over WSS |
| 18083 | HTTP | Dashboard 管理介面 / Web UI |

---

## 檔案結構 / File Structure

```
Woow_podman_emqx/
├── docker-compose.yml   # 主要部署配置 / Main compose config
├── .env.example         # 環境變數範例 / Env vars template
├── .gitignore           # Git 忽略規則 / Git ignore rules
├── README.md            # 完整中英文說明 / Full bilingual docs
└── DEPLOY_SKILL.md      # AI 部署技能指引 / This file
```

---

## 常用操作指令 / Common Operations

```bash
# 啟動 / Start
docker compose up -d

# 停止 / Stop
docker compose down

# 重啟 / Restart
docker compose restart

# 查看日誌 / View logs
docker compose logs -f emqx

# 進入容器 / Enter container
docker compose exec emqx sh

# 查看狀態 / Check status
docker compose exec emqx emqx ctl status

# 列出已連接客戶端 / List connected clients
docker compose exec emqx emqx ctl clients list

# 列出訂閱主題 / List subscriptions
docker compose exec emqx emqx ctl topics list
```

以上指令使用 Podman 時，將 `docker compose` 替換為 `podman-compose`，`docker exec` 替換為 `podman exec`。

---

## MQTT 測試指令 / MQTT Test Commands

```bash
# 安裝 mosquitto 客戶端
# Ubuntu/Debian
sudo apt install mosquitto-clients
# macOS
brew install mosquitto

# 訂閱 / Subscribe (Terminal 1)
mosquitto_sub -h localhost -p 1883 -t "test/topic" -v

# 發布 / Publish (Terminal 2)
mosquitto_pub -h localhost -p 1883 -t "test/topic" -m "Hello EMQX!"
```

---

## 資料備份還原 / Backup & Restore

```bash
# 備份 / Backup
docker run --rm -v emqx_data:/data -v $(pwd):/backup alpine tar czf /backup/emqx_data_backup.tar.gz /data
docker run --rm -v emqx_log:/data -v $(pwd):/backup alpine tar czf /backup/emqx_log_backup.tar.gz /data

# 還原 / Restore
docker run --rm -v emqx_data:/data -v $(pwd):/backup alpine tar xzf /backup/emqx_data_backup.tar.gz -C /
docker run --rm -v emqx_log:/data -v $(pwd):/backup alpine tar xzf /backup/emqx_log_backup.tar.gz -C /
```

---

## 故障排除 / Troubleshooting

| 問題 Issue | 解決方案 Solution |
|-----------|-----------------|
| 容器一直重啟 / Container keeps restarting | 檢查端口衝突: `ss -tlnp \| grep -E '1883\|8883\|8083\|8084\|18083'` |
| Dashboard 無法訪問 / Dashboard unreachable | 確認容器 healthy: `docker compose ps` |
| MQTT 連接被拒 / MQTT connection refused | 確認 1883 端口已開放，檢查防火牆設定 |
| 密碼不正確 / Wrong password | 重新建立容器: `docker compose down && docker compose up -d` |

---

## 生產環境安全建議 / Production Security

1. 修改預設密碼 / Change default password
2. 設定 `EMQX_ALLOW_ANONYMOUS=false`
3. 啟用 SSL/TLS 證書 / Enable SSL/TLS certificates
4. 設定防火牆規則 / Configure firewall rules
5. 定期備份資料 / Regular data backups
