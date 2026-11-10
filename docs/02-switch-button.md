# 02 · 拨杆的固件调度机制

这一节解释**为什么只需要写一个文件**，以及为什么不该去改 `/etc/rc.button/switch`。

## 结论先行

```
物理拨杆
  → /etc/rc.button/switch                （固件调度器：不要改，改了下次升级/恢复就丢）
  → 读 uci switch-button.@main[0].func
  → flock /var/lock/gl-switch.lock "/etc/gl-switch.d/<func>.sh" on|off &
```

要自定义某个功能的拨杆行为，**只写 `/etc/gl-switch.d/<func>.sh`，再把 `func` 指过去**。
固件自带的功能（`wifi.sh`、`led.sh`、`repeater.sh`、`wireguard.sh`…）都在这套约定下。

本仓库的做法：

```sh
uci set switch-button.@main[0].func='openclash'
uci -q delete switch-button.@main[0].sub_func
uci commit switch-button
```

注意固件调脚本前会检查 `[ -x /etc/gl-switch.d/$func.sh ]`（可执行位），
所以脚本权限必须是 755，光有内容不行。

## 原厂调度器（节选，未做任何修改）

```sh
#!/bin/sh
. /lib/functions/gl_util.sh

logger -t "gl-switch" "$BUTTON ${ACTION}"

action=off
[ "$ACTION" = "pressed" ] && action=on          # 按下去 = on，松开 = off

[ -e /proc/gl-hw-info/screen -a -z "$SERVICE" ] && {
    /usr/bin/screen_disp_switch $action         # 带屏机型：更新屏幕显示
}

func=$(uci -q get switch-button.@main[0].func) || {
    logger -t "gl-switch" "no config"
    exit 0
}
sub_func=$(uci -q get switch-button.@main[0].sub_func)
work_mode=$(uci -q get glconfig.general.mode)

...
[ -x /etc/gl-switch.d/$func.sh ] || {
    logger -t "gl-switch" "/etc/gl-switch.d/$func.sh can't be exec"
    exit 0
}

# portal / tor / 非 router 模式下标记 conflict（只对 wireguard/openvpn/tor/adguard/vpn 生效）
[ $(ubus call repeater status | jsonfilter -e "@.portal") = true ] && conflict=1
...

flock /var/lock/gl-switch.lock "/etc/gl-switch.d/$func.sh" $action &
```

三个要记住的点：

1. **`ACTION=pressed|released`，`BUTTON=switch`**，脚本收到的第一个参数是 `on` / `off`。
2. `flock /var/lock/gl-switch.lock <命令> &` 是**文件形式**的锁：锁挂在打开的文件描述符上，
   并且会随 `fork` 传给子进程 —— 这是很多"拨了没反应"的根源，见下节。
3. `conflict` 只对 VPN 类功能生效。也就是说**即使路由器正卡在 captive portal，
   openclash 分支依然会被调用**，所以门控必须由我们自己的脚本做
   （见 [04-network-gating.md](04-network-gating.md)）。

## 锁继承：为什么"拨一次之后永远没反应"

调度器把整条命令交给 `flock`，命令退出锁才释放。我们的脚本会启动两个常驻/后台的东西：

- `/etc/init.d/openclash start`（它自己会 fork 出 clash 核心）
- watcher 后台轮询进程

如果在 `fork` 之前没有关闭 fd 3~20，这两个进程就会**继承锁的文件描述符**并一直持有。
锁不释放 → 下一次拨动排队的 `flock` 永远等不到 → 表现就是"开关失灵"，
而且 `ps` 里看起来一切正常。

所以脚本开头必须有：

```sh
for _fd in 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    eval "exec $_fd<&-" 2>/dev/null
done
```

锁仍由固件的 `flock` 父进程持有到本脚本退出，串行化效果不受影响。

自查有没有人被锁挂住：

```sh
for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    ls -l $d/fd 2>/dev/null | grep -q 'gl-switch.lock' && echo "$pid $(cat $d/comm)"
done
# 输出为空 = 没人占锁
```

## 开机链路

```
S99gl_switch_button_check (START=99)
  status=$(get_switch_button_status)     # 读 GPIO：on / off / no support
  on  -> ACTION=pressed   SERVICE=true
  off -> ACTION=released  SERVICE=true
  BUTTON=switch ACTION=$action SERVICE=true /etc/rc.button/switch &
```

于是开机时**拨杆位置会自动被同步一次**，不需要额外开机脚本 —— 我们的模块收到 `on`
会先探测外网：网络还没起来就转后台等待，起来了直接拉核心。

`SERVICE=true` 的另一个作用：调度器里 `[ -e /proc/gl-hw-info/screen -a -z "$SERVICE" ]`
会跳过屏幕刷新，避免开机就抢显示。

`/etc/rc.local` 里的钩子（`install.sh` 会加，`--no-rc-hook` 可跳过）只是**兜底**：
延迟 25 秒再 `sync` 一次，覆盖"网络比 init 起得还晚"和"上次关机时状态不一致"的情况。

## 常见误解

| 误解 | 事实 |
|---|---|
| 要改 `/etc/rc.button/switch` | 它是固件调度器，改了三件事都会丢：升级、恢复出厂、`/rom` 校验不一致。**不要改**。 |
| 按键映射成 `BTN_0` 事件 | 这机型 `BUTTON=switch` 走 `rc.button/switch`，没有 `/etc/hotplug.d/button/`。自建 `BTN_0` 是错的（v0.1 犯过）。 |
| 钩子放 `/etc/hotplug.d/button/` | 该目录不存在。按钮事件由 procd 直接 exec `/etc/rc.button/*`。 |
| 要在 GL 网页里选 openclash 才行 | 网页下拉框只是写同一个 uci 值，CLI 效果完全一样。 |
| 加了 `sub_func` 才生效 | 对 openclash 没有 `sub_func` 概念，留着反而可能干扰，`install.sh` 会删掉。 |

## 验证链路是否通

```sh
# 1) 绑定是否正确
uci show switch-button

# 2) 脚本是否可执行
ls -l /etc/gl-switch.d/openclash.sh     # 需要 -rwxr-xr-x

# 3) 固件有没有真的调用（拨一下再看）
logread -e gl-switch | tail -5
# 期望形如：gl-switch: switch pressed

# 4) 我们的模块有没有收到（看日志第一行）
tail -3 /tmp/openclash-switch.log
```

第 3 步有日志、第 4 步没有 → 问题在绑定或可执行位；两步都没有 → 拨杆硬件/GPIO 映射问题，
先看 `get_switch_button_status` 是否返回 `no support`。
