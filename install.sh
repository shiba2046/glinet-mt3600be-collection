#!/bin/sh
# ============================================================================
#  install.sh — 在路由器上安装 / 升级 openclash 拨动开关模块
#
#  通常在本地执行 ./deploy.sh，由它推包并在设备上调用本脚本；也可以在设备上
#  手动运行（前提是本脚本同级的 scripts/ 目录完整）。
#
#  用法：
#    sh install.sh [选项]
#
#    --switch-only      只装拨动开关模块（不装自动更新、不动 cron）
#    --no-rc-hook       不往 /etc/rc.local 加开机校正钩子
#    --keep-autostart   保留 /etc/init.d/openclash 开机自启（默认会 disable）
#    --tune-openclash   顺带应用小内存优化（small_flash_memory=0 等，见 docs/05）
#    --trim-services    顺带停用 netifyd / gl_dpi（省约 20MB，会失去客户端流量统计）
#    --no-cron          不安装每日 04:00 订阅更新任务
#    --dry-run          只打印将要做的事，不落盘
# ============================================================================

VERSION="0.3.0"
TARGET_DIR="/etc/gl-switch.d"
SWITCH_DST="$TARGET_DIR/openclash.sh"
AUTOUP_DST="/etc/openclash-auto-update.sh"
BACKUP_ROOT="/root/openclash-switch-backup"
TS=$(date '+%Y%m%d-%H%M%S')
BACKUP_DIR="$BACKUP_ROOT/$TS"

HERE=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
SRC_SWITCH="$HERE/scripts/gl-switch.d/openclash.sh"
SRC_AUTOUP="$HERE/scripts/openclash-auto-update.sh"

DO_AUTOUP=1
DO_RC_HOOK=1
DISABLE_AUTOSTART=1
DO_TUNE=0
DO_TRIM=0
DO_CRON=1
DRY=0

RC_HOOK_TAG="# openclash-switch-hook"
RC_HOOK_BODY="( sleep 25; $SWITCH_DST sync >/dev/null 2>&1 ) &"

# ---------------------------------------------------------------------------
# 基础
# ---------------------------------------------------------------------------
say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*" >&2; }
die()  { printf '[error] %s\n' "$*" >&2; exit 1; }

run() {
    if [ "$DRY" = "1" ]; then
        printf '  [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

backup() {
    [ -e "$1" ] || return 0
    run mkdir -p "$BACKUP_DIR"
    run cp -f "$1" "$BACKUP_DIR/$(basename "$1")"
    [ "$DRY" = "1" ] || say "  已备份 $1"
}

for _a in "$@"; do
    case "$_a" in
        --switch-only)    DO_AUTOUP=0; DO_CRON=0 ;;
        --no-rc-hook)     DO_RC_HOOK=0 ;;
        --keep-autostart) DISABLE_AUTOSTART=0 ;;
        --tune-openclash) DO_TUNE=1 ;;
        --trim-services)  DO_TRIM=1 ;;
        --no-cron)        DO_CRON=0 ;;
        --dry-run)        DRY=1 ;;
        -h|--help)        sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                die "未知参数：$_a（-h 看帮助）" ;;
    esac
done

# ---------------------------------------------------------------------------
# 预检
# ---------------------------------------------------------------------------
step "预检"
[ "$(id -u)" = "0" ] || die "需要用 root 运行"
[ -d "$TARGET_DIR" ] || die "找不到 $TARGET_DIR，这似乎不是 GL.iNet 固件"
command -v uci >/dev/null 2>&1 || die "找不到 uci"
[ -f "$SRC_SWITCH" ] || die "包不完整：缺少 $SRC_SWITCH"
for _t in curl pidof flock; do
    command -v "$_t" >/dev/null 2>&1 || warn "缺少命令 $_t，部分功能会退化"
done
say "  固件      : $(cat /etc/glversion 2>/dev/null || echo unknown)"
say "  内核      : $(uname -r) $(uname -m)"
say "  OpenClash : $(opkg list-installed 2>/dev/null | grep -m1 '^luci-app-openclash' | awk '{print $3}' || echo 未安装)"
say "  模块版本  : $VERSION"
[ "$DRY" = "1" ] && say "  （dry-run，不会真的改动任何文件）"

# ---------------------------------------------------------------------------
# 1. 拨动开关模块
# ---------------------------------------------------------------------------
step "安装拨动开关模块 -> $SWITCH_DST"

# 升级前先停掉在跑的 watcher，避免旧逻辑继续动作
if [ -f /var/run/openclash-switch.watch.pid ]; then
    _wp=$(cat /var/run/openclash-switch.watch.pid 2>/dev/null)
    if [ -n "$_wp" ] && kill -0 "$_wp" 2>/dev/null; then
        say "  停掉旧 watcher pid=$_wp"
        run kill "$_wp" 2>/dev/null
        sleep 1
    fi
    run rm -f /var/run/openclash-switch.watch.pid
