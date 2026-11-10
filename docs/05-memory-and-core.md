# 05 · 内存与核心

这台机器的所有"玄学问题"最后都指向同一个约束：**481MB 内存、零 swap、mihomo 要 100MB。**

## 内存账本（实测）

| 项 | 数值 |
|---|---|
| MemTotal | 481MB |
| GL 固件后台服务（nginx、gl_* 守护、uhttpd、日志…） | 约 250–300MB |
| mihomo 核心（加载完整规则集后 RSS） | 约 100MB |
| 优化前可用内存 | 20MB 级（贴着 OOM 线） |
| 优化后可用内存 | 55–60MB 起步，156MB（核心未跑时） |

`free` 在这台机器上参考价值有限，用 `MemAvailable` 更准：

```sh
awk '/MemTotal|MemAvailable/{print $1, int($2/1024)"MB"}' /proc/meminfo
```

swap 是没有的，而且**加不了**：无 `zram` 模块，`/proc/swaps` 为空，ubifs 也不支持 swapfile。
所以唯一出路是"少占一点"。

## OOM 与它的连锁反应

`dmesg` 里的证据：

```
Killed process 12345 (clash) total-vm:... anon-rss:... 
```

被 OOM 杀掉本身不算最坏 —— 最坏的是**之后发生的事**：

```
1. clash 被杀
2. OpenClash 判定核心启动失败，把 core_type 从 Smart 降级成 Meta
3. 但 auto_smart_switch=1 时，配置生成阶段会把代理组写成 type: smart
4. Meta 核心不认识 smart 组
     -> level=fatal msg="Parse config error: proxy group[0]: unsupported type: smart"
5. 于是无论手动点"开启"还是拨杆，核心都起不来
```

第 3 步的机制：启用 smart 相关开关时，OpenClash 在生成运行配置（`/etc/openclash/聚合.yaml`）
的阶段会把 `url-test` 组改写成 smart 组（为了用 lightgbm 做延迟预测）。
关掉开关后生成的配置里就是标准的 `type: url-test`，Meta 核心可以直接跑。

复现/确认：

```sh
grep -c 'type: smart' /etc/openclash/聚合.yaml     # 大于 0 就会有解析错误
grep -i 'unsupported type' /tmp/openclash.log | tail
```

## 为什么不用 Smart 核心

Smart（带 lightgbm 的 alpha 分支）需要额外的 `Model.bin`（约 8.9MB）常驻做延迟预测，
运行内存明显高于标准 Meta。在这台 481MB 的机器上实测无法稳定常驻，会被 OOM 反复杀掉。
所以本仓库统一使用**标准 Meta 核心**：

```sh
/etc/openclash/core/clash_meta -v
# Mihomo Meta alpha-gbc76c13 linux arm64 with go1.26.9 ...
```

对应参数：

```sh
uci set openclash.config.core_type='Meta'
uci set openclash.config.smart_enable='0'
uci set openclash.config.smart_enable_lgbm='0'
uci set openclash.config.auto_smart_switch='0'
uci commit openclash
```

不要装 Smart 就不要留着 `Model.bin`（8.9MB，纯占空间）：

```sh
rm -f /etc/openclash/Model.bin
```

## 换核心的正确姿势

自动更新脚本提供两个手动命令（**不放进 cron**，见 [06](06-auto-update.md)）：

```sh
sh /etc/openclash-auto-update.sh core-check     # 只查版本
sh /etc/openclash-auto-update.sh core-update    # 下载 → 校验 → 备份 → 替换
```

`core-update` 的保护：

- 可用内存 < 80MB 直接拒绝（下载+解包会顶到峰值）
- 外网不通拒绝
- 下载/解包/执行任一失败都放弃替换，原核心不动
- 替换前备份 `clash_meta.bak`，新核心执行失败自动回滚

手动方式（比如 `core-update` 不可用时）：

```sh
cd /tmp
wget -O clash.tar.gz https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz
mkdir -p metatest && tar -xzf clash.tar.gz -C metatest
./metatest/clash -v                      # 能打印版本才继续
/etc/init.d/openclash stop
cp -f /etc/openclash/core/clash_meta /etc/openclash/core/clash_meta.bak
cp -f metatest/clash /etc/openclash/core/clash_meta && chmod 755 /etc/openclash/core/clash_meta
rm -rf /tmp/metatest /tmp/clash.tar.gz
```

## 持久化：为什么以前每次开机都要下载

`openclash.config.small_flash_memory=1` 时，OpenClash 把核心和 geo 数据放在
`/tmp/etc/openclash/` —— 这是 tmpfs，**重启即清空**。于是每次开机都要重下：

| 文件 | 大小 |
|---|---|
| 核心 `clash_meta` | 12.8MB |
| `GeoSite.dat` | 4.2MB |
| `Model.bin` | 8.9MB（smart 用，现在不需要） |

改成 `0` 之后全部落在 `/etc/openclash/`（flash，持久）：

```
/etc/openclash/clash          -> core/clash_meta
/etc/openclash/core/clash_meta   12.8MB
/etc/openclash/GeoSite.dat        4.2MB
/etc/openclash/china_ip_route.ipset  150KB
```

overlay 343MB，装完还剩 285MB，完全够。

```sh
uci set openclash.config.small_flash_memory='0'
uci commit openclash
ls -d /tmp/etc/openclash 2>/dev/null || echo '已无临时目录，启动不再走 /tmp'
```

## geodata 加载模式

```sh
uci set openclash.config.geodata_loader='memconservative'
uci commit openclash
```

日志里可以确认生效：

```
Geodata Loader mode: memconservative
```

它牺牲一点匹配速度，换取更低的 GeoSite 解析内存，在这个量级的设备上是划算的。

## 腾内存的取舍

| 手段 | 省下 | 代价 | 建议 |
|---|---|---|---|
| `worker_processes 2 → 1` | ~10MB | 无 | 做 |
| `netifyd` + `gl_dpi` 停用 | ~20MB | GL 网页的客户端流量/应用识别统计失效 | 内存紧张时做 |
| 不用 Smart 核心 | 8.9MB 文件 + 运行内存 | 没有 lightgbm 延迟预测 | 做 |
| 精简规则集（减少 rule-providers） | 10–30MB | 分流精度下降 | 只在还不够时做 |
| 加 swap | — | 无 zram 模块、ubifs 不支持 swapfile | 做不了 |

恢复被停用的 DPI（想用回客户端统计时）：

```sh
/etc/init.d/netifyd enable && /etc/init.d/netifyd start
/etc/init.d/gl_dpi enable && /etc/init.d/gl_dpi start
```

## 阈值与告警

脚本里有两处内存判断：

- 启动成功但可用内存 < 30MB → 日志写 WARN，提示可能再次被 OOM
- 自动更新前可用内存 < 45MB → 跳过本次更新（更新过程内存峰值更高）

`status` 里直接看：

```
可用内存      : 57MB / 481MB
```
