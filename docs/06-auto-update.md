# 06 · 依赖文件的自动更新

文件：`scripts/openclash-auto-update.sh` → 设备上 `/etc/openclash-auto-update.sh`

## 先分清"谁该负责"

OpenClash 目录下那堆文件，更新责任不是一个，而是三个：

| 文件 | 谁更新 | 需要 cron 吗 |
|---|---|---|
| `GeoSite.dat`、`Country.mmdb`、`geoip*.dat` | **mihomo 核心自己**（`geo-auto-update: true`） | 不需要 |
| `rule_provider/*.mrs`（十来个远程规则，共约 1.3MB） | **mihomo 核心自己**（每个 provider 带 `interval: 86400`） | 不需要 |
| `config/聚合.yaml`（订阅配置） | 本脚本 | **需要**（每日 04:00） |
| `core/clash_meta`（核心二进制 12.8MB） | 手动 | 不需要（故意不自动） |

依据就在配置里：

```yaml
geo-auto-update: true
geo-update-interval: 24
```

以及每个 `rule-providers` 条目自带的 `interval: 86400`。核心只要在跑，到点就自己下载并
原地覆盖到持久目录 —— **你再加一套 cron 去下同一批文件，纯属和核心抢文件。**

所以本脚本只做"订阅配置"这一件真正需要定时的事。

## 为什么不直接用网页里的自动更新

OpenClash 自己确实支持，但有两个坑：

**坑 1：任务会被 `stop` 删掉。** 它把任务写进 `/etc/crontabs/root` 并带上
`#openclash-cron-task` 标记：

```sh
echo "0 $(...auto_update_time) * * ... /usr/share/openclash/openclash.sh #openclash-cron-task" >> $CRON_FILE
```

而停止服务时：

```sh
del_cron()
{
   sed -i '/#openclash-cron-task/d' $CRON_FILE
   sed -i '/#openclash-overwrite-download/d' $CRON_FILE
   crontab $CRON_FILE
}
```

也就是说**拨到 OFF、OpenClash 一停，任务就整行消失**，下次 `start` 才重建。
你带着路由器出门、家里开关 OFF 的那几天，订阅是不会更新的。

**坑 2：没有网络门控。** 凌晨 4 点在酒店可能既没连上 WiFi 又卡在认证页，
官方任务会照跑一遍、失败、刷一堆日志。`openclash.sh` 失败后还会走"直连重试"分支。

## 本仓库的做法

```
0 4 * * * /etc/openclash-auto-update.sh run >/dev/null 2>&1 # openclash-auto-update
```

这行**不带** `#openclash-cron-task` 标记，所以 `del_cron` 删不掉它。
效果：开关 OFF 期间订阅照常更新（在家时把新订阅准备好，出门拨 ON 直接用新的）。

安装：`sh /etc/openclash-auto-update.sh install-cron`（`install.sh` 会自动调用）。
它会先按标记删掉旧行再追加，重复执行不会堆积。

同时在 GL 网页里**关闭**这几个开关，避免两套任务并存：

- 配置文件自动更新（`auto_update`）
- GeoIP / GeoSite / ASN / chnroute 自动更新（`geo_auto_update` 等）
- 配置文件定时重启（`auto_restart`）

## 三道门

每次 `run` 先过门，不通过就跳过并记原因，不产生失败噪音：

| 检查 | 判据 | 跳过时状态 |
|---|---|---|
| 外网 | 三个 `generate_204`，任一 204 | `skipped-offline` |
| 认证页 | HTTP 200/30x 且 body 含 `<html` | `skipped-portal` |
| 内存 | 可用内存 < 45MB | `skipped-lowmem` |

状态写到 `/etc/openclash/.auto-update.state`：

```
time=2026-11-10 13:03:11
result=ok
detail=mode=norestart
```

## 核心没在跑时不重启

这是关键设计。更新订阅后要生效需要重启核心，但如果开关是 OFF（你在家里不用代理），
凌晨把核心偷偷拉起来会：占 100MB 内存、违背拨杆状态、还可能和门控抢执行。

所以脚本判断：

```sh
if [ -n "$(clash_pid)" ]; then
    "$OC_UPDATE" ""            # 允许 OpenClash 自己重启核心使配置生效
else
    "$OC_UPDATE" "" norestart  # 只更新文件，不拉起核心
fi
```

新配置落盘后，下次拨到 ON 或者下次重启核心时自然生效。

> **坑**：`/usr/share/openclash/openclash.sh` 的 shebang 是 `#!/bin/bash`。
> 用 `sh openclash.sh` 调用会因 ash 不兼容而**静默失败**（rc=2，日志里几乎看不出原因）。
> 必须直接执行 `"$OC_UPDATE"` 让 shebang 生效。

## geo 字段兜底

换订阅模板后，`geo-auto-update` 可能丢字段或被改成 false，那样核心就再也不更新 geo 了
——而这批文件恰恰不需要我们管，唯一的保障就是这两个字段存在。

`ensure_geo_auto()` 在每次订阅更新成功后检查订阅源文件 `config/聚合.yaml`：

- 有 `geo-auto-update:` 但不是 `true` → 改回 `true`
- 完全没有该字段 → 在文件头插一行 `geo-auto-update: true`
- 缺 `geo-update-interval:` → 补 `24`

改的是**订阅源模板**，OpenClash 每次 `start` 会据此重新生成运行配置。

## 核心二进制：故意不自动

12.8MB 下载 + Alpha 版本变动可能改变内存占用，在只剩 55MB 的设备上自动替换风险太高。
只提供手动命令：

```sh
sh /etc/openclash-auto-update.sh core-check    # 当前版本 / GitHub 最新 tag（仅参考）
sh /etc/openclash-auto-update.sh core-update   # 带内存门控、备份、失败回滚
```

`core-check` 查的是 MetaCubeX/mihomo 的稳定版 tag，而本机装的是 OpenClash 提供的
alpha 构建，版本号不直接可比，只作参考。

## 状态与日志

```sh
sh /etc/openclash-auto-update.sh status
```

输出包含：核心版本、各 geo 文件大小与时间、规则集数量与最近更新时间、cron 任务、
上次执行结果、配置里的 `geo-auto-update`、日志尾部。

日志 `/tmp/openclash-auto-update.log`，超过 128KB 保留后半段。
正常一次运行约 40–50 秒（3 个订阅源，无变化时不重启核心）。

## 推荐的完整更新节奏

| 频率 | 内容 | 方式 |
|---|---|---|
| 核心运行期间自动 | geo 数据、远程规则集 | mihomo 自带 `geo-auto-update` / `interval` |
| 每天 04:00 | 订阅配置 | 本脚本 cron（带网络门控） |
| 换季/有空时 | 核心二进制 | 手动 `core-update` |

这样既不会"每次开机重新下载"，也不会出现两套逻辑抢同一批文件。
