#!/bin/sh
# ============================================================================
#  /etc/gl-switch.d/openclash.sh
#
#  物理拨动开关 -> OpenClash 模块（GL.iNet GL-MT3600BE / 固件 v4.x）
#
#  Repo   : https://github.com/shiba2046/glinet-mt3600be-collection
#  Version: 0.3.0
#
#  调用链（全部由固件负责，本文件只是被调用的一方）：
#     物理拨杆
#       -> /etc/rc.button/switch        （固件调度器，读 switch-button.@main[0].func）
#       -> /etc/gl-switch.d/openclash.sh on|off
#
#  绑定方式（CLI，不需要改任何固件文件）：
#     uci set switch-button.@main[0].func='openclash'
#     uci -q delete switch-button.@main[0].sub_func
#     uci commit switch-button
#
#  本脚本额外负责「网络门控」，针对酒店/公共 WiFi 场景：
#     - 拨到 ON 时若外网不可用（或卡在 captive portal 认证页），不启动核心，
#       只登记意图并转入后台等待；网络一通立刻拉起，避免核心空转被 OOM 杀掉。
#     - 核心运行中若掉网或认证失效，自动停核心（暂停代理），恢复后自动重启。
#
#  日志：/tmp/openclash-switch.log（超过 256KB 自动轮转，可用 OCSW_LOG 改路径）
#  手动操作：
#     sh /etc/gl-switch.d/openclash.sh status     # 看全部状态
#     sh /etc/gl-switch.d/openclash.sh sync       # 按物理位置校正一次
#     sh /etc/gl-switch.d/openclash.sh watch      # 只起后台守护
# ============================================================================

VERSION="0.3.0"
MAIN_LOG="${OCSW_LOG:-/tmp/openclash-switch.log}"
OC_START_LOG="/tmp/openclash_start.log"
OC_LOG="/tmp/openclash.log"
WATCH_PID="/var/run/openclash-switch.watch.pid"
LOCK_DIR="/var/lock/openclash-switch.lock"

# ---------------------------------------------------------------------------
# 关键：不要把调用方的锁句柄遗传给子进程。
# 固件的调度方式是 `flock /var/lock/gl-switch.lock <本脚本> $action &`，
# 锁挂在打开的文件描述符上，并且会随 fork 传给子进程。一旦后台守护继承了它，
# 后续每次拨动都会永远排队在 flock 上不执行 —— 表现就是"开关失灵"。
# 这里关掉 3~20 号 fd；锁仍由固件的 flock 父进程持有到本脚本退出，串行化不受影响。
# ---------------------------------------------------------------------------
for _fd in 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    eval "exec $_fd<&-" 2>/dev/null
done
unset _fd

START_TIMEOUT=150          # 等待 clash 进程出现的上限（秒）
STABLE_SEC=14              # 核心连续存活多久算启动成功（秒）
STOP_TIMEOUT=90            # 等待 clash 进程消失的上限（秒）
WATCH_INTERVAL="${OCSW_WATCH_INTERVAL:-20}"   # 后台守护轮询间隔（秒）
LOG_MAX=262144             # 日志轮转阈值 256KB

# 外网探测地址：正常必须返回 204。返回其它 HTTP 码通常说明被强制门户劫持。
# 调试时可用 OCSW_PROBE_URLS 覆盖，例如模拟离线：OCSW_PROBE_URLS=http://127.0.0.1:9/x
PROBE_URLS="${OCSW_PROBE_URLS:-http://connect.rom.miui.com/generate_204 http://www.gstatic.com/generate_204 http://cp.cloudflare.com/generate_204}"

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------
log() {
    _lvl="$1"; shift
    _ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '%s [%s] %s\n' "$_ts" "$_lvl" "$*" >> "$MAIN_LOG"
}

