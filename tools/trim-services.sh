#!/bin/sh
# ============================================================================
#  trim-services.sh — 停用 MT3600BE 上用不到的常驻服务（幂等，可一键恢复）
#
#  在路由器上执行：sh /tmp/trim-services.sh trim
#
#  实测（固件 4.9.0 / OpenWrt 21.02）：拨杆 OFF 时 MemAvailable 158 → 175MB，
#  拨杆 ON 时 49 → 62MB。省下的主要是 quickstart（GL 首次设置向导，9.7MB）、
#  4G 短信/蜂窝三件套、ttyd、avahi，以及被 eco 守护拉起的 gl-dpi / gl-cloud /
#  alarm_event_report。
#
#  ★ 保护名单（绝不触碰）★
#    gl-repeater / gl-ngx-session   —— 桥接公共 WiFi 与 GL 管理界面会话
#    gl_led / led / gpio_switch / gl_switch_button_check —— 拨杆与指示灯
#    nginx / uhttpd / dnsmasq       —— 管理界面、配置页 CGI、DNS
#  这些进程的名字是 eco，用 pidof 查不到属正常，不要用 pidof 判断它们是否还活着。
#
#  子命令：trim | restore | status
# ============================================================================

TRIM_LIST="quickstart sms_manager smstools3 gl_cellular_manager modem_signal ttyd avahi-daemon gl-cloud gl-alarm gl_dpi gl_dpi_flow_statistics netifyd"
KEEP_LIST="repeater gl-ngx-session gl_led led gpio_switch gl_switch_button_check nginx uhttpd dnsmasq"

say() { printf '%s\n' "$*"; }

mem_line() {
    awk '/MemAvailable/{printf "MemAvailable %.1f MB\n", $2/1024}' /proc/meminfo
}

kill_eco_leftovers() {
    # eco 是 GL 的进程包装器，init 脚本 stop 之后偶尔仍有残留。
    # 只收掉三个明确无用的，gl-repeater 与 gl-ngx-session 必须留着。
    for _p in $(pidof eco 2>/dev/null); do
        _c=$(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null)
        case "$_c" in
            *gl-dpi*|*gl-cloud*|*alarm_event_report*)
                say "  kill 残留 $_p ($_c)"
                kill "$_p" 2>/dev/null
                ;;
        esac
    done
}

check_protected() {
    say "=== 保护名单状态（不应被 disable）==="
    for _s in $KEEP_LIST; do
        [ -f "/etc/init.d/$_s" ] || continue
        if /etc/init.d/$_s enabled >/dev/null 2>&1; then
            say "  $_s : enabled  OK"
        else
            say "  $_s : disabled  ← 注意：这个服务被停用了，可能影响桥接/拨杆"
        fi
    done
}

do_trim() {
    say "=== 优化前：$(mem_line) ==="
    say "=== 停用服务 ==="
    for _s in $TRIM_LIST; do
        [ -f "/etc/init.d/$_s" ] || continue
        /etc/init.d/$_s stop >/dev/null 2>&1
        /etc/init.d/$_s disable >/dev/null 2>&1
        say "  $_s : stop + disable"
    done
    kill_eco_leftovers
    sleep 5
    say "=== 优化后：$(mem_line) ==="
    check_protected
    say "=== 自检 ==="
    say "  配置页 HTTP : $(curl -s -m 8 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/cgi-bin/oc-notify 2>/dev/null)"
    say "  外网探测    : $(curl -s -m 8 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null)"
    say "  提示：ttyd 停了就没有网页终端，4G 相关停了就不能用 USB 蜂窝网卡；"
    say "        需要时执行 sh $0 restore 全部恢复。"
}

do_restore() {
    say "=== 恢复服务 ==="
    for _s in $TRIM_LIST; do
        [ -f "/etc/init.d/$_s" ] || continue
        /etc/init.d/$_s enable >/dev/null 2>&1
        /etc/init.d/$_s start >/dev/null 2>&1
        say "  $_s : enable + start"
    done
    say "=== 恢复后：$(mem_line) ==="
}

do_status() {
    say "=== 服务状态 ==="
    for _s in $TRIM_LIST; do
        [ -f "/etc/init.d/$_s" ] || continue
        if /etc/init.d/$_s enabled >/dev/null 2>&1; then _st=enabled; else _st=disabled; fi
        say "  $_s : $_st"
    done
    say "=== 剩余的 eco 进程 ==="
    for _p in $(pidof eco 2>/dev/null); do
        say "  $_p  $(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null)"
    done
    say "=== $(mem_line) ==="
    check_protected
}

case "${1:-status}" in
    trim)    do_trim ;;
    restore) do_restore ;;
    status)  do_status ;;
    *)       say "用法: $0 trim|restore|status" >&2; exit 1 ;;
esac
exit 0