fi
run rm -rf /var/lock/openclash-switch.watch /var/lock/openclash-switch.lock

backup "$SWITCH_DST"
run mkdir -p "$TARGET_DIR"
if [ "$DRY" != "1" ]; then
    cp -f "$SRC_SWITCH" "$SWITCH_DST.tmp" && chmod 755 "$SWITCH_DST.tmp" && mv -f "$SWITCH_DST.tmp" "$SWITCH_DST" \
        || die "写入 $SWITCH_DST 失败"
    sh -n "$SWITCH_DST" || die "语法检查失败：$SWITCH_DST"
    say "  已安装，语法检查通过"
else
    say "  [dry-run] 复制 $SRC_SWITCH -> $SWITCH_DST"
fi

# 清理 v0.1 的遗留实现（那时还叫 /etc/openclash-switch.sh + 自建 BTN_0）
step "清理旧版本遗留文件"
for _f in /etc/openclash-switch.sh /etc/rc.button/BTN_0; do
    if [ -f "$_f" ]; then
        _n=$(basename "$_f").legacy
        backup "$_f"
        run mv -f "$_f" "$BACKUP_DIR/$_n"
        say "  v0.1 遗留文件已归档：$_f"
    fi
done
# 原厂 /etc/rc.button/switch 若被改过，从只读分区恢复
if [ -f /rom/etc/rc.button/switch ]; then
    if ! cmp -s /rom/etc/rc.button/switch /etc/rc.button/switch 2>/dev/null; then
        backup /etc/rc.button/switch
        run cp -f /rom/etc/rc.button/switch /etc/rc.button/switch
        run chmod 755 /etc/rc.button/switch
        say "  已从 /rom 恢复原厂调度器 /etc/rc.button/switch"
    else
        say "  /etc/rc.button/switch 与原厂一致，无需处理"
    fi
fi

# ---------------------------------------------------------------------------
# 2. 绑定开关功能（只改 uci，不动任何固件文件）
# ---------------------------------------------------------------------------
step "绑定 switch-button.@main[0].func=openclash"
_old_func=$(uci -q get switch-button.@main[0].func)
say "  原值：${_old_func:-<空>}"
run uci set switch-button.@main[0].func='openclash'
run uci -q delete switch-button.@main[0].sub_func
run uci commit switch-button
say "  新值：$(uci -q get switch-button.@main[0].func)"

# ---------------------------------------------------------------------------
# 3. 开机时机：关掉 OpenClash 自己的 S99，交给开关模块决定
# ---------------------------------------------------------------------------
if [ "$DISABLE_AUTOSTART" = "1" ]; then
    step "调整开机自启"
    if [ -e /etc/rc.d/S99openclash ]; then
        run /etc/init.d/openclash disable
        [ "$DRY" = "1" ] || say "  已 disable /etc/init.d/openclash（S99openclash 移除）"
        say "  开机由 S99gl_switch_button_check 按物理拨杆位置调用本模块"
    else
        say "  已经是禁用状态"
    fi
else
    step "保留 /etc/init.d/openclash 开机自启（按 --keep-autostart）"
fi

# ---------------------------------------------------------------------------
# 4. /etc/rc.local 兜底钩子
# ---------------------------------------------------------------------------
if [ "$DO_RC_HOOK" = "1" ]; then
    step "配置 /etc/rc.local 开机校正钩子"
    # 标记和钩子本体任一存在都算已配置：老版本部署的 rc.local 里只有钩子没有标记
    if grep -qF "$RC_HOOK_TAG" /etc/rc.local 2>/dev/null \
        || grep -q 'gl-switch.d/openclash.sh sync' /etc/rc.local 2>/dev/null; then
        say "  钩子已存在，跳过"
    else
        backup /etc/rc.local
        if [ "$DRY" = "1" ]; then
            say "  [dry-run] 在 /etc/rc.local 的 exit 0 之前插入 sync 钩子"
        else
            # 插在最后一个 exit 0 之前；没有 exit 0 就追加到末尾
            awk -v tag="$RC_HOOK_TAG" -v body="$RC_HOOK_BODY" '
                { lines[NR] = $0 }
                END {
                    done = 0
                    for (i = 1; i <= NR; i++) {
                        if (!done && lines[i] ~ /^exit 0[[:space:]]*$/) {
                            print tag; print body; done = 1
                        }
                        print lines[i]
                    }
                    if (!done) { print tag; print body; print "exit 0" }
                }
            ' /etc/rc.local > /etc/rc.local.new && mv -f /etc/rc.local.new /etc/rc.local
            chmod 755 /etc/rc.local
            sh -n /etc/rc.local || die "/etc/rc.local 语法检查失败，请从 $BACKUP_DIR 恢复"
            say "  已插入：$RC_HOOK_BODY"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 5. 固件升级保留清单
