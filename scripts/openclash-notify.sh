#!/bin/sh
# ============================================================================
#  /etc/openclash-notify.sh
#
#  OpenClash 状态事件 -> Telegram Bot 推送（GL.iNet GL-MT3600BE / OpenWrt 21.02）
#  Repo   : https://github.com/shiba2046/glinet-mt3600be-collection
#  Version: 1.2.0
#
#  设计要点（为什么不是一个 curl 就完事）：
#    1. 不阻塞拨杆：拨杆脚本处在固件的 flock 串行区里，一次 HTTPS 超时 12s
#       会让开关看起来"卡住"。这里 emit 只写一个本地队列文件（毫秒级），
#       再 fork 独立进程去发；主流程永不等待网络。
#    2. 分阶段反馈：拨杆瞬间先发一条「🟢 开始」，核心稳定后再发一条
#       「✅ 结果」。开始类事件豁免 25s 防抖，每次拨动都必有反馈。
#    3. 离线也能记：断网 / captive portal 时 Telegram 同样发不出去，
#       消息留在 flash 队列，等网络恢复后按序补发，并标注"延迟送达"。
#    4. API 地址可配：api_base 默认 https://api.telegram.org，也可以填自建
#       反代（墙后直连可达的那种）。默认 api_mode=direct，只请求这一个地址，
#       不做任何自动切换、不走 clash 代理，避免反代流量被二次转发。
#       反代需要鉴权时用 proxy_auth 加 X-Proxy-Auth 头；上游 DNS 有 NXDOMAIN
#       负缓存时用 api_resolve 填 IP，走 curl --resolve 绕开（留空则用系统 DNS）。
#       仍保留 proxy / auto 两个可选模式，但默认不用。
#    5. 不刷屏：同一事件 25 秒内只记一次；watcher 是边沿触发而非每次轮询。
#
#  配置：/etc/config/openclash-notify （UCI）
#  队列：/etc/openclash-notify/spool/ （flash，重启不丢）
#  日志：/tmp/openclash-notify.log
#
#  子命令：
#    init                      创建默认配置（幂等，不覆盖已有 token）
#    emit <event> <text>       记录一条事件并异步发送（供拨杆脚本调用）
#    flush                     发送队列里的消息
#    test [text]               同步发一条测试消息，打印结果
#    config                    显示配置（token 打码）
#    set <key> <value>         修改一个配置项
#    enable | disable          开关通知
#    status                    配置摘要 + 队列长度 + 最近日志
#    clear                     清空队列
# ============================================================================

VERSION="1.2.0"
CONF="/etc/config/openclash-notify"
SPOOL="${OCN_SPOOL:-/etc/openclash-notify/spool}"
LOG="${OCN_LOG:-/tmp/openclash-notify.log}"
STATE="${OCN_STATE:-/var/run/oc-notify}"
LOCK="/var/lock/oc-notify.lock"
CA="/etc/ssl/certs/ca-certificates.crt"
API_DEFAULT="https://api.telegram.org"       # 也可用 OCN_API 环境变量覆盖，便于离线自测
DEFAULT_EVENTS="switch_on_begin,ready,start_fail,switch_off_begin,switch_off,off_fail,net_down,captive,net_up,net_up_begin,offline,core_down,update_start,update_ok,update_fail"
QUEUE_MAX=50
DEBOUNCE=25

# ash 的 $$ 在子 shell 里仍是父 pid，所有后台动作都必须是独立进程
# 这里同样避免继承调用方的锁 fd（拨杆脚本会打开 3~20 号 fd 持锁）
for _fd in 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    eval "exec $_fd<&-" 2>/dev/null
done
unset _fd

log() {
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG" 2>/dev/null
}

cfg() { uci -q get "openclash-notify.main.$1" 2>/dev/null; }

cfg_or() {
    _v=$(cfg "$1")
    [ -n "$_v" ] && printf '%s' "$_v" || printf '%s' "$2"
}

ensure_dirs() {
    mkdir -p "$SPOOL" "$STATE" 2>/dev/null
}

log_rotate() {
    [ -f "$LOG" ] || return 0
    _sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    [ "$_sz" -gt 131072 ] 2>/dev/null || return 0
    mv -f "$LOG" "$LOG.1" 2>/dev/null
    log INFO "日志超过 128KB，已轮转到 $LOG.1"
}

