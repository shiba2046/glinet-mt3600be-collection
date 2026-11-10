# 12 · 内存占用、zram 压缩交换与规则精简

> 实测环境：GL-MT3600BE，固件 4.9.0 / OpenWrt 21.02-SNAPSHOT，内核 `5.4.281`，
> `MemTotal ≈ 481 MB`（512MB 物理内存扣除内核保留）。2026-11-10。

## 12.1 49MB 是怎么来的

| 状态 | MemAvailable | 说明 |
|---|---|---|
| 拨杆 OFF，优化前 | 152–158 MB | clash 未运行 |
| **拨杆 ON，优化前** | **49.0 MB** | clash 单进程 RSS **105 MB**，代理 `generate_204` 返回 204 / 0.115s |
| 拨杆 OFF，停服务后 | 174.8 MB | 见 12.3 |
| **拨杆 ON，停服务 + zram 后** | **61.6 MB** | 代理 204 / 0.065s |

49MB 不是「马上要崩」：内核 `min_free_kbytes = 16MB`，ON 时 `MemFree` 还有 46MB，
离水位约 30MB。但余量太薄——每日 04:00 订阅更新下载+解压、Telegram 通知起 curl、
watcher 探测、连接数暴涨，任意一项都能瞬间再吃 20–40MB。之前「核心反复被 OOM Killer
杀掉」就发生在这个区间。**目标是把 ON 状态抬到 ≥80MB。**

内存大头实测：

| 项 | 大小 | 能否省 |
|---|---|---|
| clash（Meta 核心）RSS | 105 MB | 能，见 12.5 |
| 内核 `SUnreclaim` slab | 56.7 MB | 基本不能：mt_wifi / mt7993 / mtk_hwnat 驱动预分配 |
| `VmallocUsed` | 45 MB | 同上，别在这里折腾 |
| nginx（master + 1 worker） | 33 MB | 已 `worker_processes 1`，没得再省 |
| 可回收 page cache | 42–50 MB | 内核自动回收，`MemAvailable` 已计入 |
| conntrack | 858 / 16384 条 | 上限可减半，但只省几 MB |

## 12.2 内存压缩：只有 zram 一条路

内核配置实测：

```
CONFIG_SWAP=y          CONFIG_ZRAM=m        CONFIG_ZSMALLOC=m
CONFIG_CRYPTO_LZO=y    CONFIG_CRYPTO_LZ4=m
# CONFIG_KSM is not set          （zswap 也未编译）
```

也就是说 **KSM 页合并、zswap 都不可用**，固件没有网页上的「内存压缩」开关；
唯一能开的就是 zram（把一部分 RAM 当作压缩的 swap 设备）。而且 `zram.ko`
**没有预装**，但 GL 官方 kmod feed 有版本完全匹配的包：

```
kmod-zram       5.4.281-1   依赖 kernel 5.4.281-1-df4fa33… 与 kmod-lib-lzo
zram-swap       8           提供 /etc/init.d/zram，开机自动启用
```

### 当前配置

| 项 | 值 |
|---|---|
| `system.@system[0].zram_size_mb` | `96`（默认按 `MemTotal/2048` 会算成 240MB，过大） |
| `zram_comp_algo` | `lzo`（内核 builtin，A53 上最快） |
| `zram_priority` | `100`（优先用压缩 RAM，不碰磁盘 swap） |
| `vm.swappiness` | `30`，写在 `/etc/sysctl.conf` |
| 开机自启 | `/etc/rc.d/S15zram -> ../init.d/zram` |

### 为什么要正确预期

zram 只压缩**匿名页**（进程堆/栈）。clash 的 geo 数据库是 mmap 的文件页，内核会直接
丢弃干净页再重读，不进压缩池；能被压的主要是 Go 堆。它**不是凭空多出一倍内存**，
而是「用少量 CPU 换空间」，核心价值在于**突发压力时避免 OOM killer**。

对照实测（拨杆 ON）：

| swappiness | zram 换出 | MemAvailable | 代理延迟 |
|---|---|---|---|
| 30（当前） | 0 KB | 61.6 MB | 0.065s |
| 60 | 1.2 MB → 压缩 0.3 MB（4:1） | 57.5 MB | 0.110s |

60 反而更差：换出量小、可用内存更低、延迟更高。所以**保持 30**，让 zram 待命即可。
真遇到订阅更新 / 连接爆发时才会有明显换出，那时压缩比能到 3–4:1。

### 一键安装与回滚

```sh
# 本地把脚本推到设备
scp tools/setup-zram.sh root@192.168.8.1:/tmp/
ssh root@192.168.8.1 'sh /tmp/setup-zram.sh install'

# 查看 / 卸载
sh /tmp/setup-zram.sh status
sh /tmp/setup-zram.sh remove      # 关 swap、卸载包、swappiness 回 60
```

脚本幂等，环境变量 `ZRAM_SIZE_MB` / `ZRAM_SWAPPINESS` 可覆盖默认值。
`/etc/config/system` 与 `/etc/sysctl.conf` 会写进 `/etc/sysupgrade.conf`。

> **刷机注意**：opkg 装的 kmod 包在 `/overlay`，sysupgrade 一般只保留配置文件、
> 不保证保留已装包。升级固件后重跑一次 `setup-zram.sh install` 即可（会跳过已装的包）。

## 12.3 停用无用常驻服务