# ---------------------------------------------------------------------------
step "写入 /etc/sysupgrade.conf（升级保留）"
for _p in "$TARGET_DIR/" /etc/rc.local; do
    if grep -qxF "$_p" /etc/sysupgrade.conf 2>/dev/null; then
        say "  已存在：$_p"
    elif [ "$DRY" = "1" ]; then
        say "  [dry-run] 追加 $_p"
    else
        echo "$_p" >> /etc/sysupgrade.conf
        say "  已追加：$_p"
    fi
done
if [ "$DO_AUTOUP" = "1" ]; then
    if grep -qxF "$AUTOUP_DST" /etc/sysupgrade.conf 2>/dev/null; then
        say "  已存在：$AUTOUP_DST"
    elif [ "$DRY" = "1" ]; then
        say "  [dry-run] 追加 $AUTOUP_DST"
    else
        echo "$AUTOUP_DST" >> /etc/sysupgrade.conf
        say "  已追加：$AUTOUP_DST"
    fi
fi

# ---------------------------------------------------------------------------
# 6. 自动更新
# ---------------------------------------------------------------------------
if [ "$DO_AUTOUP" = "1" ]; then
    step "安装依赖文件自动更新 -> $AUTOUP_DST"
    [ -f "$SRC_AUTOUP" ] || die "包不完整：缺少 $SRC_AUTOUP"
    backup "$AUTOUP_DST"
    if [ "$DRY" = "1" ]; then
        say "  [dry-run] 复制 $SRC_AUTOUP -> $AUTOUP_DST"
    else
        cp -f "$SRC_AUTOUP" "$AUTOUP_DST.tmp" && chmod 755 "$AUTOUP_DST.tmp" && mv -f "$AUTOUP_DST.tmp" "$AUTOUP_DST" \
            || die "写入 $AUTOUP_DST 失败"
        sh -n "$AUTOUP_DST" || die "语法检查失败：$AUTOUP_DST"
        say "  已安装，语法检查通过"
    fi
    if [ "$DO_CRON" = "1" ]; then
        run sh "$AUTOUP_DST" install-cron
    fi
fi

# ---------------------------------------------------------------------------
# 7. 可选：OpenClash 小内存参数
# ---------------------------------------------------------------------------
if [ "$DO_TUNE" = "1" ]; then
    step "应用 OpenClash 小内存参数"
    say "  small_flash_memory=0     核心/geo 落 flash，重启不再重新下载"
    say "  geodata_loader=memconservative  降低 GeoSite 解析占用"
    say "  smart_enable=0 / smart_enable_lgbm=0 / auto_smart_switch=0"
    say "                            避免配置被改写成 type: smart（Meta 核心不支持）"
    for _kv in \
        "small_flash_memory=0" \
        "geodata_loader=memconservative" \
        "smart_enable=0" \
        "smart_enable_lgbm=0" \
        "auto_smart_switch=0"
    do
        run uci set "openclash.config.${_kv%%=*}=${_kv#*=}"
    done
    run uci commit openclash
    _ct=$(uci -q get openclash.config.core_type)
    say "  当前 core_type=${_ct:-<空>}（本脚本不改它；若核心文件是 meta 构建，应设为 Meta）"
fi

# ---------------------------------------------------------------------------
# 8. 可选：腾内存
# ---------------------------------------------------------------------------
if [ "$DO_TRIM" = "1" ]; then
    step "停用非必要后台服务（省内存）"
    for _s in netifyd gl_dpi gl_dpi_flow_statistics; do
        if [ -x "/etc/init.d/$_s" ]; then
            run /etc/init.d/"$_s" disable
            run /etc/init.d/"$_s" stop
            say "  已停用 $_s"
        fi
    done
    if grep -q '^worker_processes 2;' /etc/nginx/nginx.conf 2>/dev/null; then
        backup /etc/nginx/nginx.conf
        run sed -i 's/^worker_processes 2;/worker_processes 1;/' /etc/nginx/nginx.conf
        run /etc/init.d/nginx reload
        say "  nginx worker_processes 2 -> 1"
    else
        say "  nginx worker 已是 1 或配置不存在"
    fi
fi

# ---------------------------------------------------------------------------
# 9. 收尾
# ---------------------------------------------------------------------------
step "完成"
if [ "$DRY" = "1" ]; then
    say "  dry-run 结束，未做任何修改"
    exit 0
fi
[ -d "$BACKUP_DIR" ] && say "  本次备份：$BACKUP_DIR"
say "  当前可用内存：$(awk '/MemAvailable/{print int($2/1024)"MB"}' /proc/meminfo)"
say ""
say "  下一步："
say "    sh $SWITCH_DST status      # 看状态"
say "    拨动开关                    # 实际验证（或 OCSW_IGNORE_POS=1 sh $SWITCH_DST on）"
say "    tail -f /tmp/openclash-switch.log"
exit 0
