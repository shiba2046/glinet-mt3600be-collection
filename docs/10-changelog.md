# 10 · 版本历史与踩坑记录

## v0.3.0

**新增**

- `openclash-auto-update.sh`：订阅配置每日更新，带网络/认证页/内存三道门
- `install.sh` / `deploy.sh`：一键安装，先备份再覆盖，自动清理 v0.1 遗留
- `docs/`：完整文档（本目录）
- `tools/rssh.py`：无 sftp 环境下的远程执行/上传工具

**修复**

- 指示灯改走 `/etc/gl-switch.d/led.sh`（`gl_led turnon/turnoff`）：
  `stop_clash` 的"核心未运行"早退分支也关灯；`do_sync` 在 ON 分支先点灯再启动
- 失败诊断的 OOM 判断加上 `dmesg` 基线，避免历史 OOM 记录被当成本次根因
- `status` 增加模块版本号；日志路径支持 `OCSW_LOG`

## v0.2.0

**重构**（纠正 v0.1 的目录误用）

- 主逻辑迁到 `/etc/gl-switch.d/openclash.sh`，恢复原厂 `/etc/rc.button/switch`，
  删除自建的 `BTN_0`
- 新增网络门控：拨到 ON 但没网 / 认证页 → 不启动核心，watcher 等待后自动拉起
- 新增 `sync`（按物理位置校正）与 `watch`（只起守护）子命令
- `/etc/init.d/openclash disable`，开机时机交给 `S99gl_switch_button_check` + `rc.local`

**修复**

- BusyBox `flock` 不支持 `-w`、`flock -n FD` 空闲也返回 1 → 改用原子目录锁
- 后台进程继承 `gl-switch.lock` 的 fd 导致锁永不放 → 脚本开头关闭 fd 3–20
- ash 子 shell 里 `$$` 是父进程 pid → watcher 改用 `sh $0 watch` 独立进程
- `trap ... TERM` 不 `exit` 会让 ash 卡在 `do_wait` → 改 `trap 'exit 143'`

## v0.1.0

初版（已被 v0.2 取代，这里是错误示范）

- 改的是 `/etc/rc.button/switch`（固件调度器），还额外造了 `/etc/rc.button/BTN_0`
- 三个入口脚本各写一套逻辑，互相打架
- 用 IP 归属地判断网络可用性

---

## 踩坑记录

### 1. 拨杆脚本失效的直接原因：查 IP 归属地

旧脚本每次 `on` 都请求 `ip-api.com`，只要返回不是 `CN` 就**主动 stop OpenClash**。
用户出口是 HK，于是"拨到 ON"等于"每次都关掉代理"。

教训：判断"能不能上网"用 `generate_204`，不要用地区判定。

### 2. 不该改 `/etc/rc.button/switch`

它是固件调度器，改了三件事都会丢：固件升级、恢复出厂、`/rom` 校验不一致。
正确做法是写 `/etc/gl-switch.d/<func>.sh` 并把 `switch-button.@main[0].func` 指过去。

### 3. 这台机器没有 `BTN_0` 事件

自作聪明加的 `/etc/rc.button/BTN_0` 从来不会被调用。`BUTTON=switch`，走 `rc.button/switch`。

### 4. `flock` 在这套 BusyBox 上基本不可用

| 用法 | 实测结果 |
|---|---|
| `flock -w 25 9` | 不支持 `-w`，直接失败 → 整个脚本卡在取锁 |
| `flock -n 9`（空闲） | 返回 1，误判为"已被占用" |
| `flock /path cmd` | 可用（固件就是这么用的） |

改用 `mkdir` 原子目录锁。

### 5. 锁句柄会被子进程继承

固件用 `flock /var/lock/gl-switch.lock <cmd> &`，锁挂在 fd 上并随 fork 传递。
clash 核心和 watcher 继承后一直持有 → 后续每次拨动都永久排队。
必须在脚本开头 `exec 3..20<&-`。

### 6. OpenClash 的 `start` 会在核心拉起前返回

把它当同步命令 → 假失败。而且核心会"闪断重启"一次，pid 会变 → 假成功。
判定必须是"连续 N 秒同一 pid"。

### 7. ash 的 `trap` 不写 `exit` 会卡住

`trap 'rm -f ...' TERM` 收到信号后执行完 trap 动作会继续原流程，进程卡在 `do_wait`。
要写 `trap 'exit 143' INT TERM HUP`。

### 8. `$$` 在子 shell 里不是子 shell 的 pid

`( watch_loop & )` 里的 `$$` 仍是父进程 pid → pidfile 记错，事后杀不掉。
改用 `( exec sh "$0" watch & )`。

### 9. OOM 之后核心会被"降级"

内存不足 → OOM 杀 clash → OpenClash 把核心从 Smart 降成 Meta → 但配置里还有
`type: smart` → `Parse config error: unsupported type: smart`。
看起来像"配置坏了"，实际是内存问题。

### 10. `small_flash_memory=1` 就是"每次开机都下载"的根因

核心和 geo 数据放 `/tmp`（tmpfs），重启清空。改成 0 落 flash 即可。

### 11. 直接写 LED sysfs 会被守护改回

`/usr/bin/gl_led` 每 2 秒按网络状态刷新。必须 `gl_led turnoff`（会先停守护）。
另外这机型有两盏灯，`white:system` 表示"系统在线"，跟 OpenClash 无关。

### 12. `led.sh off` 有 `sleep 5`

同步调用会让每次开关动作白等 5 秒，要放后台。

### 13. `/usr/share/openclash/openclash.sh` 是 bash 脚本

用 `sh` 调用会 rc=2 **静默失败**，日志里几乎没有线索。必须直接执行让 shebang 生效。

### 14. OpenClash 自己的 cron 任务会被 `stop` 删掉

`del_cron()` 里 `sed -i '/#openclash-cron-task/d'`。所以自建任务不能带这个标记。

### 15. geo/规则文件不需要 cron

核心配置里有 `geo-auto-update: true` 和每个 rule-provider 的 `interval: 86400`，
核心在跑就自己更新。再加 cron 是两套逻辑抢同一批文件。

### 16. 两个 crond

GL 自己的读 `/tmp/gl_crontabs`（开机重建，不能手写），系统 cron 读 `/etc/crontabs/root`。
任务要写后者。

---

## 已知问题 / 后续可做

- 门控只看"HTTP 204"，如果酒店把 `generate_204` 域名直接封掉（返回 000），
  会被判为离线。可考虑增加备用探测（DNS 解析 + TCP 443）。
- `/tmp` 日志重启即清；需要长期留档可把 `OCSW_LOG` 指到持久目录（注意 flash 写入）。
- GL 网页的「拨动开关功能」下拉框不显示 openclash（需要改厂商前端 JS），
  目前纯 CLI 绑定；如果网页里手动改选别的功能，绑定会被覆盖。
- 只支持单拨杆功能（`switch-button.@main[0].func` 是单值）。