log_rotate() {
    [ -f "$MAIN_LOG" ] || return 0
    _sz=$(wc -c < "$MAIN_LOG" 2>/dev/null || echo 0)
    [ "$_sz" -gt "$LOG_MAX" ] 2>/dev/null || return 0
    mv -f "$MAIN_LOG" "$MAIN_LOG.1" 2>/dev/null
    log INFO "日志超过 ${LOG_MAX}B，已轮转到 $MAIN_LOG.1"
}

# ---------------------------------------------------------------------------
# 状态读取
# ---------------------------------------------------------------------------
mem_avail() {
    awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null
}

mem_total() {
    awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null
}

clash_pid() {
    _p=$(pidof clash 2>/dev/null)
    [ -n "$_p" ] && echo "${_p%% *}"
}

# 物理拨杆位置：on / off / no support / 空
phys_state() {
    sh -c '. /lib/functions/gl_util.sh 2>/dev/null; get_switch_button_status 2>/dev/null' 2>/dev/null \
        | tr -d '\r\n'
}

# 上游链路是否通（只看链路，不看外网）：有默认路由且网关能 ping 通
link_ok() {
    _gw=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')
    [ -n "$_gw" ] || return 1
    ping -c 1 -W 2 "$_gw" >/dev/null 2>&1
}

# 中继/桥接状态（非中继模式下该命令可能不存在，仅用于日志）
upstream_info() {
    _s=$(timeout 5 ubus call repeater status 2>/dev/null)
    _u=$(echo "$_s" | jsonfilter -e '@.state_s' 2>/dev/null)
    _p=$(echo "$_s" | jsonfilter -e '@.portal' 2>/dev/null)
    [ -n "$_u" ] && echo "repeater=${_u} portal=${_p:-?}"
}

# 外网探测：0=在线 1=需要网页认证 2=离线
# 结果说明写入 PROBE_DETAIL
probe() {
    PROBE_DETAIL=""
    _seen=""
    _loc=""
    for _u in $PROBE_URLS; do
        _r=$(curl -s -m 5 -o /dev/null -w '%{http_code} %{redirect_url}' "$_u" 2>/dev/null)
        _c=${_r%% *}
        _s=${_r#* }
        case "$_c" in
            204)
                PROBE_DETAIL="$_u -> 204"
                return 0
                ;;
            000|"")
                continue
                ;;
            *)
                # 有 HTTP 应答但不是 204：几乎可以确定是被认证页劫持
                _seen="$_c"
                [ -n "$_s" ] && _loc="$_s"
                ;;
        esac
    done
    if [ -n "$_seen" ]; then
        PROBE_DETAIL="HTTP=$_seen ${_loc:+redirect=$_loc}"
        return 1
    fi
    PROBE_DETAIL="无 HTTP 响应"
    return 2
}

# ---------------------------------------------------------------------------
# 依赖文件自检（避免"每次开机重新下载"时看不出为什么）
# ---------------------------------------------------------------------------
verify_assets() {
    _core=$(uci -q get openclash.config.core_type)
    _sfm=$(uci -q get openclash.config.small_flash_memory)
    _cp=/etc/openclash/core/clash_meta

    log INFO "资源自检：core_type=${_core} small_flash_memory=${_sfm} 可用内存=$(mem_avail)MB"

    if [ "$_sfm" = "1" ]; then
        log WARN "small_flash_memory=1：核心与 geo 数据放在 /tmp，重启后必然重新下载（这是启动慢的根因）"
        log WARN "如需持久化：uci set openclash.config.small_flash_memory='0'; uci commit openclash"
    fi

    if [ -x "$_cp" ]; then
        _v=$(timeout 10 "$_cp" -v 2>/dev/null | head -1)
        log INFO "核心就绪：$_cp（${_v:-版本未知}）"
    else
        log WARN "核心缺失（$_cp），OpenClash 将尝试联网下载，可能很慢甚至失败"
    fi

    for _f in /etc/openclash/GeoSite.dat /etc/openclash/china_ip_route.ipset; do
        if [ -f "$_f" ]; then
            log INFO "数据就绪：$_f（$(du -k "$_f" 2>/dev/null | awk '{print $1}')KB）"
        else
            log WARN "数据缺失：$_f，OpenClash 将尝试联网下载"
        fi
    done

    if [ -L /etc/openclash/clash ]; then
        log INFO "/etc/openclash/clash -> $(readlink /etc/openclash/clash)"
    fi
}

