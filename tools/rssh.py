#!/usr/bin/env python3
"""
rssh.py — 命令行/脚本化访问 GL.iNet 路由器的小工具（HTTP/SCP 都不可用时的替补）

为什么需要它：
  部分固件只跑 dropbear，没有 sftp 子系统，scp 会失败；Windows 上也不一定有
  sshpass。这个脚本用 paramiko 走纯 exec 通道，顺便提供 `--put`（用 cat > 上传）
  和 `--get`（用 cat 下载）。

依赖：pip install paramiko

配置（环境变量，不要写死在代码里）：
  ROUTER_HOST   默认 192.168.8.1
  ROUTER_USER   默认 root
  ROUTER_PORT   默认 22
  ROUTER_PASS   不设则交互式询问

例子：
  python3 rssh.py 'uci show openclash | grep enable'
  python3 rssh.py --timeout 600 '/etc/init.d/openclash start'
  python3 rssh.py --put ./openclash.sh /etc/gl-switch.d/openclash.sh
  python3 rssh.py --get /tmp/openclash-switch.log > switch.log
"""
import argparse
import getpass
import os
import sys

try:
    import paramiko
except ImportError:
    sys.exit("缺少 paramiko：pip install paramiko")


def connect(args):
    password = os.environ.get("ROUTER_PASS") or args.password
    if not password:
        password = getpass.getpass(f"{args.user}@{args.host} password: ")

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(
        args.host, port=args.port, username=args.user, password=password,
        timeout=12, banner_timeout=20, auth_timeout=20,
        look_for_keys=False, allow_agent=False,
    )
    return client


def run(client, cmd, timeout):
    stdin, stdout, stderr = client.exec_command(cmd, timeout=timeout)
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    rc = stdout.channel.recv_exit_status()
    return out, err, rc


def main():
    p = argparse.ArgumentParser(description="SSH helper for GL.iNet routers")
    p.add_argument("command", nargs="*", help="remote command")
    p.add_argument("--host", default=os.environ.get("ROUTER_HOST", "192.168.8.1"))
    p.add_argument("--user", default=os.environ.get("ROUTER_USER", "root"))
    p.add_argument("--port", type=int, default=int(os.environ.get("ROUTER_PORT", "22")))
    p.add_argument("--password", default=os.environ.get("ROUTER_PASS"))
    p.add_argument("--timeout", type=int, default=120, help="命令超时秒数（默认 120）")
    p.add_argument("--put", nargs=2, metavar=("LOCAL", "REMOTE"), help="上传文件")
    p.add_argument("--get", metavar="REMOTE", help="下载文件到 stdout")
    p.add_argument("--chmod", default="755", help="--put 之后设置的权限（默认 755）")
    args = p.parse_args()

    client = connect(args)

    if args.put:
        local, remote = args.put
        with open(local, "rb") as fh:
            data = fh.read()
        # 先写临时文件再 mv，避免传输中断留下半个脚本（脚本被截断会静默失败）
        stdin, stdout, stderr = client.exec_command(
            f"cat > {remote}.tmp && chmod {args.chmod} {remote}.tmp && mv -f {remote}.tmp {remote}"
        )
        stdin.write(data)
        stdin.channel.shutdown_write()
        rc = stdout.channel.recv_exit_status()
        err = stderr.read().decode("utf-8", "replace").strip()
        print(f"put {local} -> {remote} ({len(data)} bytes, rc={rc}){' ' + err if err else ''}")
        client.close()
        return 0 if rc == 0 else rc

    if args.get:
        out, err, rc = run(client, f"cat {args.get}", args.timeout)
        sys.stdout.write(out)
        if err.strip():
            sys.stderr.write(err)
        client.close()
        return rc

    cmd = " ".join(args.command) if args.command else sys.stdin.read()
    if not cmd.strip():
        p.error("需要一条远程命令，或用 --put / --get")
    out, err, rc = run(client, cmd, args.timeout)
    sys.stdout.write(out)
    if err.strip():
        sys.stdout.write("\n[stderr]\n" + err)
    sys.stdout.write(f"\n[rc={rc}]\n")
    client.close()
    return rc


if __name__ == "__main__":
    sys.exit(main())
