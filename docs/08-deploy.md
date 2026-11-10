# 08 · 部署、回滚与卸载

## 前置条件

1. GL 后台 → 系统 → SSH 已启用（默认 root 密码就是后台密码）。
2. 电脑与路由器同网段（`192.168.8.x`）。
3. 建议配置免密，只需输一次密码：

```sh
ROUTER_HOST=192.168.8.1 ./deploy.sh --setup-key
```

它会生成 `~/.ssh/id_ed25519_glinet`，把公钥追加到 **`/etc/dropbear/authorized_keys`**
（GL 固件跑 dropbear，`ssh-copy-id` 默认写的 `~/.ssh/authorized_keys` 不生效），
之后 `deploy.sh` 自动带 `-i`，不再提示密码。详见踩坑 #18。

## 部署

```sh
ROUTER_HOST=192.168.8.1 ./deploy.sh --dry-run     # 先看会做什么
ROUTER_HOST=192.168.8.1 ./deploy.sh               # 正式部署
```

`deploy.sh` 做的事很简单：把 `install.sh` + `scripts/` 打成 tar 通过 ssh 管道送到
`/tmp/oc-pkg`，然后执行 `sh /tmp/oc-pkg/install.sh`。所以它不依赖 sftp/scp
（这两个在只跑 dropbear 的固件上经常不可用）。

参数（`deploy.sh` 会原样透传给 `install.sh`）：

| 参数 | 作用 |
|---|---|
| `--switch-only` | 只装拨动开关模块，不装自动更新、不动 cron |
| `--no-rc-hook` | 不往 `/etc/rc.local` 加开机校正钩子 |
| `--keep-autostart` | 保留 `/etc/init.d/openclash` 开机自启（默认会 disable） |
| `--tune-openclash` | 应用小内存参数（`small_flash_memory=0`、关 smart 等） |
| `--trim-services` | 停用 `netifyd` / `gl_dpi`，nginx worker 2→1 |
| `--no-cron` | 不安装每日 04:00 订阅更新任务 |
| `--no-notify` | 不安装 Telegram 通知模块与配置页 |
| `--dry-run` | 只打印计划 |

`./deploy.sh --status` 只看状态（开关 / 自动更新 / 通知三块），不做任何改动；
`./deploy.sh --setup-key` 只配置 SSH 免密，不安装任何东西。

## install.sh 做了什么

按顺序：

1. **预检**：root、`/etc/gl-switch.d` 存在、`uci` 可用、包完整。
2. **停旧 watcher**，清理 `/var/lock/openclash-switch.*`（升级时不清理会导致新旧两套逻辑打架）。
3. **装开关模块** 到 `/etc/gl-switch.d/openclash.sh`，`chmod 755`，`sh -n` 语法检查。
4. **清理 v0.1 遗留**：`/etc/openclash-switch.sh`、`/etc/rc.button/BTN_0` 移到备份目录。
   如果 `/etc/rc.button/switch` 与 `/rom` 里的原厂版本不一致，自动恢复原厂。
5. **绑定**：`switch-button.@main[0].func=openclash`，删掉 `sub_func`。
6. **开机时机**：`/etc/init.d/openclash disable`（默认），改由 `S99gl_switch_button_check` 决定。
7. **`/etc/rc.local` 钩子**：在 `exit 0` 前插入 `( sleep 25; ... sync ) &`，已有则跳过，
   改完做 `sh -n` 校验，失败会提示从备份恢复。
8. **升级保留**：把 `/etc/gl-switch.d/`、`/etc/rc.local`、`/etc/openclash-auto-update.sh`、
   `/etc/openclash-notify.sh`、`/www/cgi-bin/oc-notify`、`/etc/config/openclash-notify`、
   `/etc/openclash-notify/` 写进 `/etc/sysupgrade.conf`（逐条判重，不重复追加）。
9. **自动更新**：装 `/etc/openclash-auto-update.sh`，调 `install-cron`（会先把旧任务行清空再加，
   保证只有一条）。
10. **Telegram 通知**（`--no-notify` 跳过）：装 `/etc/openclash-notify.sh`、配置页 CGI，
    再 `init` 生成默认配置 —— **已有 bot_token 不会被覆盖**。
11. **可选优化**（`--tune-openclash` / `--trim-services`，见 [05](05-memory-and-core.md)）。
12. **收尾**：打印备份目录、可用内存、配置页地址和下一步提示。