# ---------------------------------------------------------------------------
# 指示灯
#   统一交给固件自带的 /etc/gl-switch.d/led.sh（内部就是 gl_led turnon/turnoff）。
#   不能直接写 /sys/class/leds/white:system/brightness：gl_led 守护每 2 秒按网络状态
#   刷新一次（在线=白灯亮、蓝灯灭；离线=白灯灭、蓝灯闪），写完 25 秒内必被改回。
#   gl_led turnoff 会先停掉守护，再把 white:system 和 blue:run 一起归零，
#   所以 OFF 之后灯能真正保持熄灭。
#   注意 led.sh 末尾有 sleep 5，同步调用会拖慢开关动作，这里放后台执行。
# ---------------------------------------------------------------------------
LED_CTL="/etc/gl-switch.d/led.sh"
LED_PATH="/sys/class/leds/blue:run/brightness"
LED_WHITE="/sys/class/leds/white:system/brightness"

led_write() {
    [ -w "$LED_PATH" ] && echo "$1" > "$LED_PATH" 2>/dev/null
    [ -w "$LED_WHITE" ] && echo "$1" > "$LED_WHITE" 2>/dev/null
}

led_on() {
    log INFO "指示灯：led.sh on（gl_led turnon，交回固件：白灯=系统在线，蓝灯=断网闪烁）"
    if [ -f "$LED_CTL" ]; then
        ( sh "$LED_CTL" on >/dev/null 2>&1 & )
    else
        log WARN "找不到 $LED_CTL，退化为直接写 sysfs"
        led_write 255
    fi
}

led_off() {
    log INFO "指示灯：led.sh off（gl_led turnoff，白灯与蓝灯全灭）"
    if [ -f "$LED_CTL" ]; then
        ( sh "$LED_CTL" off >/dev/null 2>&1 & )
    else
        log WARN "找不到 $LED_CTL，退化为直接写 sysfs"
        led_write 0
    fi
}

# ---------------------------------------------------------------------------
# 失败诊断
# ---------------------------------------------------------------------------
fail_diag() {
    log ERROR "启动失败，开始收集诊断信息"
    log ERROR "内存：Total=$(mem_total)MB Available=$(mem_avail)MB Swap=$(awk '/^SwapTotal:/{print int($2/1024)}' /proc/meminfo)MB"
    # 只认本次启动之后新增的 dmesg 行，否则几个月前那次 OOM 会被当成本次根因
    _new=$(dmesg 2>/dev/null | tail -n +"$(( ${DMESG_BASE:-0} + 1 ))" | grep 'Killed process.*clash')
    if [ -n "$_new" ]; then
        log ERROR "根因：内存不足，clash 被内核 OOM Killer 杀死"
        echo "$_new" | tail -n 2 | while read -r _l; do
            log ERROR "  dmesg: $_l"
        done
    fi
    if [ -s "$OC_START_LOG" ]; then
        log ERROR "OpenClash 启动日志尾部（$OC_START_LOG）："
        tail -n 8 "$OC_START_LOG" 2>/dev/null | while read -r _l; do
            log ERROR "  $_l"
        done
    fi
    if [ -s "$OC_LOG" ]; then
        _e=$(tail -n 30 "$OC_LOG" 2>/dev/null | grep -i -E 'level=fatal|parse config error|unsupported' | tail -n 3)
        if [ -n "$_e" ]; then
            log ERROR "OpenClash 运行日志中的致命错误："
            echo "$_e" | while read -r _l; do
                log ERROR "  $_l"
            done
        fi
    fi
}

