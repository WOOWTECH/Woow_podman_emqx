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

`scripts/migrate-legacy.sh` 會完整執行整個流程，並提供回復。Quadlet 單元已沿用 compose 時期的名稱（容器
`woow-emqx`、volume `woow_emqx_data` 與 `woow_emqx_log`、網路 `woow_emqx_network`、節點名稱
`emqx@127.0.0.1`），因此**兩個 volume 都是原地沿用 — 不複製任何資料**，切換時間約一分鐘。

```bash
scripts/migrate-legacy.sh --dry-run        # 全部檢查，並說明本主機需要哪一種回復形式
scripts/migrate-legacy.sh --prepare-only   # 熱備份與回復副本；無停機
scripts/migrate-legacy.sh --yes            # 正式切換
scripts/migrate-legacy.sh --status         # 查看記錄
```

它會拒絕而不是猜測的情況：容器不存在或已由 Quadlet 管理、容器未執行、資料 volume 掛在
`/opt/emqx/data` 以外的位置、另有執行中的容器在寫同一個 volume、**節點名稱**不是 `emqx@127.0.0.1`
（mnesia 存放在資料 volume 裡以節點名稱命名的目錄下，名稱不符會讓 broker 從空資料庫啟動）、映像不是本
checkout 釘選的 digest、網路不存在、埠發佈在多個位址、目標埠被非舊 broker 的程式占用，以及單元已安裝。

接著它會對兩個 volume 做熱匯出，並保存 `podman inspect`、舊的 `.env` 與 compose 檔（權限 0600 —
inspect 內含 dashboard 密碼），停止 broker、做冷匯出、退役舊容器、安裝，然後**驗證沿用**：比對每個
volume 的 mountpoint、`CreatedAt` 與 inode 是否與切換前讀到的一致。若 `.volume` 少了 `VolumeName=`，
這裡會出現全新的 `systemd-emqx-data`，而這個比對正是用來抓出它。實測停機時間會列出並寫入狀態檔。

有兩件事會刻意改變，腳本會明確說明：

* **dashboard 密碼不會變。** EMQX 只在資料 volume 為**空**時才寫入 `EMQX_DASHBOARD__DEFAULT_PASSWORD`，
  所以在沿用的 volume 上，產生的 `woow-emqx-dashboard-password` secret 不生效，舊密碼仍然有效。加上
  `--reset-dashboard-password` 可讓兩者一致，或之後執行
  `podman exec woow-emqx emqx ctl admins passwd admin <new>`。
* **`config/base.hocon` 宣告了 built-in-database 認證器。** 認證鏈為空的 compose broker 會接受匿名連線
  （`EMQX_ALLOW_ANONYMOUS` 在 EMQX 5 中無作用）；遷移後這些連線會被拒絕。腳本會回報切換前的連線數，
  不為零時發出警告。volume 的 `cluster.hocon` 中由 Dashboard 建立的認證器優先於 `base.hocon`，會被保留。

### 回復形式：為什麼這個 stack 必須用 capture

把舊容器改名並保持停止，只在沒有東西再啟動它時才安全。使用者單元 `podman-restart.service` 會在開機時執行
`podman start --all --filter restart-policy=always`，而 **`woow-emqx` 是整個 WOOWTECH 機隊中唯一重啟策略
正好是 `always` 的容器**（compose overlay `docker-compose.autostart.yml` 設定的，因為沒有別的機制能在重開機
後把 broker 帶回來）。在啟用該單元的主機上，改名後停止的 `woow-emqx` 會在下次開機復活，與 Quadlet 容器爭奪
名稱、五個埠與兩個 volume — 而 podman 4.9.3 事後無法清除重啟策略（`podman update` 只能改 cgroup 參數）。

因此 `ql_rollback_strategy` 會問主機兩個問題 — 這個使用者的 `podman-restart.service` 是否啟用、是否有舊容器
的策略正好是 `always` — 然後回答：

