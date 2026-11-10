# 03 · 拨动开关模块的设计

文件：`scripts/gl-switch.d/openclash.sh` → 设备上 `/etc/gl-switch.d/openclash.sh`

## 命令接口

| 命令 | 谁调用 | 行为 |
|---|---|---|
| `on` | 固件拨杆（`pressed`） | 置意图=1 → 探测网络 → 启动核心或转等待 → 起 watcher |
| `off` | 固件拨杆（`released`） | 置意图=0 → 停 watcher → 停核心 → 关灯 |
| `sync` | `/etc/rc.local` 钩子 | 读物理拨杆位置，等价调用 `on` 或 `off` |
| `status` | 人工 | 打印全部状态，**不加锁、不产生副作用** |
| `watch` | `on` 内部拉起 | 只跑后台门控循环 |

`status` / `watch` 在加锁之前就分流了，所以它们在核心启动过程中也能随时执行
（不然调试时会和正在跑的 `on` 抢锁）。

## 三个状态来源，别混

排查问题时最容易搞混的就是这三个：

| 名称 | 存在哪 | 含义 |
|---|---|---|
| **物理位置** | GPIO，`get_switch_button_status` | 拨杆现在在哪边 |
| **意图** | `uci openclash.config.enable` | 我们"希望"开还是关（watcher、启动流程都看它） |
| **实际** | `pidof clash` | 核到底在不在跑 |

正常情况三者一致。不一致的情况：

- 拨到 ON 但没网 → 物理=on、意图=1、实际=无（这是**设计如此**，等网）
- 卡在认证页 → 同上，另外日志里会写 `需要网页认证`
- 排队事件 → 物理位置和事件矛盾，脚本按物理位置丢弃该事件（见"防抖"）

`status` 会把三者都打出来，第一眼就该看这三个。

## ON 的完整流程

```
do_on
 ├─ 读物理位置；若与 on 矛盾（排队事件）→ 记 WARN 后 return
 ├─ uci set enable=1 && commit
 ├─ probe()
 │    ├─ 0 在线     → 若核心已在跑：只同步指示灯；否则 start_clash
 │    ├─ 1 认证页   → 若核心在跑：先 stop_clash（否则认证页打不开）；不启动
 │    └─ 2 离线     → 若核心在跑：stop_clash；不启动
 └─ watch_start     （无论哪条分支都起守护，网络恢复后自动拉起）
```

**为什么"核心已在跑"不重启**：开机时 `gl_switch_button_check` 和 `rc.local`
可能各触发一次；每次都重启核心，既慢（20s+）又会在启动瞬间把内存打满。
需要真正重载配置请 `off` → `on`，或在网页上操作。

## 启动成功的判定

这里踩过两个坑，所以逻辑比直觉复杂：

**坑 1：`/etc/init.d/openclash start` 会在核心拉起之前就返回。**
早期版本把它当成同步命令，命令一退出就判定失败 → 假失败。

**坑 2：核心会"闪断重启"一次。** 配置校验通过后 OpenClash 可能重建进程，
pid 会变。看到一次 pid 就当成功 → 假成功（几秒后进程没了）。

现在的判定：

```sh
START_TIMEOUT=150   # 最长等 150s
STABLE_SEC=14       # 同一个 pid 连续存活 14s 才算成功
```

主循环每 2 秒采样一次 `pidof clash`：

- pid 出现 → 开始计时；**pid 变化 → 计时清零并记 WARN**
- 连续 14s 同一 pid → 成功，记录总耗时和可用内存
- 中途 `uci enable` 变成 0（用户又拨回去了）→ 立刻放弃，不跟用户抢
- 超时 → 进 `fail_diag()`

实测：核心通常在 4s 内出现，21s 左右判定成功。

## OFF 的流程

```
do_off
 ├─ 读物理位置；与 off 矛盾 → 丢弃
 ├─ uci set enable=0 && commit      # 先改意图，watcher 和启动循环会自己退出
 ├─ watch_stop                       # 先停守护，避免它把核心又拉起来
 └─ stop_clash
      ├─ 核心本来就不在 → led_off 后 return（早退也要关灯！）
      ├─ /etc/init.d/openclash stop，每 2s 检查，最长 90s
      └─ 仍有残留 → kill -9，再确认
```

早期版本在"核心本来就没跑"时直接 `return 0`，跳过了关灯 → 于是出现
"有时候灯灭了、有时候没灭"的玄学现象。

## 防抖与幂等

