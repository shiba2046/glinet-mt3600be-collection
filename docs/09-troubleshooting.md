# 09 · 排错手册

先用这一段把现场捞全，90% 的问题看这个就够：

```sh
echo "--- 物理位置 / 绑定 ---"
. /lib/functions/gl_util.sh; get_switch_button_status
uci show switch-button
ls -l /etc/gl-switch.d/openclash.sh

echo "--- 状态 ---"
sh /etc/gl-switch.d/openclash.sh status

echo "--- 最近日志 ---"
tail -20 /tmp/openclash-switch.log

echo "--- 锁占用（应为空）---"
for d in /proc/[0-9]*; do pid=${d#/proc/}
  ls -l $d/fd 2>/dev/null | grep -q 'gl-switch.lock' && echo "$pid $(cat $d/comm)"
done

echo "--- OOM 记录 ---"
dmesg | grep 'Killed process' | tail -3
```

---

## A. 拨杆没反应

### A1. 拨了完全没动静，日志一行都不加

按链路逐段确认：

```sh
# ① 固件有没有收到按钮事件
logread -e gl-switch | tail -3        # 期望：gl-switch: switch pressed

# ② 绑定对不对
uci get switch-button.@main[0].func   # 期望：openclash

# ③ 脚本可执行吗（固件调用前检查 -x）
ls -l /etc/gl-switch.d/openclash.sh   # 期望：-rwxr-xr-x
```

- ① 有、②③ 对，但日志还是空的 → 手工跑一次看报错：`sh -x /etc/gl-switch.d/openclash.sh status`
- ③ 没有 `x` → `chmod 755 /etc/gl-switch.d/openclash.sh`
- ② 不是 `openclash` → 有人（或 GL 网页）改回去了：
  `uci set switch-button.@main[0].func='openclash'; uci commit switch-button`
- ① 也没有 → 看 `get_switch_button_status` 是否返回 `no support`（GPIO 没映射，硬件/固件问题）

### A2. 日志里写"与 ON 事件矛盾…忽略本次"

这是**排队事件被丢弃**，不是故障。

```sh
2026-11-10 13:40:02 [WARN] 物理开关此刻在 off，与 ON 事件矛盾（很可能是连续拨动留下的排队事件），忽略本次
```

固件的 `flock` 只保证串行，连续快拨会积压事件，等第一个动作跑完才轮到旧事件。
脚本按物理位置丢弃过期事件，避免"拨回来又被旧事件拨走"。

不需要处理。真要强制测试：`OCSW_IGNORE_POS=1 sh /etc/gl-switch.d/openclash.sh on`。

### A3. 第一次能用，之后怎么拨都永远不执行

经典锁泄漏。检查谁占着固件的锁：

```sh
for d in /proc/[0-9]*; do pid=${d#/proc/}
  ls -l $d/fd 2>/dev/null | grep -q 'gl-switch.lock' && echo "$pid $(tr '\0' ' ' < $d/cmdline)"
done
```

输出应该为空。如果有 clash 或 watcher 在里面 → 说明跑的是旧版脚本（没关继承 fd）。
升级到当前版本并重启一次即可。

### A4. `ps` 里有卡住的 `openclash.sh` 进程

```sh
ps w | grep gl-switch.d | grep -v grep
cat /proc/<pid>/stat | awk '{print $3, $4}'   # state=S, ppid=1
```

状态 `S` 且没有子进程的，是 ash 收到了 TERM 但 trap 里没 `exit`，卡在 `do_wait`。
当前版本已经改成 `trap 'exit 143' INT TERM HUP`。清理：

```sh
pkill -9 -f 'gl-switch.d/openclash.sh'
rm -rf /var/lock/openclash-switch.*
```

---

## B. 核心起不来

### B1. `Parse config error: unsupported type: smart`

```sh
grep -i 'unsupported type' /tmp/openclash.log | tail -2
grep -c 'type: smart' /etc/openclash/聚合.yaml
```

原因：配置里被改写成 `type: smart`，而当前核心是标准 Meta（不认识 smart）。
根因通常是之前 OOM 导致核心被降级。修：

```sh
uci set openclash.config.smart_enable='0'
uci set openclash.config.smart_enable_lgbm='0'
uci set openclash.config.auto_smart_switch='0'
uci commit openclash
sh /etc/gl-switch.d/openclash.sh off
sh /etc/gl-switch.d/openclash.sh on
```

详见 [05-memory-and-core.md](05-memory-and-core.md)。

### B2. `Core Start Failed` + dmesg 有 OOM

```sh
dmesg | grep 'Killed process.*clash' | tail -3
sh /etc/gl-switch.d/openclash.sh status | grep 可用内存
```

内存不够。按 [05](05-memory-and-core.md) 的取舍表处理：停 DPI、nginx worker 1、
不要 Smart 核心、必要时精简规则。

脚本的 `fail_diag()` 会把这些自动写进日志（只统计**本次启动之后**新增的 dmesg 行）：