# ---------------------------------------------------------------------------
# 启动 / 停止
# ---------------------------------------------------------------------------
start_clash() {
    _t0=$(date +%s)
    _pid=$(clash_pid)
    if [ -n "$_pid" ]; then
        log INFO "clash 已在运行 pid=$_pid，仍执行一次 start 以刷新配置（OpenClash 自身幂等）"
    fi

    # 记录 dmesg 基线，失败时只匹配本次新增的 OOM 记录
    DMESG_BASE=$(dmesg 2>/dev/null | wc -l)

    verify_assets
    uci set openclash.config.enable='1' 2>/dev/null
    uci commit openclash 2>/dev/null

    : > "$OC_START_LOG" 2>/dev/null
    log INFO "调用 /etc/init.d/openclash start（后台执行，最长等待 ${START_TIMEOUT}s）"
    /etc/init.d/openclash start > "$OC_START_LOG" 2>&1 &
    _spid=$!

    _wait=0
    _stable=0
    _seen_pid=""
    while [ "$_wait" -lt "$START_TIMEOUT" ]; do
        sleep 2
        _wait=$((_wait + 2))

        # 中途被拨回 OFF：立即放弃，不要和用户抢
        if [ "$(uci -q get openclash.config.enable)" != "1" ]; then
            log WARN "第 ${_wait}s：检测到开关意图已变为 OFF，放弃本次启动"
            return 1
        fi

        _p=$(clash_pid)
        if [ -n "$_p" ]; then
            if [ "$_p" = "$_seen_pid" ]; then
                _stable=$((_stable + 2))
            else
                if [ -n "$_seen_pid" ]; then
                    log WARN "第 ${_wait}s：核心 pid 变化 $_seen_pid -> $_p（OpenClash 内部重启），稳定性重新计时"
                else
                    log INFO "第 ${_wait}s：发现 clash 进程 pid=$_p，开始稳定性计时"
                fi
                _seen_pid="$_p"
                _stable=0
            fi
            if [ "$_stable" -ge "$STABLE_SEC" ]; then
                _av=$(mem_avail)
                _el=$(( $(date +%s) - _t0 ))
                log INFO "ON 成功：clash pid=$_p 已稳定 ${_stable}s，总耗时 ${_el}s，可用内存 ${_av}MB"
                if [ -n "$_av" ] && [ "$_av" -lt 30 ]; then
                    log WARN "可用内存仅 ${_av}MB，偏低（可停用 netifyd/DPI 或精简规则）"
                fi
                led_on
                return 0
            fi
        else
            if [ -n "$_seen_pid" ]; then
                log WARN "第 ${_wait}s：clash pid=$_seen_pid 已退出，继续等待（可能正在重载配置）"
                _seen_pid=""
                _stable=0
            elif [ "$_wait" = "2" ] && ! kill -0 "$_spid" 2>/dev/null; then
                # init 命令已返回但核心还没出现，属正常现象，继续等
                log INFO "init start 已返回，继续等待核心进程出现"
            fi
        fi
    done

    log ERROR "等待 ${START_TIMEOUT}s 仍未得到稳定运行的核心"
    fail_diag
    return 1
}

