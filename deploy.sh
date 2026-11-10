#!/bin/sh
# ============================================================================
#  deploy.sh — 在本地电脑上运行：把本仓库推到路由器并执行 install.sh
#
#  用法：
#    ./deploy.sh --setup-key              # 【首次】生成专用密钥并用密码装到路由器，只需输一次密码
#    ./deploy.sh                          # 部署全部（开关模块 + 自动更新 + 通知 + cron）
#    ./deploy.sh --switch-only            # 只装拨动开关模块
#    ./deploy.sh --tune-openclash --trim-services
#    ./deploy.sh --dry-run                # 只打印计划
#    ./deploy.sh --status                 # 不安装，只看设备当前状态
#
#  连接参数（环境变量）：
#    ROUTER_HOST=192.168.8.1  ROUTER_USER=root  ROUTER_PORT=22
#    ROUTER_KEY=~/.ssh/id_ed25519_glinet       # 专用私钥，存在则自动带 -i
#    ROUTER_SSH_OPTS='-o StrictHostKeyChecking=accept-new'
#
#  为什么需要 --setup-key：
#    GL.iNet 固件跑 dropbear，公钥要放进 /etc/dropbear/authorized_keys，
#    不是 ssh-copy-id 默认写的 ~/.ssh/authorized_keys。装好之后本脚本会自动
#    带上 -i <专用密钥>，不再提示密码。
#
#  ~/.ssh/config 里的 Host * 若开了 ForwardX11/ForwardAgent，命令行用 -o 关掉：
#    -o 参数优先级高于 config，避免每次连接的 xauth 噪音和把 agent 转给路由器。
# ============================================================================

set -u

HOST="${ROUTER_HOST:-192.168.8.1}"
USER="${ROUTER_USER:-root}"
PORT="${ROUTER_PORT:-22}"
SSH_OPTS="${ROUTER_SSH_OPTS:--o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ForwardX11=no -o ForwardAgent=no}"
KEY="${ROUTER_KEY:-$HOME/.ssh/id_ed25519_glinet}"

HERE=$(cd "$(dirname "$0")" && pwd)
REMOTE_PKG=/tmp/oc-pkg

KEY_OPTS=""
[ -f "$KEY" ] && KEY_OPTS="-i $KEY -o IdentitiesOnly=yes"

MODE=install
ARGS=""

for _a in "$@"; do
    case "$_a" in
        --setup-key) MODE=setup-key ;;
        --status)    MODE=status ;;
        -h|--help)   sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           ARGS="$ARGS $_a" ;;
    esac
done

rssh() {
    # shellcheck disable=SC2086
    ssh $KEY_OPTS $SSH_OPTS -p "$PORT" "$USER@$HOST" "$1"
}

# ---------------------------------------------------------------------------
# 首次：生成密钥 + 用密码装公钥
# ---------------------------------------------------------------------------
if [ "$MODE" = "setup-key" ]; then
    if [ -f "$KEY" ]; then
        printf '密钥已存在：%s\n' "$KEY"
    else
        printf '生成专用密钥：%s\n' "$KEY"
        ssh-keygen -t ed25519 -f "$KEY" -N '' -C "$USER@$HOST" || exit 1
    fi
    PUB=$(cat "$KEY.pub")
    printf '\n用密码登录一次，把公钥写入 /etc/dropbear/authorized_keys ...\n'
    # shellcheck disable=SC2086
    ssh $SSH_OPTS -p "$PORT" -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        "$USER@$HOST" \
        "cp -n /etc/dropbear/authorized_keys /etc/dropbear/authorized_keys.bak-\$(date +%Y%m%d) 2>/dev/null; grep -qF '$PUB' /etc/dropbear/authorized_keys || printf '%s\n' '$PUB' >> /etc/dropbear/authorized_keys; chmod 600 /etc/dropbear/authorized_keys; echo 公钥已写入"
    [ $? = 0 ] || exit 1
    printf '\n验证免密 ...\n'
    # shellcheck disable=SC2086
    if ssh -i "$KEY" -o IdentitiesOnly=yes $SSH_OPTS -p "$PORT" -o BatchMode=yes \
        "$USER@$HOST" true 2>/dev/null; then
        printf '免密可用。以后直接 ./deploy.sh 即可，不用再输密码。\n'
        exit 0
    fi
    printf '公钥已写入但免密验证失败，请检查路由器上 /etc/dropbear/authorized_keys 的权限\n' >&2
    exit 1
fi

if ! rssh "true" 2>/dev/null; then
    printf '无法连接 %s@%s:%s\n' "$USER" "$HOST" "$PORT" >&2
    printf '  1) 确认电脑和路由器在同一网段，且已在 GL 后台启用 SSH\n' >&2
    printf '  2) 首次使用请先跑一次：./deploy.sh --setup-key（输一次密码，之后免密）\n' >&2
    printf '  3) 若手工配置了密钥，检查 ROUTER_KEY 或 ~/.ssh/config\n' >&2
    exit 1
fi

if [ "$MODE" = "status" ]; then
    rssh "sh /etc/gl-switch.d/openclash.sh status 2>/dev/null; echo; sh /etc/openclash-auto-update.sh status 2>/dev/null; echo; sh /etc/openclash-notify.sh status 2>/dev/null"
    exit $?
fi

printf '打包并上传到 %s:%s ...\n' "$HOST" "$REMOTE_PKG"
# 只推必要文件：install.sh + scripts/（含 gl-switch.d/ 与 cgi-bin/）
tar -czf - -C "$HERE" install.sh scripts \
    | rssh "rm -rf $REMOTE_PKG && mkdir -p $REMOTE_PKG && tar -xzf - -C $REMOTE_PKG && echo uploaded"

printf '\n在设备上执行 install.sh%s\n' "$ARGS"
# shellcheck disable=SC2086
rssh "sh $REMOTE_PKG/install.sh$ARGS"
RC=$?

printf '\n远程包保留在 %s（可手动差量重装：sh %s/install.sh）\n' "$REMOTE_PKG" "$REMOTE_PKG"
exit $RC
