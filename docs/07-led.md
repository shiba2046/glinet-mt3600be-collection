# 07 · 指示灯

拨到 OFF 之后灯还亮着，是这套脚本里最容易让人误判"没生效"的地方。原因有三层。

## 这颗机器上有两盏灯

```sh
ls /sys/class/leds/
# blue:run       蓝色（状态指示，可闪烁）
# white:system   白色（系统在线指示）
# led            WiFi 相关
```

固件按网络状态控制前两个（`/lib/functions/gl_util.sh`）：

```sh
# online_led_display  网络正常
echo 0 > /sys/class/leds/blue:run/brightness
echo 1 > /sys/class/leds/white:system/brightness

# offline_led_display 网络断开
echo 0 > /sys/class/leds/white:system/brightness
echo timer > /sys/class/leds/blue:run/trigger
```

也就是说：**白灯亮 = 系统在线，跟 OpenClash 没有任何关系。**
早期实现只写了 `blue:run`，白灯自然一直亮着。

## 直接写 sysfs 没用

`/usr/bin/gl_led` 是个守护进程，循环里每 2 秒刷新一次：

```sh
while true; do
    ... 按网络状态设置 LED ...
    sleep 2
done
```

实测：手动 `echo 0 > white:system/brightness`，25 秒内就被改回 1。
所以**必须停掉守护**，而不是跟它抢写。

## 正确入口：/etc/gl-switch.d/led.sh

固件自带这个模块，整个文件就几行：

```sh
#!/bin/sh
action=$1

[ "$action" = "on" ]  && /etc/init.d/gl_led turnon
[ "$action" = "off" ] && /etc/init.d/gl_led turnoff

sleep 5
```

`gl_led turnoff` 做三件事：停守护 → `white:system=0` + `blue:run=0` → 保持熄灭。
`gl_led turnon` 反向恢复，守护重新接管。

脚本里的封装：

```sh
led_on()  { ( sh "$LED_CTL" on  >/dev/null 2>&1 & ) }
led_off() { ( sh "$LED_CTL" off >/dev/null 2>&1 & ) }
```

**放后台执行**是因为 `led.sh` 末尾有个 `sleep 5`，同步调用会让每次开关动作平白多 5 秒。
如果 `led.sh` 不存在（换固件），退化为直接写 sysfs（不持久，但至少有反应）。

## 三个必须记住的副作用

1. **OFF 期间整机 LED 全灭**，包括原本表示"联网状态"的白灯。这是 `led.sh` 的语义
   （它的用途是"关掉所有灯"），不是 bug。
2. **`gl_led turnoff` 会持久化** `uci gl_led.global.led_enable=0`。所以带着 OFF 状态重启，
   开机后灯是黑的，要等核心起来才亮 —— 为此 `do_sync` 在 ON 分支里**先 `led_on` 再启动核心**，
   避免开机几十秒看起来像没通电。
3. **拨杆改绑到别的功能后**，灯会一直是黑的（`led_enable=0` 还留着）。恢复：

```sh
/etc/init.d/gl_led turnon
```

## 如果你不想 OFF 就全灭

`gl_led turnoff` 是"关掉全部灯"，没有"只关蓝灯"的接口。想保留白灯（系统在线指示）
就要放弃用 `led.sh`，改成自己控制 `blue:run` 并接受守护会抢回控制权 —— 不推荐。

折中方案：不改 LED，只在日志里体现状态（`status` 已经打印
`white= blue= led_enable= gl_led守护=`）。拨杆本身的位置就是最直观的指示。

## 验证

```sh
# 当前状态
sh /etc/gl-switch.d/openclash.sh status | grep 指示灯

# 期望（OFF）：white=0 blue=0 led_enable=0 gl_led守护=0
# 期望（ON） ：white=1 blue=0 led_enable=1 gl_led守护=1
```

`gl_led守护` 是 `ps w | grep -c '[/]usr/bin/gl_led'` 的结果，0 表示守护已停 ——
这是判断"灯会不会被改回去"最直接的指标。