stop_clash() {
    _t0=$(date +%s)
    _pid=$(clash_pid)
    if [ -z "$_pid" ]; then
        log INFO "clash 未在运行，无需停止；仍同步一次指示灯"
        led_off
        return 0
    fi
    log INFO "停止 OpenClash（当前 pid=$_pid）"
    /etc/init.d/openclash stop >/dev/null 2>&1

    _wait=0
    while [ "$_wait" -lt "$STOP_TIMEOUT" ]; do
        sleep 2
        _wait=$((_wait + 2))
        if [ -z "$(clash_pid)" ]; then
            log INFO "OFF 成功：clash 进程已消失，耗时 $(( $(date +%s) - _t0 ))s"
            led_off
            return 0
        fi
    done
    _left=$(clash_pid)
    if [ -n "$_left" ]; then
        log WARN "等待 ${STOP_TIMEOUT}s 后仍有残留进程 pid=$_left，强制结束"
        kill -9 "$_left" 2>/dev/null
        sleep 2
        if [ -z "$(clash_pid)" ]; then
            log INFO "OFF 成功：强制结束后进程已消失"
            led_off
            return 0
        fi
        log ERROR "OFF 失败：进程 pid=$_left 仍然存在"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 后台守护：网络门控
#   在线   -> 确保核心在跑
#   认证页 -> 停核心，等用户完成认证（否则认证页本身也会被代理打不开）
#   离线   -> 停核心，等网络恢复
# ---------------------------------------------------------------------------
watch_loop() {
    _wl="/var/lock/openclash-switch.watch"
    if ! mkdir "$_wl" 2>/dev/null; then
        _o=$(cat "$_wl/pid" 2>/dev/null)
        if [ -n "$_o" ] && kill -0 "$_o" 2>/dev/null; then
            log INFO "watcher：已有实例 pid=$_o 在运行，本次不重复启动"
            return 0
        fi
        rm -rf "$_wl"
        mkdir "$_wl" 2>/dev/null || return 0
    fi
    echo $$ > "$_wl/pid"
    echo $$ > "$WATCH_PID"
    # 注意：TERM/INT 必须显式 exit，否则 ash 只跑 trap 动作后继续执行会卡住
    trap 'rm -rf "$_wl"; rm -f "$WATCH_PID"' EXIT
    trap 'exit 143' INT TERM HUP
    log INFO "watcher 启动 pid=$$，${WATCH_INTERVAL}s 轮询一次"

    _last=""
    _fail=0
    _beat=0

    while :; do
        if [ "$(uci -q get openclash.config.enable)" != "1" ]; then
            log INFO "watcher：开关意图已为 OFF，守护退出"
            break
        fi

        probe
        _st=$?
        case "$_st" in
            0)
                _fail=0
                if [ -z "$(clash_pid)" ]; then
                    _last=""
                    log INFO "watcher：外网可用（$PROBE_DETAIL），启动 OpenClash"
                    start_clash
                else
                    if [ "$_last" != "online" ]; then
                        log INFO "watcher：外网可用（$PROBE_DETAIL），clash 运行中 pid=$(clash_pid) $(upstream_info)"
                    fi
                fi
                _last="online"
                ;;
            1)
                _fail=0
                if [ -n "$(clash_pid)" ]; then
                    log WARN "watcher：需要网页认证（$PROBE_DETAIL），先暂停 OpenClash 以便打开认证页"
                    stop_clash
                elif [ "$_last" != "portal" ]; then
                    log WARN "watcher：仍在等待网页认证（$PROBE_DETAIL）。浏览器打开任意 http 页面完成登录后会自动恢复"
                fi
                _last="portal"
                ;;
            2)
                if link_ok; then
                    _fail=$((_fail + 1))
                    if [ "$_fail" -le 3 ]; then
                        log WARN "watcher：上游链路正常但外网不通（$PROBE_DETAIL），第 ${_fail}/3 次"
                    fi
                    if [ "$_fail" -eq 3 ]; then
                        log WARN "watcher：连续 3 次外网不通，暂停 OpenClash（可能是认证过期或节点失效）"
                        [ -n "$(clash_pid)" ] && stop_clash
                        _last="degraded"
                    fi
                else
                    _fail=0
                    if [ -n "$(clash_pid)" ]; then
                        log WARN "watcher：上游网络断开（无默认路由或网关不可达），暂停 OpenClash"
                        stop_clash
                    elif [ "$_last" != "offline" ]; then
                        log WARN "watcher：上游网络不通，等待网络恢复后自动启动"
                    fi
                    _last="offline"
                fi
                ;;
        esac

        # 每 15 轮（约 5 分钟）留一条心跳，方便判断"还在等"还是"已经挂了"
        _beat=$((_beat + 1))
        if [ "$_beat" -ge 15 ]; then
            _beat=0
            log INFO "watcher 心跳：状态=${_last:-未知} 连续失败=${_fail} clash_pid=$(clash_pid) 可用内存=$(mem_avail)MB"
        fi

        sleep "$WATCH_INTERVAL"
    done

    rm -f "$WATCH_PID"
    log INFO "watcher 退出 pid=$$"
}

