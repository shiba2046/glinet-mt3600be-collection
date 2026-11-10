# 10 · 版本历史与踩坑记录

## v1.2.0 / 拨杆 v0.5.0（2026-11-10）：分阶段 Telegram 通知

- 消息全面 emoji 化、改多行排版；抬头 🛰 / 时间尾 🕒 / 延迟补发 ⏳。
- 新增事件：`switch_on_begin` / `switch_off_begin` / `off_fail` / `net_up_begin` /
  `update_start` / `update_ok`；拨杆和网络恢复都是「开始 → 结果」两条。
- 开始类事件豁免 25s 防抖（`do_emit`），每次拨动必有即时反馈。
- `install.sh` 幂等合并新事件到已有 `notify_events` 白名单，升级不会丢通知。
- 用户先要求删除 `api_resolve`，随后因「`--resolve` 略快」决定保留；
  现作为可选 DNS 兜底，留空即用系统 DNS。
- 实测：ON 开始 1s / 结果 21s，OFF 开始 1s / 结果 11s，队列 0 条。

### 新增踩坑：改了代码却收不到新事件

旧设备的 `notify_events` 是显式列表，`do_emit` 对不在白名单里的事件直接跳过。
所以新增事件名时**必须迁移配置**，不能只改脚本。

---

## 运维配置 · 内存调优（2026-11-10，拨杆脚本未改动）

**实测基线**（固件 4.9.0，`MemTotal 481MB`）：拨杆 OFF 152–158MB；拨杆 ON 仅 **49.0MB
available**，clash RSS 105MB，代理 204/0.115s。内核另占 `SUnreclaim 56.7MB` +
`Vmalloc 45MB`（WiFi / hwnat 驱动预分配，动不了）。`min_free_kbytes=16MB`，余量薄，
订阅更新或连接爆发容易触发 OOM killer。

**已在设备上实施**

- 停用 12 个无用 init 服务（quickstart 9.7MB、4G 短信/蜂窝三件套、ttyd、avahi、
  gl-cloud / gl-alarm / gl-dpi 等），并收掉 eco 守护拉起的残留。
  `gl_dpi` 的 init 明明是 disabled，进程仍会被 `/usr/bin/eco` 拉起——必须额外 kill。
  **保护**：`gl-repeater`（桥接公共 WiFi）、`gl-ngx-session`、拨杆/LED、
  nginx/uhttpd/dnsmasq 一律不动。OFF 158 → 174.8MB；ON 49 → 61.6MB。
- 内核支持 `CONFIG_ZRAM=m` / `ZSMALLOC=m` / `CRYPTO_LZO=y`，但 `CONFIG_KSM is not set`、
  zswap 未编，且 `.ko` 未预装。GL 官方 kmod feed 有版本完全匹配的
  `kmod-zram 5.4.281-1` + `zram-swap 8`，装后配 96MB / lzo / priority 100 /
  swappiness 30、`S15zram` 开机自启；`/etc/config/system` 与 `/etc/sysctl.conf`
  已加入升级保留清单。
- swappiness 对照：60 时只换出 1.2MB（压缩 0.3MB，4:1），可用内存反降到 57.5MB、
  延迟 0.065 → 0.110s，故**保持 30**。zram 定位为突发 OOM 保险，常态不介入。

**新增**：`tools/setup-zram.sh`、`tools/trim-services.sh`、`docs/12-memory-tuning.md`。

**未做（待用户确认）**：clash 规则精简。当前 13–14 个 rule-providers / 1.3MB `.mrs` /
3 个 proxy-providers（其中 Cloudflare Edge Tunnel 订阅 689KB / 约 41 节点）；
运行配置的 `geodata-loader` 已被 UCI 覆盖为 `memconservative`。清单见 12.5。

## v1.1.0（通知模块；拨杆脚本仍为 v0.4.0）

**新增：反代鉴权头 + DNS 负缓存兜底**

- `proxy_auth`：非空时给每次请求加 `-H "X-Proxy-Auth: <值>"`，头名可在 `send_one()`
  的 `_authopt` 一行改；`config` / `status` 打码显示
- `api_resolve`：填反代 IP 时用 `curl --resolve <host>:<port>:<ip>` 绕开本地 DNS，
  TLS SNI 仍用原主机名；端口从 `api_base` 提取，默认 443
- 配置页新增两个输入框；`do_init` 默认配置、`do_set` 白名单、`do_config` 同步
- `mask_token` 泛化为 `mask_val <key>`，同时给 `proxy_auth` 打码
- 修正 `do_set` 注释/报错里「允许空格」的错误描述：正则实际不允许，且 `proxy_auth`
  含空格会被拆成两个 curl 参数

**排查结论（DNS）**

反代域名在 1.1.1.1 / 8.8.8.8 / 223.5.5.5 / 208.67.222.222 均可解析，权威 NS/SOA 正常；
只有路由器上游 `192.168.1.1` 返回 NXDOMAIN → 记录添加前留下的**负缓存**或 DNS 过滤，
不是「域名没生效」。改全局 DNS 会影响桥接 WiFi 的 captive portal，故只用 `--resolve`
作用于通知请求。

**实测**：`getMe` 返回 `ok:true`；`test` 发送成功；`emit ready` 0s 返回、1s 后送达、
队列 1 → 0。真实凭证只写设备 `/etc/config/openclash-notify`（权限 600），未入库。

## v0.4.0

**新增：Telegram 状态通知**