| 回答 | 切換時的動作 | `--rollback` 的動作 |
|---|---|---|
| `rename` | `podman rename woow-emqx woow-emqx-legacy-<suffix>`，保持停止 | 改名回去並啟動 |
| `capture` | `ql_capture_container` 寫入備份目錄，然後執行單純的 `podman rm`（絕不用 `rm -v`，那會刪掉 capture 預期要找回的匿名 volume） | `ql_recreate_container` 重建它並**重新加回 `always` 重啟策略**，然後啟動 |

capture 在準備階段（尚未停機時）進行，因此若某個容器無法被函式庫重放，會在 broker 仍在服務時就被發現。
EMQX 只寫入它的兩個 volume，不寫自己的容器 — 線上容器的可寫層約 11 KB — 所以 capture 不需要 `--commit`；
腳本會實際量測並說明。

### 回復

```bash
scripts/migrate-legacy.sh --rollback
```

它會停止並移除 Quadlet 單元（**兩個 volume、網路與 secrets 都保留**），依切換當時採用的形式把舊容器帶回來、
啟動它並等待 dashboard。過程中不涉及資料還原：volume 是原地沿用、從未被覆寫。備份目錄中的冷匯出只在資料本身
損壞時才需要 — 在 stack 停止的狀態下用 `podman volume import woow_emqx_data <file>.tar` 還原。

### 觀察期結束後

Quadlet stack 穩定運行一段時間後：移除 `woow-emqx-legacy-<suffix>`（rename 路徑），或備份中的
`legacy-container/` 目錄與（若有 commit）`localhost/woow-emqx-legacy-*` 映像（capture 路徑），並封存備份目錄。
在那之前請保留 compose checkout。

## 檔案

```
quadlet/                 帶 @@VAR@@ 標記的 Quadlet 單元；quadlet/render-vars 列出可替換的變數
quadlet/optional/        ngrok 通道單元
config/emqx.env.example  ~/.config/emqx/emqx.env 的範本
config/base.hocon        認證器預設值，安裝到 ~/.config/emqx/base.hocon
scripts/                 install、upgrade、uninstall、backup、restore、ngrok-url、migrate-legacy
scripts/legacy-common.sh rename 與 capture 回復輔助函式，以及 volume 沿用驗證
scripts/render-args.sh   由 env 檔計算的值（install.sh 與 tests/dryrun.sh 共用）
scripts/lib/             內嵌的 quadlet-lib（請勿修改；CI 會檢查其雜湊）
tests/dryrun.sh          產生單元 + Quadlet 4.9.3 dry-run + systemd-analyze verify（CI 與本機）
tests/smoke.sh           在主機上的安裝後檢查
tests/lint-repo.sh       憑證掃描、compose 移除、README 與 EMQX 不變條件（CI）
tests/rollback-model.sh  以 tests/shims 驗證回復模型與沿用驗證（CI）
tests/shims/             podman 與 systemctl 測試替身；不會建立任何容器
```

開發檢查（全為靜態，不啟動容器）：`bash tests/dryrun.sh`、`shellcheck -x scripts/*.sh tests/*.sh`、
`tests/lint-repo.sh`、`tests/rollback-model.sh`。

## 疑難排解

| 症狀 | 檢查 |
|---|---|
| `install.sh` 說有個容器存在且不受管理 | 先停止執行它的東西（compose、手寫的單元），再用印出的 `podman rename`，或把它移除（見遷移）。 |
| 安裝後 `emqx.service` 立即失敗 | `journalctl --user -u emqx.service -n 100` 與 `podman logs woow-emqx`；埠被占用會顯示在這裡，可用 `ss -tlnp` 查。 |
| 沿用的 volume 無法登入 Dashboard | admin 密碼存在資料 volume 裡；secret 只在空的 volume 上有作用。 |
| MQTT 客戶端出現 "not authorised" | 匿名存取已關閉。請使用內建資料庫中的使用者（Dashboard > Authentication）。 |
| 登出或重開機後單元消失 | `loginctl show-user $USER -p Linger` 必須是 `yes`。 |
| 透過 `su` 或 `sudo` 時 `systemctl --user` 失敗 | 以該使用者用 ssh 或主控台登入，或 `export XDG_RUNTIME_DIR=/run/user/$(id -u)`。 |