所有被覆盖的文件都先拷到 `/root/openclash-switch-backup/<YYYYMMDD-HHMMSS>/`。

## 部署后验证清单

```sh
# 1) 绑定与可执行位
uci show switch-button
ls -l /etc/gl-switch.d/openclash.sh

# 2) 状态总览
sh /etc/gl-switch.d/openclash.sh status

# 3) 拨一下开关，然后看两边日志
logread -e gl-switch | tail -3          # 固件收到了事件
tail -8 /tmp/openclash-switch.log       # 模块处理了事件

# 4) 代理是否真的通（核心运行中）
curl -s -m 10 -x http://127.0.0.1:7890 -o /dev/null \
     -w 'code=%{http_code} time=%{time_total}s\n' https://www.gstatic.com/generate_204

# 5) cron 是否装上（只能有 1 行，出现多行见踩坑 #17）
crontab -l | grep -c openclash-auto-update

# 6) 通知配置页与模块
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.8.1:8080/cgi-bin/oc-notify
sh /etc/openclash-notify.sh status
sh /etc/openclash-notify.sh test        # 填好 token 之后
```

期望：ON 约 20 秒核心稳定、`code=204`；OFF 约 10 秒进程消失、灯全灭；
配置页返回 `200`。通知配置详见 [11](11-telegram-notify.md)。

## 升级（装新版本）

直接再跑一次 `deploy.sh`。它会先停旧 watcher、备份旧脚本，再覆盖。
不需要先卸载，也不需要 reboot。

## 回滚

```sh
ls /root/openclash-switch-backup/            # 找最近一次时间戳目录
cp -f /root/openclash-switch-backup/20261110-131500/openclash.sh /etc/gl-switch.d/openclash.sh
sh /etc/gl-switch.d/openclash.sh status
```

如果连原厂 `led.sh` 之类也被动过（本仓库不会动它），从 `/rom` 恢复：

```sh
cp -f /rom/etc/gl-switch.d/led.sh /etc/gl-switch.d/led.sh
cp -f /rom/etc/rc.button/switch  /etc/rc.button/switch
```

## 完全卸载

```sh
# 1) 停止并移除模块
[ -f /var/run/openclash-switch.watch.pid ] && kill $(cat /var/run/openclash-switch.watch.pid) 2>/dev/null
rm -f  /etc/gl-switch.d/openclash.sh
rm -f  /etc/openclash-auto-update.sh
rm -f  /etc/openclash-notify.sh /www/cgi-bin/oc-notify
rm -f  /etc/config/openclash-notify          # 不想保留 bot token 时
rm -rf /etc/openclash-notify /var/lock/openclash-switch.*

# 2) 解除绑定（改成你想要的固件功能，例如 wifi）
uci set switch-button.@main[0].func='wifi'
uci commit switch-button

# 3) 移除 rc.local 钩子
sed -i '/openclash-switch-hook/,+1d' /etc/rc.local

# 4) 移除 cron 行
sed -i '/openclash-auto-update/d' /etc/crontabs/root && crontab /etc/crontabs/root

# 5) 移除升级保留项
sed -i '\#/etc/gl-switch.d/#d; \#/etc/openclash-auto-update.sh#d; \#/etc/openclash-notify#d; \#/www/cgi-bin/oc-notify#d' /etc/sysupgrade.conf

# 6) 恢复 OpenClash 开机自启（如果想恢复出厂行为）
/etc/init.d/openclash enable

# 7) 恢复灯（OFF 时 led_enable 可能还是 0）
/etc/init.d/gl_led turnon
```

## 不用 deploy.sh 的裸机方式

路由器能上网的话，直接在设备上操作也许更快：

```sh
mkdir -p /tmp/oc-pkg/scripts/gl-switch.d
# 用任意方式把仓库文件放进去，然后：
cd /tmp/oc-pkg && sh install.sh --switch-only
```

只有文件没有安装脚本时，最小可用的手动步骤：

```sh
cat > /etc/gl-switch.d/openclash.sh <<'EOF'
...（脚本内容）
EOF
chmod 755 /etc/gl-switch.d/openclash.sh
sh -n /etc/gl-switch.d/openclash.sh
uci set switch-button.@main[0].func='openclash'
uci commit switch-button
/etc/init.d/openclash disable
sh /etc/gl-switch.d/openclash.sh status
```

注意 `chmod 755` 不能漏：固件调脚本前会检查 `[ -x ... ]`，不可执行就静默返回，
日志里只有一句 `can't be exec`。
