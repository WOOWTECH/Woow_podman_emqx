# EMQX Quadlet deployment skill / 部署 Skill

> A runbook for AI assistants and operators. The README has the details; this page is the short path.
> 給 AI 助手與維運人員的操作手冊；細節見 README，這裡是最短路徑。

## Rules / 規則

- Run everything as the user that owns the containers, in a real login session (ssh or console). Never
  use `sudo` or `su` for these scripts.
  以擁有容器的使用者、在真正的登入工作階段中執行，腳本不可用 `sudo` 或 `su`。
- Never put credentials on a command line, in the env file or in a commit. They live in podman secrets.
  憑證不可放在指令列、env 檔或 commit 中，一律存在 podman secrets。
- Never print a secret value into a shared log or chat. Read it only in a private terminal.
  不要把 secret 值印到共享的 log 或對話中，只在私人終端機讀取。

## Fresh install / 全新安裝

```bash
git clone https://github.com/WOOWTECH/Woow_podman_emqx.git ~/Woow_podman_emqx
cd ~/Woow_podman_emqx
bash tests/dryrun.sh                         # static check on this host: same result as CI
scripts/install.sh --accept-defaults         # or run it once, edit ~/.config/emqx/emqx.env, run again
tests/smoke.sh                               # A1-A8 must PASS; the key one is "A5 anonymous MQTT is refused"
```

Ports taken on the host? Move them at install time / 主機埠被占用時，安裝時改埠：

```bash
scripts/install.sh --set WOOW_EMQX_PORT_MQTT=21883 --set WOOW_EMQX_PORT_DASHBOARD=28083
```

## Day 2 / 日常維運

| Task | Command |
|---|---|
| Status | `systemctl --user status emqx.service`; `podman ps --filter name=woow-emqx` |
| Logs | `journalctl --user -u emqx.service -n 100` |
| Change a setting | edit `~/.config/emqx/emqx.env`, then `scripts/install.sh` |
| Upgrade | `git pull && scripts/upgrade.sh` (automatic unit rollback on failure) |
| Backup | `scripts/backup.sh` (hot) or `scripts/backup.sh --cold` |
| Restore | `scripts/restore.sh --archive <file> --confirm-restore emqx` |
| Tunnel | `NGROK_AUTHTOKEN=<token> scripts/install.sh --with-ngrok`, `scripts/ngrok-url.sh` |
| Remove | `scripts/uninstall.sh` (keeps data) or `scripts/uninstall.sh --purge --yes` |

Remote host / 遠端主機：`ssh <host> 'cd ~/Woow_podman_emqx && git pull && scripts/upgrade.sh'`.

## Done when / 完成條件

- `tests/smoke.sh` ends with `0 failed`.
- `systemctl --user list-dependencies default.target --plain | grep -w emqx.service` prints the unit
  (it starts at boot through linger).
- Running `scripts/install.sh` a second time reports `nothing to restart or start`.
