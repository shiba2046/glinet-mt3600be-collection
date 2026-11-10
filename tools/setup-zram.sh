#!/bin/sh
# ============================================================================
#  setup-zram.sh — 在 GL-MT3600BE 上启用 zram 压缩交换（幂等，可回滚）
#
#  在路由器上执行：sh /tmp/setup-zram.sh install
#  本地跑法见 docs/12-memory-tuning.md
#
#  背景：内核 5.4.281 编了 CONFIG_ZRAM=m / CONFIG_ZSMALLOC=m / CONFIG_SWAP=y，
#  但 GL 固件没有预装 zram.ko。GL 官方 kmod feed 里有版本完全匹配的
#  kmod-zram 5.4.281-1 与 zram-swap 8，装完由 /etc/init.d/zram 开机自动启用。
#
#  预期：zram 是「突发内存压力的保险」，不是常态扩容。实测 swappiness=30 时
#  拨杆 ON 换出 0 KB，swappiness=60 也只换出 1.2MB 且延迟变差，故默认 30。
#  订阅更新 / 连接爆发 / OOM 边缘时它才会真正介入。
#
#  子命令：install | status | remove | check
#  环境变量：ZRAM_SIZE_MB（默认 96）、ZRAM_SWAPPINESS（默认 30）
# ============================================================================

SIZE_MB="${ZRAM_SIZE_MB:-96}"
SWAPPINESS="${ZRAM_SWAPPINESS:-30}"
SYSCTL="/etc/sysctl.conf"
SYSUP="/etc/sysupgrade.conf"

say() { printf '%s\n' "$*"; }
die() { say "[error] $*" >&2; exit 1; }

need_root() {
    [ "$(id -u)" = "0" ] || die "需要用 root 运行"
}

add_sysupgrade() {
    _p="$1"
    grep -qxF "$_p" "$SYSUP" 2>/dev/null && { say "  已存在：$_p"; return 0; }
    echo "$_p" >> "$SYSUP"
    say "  已追加：$_p"
}

do_check() {
    say "=== 内核与包可用性 ==="
    if [ -r /proc/config.gz ]; then
        zcat /proc/config.gz | grep -E "CONFIG_(ZRAM|ZSMALLOC|SWAP|CRYPTO_LZO)[ =]" | head -8
    else
        say "  （无 /proc/config.gz，跳过内核配置检查）"
    fi
    say "  /proc/swaps 存在：$([ -e /proc/swaps ] && echo 是 || echo 否)"
    say "  已装 kmod-zram：$(opkg list-installed 2>/dev/null | grep -c '^kmod-zram ')"
    say "  已装 zram-swap：$(opkg list-installed 2>/dev/null | grep -c '^zram-swap ')"
    say "  当前 swap："
    cat /proc/swaps 2>/dev/null
}

do_install() {
    need_root
    say "=== 1) 检查并安装 zram 包 ==="
    if opkg list-installed 2>/dev/null | grep -q '^zram-swap '; then
        say "  zram-swap 已安装，跳过"
    else
        say "  opkg update ..."
        opkg update >/dev/null 2>&1 || say "  [warn] opkg update 失败，尝试用现有索引继续"
        opkg list 2>/dev/null | grep -q '^kmod-zram ' || die "源里找不到 kmod-zram（检查 /etc/opkg/distfeeds.conf 与外网）"
        opkg install kmod-zram zram-swap || die "安装失败"
    fi

    say "=== 2) UCI 配置：${SIZE_MB}MB / lzo / priority 100 ==="
    uci set system.@system[0].zram_size_mb="$SIZE_MB"
    uci set system.@system[0].zram_comp_algo='lzo'
    uci set system.@system[0].zram_priority='100'
    uci commit system || die "uci commit system 失败"

    say "=== 3) swappiness=${SWAPPINESS}（持久化）==="
    if grep -q '^vm.swappiness' "$SYSCTL" 2>/dev/null; then
        sed -i "s/^vm.swappiness=.*/vm.swappiness=$SWAPPINESS/" "$SYSCTL"
    else
        echo "vm.swappiness=$SWAPPINESS" >> "$SYSCTL"
    fi
    echo "$SWAPPINESS" > /proc/sys/vm/swappiness
    add_sysupgrade "$SYSCTL"
    # UCI 里记的 zram 参数随 /etc/config/system 一起升级保留
    add_sysupgrade /etc/config/system

    say "=== 4) 重启 zram 并设开机自启 ==="
    /etc/init.d/zram stop >/dev/null 2>&1
    sleep 1
    /etc/init.d/zram start || die "/etc/init.d/zram start 失败"
    /etc/init.d/zram enable

    say "=== 完成 ==="
    do_status
}

do_status() {
    say "--- /proc/swaps ---"
    cat /proc/swaps 2>/dev/null || die "内核不支持 swap"
    say "--- zram0 ---"
    for _f in disksize comp_algorithm mm_stat; do
        printf '  %-16s %s\n' "$_f" "$(cat "/sys/block/zram0/$_f" 2>/dev/null || echo 缺失)"
    done
    say "  swappiness      $(cat /proc/sys/vm/swappiness 2>/dev/null)"
    say "  开机自启        $(ls -l /etc/rc.d/S15zram 2>/dev/null | sed 's/.*-> //' || echo 未启用)"
    say "--- 内存 ---"
    awk '/MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree/{printf "  %-14s %.1f MB\n", $1, $2/1024}' /proc/meminfo
}

do_remove() {
    need_root
    say "=== 回滚：关闭并卸载 zram ==="
    /etc/init.d/zram disable >/dev/null 2>&1
    /etc/init.d/zram stop >/dev/null 2>&1
    uci -q delete system.@system[0].zram_size_mb
    uci -q delete system.@system[0].zram_comp_algo
    uci -q delete system.@system[0].zram_priority
    uci commit system
    opkg remove zram-swap kmod-zram kmod-lib-lzo kmod-crypto-acompress >/dev/null 2>&1
    sed -i '/^vm.swappiness=/d' "$SYSCTL" 2>/dev/null
    echo 60 > /proc/sys/vm/swappiness
    say "  已卸载，swappiness 恢复 60。/etc/sysupgrade.conf 里的条目如需清掉请手动删除。"
    do_check
}

case "${1:-install}" in
    check)   do_check ;;
    install) do_install ;;
    status)  do_status ;;
    remove)  do_remove ;;
    *)       die "用法: $0 check|install|status|remove" ;;
esac
exit 0