watch_start() {
    if [ -f "$WATCH_PID" ] && kill -0 "$(cat "$WATCH_PID" 2>/dev/null)" 2>/dev/null; then
        log INFO "watcher 已在运行 pid=$(cat "$WATCH_PID")，不重复启动"
        return 0
    fi
    log INFO "拉起后台守护 watcher"
    # 必须用独立进程启动：ash 子 shell 里 $$ 仍是父进程 pid，pidfile 会记错
    ( exec sh "$0" watch >/dev/null 2>&1 & )
}

watch_stop() {
    if [ -f "$WATCH_PID" ]; then
        _wp=$(cat "$WATCH_PID" 2>/dev/null)
        if [ -n "$_wp" ] && kill -0 "$_wp" 2>/dev/null; then
            log INFO "结束后台守护 pid=$_wp"
            kill "$_wp" 2>/dev/null
            sleep 1
            kill -0 "$_wp" 2>/dev/null && kill -9 "$_wp" 2>/dev/null
        fi
        rm -f "$WATCH_PID"
    fi
    rm -rf /var/lock/openclash-switch.watch
}

# ---------------------------------------------------------------------------
# 动作
# ---------------------------------------------------------------------------
do_on() {
    _pos=$(phys_state)
    log INFO "===== 动作 ON 开始（物理位置=${_pos:-未知}，uci enable=$(uci -q get openclash.config.enable)，clash pid=$(clash_pid)）====="

    if [ "${OCSW_IGNORE_POS:-0}" != "1" ] && [ -n "$_pos" ] && [ "$_pos" != "no support" ] && [ "$_pos" != "on" ]; then
        log WARN "物理开关此刻在 $_pos，与 ON 事件矛盾（很可能是连续拨动留下的排队事件），忽略本次"
        return 0
    fi

    uci set openclash.config.enable='1' 2>/dev/null
    uci commit openclash 2>/dev/null

    probe
    _st=$?
    case "$_st" in
        0)
            if [ -n "$(clash_pid)" ]; then
                # 开机时 gl_switch_button_check 与 rc.local 可能各触发一次，
                # 每次都重启核心既慢又费内存；已在运行就只补守护。
                log INFO "外网可用（$PROBE_DETAIL），clash 已在运行 pid=$(clash_pid)，跳过重启，仅同步指示灯"
                led_on
            else
                log INFO "外网可用（$PROBE_DETAIL），立即启动"
                start_clash
            fi
            ;;
        1)
            log WARN "外网需要网页认证（$PROBE_DETAIL）：暂不启动核心，先让认证页能打开"
            log WARN "请在浏览器访问任意 http 网站完成登录，之后会自动启动 OpenClash"
            [ -n "$(clash_pid)" ] && stop_clash
            ;;
        2)
            log WARN "外网不通（$PROBE_DETAIL，$(upstream_info)）：暂不启动核心，等网络恢复"
            [ -n "$(clash_pid)" ] && stop_clash
            ;;
    esac

    watch_start
    return 0
}

do_off() {
    _pos=$(phys_state)
    log INFO "===== 动作 OFF 开始（物理位置=${_pos:-未知}，clash pid=$(clash_pid)）====="

    if [ "${OCSW_IGNORE_POS:-0}" != "1" ] && [ -n "$_pos" ] && [ "$_pos" != "no support" ] && [ "$_pos" != "off" ]; then
        log WARN "物理开关此刻在 $_pos，与 OFF 事件矛盾（排队事件），忽略本次"
        return 0
    fi

    # 先把意图置 0，watcher 与启动流程都会据此自行退出
    uci set openclash.config.enable='0' 2>/dev/null
    uci commit openclash 2>/dev/null

    watch_stop
    stop_clash
    return 0
}

