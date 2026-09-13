# EMQX MQTT Broker：rootless Podman（Quadlet + systemd）部署

[English](README.md)

本倉庫以 rootless Podman [Quadlet](https://docs.podman.io/en/v4.9.3/markdown/podman-systemd.unit.5.html)
單元在 `systemd --user` 下執行 **EMQX 5.8.9** MQTT broker。透過 linger 開機自動啟動、當機自動重啟，
每台主機的設定集中在一個 env 檔。

其他平台：
[Woow_k3s_emqx](https://github.com/WOOWTECH/Woow_k3s_emqx)（Kubernetes / Helm）·
[Woow_ha_emqx](https://github.com/WOOWTECH/Woow_ha_emqx)（Home Assistant add-on）

> **Docker 或 podman-compose 使用者：** 6.0.0 版已移除 compose 檔。最後一版 compose 保留在 tag
> [`compose-final`](https://github.com/WOOWTECH/Woow_podman_emqx/tree/compose-final)
> （`git clone -b compose-final https://github.com/WOOWTECH/Woow_podman_emqx.git`）。該 tag 不再維護，
> 且保留舊預設值：接受匿名 MQTT、Dashboard 登入為 `admin` / `public`。使用前請務必兩者都改掉。

## 安裝內容

| 項目 | 名稱 | 說明 |
|---|---|---|
| Broker 容器 | `woow-emqx`（單元 `emqx.service`） | `docker.io/emqx/emqx:5.8.9`，以 digest 釘版 |
| 網路 | `woow_emqx_network`（單元 `emqx-network.service`） | 私有 bridge |
| Volume | `woow_emqx_data`、`woow_emqx_log` | 與 compose 相同名稱，既有資料可直接沿用 |
| 選用通道 | `woow-emqx-ngrok`（單元 `emqx-ngrok.service`） | 僅在 `--with-ngrok` 時安裝 |
| 設定 | `~/.config/emqx/emqx.env`（0600）、`~/.config/emqx/base.hocon` | 由 `scripts/install.sh` 建立 |
| 憑證 | podman secrets `woow-emqx-*` | 安裝時產生，絕不寫入檔案 |

安全預設：

- **匿名 MQTT 關閉。** `config/base.hocon` 宣告了內建資料庫認證器，第一個 MQTT 使用者由 podman
  secret 匯入。
- **Dashboard 密碼自動產生。** 不再有 `admin` / `public` 登入。
- **所有埠預設綁定 127.0.0.1。** 要做區網 broker 請設定 `WOOW_EMQX_BIND`。

> **為什麼匿名存取是關閉的。** EMQX 5 的 MQTT 沒有「允許匿名」開關：只要認證鏈是空的，客戶端就被視為
> 匿名；EMQX 4 時代的 `EMQX_ALLOW_ANONYMOUS` 變數會被默默忽略。因此本倉庫先前的每一個安裝都接受匿名
> 客戶端，即使把那個變數設成 `false` 也一樣。真正關閉匿名存取的方法是宣告一個認證器。

## 需求

- 有 systemd 與 cgroup v2 的 Linux。已在 Ubuntu 24.04 測試。
- Podman 4.9 以上、rootless。已用 Ubuntu 24.04 內建的 4.9.3 測試。
- 擁有容器的使用者需以一般登入工作階段操作（ssh 或主控台，不要用 `su` 或 `sudo -u`）。
- 該使用者需啟用 linger。`install.sh` 會自動啟用；若 polkit 拒絕，會印出需要執行的那一行 `sudo` 指令。
- 空閒的埠：1883、8883、8083、8084、18083，每一個都可以改。
- 映像約 250 MB 磁碟，閒置約 50 MB 記憶體。

## 安裝

```bash
git clone https://github.com/WOOWTECH/Woow_podman_emqx.git
cd Woow_podman_emqx
scripts/install.sh               # 第一次：建立 ~/.config/emqx/emqx.env 後停下，讓你先檢查
nano ~/.config/emqx/emqx.env     # 選擇性：綁定位址、埠號、MQTT 使用者名稱
scripts/install.sh               # 產生單元、驗證、拉映像、建立 secrets、啟動、執行 tests/smoke.sh
```

`install.sh` 依序執行以下步驟。在產生單元與 Quadlet dry-run 通過之前，不會安裝任何東西。

1. 前置檢查，然後啟用 linger。
2. 準備 env 檔。
3. 舊容器衝突檢查。
4. 產生單元，接著執行 Quadlet dry-run 與 `systemd-analyze verify`。
5. 拉取映像。
6. 建立 podman secrets。
7. 安裝單元，只重啟有變更的單元。
8. 等待健康檢查通過，然後執行 `tests/smoke.sh`。

常用選項：

| 選項 | 作用 |
|---|---|
| `--accept-defaults` | 第一次執行時直接採用範例設定繼續，不停下來。 |
| `--set KEY=VALUE` | 先把設定寫入 env 檔，可重複使用。只接受 `config/emqx.env.example` 裡的鍵，且一律不接受憑證。 |
| `--with-ngrok` / `--without-ngrok` | 加入或移除 ngrok 通道，見 [ngrok](#ngrok-tcp-通道選用)。 |
| `--dry-run` | 只產生與驗證，列出會變更的內容，不動任何東西。 |
| `--no-start`、`--no-smoke` | 安裝但不啟動；略過 smoke 測試。 |

非互動式、改用其他埠安裝（例如標準埠已被占用的主機）：

```bash
scripts/install.sh --set WOOW_EMQX_PORT_MQTT=21883 --set WOOW_EMQX_PORT_DASHBOARD=28083
```

重複執行 `install.sh` 是安全的；沒有變更時不會重啟任何東西。

## 設定

編輯 `~/.config/emqx/emqx.env`，再執行一次 `scripts/install.sh`。它會重新產生單元，只有在 broker
讀取的內容有變時才重啟。

| 鍵 | 預設 | 說明 |
|---|---|---|
| `WOOW_EMQX_BIND` | `127.0.0.1` | 埠發布的位址：`127.0.0.1`、本機的某個 IPv4 位址，或 `all`（IPv4 與 IPv6）。 |
| `WOOW_EMQX_PORT_MQTT` | `1883` | MQTT over TCP |
| `WOOW_EMQX_PORT_MQTTS` | `8883` | MQTT over TLS（EMQX 內附的自簽憑證） |
| `WOOW_EMQX_PORT_WS` / `_WSS` | `8083` / `8084` | MQTT over WebSocket / 加密 WebSocket |
| `WOOW_EMQX_PORT_DASHBOARD` | `18083` | Dashboard 與 REST API |
| `WOOW_EMQX_MQTT_USER` | `woow` | 首次啟動時匯入的 MQTT 使用者 |
| `WOOW_EMQX_NGROK` | `0` | `1` 表示執行 ngrok 通道（由 `--with-ngrok` 設定） |
| `WOOW_EMQX_NGROK_REMOTE_ADDR` | 空 | 保留的 ngrok TCP 位址，例如 `1.tcp.ngrok.io:12345` |
| `EMQX_*` | | 任何 EMQX 設定，原樣傳給 broker（`EMQX_LOG__CONSOLE__LEVEL=info` 等） |

env 檔不可存放憑證。`install.sh` 會拒絕結尾為 `PASSWORD`、`SECRET`、`TOKEN` 或 `_KEY` 且有值的鍵。

### Secrets

| Podman secret | 用途 | 如何傳給 EMQX |
|---|---|---|
| `woow-emqx-dashboard-password` | Dashboard 使用者 `admin` | 環境變數 `EMQX_DASHBOARD__DEFAULT_PASSWORD`。EMQX 只在空的資料 volume 首次開機時讀取。 |
| `woow-emqx-mqtt-password` | MQTT 使用者 `WOOW_EMQX_MQTT_USER` | 不掛載，是下方匯入檔的來源。 |
| `woow-emqx-mqtt-bootstrap` | 匯入 MQTT 使用者 | `emqx` 使用者可讀的 0400 檔。認證器啟動時匯入，絕不覆蓋已存在的使用者。 |
| `woow-emqx-ngrok-authtoken` | ngrok | 通道容器的環境變數 `NGROK_AUTHTOKEN`，只在 `--with-ngrok` 時建立 |

在私人終端機讀取其值：

```bash
podman secret inspect --showsecret --format '{{.SecretData}}' woow-emqx-dashboard-password
```

輪替 Dashboard 密碼：先在 Dashboard 修改（使用者選單 > 修改密碼），再更新記錄的副本。`read -s` 與
`printf` 讓密碼不進入 shell 歷史，也不出現在任何程序的參數裡：

```bash
read -rs -p 'new dashboard password: ' p; printf '%s' "$p" | podman secret create --replace woow-emqx-dashboard-password -; unset p
```

輪替 MQTT 密碼：在 Dashboard（Authentication > Built-in Database > Users）修改後，用同樣方法取代
`woow-emqx-mqtt-password`，再執行 `scripts/install.sh`，匯入檔也會一併更新。匯入永遠不覆蓋已存在的使用者，
所以以 Dashboard 上的修改為準。

## 連線

- **Dashboard：** `http://127.0.0.1:18083/`，使用者 `admin`，密碼取自上方的 secret。從其他機器連線請用
  `ssh -L 18083:127.0.0.1:18083 <host>`、Cloudflare tunnel 或 NPM。
- **MQTT 測試**（使用匯入的使用者；密碼經由 0600 的選項檔傳遞，不出現在指令列）：

  ```bash
  mkdir -p -m 700 ~/.config/woow-mqtt
  (umask 077; printf -- '-u woow\n-P %s\n' \
    "$(podman secret inspect --showsecret --format '{{.SecretData}}' woow-emqx-mqtt-password)" >~/.config/woow-mqtt/mosquitto_pub)
  XDG_CONFIG_HOME=~/.config/woow-mqtt mosquitto_pub -h 127.0.0.1 -p 1883 -t test/topic -m hello
  ```

- **匿名客戶端會被拒絕**，訊息為 `Connection Refused: not authorised`，這是預期行為。若要在封閉網路刻意
  允許匿名，請在 Dashboard 停用認證器；該變更存在 `cluster.hocon`，優先於 `base.hocon`。
- **全面檢查：** `tests/smoke.sh`（加 `--quick` 可略過 MQTT 客戶端檢查）。

## ngrok TCP 通道（選用）

此通道會把 raw MQTT（1883）公開到網際網路，只有在認證強制啟用時才安全；只要 smoke 測試失敗，
`install.sh` 就會停止通道。

```bash
NGROK_AUTHTOKEN=<your-token> scripts/install.sh --with-ngrok   # 或不設變數，在隱藏提示中輸入
scripts/ngrok-url.sh                                           # tcp://N.tcp.ngrok.io:PORT
scripts/install.sh --without-ngrok                             # 再次移除通道
```

需要固定位址時，先在 ngrok dashboard 保留一個，再設定 `WOOW_EMQX_NGROK_REMOTE_ADDR`。WebSocket（8083）
不經通道，請改用 Cloudflare tunnel。

## 升級

映像版本釘在本倉庫中。升級方法是更新倉庫後執行升級腳本：

```bash
git pull
scripts/upgrade.sh            # 跨 EMQX 大版本升級前請加 --cold
```

`upgrade.sh` 會：

1. 先備份。
2. 保存目前已安裝的單元。
3. 執行 `install.sh`（在動任何單元前先拉新映像）。
4. 執行 smoke 測試。

若第 3 或第 4 步失敗，會放回原本的單元，並以原本的映像重啟 broker。新版 EMQX 已經遷移過的資料不會自動
回復；若要跨大版本退回，請用 `restore.sh` 還原升級前的備份。

## 備份與還原

```bash
scripts/backup.sh             # 熱備份：emqx ctl data export（設定、使用者、規則、保留訊息）
scripts/backup.sh --cold      # 另外完整匯出 woow_emqx_data volume（短暫停機）
scripts/restore.sh --archive ~/.local/share/woow-backups/emqx/backup-<ts>/emqx-export-<...>.tar.gz --confirm-restore emqx
scripts/restore.sh --archive ~/.local/share/woow-backups/emqx/backup-<ts>/woow_emqx_data-<ts>.tar --confirm-restore emqx
```

備份存放於 `~/.local/share/woow-backups/emqx/`：檔案 0600、目錄 0700，並附 `SHA256SUMS`。邏輯匯出會
匯入執行中的 broker；volume 匯出則會先保留一份還原前的副本，再取代資料 volume。

## 解除安裝

```bash
scripts/uninstall.sh                 # 移除單元；保留 volume、網路、secrets、設定與備份
scripts/uninstall.sh --purge         # 另外刪除 volume、網路、secrets 與 ~/.config/emqx（需輸入 "emqx" 確認）
```

`--purge` 是唯一會刪除資料的指令，而且會先對資料 volume 與 env 檔做最後一次備份。映像與備份一律不刪除。

## 從既有 compose 部署遷移

Quadlet 單元沿用 compose 的名稱（容器 `woow-emqx`、volume `woow_emqx_data` 與 `woow_emqx_log`、網路
`woow_emqx_network`、節點名稱 `emqx@127.0.0.1`），所以遷移時資料原地沿用。

1. **備份。** 執行 `podman exec woow-emqx emqx ctl data export` 並把檔案複製出來；另外執行
   `podman volume export woow_emqx_data -o woow_emqx_data.tar`，並保存
   `podman inspect woow-emqx > legacy-inspect.json`。
2. **從舊的 `.env` 匯入 secrets**，讓記錄的副本與實際一致。一律用管線傳遞，不要 echo。
   - `grep '^EMQX_DASHBOARD_PASSWORD=' .env | cut -d= -f2- | tr -d '\n' | podman secret create woow-emqx-dashboard-password -`
   - MQTT 使用者的密碼用同樣方式存成 `woow-emqx-mqtt-password`，並設定 `WOOW_EMQX_MQTT_USER`。
3. **移除 compose 容器：** `podman stop woow-emqx && podman rm woow-emqx`。
   - 若它是以 `restart: always` 啟動的，不要只改名。啟用 `podman-restart.service` 時它會在每次開機再被
     啟動並搶占埠，而 podman 4.9 無法修改容器的重啟策略。
   - 其他情況下，`install.sh` 會拒絕取代它不管理的容器，並印出 `podman rename` 指令；可用此方式保留舊容器
     以便回復。
4. **安裝：** `scripts/install.sh`，接著 `tests/smoke.sh`。volume 裡 `cluster.hocon` 中由 Dashboard 建立的
   認證器優先於 `base.hocon`，因此既有使用者與設定都會保留。
5. **需要時回復：** `scripts/uninstall.sh`，然後從 `compose-final` 的 checkout 重新啟動舊 compose 專案；
   兩條路徑使用同樣的 volume。

## 檔案

```
quadlet/                 帶 @@VAR@@ 標記的 Quadlet 單元；quadlet/render-vars 列出可替換的變數
quadlet/optional/        ngrok 通道單元
config/emqx.env.example  ~/.config/emqx/emqx.env 的範本
config/base.hocon        認證器預設值，安裝到 ~/.config/emqx/base.hocon
scripts/                 install、upgrade、uninstall、backup、restore、ngrok-url
scripts/render-args.sh   由 env 檔計算的值（install.sh 與 tests/dryrun.sh 共用）
scripts/lib/             內嵌的 quadlet-lib（請勿修改；CI 會檢查其雜湊）
tests/dryrun.sh          產生單元 + Quadlet 4.9.3 dry-run + systemd-analyze verify（CI 與本機）
tests/smoke.sh           在主機上的安裝後檢查
tests/lint-repo.sh       憑證掃描、compose 移除、README 與 EMQX 不變條件（CI）
```

開發檢查（全為靜態，不啟動容器）：`bash tests/dryrun.sh`、`shellcheck -x scripts/*.sh tests/*.sh`、
`tests/lint-repo.sh`。

## 疑難排解

| 症狀 | 檢查 |
|---|---|
| `install.sh` 說有個容器存在且不受管理 | 先停止執行它的東西（compose、手寫的單元），再用印出的 `podman rename`，或把它移除（見遷移）。 |
| 安裝後 `emqx.service` 立即失敗 | `journalctl --user -u emqx.service -n 100` 與 `podman logs woow-emqx`；埠被占用會顯示在這裡，可用 `ss -tlnp` 查。 |
| 沿用的 volume 無法登入 Dashboard | admin 密碼存在資料 volume 裡；secret 只在空的 volume 上有作用。 |
| MQTT 客戶端出現 "not authorised" | 匿名存取已關閉。請使用內建資料庫中的使用者（Dashboard > Authentication）。 |
| 登出或重開機後單元消失 | `loginctl show-user $USER -p Linger` 必須是 `yes`。 |
| 透過 `su` 或 `sudo` 時 `systemctl --user` 失敗 | 以該使用者用 ssh 或主控台登入，或 `export XDG_RUNTIME_DIR=/run/user/$(id -u)`。 |
