#!/bin/sh
# ============================================================================
# OpenClash 依赖文件自动更新
#   部署路径：/etc/openclash-auto-update.sh
#   Repo     ：https://github.com/shiba2046/glinet-mt3600be-collection
#   Version  ：0.3.0
#   日志：/tmp/openclash-auto-update.log（超过 128KB 自动截断）
#
# 设计原则（重要，别再加多余任务）：
#   1. GeoSite.dat / Country.mmdb / rule_provider/*.mrs 由 mihomo 核心自己更新
#      （配置文件里 geo-auto-update: true + rule-providers 的 interval: 86400），
#      这里不重复下载，避免两套逻辑抢同一批文件。
#   2. 核心二进制 clash_meta 不自动替换：12MB+ 下载 + 版本变动可能改内存占用，
#      只提供 core-check / core-update 手动命令。
#   3. 酒店/公共网络安全门控：没网、或卡在认证页（captive portal）时直接跳过，
#      不产生一堆失败日志，也不会把核心搞成半死状态。
#   4. 核心没运行时用 norestart 更新订阅，避免把开关关着的核心偷偷拉起来。
#
# 用法：
#   run           cron 调用（每天 04:00）
#   now           立即跑一次，等同 run
#   status        查看上次结果 / 各文件时间 / cron 状态
#   core-check    查询核心是否有新版（只查，不下载）
#   core-update   下载并替换核心（手动，带备份与回滚）
#   install-cron  安装/修复每日 04:00 的定时任务
# ============================================================================

LOG_FILE=/tmp/openclash-auto-update.log
LOG_MAX=131072
STATE_FILE=/etc/openclash/.auto-update.state
LOCK_DIR=/var/lock/openclash-autoupdate.lock
TMP_OUT=/tmp/openclash-autoupdate.out
CRON_FILE=/etc/crontabs/root
CRON_TAG="# openclash-auto-update"
CONFIG_DIR=/etc/openclash
CORE_DIR=$CONFIG_DIR/core
CORE_BIN=$CORE_DIR/clash_meta
OC_UPDATE=/usr/share/openclash/openclash.sh
PROBE_URLS=${OCAU_PROBE_URLS:-"http://www.gstatic.com/generate_204 http://cp.cloudflare.com/generate_204 http://connect.rom.miui.com/generate_204"}

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------
log() {
    _lvl="$1"; shift
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$_lvl] $*" >> "$LOG_FILE"
}

log_rotate() {
    [ -f "$LOG_FILE" ] || return 0
    _sz=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$_sz" -gt "$LOG_MAX" ]; then
        tail -c $((LOG_MAX / 2)) "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv -f "$LOG_FILE.tmp" "$LOG_FILE"
        log INFO "日志超过 $((LOG_MAX / 1024))KB，已截断保留后半部分"
    fi
}

mem_avail() {
    awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null
}

clash_pid() {
    pidof clash 2>/dev/null
}

core_ver() {
    "$CORE_BIN" -v 2>/dev/null | head -1
}

write_state() {
    {
        echo "time=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "result=$1"
        echo "detail=$2"
    } > "$STATE_FILE" 2>/dev/null
}

# 返回 0=外网可用 1=强制门户 2=不通
probe() {
    for _u in $PROBE_URLS; do
        _raw=$(curl -s -m 8 -w '\n%{http_code}' "$_u" 2>/dev/null)
        _code=$(printf '%s' "$_raw" | tail -n1)
        _body=$(printf '%s' "$_raw" | sed '$d')
        case "$_code" in
            204)
                PROBE_DETAIL="204 $_u"
                return 0
                ;;
            200|301|302|303|307|308)
                if printf '%s' "$_body" | grep -qiE '<html|<!doctype|<head|<body'; then
                    PROBE_DETAIL="portal(http $_code) $_u"
                    return 1
                fi
                PROBE_DETAIL="http $_code $_u"
                return 0
                ;;
        esac
    done
    PROBE_DETAIL="三个探测点均不可达"
    return 2
}