# ---------------------------------------------------------------------------
# 初始化配置
# ---------------------------------------------------------------------------
do_init() {
    if [ -f "$CONF" ]; then
        echo "配置已存在：$CONF（未改动）"
        return 0
    fi
    mkdir -p /etc/config
    cat > "$CONF" <<'EOF'
config notify 'main'
	option enabled '0'
	option bot_token ''
	option chat_id ''
	option api_base 'https://api.telegram.org'
	option proxy_auth ''
	option api_resolve ''
	option api_mode 'direct'
	option proxy_port '7893'
	option notify_events 'switch_on_begin,ready,start_fail,switch_off_begin,switch_off,off_fail,net_down,captive,net_up,net_up_begin,offline,core_down,update_start,update_ok,update_fail'
	option web_pin ''
EOF
    chmod 600 "$CONF"
    ensure_dirs
    echo "已创建默认配置：$CONF（enabled=0，填好 token 后用 enable 启用）"
}

# ---------------------------------------------------------------------------
# 组装消息
#   spool 文件前 3 行是元数据，第 4 行起是正文（正文允许多行）
#     1: epoch  2: 可读时间  3: 事件名  4+: 正文
# ---------------------------------------------------------------------------
enqueue() {
    _ev="$1"; shift
    _txt="$*"
    ensure_dirs
    _now=$(date +%s)
    _ht=$(date '+%Y-%m-%d %H:%M:%S')
    _f="$SPOOL/${_now}-${_ev}-$$.msg"
    {
        printf '%s\n%s\n%s\n%s\n' "$_now" "$_ht" "$_ev" "$_txt"
    } > "$_f.tmp" 2>/dev/null || return 1
    mv -f "$_f.tmp" "$_f" 2>/dev/null || return 1
    echo "$_f"
}

# ---------------------------------------------------------------------------
# 单条发送。返回 0=成功 1=网络/接口失败 2=配置缺失
# ---------------------------------------------------------------------------
send_one() {
    _f="$1"
    {
        IFS= read -r _ts
        IFS= read -r _ht
        IFS= read -r _ev
    } < "$_f"
    _txt=$(tail -n +4 "$_f" 2>/dev/null)

    _token=$(cfg bot_token)
    _chat=$(cfg chat_id)
    if [ -z "$_token" ] || [ -z "$_chat" ]; then
        log WARN "未配置 bot_token / chat_id，消息保留在队列"
        return 2
    fi

    _now=$(date +%s)
    _delay=$((_now - ${_ts:-_now}))
    if [ "$_delay" -gt 90 ] 2>/dev/null; then
        _txt="$_txt
⏳ 离线期间事件（发生于 $_ht，延迟 ${_delay}s 送达）"
    fi
    _host=$(uci -q get 'system.@system[0].hostname' 2>/dev/null)
    _text="🛰 ${_host:-GL-MT3600BE} · OpenClash
$_txt
🕒 $_ht"

    # api_base 支持自建反代：后面按官方规则拼 /bot<TOKEN>/sendMessage
    _base=${OCN_API:-$(cfg_or api_base "$API_DEFAULT")}
    _url="${_base%/}/bot${_token}/sendMessage"
    # 默认 direct：只请求这一个地址，不切换、不记忆、不走 clash 代理
    case "$(cfg_or api_mode direct)" in
        proxy) _modes="proxy" ;;
        auto)  _modes="direct proxy" ;;
        *)     _modes="direct" ;;
    esac

    _caopt=""
    [ -f "$CA" ] && _caopt="--cacert $CA"

    # 反代鉴权头。$_authopt 以不加引号的方式展开成两个 curl 参数，所以值不能含
    # 空格；do_set 的字符白名单已挡住空格，直接编辑配置文件时同样请勿含空格。
    _authopt=""
    _auth=$(cfg proxy_auth)
    [ -n "$_auth" ] && _authopt="-H X-Proxy-Auth:$_auth"

    # 可选 DNS 兜底：上游残留 NXDOMAIN 负缓存时，用 --resolve 把主机名钉到 IP，
    # 顺带省掉一次 DNS 查询（约 4ms）。主机名/端口从 api_base 取，
    # TLS SNI 仍按 URL 主机名发，Cloudflare 这类共享 IP 反代可正确路由。
    # 留空则完全不加该参数，走系统 DNS。反代换 IP 时记得同步改 api_resolve。
    _resopt=""
    _rip=$(cfg api_resolve)
    if [ -n "$_rip" ]; then
        _hp=$(printf '%s' "$_base" | sed -e 's|^[A-Za-z][A-Za-z0-9+.-]*://||' -e 's|/.*$||')
        _port=$(printf '%s' "$_hp" | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p')
        _rh=$(printf '%s' "$_hp" | sed 's|:[0-9][0-9]*$||')
        [ -n "$_port" ] || _port=443
        _resopt="--resolve $_rh:$_port:$_rip"
    fi

    for _m in $_modes; do
        _px=""
        if [ "$_m" = "proxy" ]; then
            # 核心没跑时代理端口根本不存在，别浪费一次超时
            pidof clash >/dev/null 2>&1 || { log INFO "核心未运行，跳过代理模式"; continue; }
            _px="--proxy http://127.0.0.1:$(cfg_or proxy_port 7893)"
        fi
        _resp=$(curl -sS --connect-timeout 4 --max-time 12 $_caopt $_px $_resopt $_authopt \
            -X POST "$_url" \
            --data-urlencode "chat_id=$_chat" \
            --data-urlencode "text=$_text" \
            -d "disable_web_page_preview=true" 2>&1)
        case "$_resp" in
            *'"ok":true'*|*'"ok": true'*)
                log INFO "已发送 $_ev（$_m -> $_base）"
                return 0
                ;;
        esac
        log WARN "$_m 发送失败：$(printf '%s' "$_resp" | head -c 180 | tr '\n' ' ')"
    done
    return 1
}

