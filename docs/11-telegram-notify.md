# 11 · Telegram 状态通知与配置页

> 对应 `scripts/openclash-notify.sh` v1.1.0、`scripts/cgi-bin/oc-notify`、`scripts/gl-switch.d/openclash.sh` v0.4.0

## 11.1 要解决什么

人在酒店、路由器在桌上，看不到 `/tmp/openclash-switch.log`。希望拨杆一开、代理一断，
手机上就能收到一条消息。

难点不在「调 Telegram API」，而在这三点：

| 约束 | 后果 | 处理方式 |
|---|---|---|
| 拨杆脚本在固件 `flock` 串行区里执行 | 一次 HTTPS 超时 12s 会让开关看起来卡死 | `emit` 只写本地队列（实测 0s 返回），另起独立进程发送 |
| 断网时 Telegram 同样发不出去 | 「断线了」这条消息恰好最难送达 | 消息落 flash 队列，网络恢复后按序补发并标注延迟 |
| Telegram 在墙后不可直连 | 走 clash 代理会把反代流量二次转发 | `api_base` 可填墙后可达的反代地址，默认 `direct` 只请求它、不切换 |

## 11.2 文件与入口

| 路径 | 作用 |
|---|---|
| `/etc/config/openclash-notify` | UCI 配置（token / chat_id / api_base / proxy_auth / api_resolve / 事件白名单 / web_pin） |
| `/etc/openclash-notify.sh` | 通知模块：入队、异步发送、补发、诊断 |
| `/etc/openclash-notify/spool/*.msg` | 待发队列，flash 持久，重启不丢；上限 50 条 |
| `/www/cgi-bin/oc-notify` | 配置页 CGI（uhttpd 现成的 `cgi_prefix=/cgi-bin`，无需新服务） |
| `/tmp/openclash-notify.log` | 发送日志，超 128KB 轮转 |

配置页地址：**`http://192.168.8.1:8080/cgi-bin/oc-notify`**

> 为什么是 8080：GL.iNet 把 80/443 给了 nginx（GL 管理界面），uhttpd/LuCI 在 8080/8443。
> 往 `/www/cgi-bin/` 放一个可执行文件就会被当 CGI 执行，不用改 uhttpd 配置、不用重启。

## 11.3 配置方式

### A. 网页（推荐）

打开上面的地址 → 首次进入设置一个访问 PIN → 填 Bot Token / Chat ID / **Telegram API 地址**
→ 启用 → 点「发送测试消息」。

密码框留空表示不修改已有 token。页面还能看队列长度、最近日志，以及手动「补发队列」「清空队列」。

### B. 命令行

```sh
sh /etc/openclash-notify.sh set bot_token '123456789:AAF...'
sh /etc/openclash-notify.sh set chat_id '-1001234567890'
sh /etc/openclash-notify.sh set api_base 'https://tg.example.com'
sh /etc/openclash-notify.sh set proxy_auth  '反代要求的密钥'    # 可选，见 11.4.1
sh /etc/openclash-notify.sh set api_resolve '1.2.3.4'            # 可选，见 11.4.2
sh /etc/openclash-notify.sh enable
sh /etc/openclash-notify.sh test            # 发一条，打印结果
sh /etc/openclash-notify.sh status          # 配置摘要 + 队列 + 最近日志
```

`set` 的值只允许字母数字和 `: _ , . = @ / + -`，**不能含空格**（`proxy_auth` 要作为单个
curl 参数展开）。直接编辑配置文件不受此限制，但同样不建议含空格。

### C. 直接改配置文件

`/etc/config/openclash-notify`：

```
config notify 'main'
	option enabled '1'
	option bot_token '123456789:AAF...'
	option chat_id '-1001234567890'
	option api_base 'https://tg.example.com'
	option proxy_auth '反代要求的密钥'
	option api_resolve ''
	option api_mode 'direct'
	option proxy_port '7893'
	option notify_events 'ready,start_fail,switch_off,net_down,captive,net_up,offline,update_fail'
	option web_pin '123456'
```

改完 `uci commit openclash-notify`。这个值会被 `install.sh` 升级保留（已加入 `/etc/sysupgrade.conf`）。

## 11.4 反代地址怎么填（api_base）

脚本按 Bot API 官方规则拼接：

```
<api_base>/bot<TOKEN>/sendMessage
```

| `api_base` | 实际请求 |
|---|---|
| `https://api.telegram.org`（默认） | `https://api.telegram.org/bot<TOKEN>/sendMessage` |
| `https://tg.example.com` | `https://tg.example.com/bot<TOKEN>/sendMessage` |
| `https://tg.example.com/tg` | `https://tg.example.com/tg/bot<TOKEN>/sendMessage` |

要点：

- **只填到域名（或路径前缀），不要带 `/bot`**，脚本自己拼。
- 末尾斜杠会自动去掉（`${api_base%/}`）。
- 反代需要保持 `/bot<TOKEN>/<METHOD>` 这段路径原样透传，这是绝大多数 Cloudflare Workers /
  Vercel / Nginx 反代 telegram bot api 的默认形态。