acquire_lock() {
    _try=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        _lp=$(cat "$LOCK_DIR/pid" 2>/dev/null)
        if [ -n "$_lp" ] && ! kill -0 "$_lp" 2>/dev/null; then
            log WARN "发现陈旧锁（pid=$_lp 已不存在），清理后重试"
            rm -rf "$LOCK_DIR"
            continue
        fi
        _try=$((_try + 1))
        if [ "$_try" -ge 10 ]; then
            log WARN "等待 20s 仍未拿到锁（另一实例在跑），本次放弃"
            return 1
        fi
        sleep 2
    done
    echo $$ > "$LOCK_DIR/pid"
    trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM HUP
    return 0
}

# ---------------------------------------------------------------------------
# 订阅更新
# ---------------------------------------------------------------------------
update_sub() {
    if [ ! -x "$OC_UPDATE" ] && [ ! -f "$OC_UPDATE" ]; then
        log ERROR "找不到 $OC_UPDATE，OpenClash 可能未安装或被升级破坏"
        return 1
    fi

    _cfg="$CONFIG_DIR/聚合.yaml"
    _before=""
    [ -f "$_cfg" ] && _before=$(md5sum "$_cfg" 2>/dev/null | awk '{print $1}')

    if [ -n "$(clash_pid)" ]; then
        _mode="restart"
        log INFO "核心在运行（pid=$(clash_pid)），更新后由 OpenClash 重启核心使新配置生效"
        "$OC_UPDATE" "" > "$TMP_OUT" 2>&1
    else
        _mode="norestart"
        log INFO "核心未运行，使用 norestart，更新后不会拉起核心"
        "$OC_UPDATE" "" norestart > "$TMP_OUT" 2>&1
    fi
    _rc=$?

    # 只摘取关键行，避免把 OpenClash 的全量日志灌进来
    if [ -s "$TMP_OUT" ]; then
        grep -E 'Update Successful|No Change|Subscribed Failed|Update Error|Config File Tested Failed|Start Updating' "$TMP_OUT" 2>/dev/null | head -30 | while IFS= read -r _line; do
            log OC "$_line"
        done
    fi
    rm -f "$TMP_OUT"

    _after=""
    [ -f "$_cfg" ] && _after=$(md5sum "$_cfg" 2>/dev/null | awk '{print $1}')

    if [ "$_rc" -ne 0 ]; then
        log ERROR "订阅更新命令返回 $_rc（网络抖动或订阅站不可用，配置文件保持原样）"
        return 1
    fi
    ensure_geo_auto
    if [ -z "$_before" ] || [ -z "$_after" ]; then
        log WARN "无法读取配置文件校验值，跳过变化判定"
        return 0
    fi
    if [ "$_before" = "$_after" ]; then
        log INFO "订阅无变化（md5=${_after%????????????????????????}…），无需重启"
    else
        _size=$(wc -c < "$_cfg" 2>/dev/null)
        log INFO "订阅已更新：md5 ${_before%????????????????????????}… -> ${_after%????????????????????????}…，大小 ${_size} bytes"
        if [ "$_mode" = "norestart" ]; then
            log INFO "新配置已落盘，下次拨到 ON（或重启核心）时生效"
        fi
    fi
    return 0
}