# ---------------------------------------------------------------------------
# 队列发送
# ---------------------------------------------------------------------------
do_flush() {
    ensure_dirs
    # 原子目录锁：本机 BusyBox flock 的 FD 形式不可用
    if ! mkdir "$LOCK" 2>/dev/null; then
        _o=$(cat "$LOCK/pid" 2>/dev/null)
        if [ -n "$_o" ] && kill -0 "$_o" 2>/dev/null; then
            return 0
        fi
        log WARN "清理陈旧发送锁（pid=${_o:-未知}）"
        rm -rf "$LOCK"
        mkdir "$LOCK" 2>/dev/null || return 0
    fi
    echo $$ > "$LOCK/pid"
    trap 'rm -rf "$LOCK"' EXIT
    trap 'exit 143' INT TERM HUP

    _sent=0
    for _f in $(ls -1 "$SPOOL"/*.msg 2>/dev/null | sort | head -30); do
        [ -f "$_f" ] || continue
        if send_one "$_f"; then
            rm -f "$_f"
            _sent=$((_sent + 1))
        else
            log WARN "暂时发不出去，队列暂停（剩余 $(ls -1 "$SPOOL"/*.msg 2>/dev/null | wc -l) 条）"
            break
        fi
        [ "$_sent" -ge 10 ] && break
        sleep 1
    done

    # 配置长期错误时不让 flash 被写爆
    _cnt=$(ls -1 "$SPOOL"/*.msg 2>/dev/null | wc -l)
    if [ "$_cnt" -gt "$QUEUE_MAX" ] 2>/dev/null; then
        _drop=$((_cnt - QUEUE_MAX))
        ls -1 "$SPOOL"/*.msg 2>/dev/null | sort | head -n "$_drop" | while read -r _x; do rm -f "$_x"; done
        log WARN "队列超过 ${QUEUE_MAX} 条，丢弃最旧的 $_drop 条"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 事件入口（供拨杆脚本调用，必须立即返回）
# ---------------------------------------------------------------------------
do_emit() {
    _ev="${1:-}"; shift 2>/dev/null
    [ -n "$_ev" ] || return 0
    [ "$(cfg_or enabled 0)" = "1" ] || return 0

    case ",$(cfg_or notify_events "$DEFAULT_EVENTS")," in
        *",$_ev,"*) ;;
        *) log INFO "事件 $_ev 未启用，跳过"; return 0 ;;
    esac

    ensure_dirs
    # 用户主动拨杆 / 测试每次都要有反馈，豁免 25s 防抖；否则快速
    # ON→OFF→ON 时第二次「开始」会被窗口吞掉，看起来像又"丢消息"。
    case "$_ev" in
        switch_on_begin|switch_off_begin|test) ;;
        *)
            _now=$(date +%s)
            _last=$(cat "$STATE/last.$_ev" 2>/dev/null)
            if [ -n "$_last" ] && [ $((_now - _last)) -lt "$DEBOUNCE" ] 2>/dev/null; then
                log INFO "事件 $_ev 在 ${DEBOUNCE}s 内重复，跳过"
                return 0
            fi
            printf '%s' "$_now" > "$STATE/last.$_ev"
            ;;
    esac

    _f=$(enqueue "$_ev" "$*") || return 0
    log INFO "入队 $_ev -> $(basename "$_f")：$(printf '%s' "$*" | tr '\n' ' ')"
    # 完全脱离调用方：拨杆脚本持有固件锁，绝不能让网络 IO 串行进去
    ( exec sh "$0" flush >/dev/null 2>&1 ) &
    return 0
}

# ---------------------------------------------------------------------------
# 配置 / 诊断
# ---------------------------------------------------------------------------
do_test() {
    ensure_dirs
    _txt="${*:-🧪 通知测试
✅ 看到这条说明 bot token / chat_id / 网络都正确}"
    _f=$(enqueue "test" "$_txt") || return 1
    if send_one "$_f"; then
        rm -f "$_f"
        echo "✅ 测试消息发送成功。API：${OCN_API:-$(cfg_or api_base "$API_DEFAULT")}"
        return 0
    fi
    rm -f "$_f"
    echo "❌ 发送失败，详见 $LOG"
    tail -n 8 "$LOG" 2>/dev/null
    return 1
}

mask_val() {
    _t=$(cfg "$1")
    case "$_t" in
        '') echo '<未设置>' ;;
        *)  printf '%s...%s\n' "$(printf '%s' "$_t" | cut -c1-6)" "$(printf '%s' "$_t" | tail -c 5)" ;;
    esac
}

do_config() {
    echo "配置文件 : $CONF"
    echo "enabled      : $(cfg_or enabled 0)"
    echo "bot_token    : $(mask_val bot_token)"
    echo "chat_id      : $(cfg_or chat_id '<未设置>')"
    echo "api_base     : $(cfg_or api_base "$API_DEFAULT")"
    echo "proxy_auth   : $(mask_val proxy_auth)  (X-Proxy-Auth 头)"
    echo "api_resolve  : $(cfg_or api_resolve '<未启用>')  (DNS 兜底 IP，留空则用系统 DNS)"
    echo "api_mode     : $(cfg_or api_mode direct)  (direct=只请求 api_base / proxy=走 clash / auto=两者都试)"
    echo "proxy_port   : $(cfg_or proxy_port 7893)（仅 proxy/auto 时用到）"
    echo "web_pin      : $(if [ -n "$(cfg web_pin)" ]; then echo 已设置; else echo '<未设置>'; fi)"
    echo "notify_events: $(cfg_or notify_events "$DEFAULT_EVENTS")"
    echo "配置页       : http://$(uci -q get network.lan.ipaddr 2>/dev/null || echo 192.168.8.1):8080/cgi-bin/oc-notify"
}

do_set() {
    _k="${1:-}"; shift 2>/dev/null
    _v="$*"
    case "$_k" in
        enabled|bot_token|chat_id|api_base|proxy_auth|api_resolve|api_mode|proxy_port|notify_events|web_pin) ;;
        *) echo "未知配置项：$_k" >&2; echo "可用：enabled bot_token chat_id api_base proxy_auth api_resolve api_mode proxy_port notify_events web_pin" >&2; return 1 ;;
    esac
    # 严格白名单：这些值最终会进 uci / curl 命令行，不能让 shell 元字符逃逸。
    # 允许字母数字和 : _ , . = @ / + -（不含空格：proxy_auth 要以单参数形式
    # 传给 curl，含空格会被拆成两个参数）。
    if printf '%s' "$_v" | grep -q '[^A-Za-z0-9_:,.=@/+-]'; then
        echo "值含不允许的字符（仅允许字母数字及 : _ , . = @ / + -，不能含空格）" >&2
        return 1
    fi
    [ -f "$CONF" ] || do_init >/dev/null
    uci set "openclash-notify.main.$_k=$_v" 2>/dev/null || return 1
    uci commit openclash-notify 2>/dev/null || return 1
    echo "$_k 已更新"
}

do_status() {
    do_config
    echo "队列       : $(ls -1 "$SPOOL"/*.msg 2>/dev/null | wc -l) 条"
    echo "日志       : $LOG"
    echo "--- 最近 12 条日志 ---"
    tail -n 12 "$LOG" 2>/dev/null || echo "(空)"
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
log_rotate
case "${1:-}" in
    init)    do_init ;;
    emit)    shift; do_emit "$@" ;;
    flush)   do_flush ;;
    test)    shift; do_test "$@" ;;
    config)  do_config ;;
    set)     shift; do_set "$@" ;;
    enable)  do_set enabled 1 ;;
    disable) do_set enabled 0 ;;
    status)  do_status ;;
    clear)   rm -f "$SPOOL"/*.msg 2>/dev/null; echo "队列已清空" ;;
    version) echo "$VERSION" ;;
    *)
        echo "用法: $0 init|emit|flush|test|config|set|enable|disable|status|clear|version" >&2
        exit 1
        ;;
esac
exit 0