- 若你的反代把 token 放在 query、header 或其它路径里，改 `send_one()` 里 `_url` 的拼接即可。
- HTTPS 自签证书：curl 带 `--cacert /etc/ssl/certs/ca-certificates.crt`，自签 CA 需要加进这个 bundle；
  纯 `http://` 反代不受影响。
- `api_mode` 默认 **`direct`**：只请求 `api_base`，不做任何模式切换、不走 clash 代理。
  另有 `proxy`（走本机 mixed-port 7893）和 `auto`（直连失败再试代理）两个可选值，
  用墙后可达的反代时**保持 direct**，避免反代流量被 clash 二次转发。

### 11.4.1 反代鉴权头（proxy_auth）

自建反代常要求一个自定义头才放行。填了 `proxy_auth` 后，每次请求都会带上：

```
curl -H "X-Proxy-Auth: <值>" ...
```

- 配置页有对应输入框；`status` / `config` 里打码显示；值为空则完全不加这个头。
- 值不能含空格。配置页里留空表示「不修改」，要**清空**需 SSH：
  `uci set openclash-notify.main.proxy_auth='' && uci commit openclash-notify`
- 头名写死在 `send_one()` 的 `_authopt` 一行，换名字改那里即可。

### 11.4.2 DNS 负缓存兜底（api_resolve）

现象：`dig @1.1.1.1 域名` 能解析，路由器上 `curl` 却报
`curl: (6) Could not resolve host`。

多为**本地解析链路的问题**：路由器的 `resolv.conf → 127.0.0.1(dnsmasq) → 上游 DNS`
里，上游在该记录添加之前查过这个主机名，缓存了 NXDOMAIN 负应答；也可能是上游开了
DNS 过滤。判断方法是多问几个公共解析器（1.1.1.1 / 8.8.8.8 / 223.5.5.5）——
若它们都返回正确 A 记录、只有默认 DNS 报 NXDOMAIN，说明域名本身已经生效，
不必等"全球生效"。

`api_resolve` 填反代 IP 后，脚本给 curl 加 `--resolve <api_base 主机>:<端口>:<IP>`
绕开系统 DNS；TLS SNI 仍按 URL 里的原主机名发，Cloudflare 这类共享 IP 反代可正确路由。
端口默认 443，`api_base` 带非标准端口时自动取用。

> **不改系统 DNS**：桥接公共 WiFi 时动 dnsmasq 上游可能影响 captive portal 弹页，
> `--resolve` 只作用于这一条请求，是最小的手术。

本地 DNS 恢复后清空即可：

```sh
uci set openclash-notify.main.api_resolve='' && uci commit openclash-notify
```

反代换 IP 时这个值也要跟着改，长期挂着需留意。

## 11.5 事件清单

默认启用：`ready,start_fail,switch_off,net_down,captive,net_up,offline,update_fail`

| 事件 | 触发时机 |
|---|---|
| `ready` | 拨到 ON 且核心启动成功（稳定 14s）；或开机 `sync` 时核心已在运行 |
| `start_fail` | 等满 150s 仍未得到稳定运行的核心 |
| `switch_off` | 拨到 OFF，核心已停止 |
| `net_down` | watcher 连续 3 次（约 60s）外网探测失败，但上游链路正常 → 暂停核心 |
| `offline` | 上游链路断开（无默认路由 / 网关不可达）→ 暂停核心 |
| `captive` | 检测到强制门户，需要网页认证 |
| `net_up` | 网络恢复，核心重新拉起或持续运行 |
| `update_fail` | 每日 04:00 依赖更新失败 |
| `update_ok` | 每日更新成功（默认**不**启用，想每天收一条心跳可手动加入） |
| `core_down` | 预留事件，当前版本未接钩子 |

去重：同一事件 25 秒内只记一次；watcher 是**状态变化（边沿）触发**，不是每 20s 轮询都发。

消息形如：

```
GL-MT3600BE · OpenClash
已就绪 | 核心 pid=1234 | 稳定 14s | 总耗时 21s | 可用内存 58MB
时间 2026-11-10 14:46:03
```

延迟补发（超过 90 秒）会追加一行：

```
（离线期间事件，发生于 2026-11-10 14:20:11，延迟 1552s 送达）
```

## 11.6 时序：为什么不会拖慢拨杆

```
拨杆 on
  └─ openclash.sh（持有固件 flock）
       ├─ start_clash / led_on ...
       └─ notify ready  →  [ -x ] + uci 检查
                              └─ ( exec sh notify.sh emit ... ) &   ← 立即返回
                                   └─ 写 spool/<ts>-<event>.msg   ← 毫秒级
                                        └─ ( exec sh notify.sh flush ) &
                                             └─ curl（独立进程，4s 连接 / 12s 总超时）
```

