# glinet-mt3600be-collection

给 **GL.iNet GL-MT3600BE**（BE3600，固件 4.9.0 / OpenWrt 21.02，aarch64）写的一套 OpenClash 运维脚本。
核心目标只有一个：**把这台小内存路由器带到酒店，用物理拨杆可靠地开关代理。**

> 适用场景：路由器不在家里，每次入住都要桥接公共 WiFi、过 captive portal 认证页；
> 内存只有 481MB 且没有 swap，OpenClash 稍不注意就会被 OOM 杀掉。

---

## 它解决什么问题

| 现象 | 真正的原因 | 本仓库的处理 |
|---|---|---|
| 拨到 ON 没反应，甚至把 OpenClash 关掉 | 旧脚本查 IP 归属地，非中国大陆就主动 stop | 门控只看「外网能不能通」，不看地区 |
| 拨了开关像"卡住"，之后怎么拨都无效 | 后台进程继承了固件的 `flock` 锁句柄，锁永不放 | 脚本启动即 `exec 3..20<&-` 关闭继承 fd + 原子目录锁 |
| 在酒店拨 ON 后上不了网，连认证页都打不开 | 核心先起来了，流量被代理走，认证页劫持失效 | 检测到 captive portal **先停核心**，认证完成自动恢复 |
| 每次重启都要下载 13MB 核心 + geo 数据 | `small_flash_memory=1` 把核心放 `/tmp`，重启清空 | `small_flash_memory=0`，核心与 geo 落 flash |
| 手动在网页点"开启"报 `Parse config error: unsupported type: smart` | 内存不足 OOM → 核心被降级为 Meta，而配置里有 `type: smart` | 关闭 smart 相关开关，统一用标准 Meta 核心 |
| 拨到 OFF 后灯还亮着 | 只关了蓝灯，没关白灯；且 `gl_led` 守护每 2 秒刷回去 | 统一调用 `/etc/gl-switch.d/led.sh off` |

---

## 特性

- **只写一个文件**：真正的逻辑全在 `/etc/gl-switch.d/openclash.sh`，不改任何固件文件
  （`/etc/rc.button/switch` 保持原厂，可用 `/rom` 校验）。
- **网络门控**：拨到 ON 但没网 / 卡在认证页 → 不启动核心，转后台等待，网络一通自动启动；
  运行中掉网或认证失效 → 自动暂停核心，恢复后自动拉起。
- **幂等 + 防抖**：重复拨动、开机双重触发都不会反复重启核心；排队事件按物理位置丢弃。
- **失败自诊断**：启动失败会自己判断是不是被 OOM Killer 杀掉（只认本次启动之后的 `dmesg`），
  并附上 OpenClash 自己的日志尾部。
- **分层自动更新**：geo/规则交给 mihomo 核心自己更，订阅走自建 cron，核心二进制只手动更。
- **Telegram 状态推送**：开启成功 / 启动失败 / 关闭 / 外网中断 / 恢复 / 认证页 / 更新失败都会发消息；
  异步队列 + 断网补发，不阻塞拨杆。支持填墙后可达的 API 反代地址。
- **配置页**：`http://192.168.8.1:8080/cgi-bin/oc-notify`，用 uhttpd 现成的 CGI，无额外常驻服务。
- **可回滚**：安装时把原有文件备份到 `/root/openclash-switch-backup/<时间戳>/`。

---

## 目录结构

```
.
├── install.sh                 # 在路由器上执行的安装/升级脚本
├── deploy.sh                  # 在本地执行：打包 → 推到设备 → 调 install.sh
├── scripts/
│   ├── gl-switch.d/
│   │   └── openclash.sh       # 拨动开关模块（部署到 /etc/gl-switch.d/openclash.sh）
│   ├── openclash-auto-update.sh  # 依赖文件自动更新（部署到 /etc/openclash-auto-update.sh）
│   ├── openclash-notify.sh    # Telegram 状态推送（部署到 /etc/openclash-notify.sh）
│   └── cgi-bin/
│       └── oc-notify          # 配置页 CGI（部署到 /www/cgi-bin/oc-notify）
├── tools/
│   ├── rssh.py                # paramiko 远程执行/上传（没有 sftp 时用得上）
│   └── rc.local.example       # rc.local 钩子示例
└── docs/                      # 详细文档，见下方索引
```

---

## 快速开始

```sh
git clone git@github.com:shiba2046/glinet-mt3600be-collection.git
cd glinet-mt3600be-collection

# 0) 首次：配置 SSH 免密（只需输一次密码）
ROUTER_HOST=192.168.8.1 ./deploy.sh --setup-key

# 1) 先看设备现状（不安装）
ROUTER_HOST=192.168.8.1 ./deploy.sh --status

# 2) 安装：开关模块 + 自动更新 + 每日 04:00 cron + Telegram 通知
ROUTER_HOST=192.168.8.1 ./deploy.sh

# 3) 可选：小内存优化 + 停用 DPI 等后台服务
ROUTER_HOST=192.168.8.1 ./deploy.sh --tune-openclash --trim-services
```

装完拨一下开关，然后：

```sh
sh /etc/gl-switch.d/openclash.sh status
tail -f /tmp/openclash-switch.log
```