do_sync() {
    _pos=$(phys_state)
    log INFO "===== 动作 SYNC（物理位置=${_pos:-未知}）====="
    case "$_pos" in
        on)
            # 上次 OFF 时 led.sh off 会把 gl_led.global.led_enable 持久化成 0，
            # 开机后指示灯是黑的。这里先点亮，避免开机几十秒看起来像没通电。
            led_on
            do_on
            ;;
        off) do_off ;;
        *)   log WARN "无法读取物理开关位置（$_pos），不做任何动作" ;;
    esac
}

do_status() {
    _core=$(uci -q get openclash.config.core_type)
    _en=$(uci -q get openclash.config.enable)
    _sfm=$(uci -q get openclash.config.small_flash_memory)
    _geo=$(uci -q get openclash.config.geodata_loader)
    _pid=$(clash_pid)

    echo "============ OpenClash 开关状态 ============"
    echo "模块版本      : $VERSION"
    echo "物理拨杆      : $(phys_state)"
    echo "uci enable    : ${_en:-<空>}"
    echo "核心类型      : ${_core:-<空>}  (small_flash_memory=${_sfm:-<空>}, geodata=${_geo:-<空>})"
    echo "核心文件      : $(ls -l /etc/openclash/core/clash_meta 2>/dev/null | awk '{print $5" bytes "$6" "$7" "$8}' || echo 缺失)"
    echo "clash 进程    : ${_pid:-未运行}"
    if [ -n "$_pid" ]; then
        echo "  内存占用    : $(grep VmRSS /proc/"$_pid"/status 2>/dev/null | awk '{print int($2/1024)"MB"}')"
    fi
    echo "端口监听      : $(netstat -lntp 2>/dev/null | grep -c -E ':7890|:7891|:7893|:9090') 个"
    echo "后台守护      : $(if [ -f "$WATCH_PID" ] && kill -0 "$(cat "$WATCH_PID" 2>/dev/null)" 2>/dev/null; then echo "运行中 pid=$(cat "$WATCH_PID")"; else echo 未运行; fi)"
    echo "指示灯        : white=$(cat "$LED_WHITE" 2>/dev/null) blue=$(cat "$LED_PATH" 2>/dev/null) led_enable=$(uci -q get gl_led.global.led_enable) gl_led守护=$(ps w | grep -c '[/]usr/bin/gl_led')"
    echo "开机自启      : $( [ -e /etc/rc.d/S99openclash ] && echo 已启用 || echo 已禁用 )"
    echo "可用内存      : $(mem_avail)MB / $(mem_total)MB"
    echo "上游          : $(upstream_info)"
    probe
    case "$?" in
        0) echo "外网探测      : 在线（$PROBE_DETAIL）" ;;
        1) echo "外网探测      : 需要网页认证（$PROBE_DETAIL）" ;;
        2) echo "外网探测      : 不通（$PROBE_DETAIL）" ;;
    esac
    echo "日志          : $MAIN_LOG"
    echo "============================================"
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
log_rotate

# 只读/常驻动作不需要主锁
case "${1:-}" in
    status) do_status; exit 0 ;;
    watch)  watch_loop; exit 0 ;;
esac

# 原子目录锁（本机 BusyBox flock 的 FD 形式不可用，且 fd 会被常驻子进程继承）
_lock_try=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    _owner=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    if [ -n "$_owner" ] && ! kill -0 "$_owner" 2>/dev/null; then
        log WARN "发现陈旧锁（pid=$_owner 已不存在），清理后继续"
        rm -rf "$LOCK_DIR"
        continue
    fi
    _lock_try=$((_lock_try + 1))
    if [ "$_lock_try" -ge 25 ]; then
        log WARN "等待 25s 仍未拿到主锁（持有者 pid=${_owner:-未知}），本次动作丢弃"
        exit 1
    fi
    sleep 1
done
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT
trap 'exit 143' INT TERM HUP

case "${1:-}" in
    on)     do_on ;;
    off)    do_off ;;
    sync)   do_sync ;;
    *)
        log WARN "未知参数 '${1:-<空>}'，可用：on | off | sync | status | watch"
        ;;
esac

exit 0