`notify.sh` 还会在入口关闭 fd 3–20，避免继承调用方的锁句柄（见踩坑记录 #5）。
`flush` 用原子目录锁串行，同一时刻只有一个发送进程；失败即停，保持队列顺序。

网络恢复时，watcher 从非 online 状态回到 online 会主动触发一次 `flush`；
心跳（约 5 分钟）也会兜底再试一次。断网期间攒下的消息因此不会丢。

## 11.7 安全

- 配置页 CGI 由 uhttpd 以 root 执行。脚本**不 `eval`、不拼接 shell 命令**，
  只经由 `notify.sh set` 的固定键白名单写入；表单值经 URL 解码后再做一次字符白名单校验
  （只允许字母数字和 `: _ , . = @ / + -`，不含空格）。
- `bot_token` 与 `proxy_auth` 在 `config` / `status` 输出里都会打码；配置页对应输入框是
  password 类型，且留空表示不修改。
- `web_pin` 防止同网段其他人打开 8080 看到 chat_id 或改配置。PIN 存在路由器本地，明文。
  忘记可在 SSH 里 `uci set openclash-notify.main.web_pin='' && uci commit openclash-notify` 重置。
- 首次进入页面时 PIN 未设置，会要求你设一个；此时页面也还没存任何 token。
- 8080/8443 由防火墙默认不对 WAN 开放；如已手动放行，务必设 PIN。
- `bot_token` 在 `config` 子命令输出里会打码。

## 11.8 排查

| 现象 | 检查 |
|---|---|
| 点测试没收到 | `sh /etc/openclash-notify.sh test` 看返回；再看 `tail -n 20 /tmp/openclash-notify.log` |
| 返回 `401 Unauthorized` | 网络/证书/URL 拼接都正常，是 token 不对 |
| 返回 `400 Bad Request: chat not found` | chat_id 不对，或 bot 没被加进那个群/频道 |
| 日志里 `direct 发送失败：` 后面是空的 | 连不上 `api_base`：反代地址写错、DNS 或证书问题 |
| `curl: (6) Could not resolve host` | 见 [11.4.2](#1142-dns-负缓存兜底api_resolve)：公共 DNS 能解析而本地不行，填 `api_resolve` |
| 反代返回 403 / 401 但链路通 | `proxy_auth` 是否填对、头名是否匹配（默认 `X-Proxy-Auth`） |
| 队列一直不减 | `enabled` 是否为 1、token/chat_id 是否填了；`sh /etc/openclash-notify.sh flush` 手动补发 |
| 消息延迟很久才到 | 正常：断网期间发不出去，恢复后补发，正文会标延迟时间 |
| 配置页 404 | 确认访问的是 **8080** 端口；`ls -l /www/cgi-bin/oc-notify` 权限应为 755 |
| 配置页 500 | `sh -n /www/cgi-bin/oc-notify`；看是否缺 `/etc/config/openclash-notify` |

## 11.9 实测（2026-11-10，固件 4.9.0）

| 项目 | 结果 |
|---|---|
| 配置页 `GET /cgi-bin/oc-notify` | HTTP 200，5442 字节，表单字段齐全 |
| 假 token 同步测试 | 收到 `{"ok":false,"error_code":401,"description":"Unauthorized"}` |
| `emit` 返回耗时 | 0s（异步生效） |
| 发送失败后的队列 | 保留 1 条，不丢 |
| 指向返回 `ok:true` 的接口补发 | 队列 1 → 0，日志 `已发送 ready` |

> 测试用的接口是临时放在 `/www/cgi-bin/ocn-mock` 的 CGI，测完已删除。
> 这一轮是**离线自测**；随后设备已填入真实配置并复测，见 11.10。

## 11.10 真实反代实测（2026-11-10，v1.1.0）

场景：`api_base` 指向自建反代，需要自定义鉴权头；本地上游 DNS 把该主机名返回 NXDOMAIN，
而 1.1.1.1 / 8.8.8.8 / 223.5.5.5 / 208.67.222.222 均返回 Cloudflare A 记录
（TTL 300），权威 NS / SOA 正常。

| 项目 | 结果 |
|---|---|
| `getMe` 带 `X-Proxy-Auth` + `--resolve` | `ok:true`，返回 bot 信息 → header / token / 反代链路全通 |
| `sh /etc/openclash-notify.sh test` | 同步测试发送成功，日志 `已发送 test` |
| `emit ready` 异步投递 | 0s 返回，1s 后 `已发送 ready`，队列 1 → 0 |
| 配置页 | `proxy_auth` / `api_resolve` 两个字段正常渲染 |

结论：域名在公网已生效，NXDOMAIN 来自本地上游的负缓存 / 过滤；用 `api_resolve` 绕开，
**未改动 dnsmasq 上游**（避免影响 captive portal）。本地 DNS 恢复后清空 `api_resolve` 即可。

> 真实 token / 鉴权值 / 反代域名只存在设备的 `/etc/config/openclash-notify`（权限 600），
> 不写入仓库；`install.sh` 的 `init` 是幂等的，重新部署不会覆盖它。