# 订阅换模板后可能丢掉 geo 自动更新字段，导致核心不再自己更新 GeoSite/GeoIP。
# 这里在更新后做一次兜底（改的是订阅源文件，OpenClash 每次 start 会据此重新生成运行配置）。
ensure_geo_auto() {
    _src="$CONFIG_DIR/config/聚合.yaml"
    [ -f "$_src" ] || return 0
    if grep -qE '^geo-auto-update:' "$_src"; then
        if ! grep -qE '^geo-auto-update: *true' "$_src"; then
            sed -i 's/^geo-auto-update:.*/geo-auto-update: true/' "$_src"
            log WARN "订阅把 geo-auto-update 改成了非 true，已改回 true（否则核心不再自动更新 geo 数据）"
        fi
    else
        sed -i '1i geo-auto-update: true' "$_src"
        log WARN "订阅缺少 geo-auto-update 字段，已补上 true"
    fi
    grep -qE '^geo-update-interval:' "$_src" || sed -i '/^geo-auto-update:/a geo-update-interval: 24' "$_src"
    return 0
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
do_run() {
    log_rotate
    log INFO "===== 自动更新开始（触发=${1:-cron}）====="

    probe
    _p=$?
    if [ "$_p" -eq 1 ]; then
        log WARN "检测到强制门户/认证页（$PROBE_DETAIL），本次跳过。请先用浏览器完成认证"
        write_state "skipped-portal" "$PROBE_DETAIL"
        log INFO "===== 结束（跳过）====="
        return 0
    elif [ "$_p" -eq 2 ]; then
        log WARN "外网不可达（$PROBE_DETAIL），本次跳过"
        write_state "skipped-offline" "$PROBE_DETAIL"
        log INFO "===== 结束（跳过）====="
        return 0
    fi
    log INFO "网络正常：$PROBE_DETAIL"

    _mem=$(mem_avail)
    if [ -n "$_mem" ] && [ "$_mem" -lt 45 ]; then
        log WARN "可用内存仅 ${_mem}MB，跳过本次更新以免触发 OOM"
        write_state "skipped-lowmem" "avail=${_mem}MB"
        log INFO "===== 结束（跳过）====="
        return 0
    fi
    log INFO "可用内存 ${_mem}MB，开始更新订阅"

    if update_sub; then
        write_state "ok" "mode=$( [ -n "$(clash_pid)" ] && echo restart || echo norestart )"
    else
        write_state "failed" "see $LOG_FILE"
    fi
    log INFO "===== 结束 ====="
}

# ---------------------------------------------------------------------------
# 安装 cron
# ---------------------------------------------------------------------------
do_install_cron() {
    if [ ! -f "$CRON_FILE" ]; then
        mkdir -p "$(dirname "$CRON_FILE")"
        : > "$CRON_FILE"
    fi
    # 清掉旧的本脚本任务行（保留 OpenClash 自己的 #openclash-cron-task 行不动）
    if grep -qF "$CRON_TAG" "$CRON_FILE" 2>/dev/null; then
        grep -vF "$CRON_TAG" "$CRON_FILE" > "$CRON_FILE.tmp" 2>/dev/null && mv -f "$CRON_FILE.tmp" "$CRON_FILE"
    fi
    [ -s "$CRON_FILE" ] && [ -n "$(tail -c 1 "$CRON_FILE" 2>/dev/null)" ] && echo >> "$CRON_FILE"
    printf '0 4 * * * /etc/openclash-auto-update.sh run >/dev/null 2>&1 %s\n' "$CRON_TAG" >> "$CRON_FILE"
    crontab "$CRON_FILE" 2>/dev/null
    log INFO "已安装定时任务：每天 04:00 执行 run（$CRON_FILE）"

    if /etc/init.d/cron enabled >/dev/null 2>&1; then
        echo "cron 服务：已启用"
    else
        echo "cron 服务：未启用，正在启用"
        /etc/init.d/cron enable >/dev/null 2>&1
        /etc/init.d/cron restart >/dev/null 2>&1
    fi
    echo "当前任务："
    grep -F "$CRON_TAG" "$CRON_FILE" 2>/dev/null | sed 's/^/  /'
}

# ---------------------------------------------------------------------------
# 核心检查 / 更新（手动）
# ---------------------------------------------------------------------------
do_core_check() {
    _cur=$(core_ver)
    echo "当前核心：${_cur:-读取失败}"
    _tag=$(curl -s -m 15 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest 2>/dev/null \
        | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    if [ -n "$_tag" ]; then
        echo "Meta 最新稳定版：$_tag"
        echo "（当前装的是 alpha 分支，稳定版号不直接可比，仅作参考）"
    else
        echo "GitHub API 不可达（可能需要代理），无法查询最新版本"
    fi
    echo "提示：核心更新请手动执行  sh /etc/openclash-auto-update.sh core-update"
}

do_core_update() {
    _mem=$(mem_avail)
    if [ -n "$_mem" ] && [ "$_mem" -lt 80 ]; then
        echo "可用内存仅 ${_mem}MB，低于 80MB，拒绝更新核心（会触发 OOM）"
        echo "可以先拨到 OFF 停掉核心再更新，或关闭其它后台服务"
        return 1
    fi

    probe
    if [ $? -ne 0 ]; then
        echo "外网不可用（$PROBE_DETAIL），无法下载核心"
        return 1
    fi

    _url="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz"
    echo "下载：$_url"
    rm -rf /tmp/oc_core_new && mkdir -p /tmp/oc_core_new
    if ! wget -T 120 -q -O /tmp/oc_core_new/clash.tar.gz "$_url"; then
        echo "下载失败"; rm -rf /tmp/oc_core_new; return 1
    fi
    if ! tar -xzf /tmp/oc_core_new/clash.tar.gz -C /tmp/oc_core_new 2>/dev/null; then
        echo "解包失败（下载内容可能不完整）"; rm -rf /tmp/oc_core_new; return 1
    fi
    _newver=$(/tmp/oc_core_new/clash -v 2>/dev/null | head -1)
    if [ -z "$_newver" ]; then
        echo "新核心无法执行，放弃替换"; rm -rf /tmp/oc_core_new; return 1
    fi
    echo "新核心版本：$_newver"
    echo "原核心版本：$(core_ver)"

    cp -f "$CORE_BIN" "$CORE_BIN.bak" 2>/dev/null
    echo "已备份原核心到 $CORE_BIN.bak"
    if [ -n "$(clash_pid)" ]; then
        echo "停止核心后替换"
        /etc/init.d/openclash stop >/dev/null 2>&1
        sleep 3
    fi
    cp -f /tmp/oc_core_new/clash "$CORE_BIN" && chmod 755 "$CORE_BIN"
    rm -rf /tmp/oc_core_new

    if [ -n "$(core_ver)" ]; then
        echo "替换完成：$(core_ver)"
        log INFO "核心已手动更新：$_newver"
        echo "如需生效：拨到 ON 或执行 /etc/init.d/openclash start"
    else
        echo "新核心异常，回滚"
        cp -f "$CORE_BIN.bak" "$CORE_BIN" && chmod 755 "$CORE_BIN"
        log ERROR "核心替换失败，已回滚"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 状态
# ---------------------------------------------------------------------------
do_status() {
    echo "======== OpenClash 依赖文件 ========"
    printf '核心        : %s\n' "$(core_ver)"
    for _f in GeoSite.dat Country.mmdb china_ip_route.ipset china_ip6_route.ipset; do
        if [ -f "$CONFIG_DIR/$_f" ]; then
            printf '%-12s: %s  %s\n' "$_f" "$(du -h "$CONFIG_DIR/$_f" 2>/dev/null | awk '{print $1}')" "$(date -r "$CONFIG_DIR/$_f" '+%m-%d %H:%M' 2>/dev/null)"
        fi
    done
    if [ -d "$CONFIG_DIR/rule_provider" ]; then
        printf '规则集      : %s / %s 个（最近更新 %s）\n' \
            "$(du -sh "$CONFIG_DIR/rule_provider" 2>/dev/null | awk '{print $1}')" \
            "$(ls "$CONFIG_DIR/rule_provider" 2>/dev/null | wc -l)" \
            "$(ls -lt "$CONFIG_DIR/rule_provider" 2>/dev/null | sed -n '2p' | awk '{print $6" "$7" "$8}')"
    fi

    echo
    echo "======== 自动更新 ========"
    if [ -f "$STATE_FILE" ]; then sed 's/^/  /' "$STATE_FILE"; else echo "  尚无执行记录"; fi
    echo
    echo "cron 任务："
    grep -F "$CRON_TAG" "$CRON_FILE" 2>/dev/null | sed 's/^/  /' || echo "  未安装（执行 install-cron 安装）"
    echo
    echo "核心内部自动更新（配置决定，无需 cron）："
    grep -m1 'geo-auto-update' "$CONFIG_DIR/聚合.yaml" 2>/dev/null | sed 's/^/  /'
    printf '  rule-providers: %s 个远程规则，各自 interval 到期后由核心更新\n' \
        "$(grep -c 'interval:' "$CONFIG_DIR/config/聚合.yaml" 2>/dev/null)"
    echo
    echo "日志：$LOG_FILE"
    [ -f "$LOG_FILE" ] && echo "最近 5 行：" && tail -5 "$LOG_FILE" | sed 's/^/  /'
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
case "${1:-}" in
    run|now)
        acquire_lock || exit 1
        do_run "${1}"
        ;;
    status)
        do_status
        ;;
    install-cron)
        do_install_cron
        ;;
    core-check)
        do_core_check
        ;;
    core-update)
        do_core_update
        ;;
    *)
        echo "用法: $0 {run|now|status|install-cron|core-check|core-update}"
        ;;
esac

exit 0