**Telegram 通知（可选）**：浏览器打开 `http://192.168.8.1:8080/cgi-bin/oc-notify`，
设一个访问 PIN，填 Bot Token / Chat ID / Telegram API 地址（墙后可达的反代），
启用后点「发送测试消息」。详见 [docs/11-telegram-notify.md](docs/11-telegram-notify.md)。

命令行等价写法：

```sh
sh /etc/openclash-notify.sh set bot_token '123456789:AAF...'
sh /etc/openclash-notify.sh set chat_id '-1001234567890'
sh /etc/openclash-notify.sh set api_base 'https://tg.example.com'
sh /etc/openclash-notify.sh enable && sh /etc/openclash-notify.sh test
```

> `--setup-key` 会生成 `~/.ssh/id_ed25519_glinet` 并把公钥写到
> `/etc/dropbear/authorized_keys`（GL 固件跑 dropbear，`ssh-copy-id` 默认写的
> `~/.ssh/authorized_keys` 不生效）。装好之后 `deploy.sh` 自动带 `-i`，不再提示密码。
> 不想用 ssh 也可以把仓库推到设备后直接跑 `sh install.sh`；
> 不想装通知模块可加 `--no-notify`，完整参数见 `sh install.sh -h`。

---

## 事件链路

```
物理拨杆
   │  (procd button handler)
   ▼
/etc/rc.button/switch                 ← 固件调度器，本仓库不修改
   │  读 switch-button.@main[0].func = "openclash"
   │  flock /var/lock/gl-switch.lock "/etc/gl-switch.d/openclash.sh" on|off &
   ▼
/etc/gl-switch.d/openclash.sh on|off  ← 本仓库唯一的实现
   │
   ├─ probe()  三个 generate_204：204=在线 / 有 HTTP 但非 204=认证页 / 全失败=离线
   ├─ uci set openclash.config.enable=1|0     ← 意图，watcher 与启动流程都看它
   ├─ start_clash / stop_clash                ← 调 /etc/init.d/openclash
   ├─ watch_start / watch_stop                ← 20s 轮询的后台守护
   └─ notify <event>                         ← 写本地队列即返回；独立进程发 Telegram
        └─ /etc/openclash-notify.sh flush     ← 断网留队列，恢复后按序补发
```

---

## 实测数据（GL-MT3600BE / 481MB RAM）

| 项目 | 数值 |
|---|---|
| 拨到 ON 到核心稳定运行 | 21s（含 14s 稳定性观察窗口） |
| 拨到 OFF 到进程消失 | 10s |
| 重复拨 ON | 秒回，不重启核心（同 pid） |
| 核心内存占用 | 约 100MB RSS |
| 启动后可用内存 | 55–60MB |
| 代理连通性 | `curl -x 127.0.0.1:7890 https://www.gstatic.com/generate_204` → 204 |

---

## 兼容性

- 设备：GL.iNet GL-MT3600BE（mt7987 / aarch64）。GL-MT3600BE 之外的 GL 4.x 固件
  只要 `switch-button` + `/etc/gl-switch.d/` 机制一致，理论上可用，但未验证。
- 固件：4.9.0（`Openwrt like iStoreOS Style by wukongdaily`）。
- OpenClash：0.48.002（luci-app-openclash），mihomo Meta 核心。
- Shell：BusyBox ash。**未在 bash 下测试**，脚本用了 ash 的特性，也能在 dash 下跑。

## 已知限制

- 只能**一个**拨杆功能：`switch-button.@main[0].func` 是单值，绑了 openclash 就不能同时绑 AdGuardHome。
- 门控依赖 `curl` 时间同步正确（HTTPS 不走，只发 HTTP 204 探测，时间错也能用）。
- `/tmp` 下的日志重启即清空；如需长期留档，把 `OCSW_LOG` 指到 `/etc/` 下（注意 flash 写入量）。
- 不改固件前端 JS，所以 GL 网页里「拨动开关功能」下拉框不会显示 openclash 选项，纯 CLI 绑定。

## 文档索引

| 文档 | 内容 |
|---|---|
| [docs/01-environment.md](docs/01-environment.md) | 设备与固件基线、内存现实、已做的系统调整 |
| [docs/02-switch-button.md](docs/02-switch-button.md) | 拨杆的固件调度机制（含原厂脚本逐段解读） |
| [docs/03-switch-module.md](docs/03-switch-module.md) | 模块设计：状态机、幂等、锁、超时、日志 |
| [docs/04-network-gating.md](docs/04-network-gating.md) | 酒店 WiFi / captive portal 门控逻辑 |
| [docs/05-memory-and-core.md](docs/05-memory-and-core.md) | OOM、核心降级、Meta vs Smart、持久化 |
| [docs/06-auto-update.md](docs/06-auto-update.md) | 三类依赖文件的更新责任划分 |
| [docs/07-led.md](docs/07-led.md) | 指示灯语义与副作用 |
| [docs/08-deploy.md](docs/08-deploy.md) | 部署、升级保留、回滚与卸载 |
| [docs/09-troubleshooting.md](docs/09-troubleshooting.md) | 症状 → 原因 → 处理 |
| [docs/10-changelog.md](docs/10-changelog.md) | 版本历史与踩坑记录 |
| [docs/11-telegram-notify.md](docs/11-telegram-notify.md) | Telegram 状态推送、反代地址、配置页与排查 |

## 许可

MIT，见 [LICENSE](LICENSE)。
