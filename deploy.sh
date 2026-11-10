#!/bin/sh
# ============================================================================
#  deploy.sh — 在本地电脑上运行：把本仓库推到路由器并执行 install.sh
#
#  用法：
#    ./deploy.sh                          # 部署全部（开关模块 + 自动更新 + cron）
#    ./deploy.sh --switch-only            # 只装拨动开关模块
#    ./deploy.sh --tune-openclash --trim-services
#    ./deploy.sh --dry-run                # 只打印计划
#    ./deploy.sh --status                 # 不安装，只看设备当前状态
#
#  连接参数（环境变量，也可用命令行覆盖）：
#    ROUTER_HOST=192.168.8.1  ROUTER_USER=root  ROUTER_PORT=22
#    ROUTER_SSH_OPTS='-o StrictHostKeyChecking=accept-new'
#
#  免密（推荐）：把本机公钥装到路由器
#    ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.8.1
#  没有免密时会提示输密码（一次部署输入 1~2 次）。
# ============================================================================

set -u

HOST="${ROUTER_HOST:-192.168.8.1}"
USER="${ROUTER_USER:-root}"
PORT="${ROUTER_PORT:-22}"
SSH_OPTS="${ROUTER_SSH_OPTS:--o StrictHostKeyChecking=accept-new -o ConnectTimeout=10}"

HERE=$(cd "$(dirname "$0")" && pwd)
REMOTE_PKG=/tmp/oc-pkg

MODE=install
ARGS=""

for _a in "$@"; do
    case "$_a" in
        --status) MODE=status ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) ARGS="$ARGS $_a" ;;
    esac
done

rssh() {
    # shellcheck disable=SC2086
    ssh $SSH_OPTS -p "$PORT" "$USER@$HOST" "$1"
}

if ! rssh "true" 2>/dev/null; then
    printf '无法连接 %s@%s:%s\n' "$USER" "$HOST" "$PORT" >&2
    printf '  1) 确认电脑和路由器在同一网段\n  2) 确认已在 GL 后台启用 SSH\n  3) 首次连接先手动 ssh 一次接受指纹\n' >&2
    exit 1
fi

if [ "$MODE" = "status" ]; then
    rssh "sh /etc/gl-switch.d/openclash.sh status 2>/dev/null; echo; sh /etc/openclash-auto-update.sh status 2>/dev/null"
    exit $?
fi

printf '打包并上传到 %s:%s ...\n' "$HOST" "$REMOTE_PKG"
# 只推必要文件：install.sh + scripts/
tar -czf - -C "$HERE" install.sh scripts \
    | rssh "rm -rf $REMOTE_PKG && mkdir -p $REMOTE_PKG && tar -xzf - -C $REMOTE_PKG && echo uploaded"

printf '\n在设备上执行 install.sh%s\n' "$ARGS"
# shellcheck disable=SC2086
rssh "sh $REMOTE_PKG/install.sh$ARGS"
RC=$?

printf '\n远程包保留在 %s（可手动差量重装：sh %s/install.sh）\n' "$REMOTE_PKG" "$REMOTE_PKG"
exit $RC
