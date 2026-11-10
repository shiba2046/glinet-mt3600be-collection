# 01 · 设备与固件基线

所有结论都在这台机器上实测过，采集命令附在每节末尾，方便你在别的固件版本上复核。

## 硬件与系统

| 项目 | 实测值 | 采集方式 |
|---|---|---|
| 型号 | GL.iNet GL-MT3600BE（BE3600） | `/proc/gl-hw-info/` |
| 固件 | 4.9.0 | `cat /etc/glversion` |
| 发行版 | `Openwrt like iStoreOS Style by wukongdaily`，OpenWrt 21.02-SNAPSHOT | `cat /etc/openwrt_release` |
| 内核 | 5.4.281 | `uname -r` |
| 架构 | aarch64（mt7987） | `uname -m` |
| 内存 | 481MB，**无 swap、无 zram 模块** | `/proc/meminfo`、`cat /proc/swaps`、`ls /sys/block` |
| 存储 | overlay `/dev/ubi0_2` 343MB，装完剩余约 285MB | `df -h /overlay` |
| 拨杆 | 有，`get_switch_button_status` 返回 `on`/`off` | `. /lib/functions/gl_util.sh; get_switch_button_status` |

## 软件

| 组件 | 版本 |
|---|---|
| luci-app-openclash | 0.48.002 |
| 核心 | mihomo Meta `alpha-gbc76c13`（linux arm64，go1.26.9） |
| 核心路径 | `/etc/openclash/clash` → `/etc/openclash/core/clash_meta`（约 12.8MB） |

## 内存现实：481MB 到底够不够

结论：**刚好够，且没有余量。**

- GL 固件自身服务（nginx、gl_* 守护、uhttpd、netifiy 等）常驻约 250–300MB。
- mihomo 加载完整规则集后 RSS 约 **100MB**。
- 两者相加已经贴着 481MB，一旦触发并发下载（核心/geo 更新）或规则重载，内核 OOM Killer
  就会挑最大的进程下手 —— 也就是 clash。

现场证据（`dmesg`）：

```
Killed process 12345 (clash) total-vm:...kB, anon-rss:...kB
```

OOM 之后还有一个连锁反应，见 [05-memory-and-core.md](05-memory-and-core.md)：
OpenClash 会把核心从 Smart 降级成 Meta，而配置里若存在 `type: smart` 代理组，
新核心会直接 `Parse config error: unsupported type: smart`，表现就是"怎么点都起不来"。

## 这台机器上做过的系统调整

这些是**可选项**，不是脚本运行的前提，但如果你也遇到 OOM，建议照做（`install.sh --tune-openclash --trim-services` 会自动执行前两组）。

**OpenClash 参数**

| 参数 | 值 | 作用 |
|---|---|---|
| `small_flash_memory` | `0` | 核心与 geo 落 flash，重启不再重新下载 |
| `geodata_loader` | `memconservative` | 降低 GeoSite 加载内存占用（日志可见 `Geodata Loader mode: memconservative`） |
| `smart_enable` / `smart_enable_lgbm` | `0` / `0` | 不启用 smart 分组/GBM 模型（省 8.9MB `Model.bin` 与额外内存） |
| `auto_smart_switch` | `0` | 不把代理组改写成 `type: smart`（Meta 核心不支持） |
| `core_type` | `Meta` | 与 `/etc/openclash/core/clash_meta` 实际构建一致 |

**腾内存**

| 动作 | 省下 | 副作用 |
|---|---|---|
| `worker_processes 2 → 1`（`/etc/nginx/nginx.conf`） | ~10MB | 无（单核设备上 2 个 worker 本来就没意义） |
| `netifyd` disable | ~20MB | GL 网页「客户端流量/应用识别」统计失效 |
| `gl_dpi` / `gl_dpi_flow_statistics` disable | 含在上项 | 同上 |

调整前可用内存约 20MB 级，调整后 **55–60MB**，代理实测 `204 / 70ms`。

**升级保留**

`/etc/sysupgrade.conf` 追加：

```
/etc/gl-switch.d/
/etc/openclash-auto-update.sh
/etc/rc.local
```

`/etc/crontabs/` 和 `/etc/openclash/` 本来就在固件的 `/lib/upgrade/keep.d/` 里，不用重复加。

## 复核命令合集

```sh
# 版本与硬件
cat /etc/glversion; uname -rm; cat /etc/openwrt_release | grep DISTRIB

# 内存压力
awk '/MemTotal|MemAvailable/{print $1, int($2/1024)"MB"}' /proc/meminfo
ps w | awk 'NR>1{printf "%d KB %s\n", $3, $5}' | sort -rn | head -8

# OpenClash 关键参数
for k in core_type small_flash_memory geodata_loader smart_enable auto_smart_switch enable; do
    printf '%-22s %s\n' "$k" "$(uci -q get openclash.config.$k)"
done

# 有没有被 OOM 杀过
dmesg | grep 'Killed process.*clash'
```