```sh
scp tools/trim-services.sh root@192.168.8.1:/tmp/
ssh root@192.168.8.1 'sh /tmp/trim-services.sh trim'      # 恢复用 restore
```

停掉（实测都在跑）：`quickstart`（GL 首次设置向导，9.7MB）、`sms_manager` /
`smstools3` / `gl_cellular_manager` / `modem_signal`（4G 蜂窝，桥接 WiFi 用不上）、
`ttyd`、`avahi-daemon`，以及被 eco 包装的 `gl-dpi`、`gl-cloud`、
`alarm_event_report`。`gl_dpi` 的 init 脚本虽然早就 disabled，进程仍会被 eco 守护
拉起，所以脚本在 disable 之后还会收掉残留。

**保护名单（脚本绝不触碰）**：`gl-repeater` / `gl-ngx-session`（桥接公共 WiFi 与
管理界面会话，进程名是 `eco`，`pidof` 查不到属正常）、`gl_led` / `led` /
`gpio_switch` / `gl_switch_button_check`（拨杆与指示灯）、`nginx` / `uhttpd` /
`dnsmasq`（管理界面、配置页 CGI、DNS）。停完自检配置页 200、外网 204。

代价：`ttyd` 停用后没有网页终端，4G 三件套停用后不能用 USB 蜂窝网卡；
`restore` 可全部恢复。实测 OFF 状态 +16MB，ON 状态 49 → 61.6MB。

## 12.4 其它可以顺手做的（本轮未做）

| 方法 | 预计 | 备注 |
|---|---|---|
| `nf_conntrack_max` 16384 → 8192 | 2–4 MB | 当前只用 858 条，见 `net.netfilter.nf_conntrack_max` |
| `vfs_cache_pressure` 100 → 150 | 几 MB | 更积极回收 dentry/inode |
| `log-level: info` → `warning` | 少量 | clash 日志缓冲 |
| `echo 3 > /proc/sys/vm/drop_caches` | 临时 ~40MB | 只是临时，重读 flash 反而慢，**不做定时** |
| 降 `min_free_kbytes` | 不推荐 | 现为 16MB，调低会来不及回收，反而更容易 OOM |

## 12.5 clash 规则精简清单（待确认后再动）

当前订阅 `uci get openclash.config.config_path` = `/etc/openclash/config/聚合.yaml`，
OpenClash 会生成运行配置 `/etc/openclash/聚合.yaml`。

| 项 | 现状 |
|---|---|
| `geodata-loader` | 源订阅写 `standard`，**运行配置已被 UCI 覆盖成 `memconservative`** ✓ |
| `small_flash_memory` | `0`（核心/geo 落 flash，不占 tmpfs）✓ |
| `proxy_mode` | `rule`（非 TUN）✓ |
| rule-providers | 源 13 个 / 运行配置 14 个，全部 `interval: 86400` |
| 规则集文件 | `/etc/openclash/rule_provider/` 共 1.3MB / 14 个 `.mrs` |
| 规则行数 | 14（主要靠 RULE-SET 引用） |
| proxy-providers | 3 个；`_auto_provider_ommehj.yaml` 689.6K / 12577 行 / 约 41 节点（Cloudflare Edge Tunnel 订阅） |
| geo 文件 | `GeoSite.dat` 4.2MB、`Country.mmdb` 268KB |
| `log-level` | `info` |

**建议的可删项**（需要你确认是否有独立策略组需求，确认后再改）：

| 动作 | 理由 |
|---|---|
| 把 `youtube`、`google`、`github`、`gitlab`、`category-ai-!cn`、`google-ip`、`telegram-ip` 合并进 `geolocation-!cn` | 7 个小众规则集，若都指向同一个代理策略组，合并后 match 行为一致但少加载 7 个 `.mrs` |
| 保留 `private-ip`、`cn-ip`、`cn`、`geolocation-cn`、`geolocation-!cn`、`category-ads-all` | 国内直连、私有地址、广告拦截，删了会改变分流 |
| 精简 Cloudflare Edge Tunnel 订阅（689KB / 41 节点） | 只保留常用节点，或换体积更小的订阅；这是 proxy-provider 里最大的一块 |
| 源订阅的 `geodata-loader: standard` 改成 `memconservative` | 防 OpenClash 重新生成配置时回退到更耗内存的 standard |
| `log-level: info` → `warning` | 减少日志缓冲与 flash 写入 |

预计收益 10–20MB，是从 105MB RSS 里省内存最有效的一块。**这轮只统计、未改动任何订阅
或规则文件**；确认要删哪些之后，改 `/etc/openclash/config/聚合.yaml`（源文件），
再由 OpenClash 重新生成运行配置，并实测 ON 状态的 RSS 与 `MemAvailable`。

## 12.6 复现测量

```sh
awk '/MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree/{printf "%-14s %.1f MB\n", $1, $2/1024}' /proc/meminfo
awk '/VmRSS/{printf "clash RSS %.1f MB\n", $2/1024}' /proc/$(pidof clash)/status
awk '{printf "zram %.1f MB -> %.1f MB\n", $1/1048576, $2/1048576}' /sys/block/zram0/mm_stat
cat /proc/swaps
/etc/init.d/zram status
```

拨杆 ON/OFF 会自动触发 Telegram 事件；批量测量时可先
`uci set openclash-notify.main.enabled='0'` 静音，测完记得恢复 `1`。