```
[ERROR] 根因：内存不足，clash 被内核 OOM Killer 杀死
[ERROR]   dmesg: Out of memory: Killed process 3532 (clash) ...
```

### B3. 核心在跑，但代理不通

```sh
pidof clash
netstat -lntp | grep -E ':7890|:7893|:9090'
curl -s -m 10 -x http://127.0.0.1:7890 -o /dev/null -w '%{http_code}\n' \
     https://www.gstatic.com/generate_204
```

- 端口没监听 → 核心在但没进入正常状态，看 `/tmp/openclash.log`
- 端口在但 204 拿不到 → 节点不可用 / 上游没网；`status` 里的「外网探测」和「上游」能区分

### B4. 每次开机都要等很久（下载核心）

```sh
uci get openclash.config.small_flash_memory    # 1 = 放在 /tmp，重启必重下
ls -d /tmp/etc/openclash 2>/dev/null           # 存在说明还在走临时目录
```

```sh
uci set openclash.config.small_flash_memory='0'
uci commit openclash
```

### B5. 启动"成功"了但几秒后进程没了

这是早期版本误判的老问题：核心会闪断重启一次，pid 变化。当前版本按"连续 14s 同 pid"
判定。如果你看到这种日志，说明跑的是旧脚本：

```
[INFO] 第 4s：发现 clash 进程 pid=1234
[INFO] ON 成功：clash pid=1234 ...
```

紧接着进程消失 → 升级脚本。

---

## C. 网络 / 酒店场景

### C1. 连上酒店 WiFi，但认证页打不开

先看核心是不是在跑：

```sh
sh /etc/gl-switch.d/openclash.sh status | grep -E '外网探测|clash 进程|后台守护'
```

如果 `外网探测 = 需要网页认证` 而核心仍在跑 → 门控没生效（旧版或 watcher 没起）。
手动停一下就能打开认证页：

```sh
sh /etc/gl-switch.d/openclash.sh off     # 认证完再 on，或让 watcher 自动恢复
```

### C2. 状态一直显示"需要网页认证"，但我已经认证过了

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://connect.rom.miui.com/generate_204
```

- 返回 `204` → 探测是通的，可能是 watcher 刚好在睡眠（默认 20s），等一下
- 返回 `200`/`302` → 认证没真正完成，或酒店网关还认旧会话，重新认证一次

停掉代理后认证、再开，是最稳的顺序。

### C3. `上游` 显示 repeater 未连接

```sh
ubus call repeater status | jsonfilter -e '@.state_s'
```

这是 GL 中继模块的状态，与我们的脚本无关。中继没连上，门控会把状态判为"离线"，
这是正确行为。

---

## D. 指示灯

### D1. OFF 后灯还亮

```sh
sh /etc/gl-switch.d/openclash.sh status | grep 指示灯
# 期望：white=0 blue=0 led_enable=0 gl_led守护=0
```

- `white=1` → 跑的旧版（只关蓝灯），升级
- `white=0` 但 `gl_led守护=1` → 灯会被改回去，说明 `gl_led turnoff` 没生效
- 手动验证：`sh /etc/gl-switch.d/led.sh off`，等 25 秒再看

### D2. 开机后灯是黑的，几十秒才亮

`led_enable=0` 是持久化的（上次 OFF 时写进去的）。当前版本 `sync` 会先 `led_on` 再启动核心，
所以黑灯时间取决于 `rc.local` 里 25 秒的延迟。想更快就把 `sleep 25` 改小。

### D3. 改绑到别的功能后灯一直是黑的

```sh
/etc/init.d/gl_led turnon
```

---

## E. 自动更新

### E1. cron 里没有任务 / 任务不执行

```sh
crontab -l | grep openclash-auto-update
/etc/init.d/cron enabled && echo cron-enabled
ps w | grep '[c]rond'
```

注意这台机器上有两个 crond：GL 自己的读 `/tmp/gl_crontabs`（每次开机重建，**不能手写**），
系统 cron 读 `/etc/crontabs/root`（持久）。我们的任务写后者。

重装：`sh /etc/openclash-auto-update.sh install-cron`

### E2. 手动跑正常，cron 跑没反应

```sh
cat /etc/openclash/.auto-update.state      # 看上次结果
tail -20 /tmp/openclash-auto-update.log
```

常见原因：cron 触发时还没网（状态会是 `skipped-offline`），或可用内存 < 45MB
（`skipped-lowmem`）。这两种都是设计行为，不是故障。

### E3. 订阅更新失败但日志里看不出原因

`/usr/share/openclash/openclash.sh` 是 bash 脚本，用 `sh` 调用会 rc=2 静默失败。
当前版本直接执行（走 shebang），如果你手动测试，也要：

```sh
/usr/share/openclash/openclash.sh '' norestart
```

### E4. 网页里设的自动更新，过几天任务没了

`del_cron()` 里有 `sed -i '/#openclash-cron-task/d'`，OpenClash 一停任务就整行删除。
这是官方行为，所以本仓库改用不带该标记的自建 cron 行。
