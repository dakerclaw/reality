#!/usr/bin/env python3
"""通过 HTTP CONNECT 隧道在远端 VPS 上执行本地 shell 脚本（Windows 本机可用）。

为什么需要它：本机直连 22 端口可能被拦，可用 --proxy 走 HTTP CONNECT 隧道；
paramiko 的 exec_command 直接传多行命令在 Windows bash 下引号极难处理，
所以改为「把本地 .sh 文件内容整体作为远端 shell 脚本执行」。

用法：
    SSH_TEST_PW=xxx python vps_ssh_run.py --host 1.2.3.4 --file ops/recon.sh [--timeout 300]
    SSH_TEST_PW=xxx python vps_ssh_run.py --host 1.2.3.4 --cmd 'uptime'

口令只从环境变量读取，不落盘、不进 argv。
"""
import argparse
import os
import socket
import sys
import time

import paramiko


def parse_proxy(s):
    """解析 host:port。容忍 "http://host:port" 这类带 scheme 的写法。

    只取第一段冒号会踩坑："http://1.2.3.4:12345" 会被切成 host="http"、
    port="//1.2.3.4:12345" 然后 int() 抛 ValueError。先把 scheme 与路径剥掉。
    """
    if not s:
        return None
    s = s.strip()
    if "://" in s:
        s = s.split("://", 1)[1]
    s = s.split("/", 1)[0]
    if s.startswith("[") and "]" in s:  # IPv6 字面量 [::1]:8080
        host, _, rest = s[1:].partition("]")
        port = rest.lstrip(":")
    else:
        host, _, port = s.rpartition(":")
        if not host:  # 没有冒号，纯 host
            host, port = port, ""
    return (host, int(port or 8080))


def tunnel(proxy, host, port, timeout=20):
    """经 HTTP 代理 CONNECT 建立到 host:port 的原始 TCP 连接。"""
    if proxy is None:
        return socket.create_connection((host, port), timeout=timeout)
    s = socket.create_connection(proxy, timeout=timeout)
    s.sendall(("CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n\r\n"
               % (host, port, host, port)).encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        d = s.recv(4096)
        if not d:
            break
        buf += d
    if b" 200" not in buf.split(b"\r\n", 1)[0]:
        raise RuntimeError("代理拒绝 CONNECT：%r" % buf.split(b"\r\n", 1)[0])
    return s


def run_script(t, script, timeout):
    """在远端以 bash -s 执行脚本内容，边收边打印。返回 (stdout, exit_code)。"""
    chan = t.open_session(timeout=20)
    chan.settimeout(timeout)
    chan.exec_command("bash -s")
    stdin = chan.makefile_stdin("wb", -1)
    # 开头关掉交互式提示，避免 apt/dpkg 卡在对话框
    stdin.write(b"export DEBIAN_FRONTEND=noninteractive\n")
    stdin.write(script.encode() if isinstance(script, str) else script)
    stdin.write(b"\nexit\n")
    stdin.flush()
    stdin.close()

    out = b""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if chan.recv_ready():
            out += chan.recv(65536)
        elif chan.exit_status_ready():
            while chan.recv_ready():
                out += chan.recv(65536)
            break
        else:
            time.sleep(0.1)
    code = chan.recv_exit_status()
    chan.close()
    return out.decode(errors="replace"), code


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--user", default="root")
    ap.add_argument("--port", type=int, default=22)
    ap.add_argument("--proxy", default=os.environ.get("SSH_PROXY", ""),
                    help="HTTP 代理 host:port，留空表示直连")
    ap.add_argument("--file", help="要执行的本地 shell 脚本")
    ap.add_argument("--cmd", help="直接执行的单条命令")
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--pw-env", default="SSH_TEST_PW")
    args = ap.parse_args()

    if not args.file and not args.cmd:
        sys.exit("必须给 --file 或 --cmd")
    script = open(args.file, "r", encoding="utf-8").read() if args.file else args.cmd

    pw = os.environ.get(args.pw_env, "")
    if not pw:
        sys.exit("环境变量 %s 为空" % args.pw_env)
    proxy = parse_proxy(args.proxy)

    print("== 经代理 %s 连接 %s@%s:%d ==" % (proxy or "(直连)", args.user, args.host, args.port))
    sock = tunnel(proxy, args.host, args.port)
    t = paramiko.Transport(sock)
    t.start_client(timeout=20)
    print("   服务端: %s" % t.remote_version)
    t.auth_password(args.user, pw)
    print("   认证成功，开始执行\n" + "-" * 60)

    out, code = run_script(t, script, args.timeout)
    t.close()
    print(out)
    print("-" * 60)
    print("== 远端退出码: %d ==" % code)
    sys.exit(0 if code == 0 else 1)


if __name__ == "__main__":
    main()