固件的 `flock` 只保证串行，不保证不重复：连续快拨会产生多个排队事件，
等第一个 `on` 跑完（20s），队伍里的旧事件才轮到执行。

处理方式：每个动作开头比对**事件方向**和**物理位置**。

```sh
OCSW_IGNORE_POS=1   # 调试时跳过这个检查
```

物理位置在 `on` 时读到的不是 `off` → 说明这事件已经过期，丢弃并记 WARN。
这样连续拨 5 下也只会执行最后那个方向。

## 并发控制

本机 BusyBox 的 `flock` 有两个坑，实测确认：

| 用法 | 结果 |
|---|---|
| `flock -w 25 9` | **不支持 `-w`**，直接失败 |
| `flock -n 9`（fd 形式，无人持有时） | **也返回 1**，不可用 |
| `flock /path/ cmd`（文件形式） | 可用（固件就是这么用的） |

所以脚本用 **原子目录锁**：

```sh
while ! mkdir /var/lock/openclash-switch.lock; do
    # 持有者 pid 已不存在 → 清理陈旧锁
    # 等满 25s 仍未拿到 → 丢弃本次动作并记日志
done
```

目录锁没有 fd 可被继承，顺带解决了上一节说的锁泄漏问题。

## watcher（后台守护）

生命周期：`on` 时拉起，`off` 时杀掉，`enable != 1` 时自己退出。

- 单实例：`mkdir /var/lock/openclash-switch.watch` 抢占，pidfile 写 `/var/run/openclash-switch.watch.pid`
- **必须用独立进程启动**：`( exec sh "$0" watch & )`。因为 ash 的子 shell 里 `$$`
  仍是父进程 pid，直接 `( watch_loop & )` 会让 pidfile 记错，之后杀不掉。
- 信号处理：`trap 'rm -rf "$_wl"; rm -f "$WATCH_PID"' EXIT` 加 `trap 'exit 143' INT TERM HUP`。
  **只写 `trap ... TERM` 不写 `exit`，ash 会卡在 `do_wait` 不退出**（实测过）。
- 心跳：每 15 轮（约 5 分钟）写一条 `watcher 心跳`，用来区分"还在等"和"已经挂了"。

## 日志

路径 `/tmp/openclash-switch.log`（`OCSW_LOG` 可改），超过 256KB 轮转到 `.1`。

格式：

```
2026-11-10 13:25:40 [INFO] ===== 动作 ON 开始（物理位置=on，uci enable=0，clash pid=）=====
2026-11-10 13:25:44 [INFO] 核心就绪：/etc/openclash/core/clash_meta（Mihomo Meta alpha-...）
2026-11-10 13:25:48 [INFO] 第 4s：发现 clash 进程 pid=3532，开始稳定性计时
2026-11-10 13:26:02 [INFO] ON 成功：clash pid=3532 已稳定 14s，总耗时 22s，可用内存 57MB
```

设计原则：**每个决策点都留痕**，尤其是"为什么没执行"——脚本里所有丢弃、跳过的分支
都会写一行 WARN，不会静默返回。

## 失败诊断

启动超时会自动收集：

- 内存总量/可用/swap
- **本次启动之后**新增的 `dmesg` 里的 `Killed process.*clash`（用启动前 `dmesg | wc -l` 做基线，
  否则几个月前那次 OOM 会被当成本次根因）
- `/tmp/openclash_start.log` 尾部 8 行（OpenClash 自己的启动输出）
- `/tmp/openclash.log` 里的 `level=fatal` / `Parse config error` / `unsupported`

## 环境变量

| 变量 | 默认 | 用途 |
|---|---|---|
| `OCSW_LOG` | `/tmp/openclash-switch.log` | 日志路径 |
| `OCSW_PROBE_URLS` | 三个 `generate_204` | 覆盖探测地址，用于模拟离线/认证页 |
| `OCSW_WATCH_INTERVAL` | `20` | watcher 轮询间隔（秒） |
| `OCSW_IGNORE_POS` | `0` | 置 1 跳过物理位置检查（调试用） |

模拟测试举例：

```sh
# 假装完全没网
OCSW_PROBE_URLS='http://127.0.0.1:9/generate_204' sh /etc/gl-switch.d/openclash.sh on

# 假装卡在认证页（本机 nginx 会返回 HTML 200）
OCSW_PROBE_URLS='http://127.0.0.1/' sh /etc/gl-switch.d/openclash.sh on
```
