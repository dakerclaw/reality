#!/usr/bin/env python3
"""经 HTTP CONNECT 隧道从 VPS 拉取文件到本地（Windows 本机可用）。

用法：
    SSH_TEST_PW=xxx python vps_ssh_pull.py --host 1.2.3.4 \
        --remote /root/backup.zip --local .workbuddy/tmp/backup.zip

口令只从环境变量读取，不落盘、不进 argv。
"""
import argparse
import hashlib
import os
import socket
import sys

import paramiko

from vps_ssh_run import parse_proxy, tunnel


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--user", default="root")
    ap.add_argument("--port", type=int, default=22)
    ap.add_argument("--proxy", default=os.environ.get("SSH_PROXY", ""))
    ap.add_argument("--remote", required=True, help="远端文件绝对路径")
    ap.add_argument("--local", required=True, help="本地保存路径")
    ap.add_argument("--pw-env", default="SSH_TEST_PW")
    args = ap.parse_args()

    pw = os.environ.get(args.pw_env, "")
    if not pw:
        sys.exit("环境变量 %s 为空" % args.pw_env)

    sock = tunnel(parse_proxy(args.proxy), args.host, args.port)
    t = paramiko.Transport(sock)
    t.start_client(timeout=20)
    t.auth_password(args.user, pw)

    sftp = t.open_sftp_client()
    size = sftp.stat(args.remote).st_size
    print("远端 %s (%d bytes) -> %s" % (args.remote, size, args.local))

    local_dir = os.path.dirname(os.path.abspath(args.local))
    if local_dir:
        os.makedirs(local_dir, exist_ok=True)
    sftp.get(args.remote, args.local)
    sftp.close()

    # 远端 sha256，避免只看大小就下结论
    chan = t.open_session(timeout=20)
    chan.exec_command("sha256sum %s" % args.remote)
    remote_sha = chan.makefile("r").read().split()[0]
    if isinstance(remote_sha, bytes):
        remote_sha = remote_sha.decode()
    chan.close()
    t.close()

    with open(args.local, "rb") as fh:
        local_sha = hashlib.sha256(fh.read()).hexdigest()

    print("远端 sha256: %s" % remote_sha)
    print("本地 sha256: %s" % local_sha)
    print("校验: %s" % ("MATCH" if remote_sha == local_sha else "DIFF"))
    sys.exit(0 if remote_sha == local_sha else 1)


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    main()