- `scripts/openclash-notify.sh`：异步队列 + 独立发送进程 + 断网补发 + 25s 事件防抖；
  队列落 `/etc/openclash-notify/spool/`（flash，重启不丢），上限 50 条
- `scripts/cgi-bin/oc-notify`：配置页，直接挂 uhttpd 现成的 `cgi_prefix=/cgi-bin`，
  不新增服务、不重启 uhttpd；带 `web_pin` 访问保护与字符白名单
- 拨杆脚本接入 8 类状态事件（开启成功 / 启动失败 / 关闭 / 外网中断 / 上游断开 /
  强制门户 / 网络恢复 / 每日更新结果）；watcher 按**状态变化**触发，不按轮询刷屏
- `api_base` 可填墙后直连可达的 Telegram API 反代；默认 `api_mode=direct`，
  不切换、不走 clash 代理，避免反代流量被二次转发
- `install.sh`：`--no-notify` 开关，`/etc/sysupgrade.conf` 追加通知相关 4 个路径
- `deploy.sh`：`--setup-key` 一键装免密公钥；自动带专用 `-i`，命令行关掉
  `ForwardX11` / `ForwardAgent`（修正 `Host *` 带来的 xauth 噪音）

**修复**

- `do_install_cron` 的去重写法 `grep -v ... > tmp && mv` 在「所有行都被删掉」时
  `grep` 返回 1 → `mv` 被短路 → 每跑一次 install-cron 多追加一行。
  设备上实测已积累到每天 04:00 执行 **3 次**，修复后为 1 次。见踩坑 #17。
- `status` 增加 Telegram 通知状态与配置页地址。
- CGI 表单解析：`tr '&' '\n'` 输出末尾没有换行，`while read` 会跳过最后一行，
  导致表单**最后一个字段永远保存不了**（实测 `notify_events` 写不进去）。
  改为 `printf '%s\n' "$BODY" | tr '&' '\n'`，并给 `while` 加 `|| [ -n "$_k" ]` 兜底。见踩坑 #20。

**实测（固件 4.9.0）**

| 项目 | 结果 |
|---|---|
| 配置页 `GET :8080/cgi-bin/oc-notify` | HTTP 200 / 5442 字节 |
| 假 token 同步测试 | Telegram 返回 `401 Unauthorized`（证明 HTTPS/CA/URL 拼接全通） |
| `emit` 返回耗时 | 0s（不阻塞拨杆） |
| 发送失败 / 恢复补发 | 队列保留 1 条 → 指向成功接口后 1 → 0 |

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

### 17. `grep -v > tmp && mv` 去重会静默失效

清理 crontab 里的旧任务行时，如果文件里**全部行**都带那个标记，`grep -v` 输出空并返回 **1**，
`&& mv` 被短路，旧文件原封不动；随后又追加一行新任务 —— 每跑一次安装就多一条。
设备上出现过每天 04:00 执行 3 次。正确写法是把 `grep` 和 `mv` 分成两条语句：

```sh
grep -vF "$CRON_TAG" "$CRON_FILE" > "$CRON_FILE.tmp" 2>/dev/null
mv -f "$CRON_FILE.tmp" "$CRON_FILE"
```

### 18. dropbear 的 authorized_keys 不在 `~/.ssh/`

GL 固件跑 dropbear 而不是 OpenSSH，公钥要放 `/etc/dropbear/authorized_keys`（本机实测该文件
已存在）。`ssh-copy-id` 默认写 `~/.ssh/authorized_keys`，经常不生效。
另外本机 Git Bash 的 `~/.ssh/` 里**没有任何默认命名的私钥**（`id_rsa`/`id_ed25519` 全缺），
密钥都带后缀命名且没有 ssh-agent，所以裸 `ssh root@192.168.8.1` 只能走密码。
`deploy.sh --setup-key` 生成专用密钥并自动带 `-i` 解决。

### 19. 配置页在 8080，不在 80

80/443 是 nginx（GL 管理界面），uhttpd/LuCI 在 8080/8443 且已配 `cgi_prefix=/cgi-bin`。
往 `/www/cgi-bin/` 放一个 755 的 ash 脚本即可当 CGI 跑，无需改配置或重启服务。
但 uhttpd 以 root 运行，CGI 里绝不能 `eval` 或拼接 shell 命令。

### 20. `tr '&' '\n'` + `while read` 会吞掉最后一个表单字段

`tr` 的输出末尾不带换行，而 `while read` 对「最后一行没有换行符」的情况返回非零，
循环体不会执行 —— 表现为表单最后一个输入框怎么都保存不了，且无任何报错。
补一个换行，或写成 `while read ... || [ -n "$var" ]`：

```sh
printf '%s\n' "$BODY" | tr '&' '\n' > "$TMP.pairs"
while IFS='=' read -r _k _v || [ -n "$_k" ]; do ... done < "$TMP.pairs"
```

---

## 已知问题 / 后续可做

- 门控只看"HTTP 204"，如果酒店把 `generate_204` 域名直接封掉（返回 000），
  会被判为离线。可考虑增加备用探测（DNS 解析 + TCP 443）。
- `/tmp` 日志重启即清；需要长期留档可把 `OCSW_LOG` 指到持久目录（注意 flash 写入）。
- GL 网页的「拨动开关功能」下拉框不显示 openclash（需要改厂商前端 JS），
  目前纯 CLI 绑定；如果网页里手动改选别的功能，绑定会被覆盖。
- 只支持单拨杆功能（`switch-button.@main[0].func` 是单值）。
