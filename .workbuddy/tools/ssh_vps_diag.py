#!/usr/bin/env python3
"""VPS SSH 登录失败诊断（Windows 本机可用）

背景：本机直连 22 端口常被 RST，而经 --proxy 指定的 HTTP CONNECT 代理
可以正常建立 TCP 连接，因此用「HTTP CONNECT 隧道 + paramiko」来绕开直连限制，
在本地完成对 VPS sshd 的连通性、认证方式、主机密钥、登录日志取证。

用法：
    set SSH_TEST_PW=你的口令
    python ssh_vps_diag.py --host 1.2.3.4 [--user root] [--proxy host:port]
                           [--section probe|auth|keys|log|all]

依赖：paramiko（隔离环境 C:\\Users\\shang\\.workbuddy\\binaries\\python\\envs\\default）
注意：仅对自有服务器使用；口令只从环境变量读取，不落盘。
"""
import argparse
import os
import socket
import sys
import time

try:
    import paramiko
except ImportError:
    sys.exit("缺少 paramiko：pip install paramiko")


def parse_proxy(s):
    if not s:
        return None
    host, _, port = s.partition(":")
    return (host, int(port or 8080))


def tunnel(proxy, host, port, timeout=15):
    """经 HTTP 代理 CONNECT 建立到 host:port 的原始 TCP 连接。"""
    if proxy is None:
        return socket.create_connection((host, port), timeout=timeout)
    s = socket.create_connection(proxy, timeout=timeout)
    s.sendall(("CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n\r\n" % (host, port, host, port)).encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        d = s.recv(4096)
        if not d:
            break
        buf += d
    if b" 200" not in buf.split(b"\r\n", 1)[0]:
        raise RuntimeError("代理拒绝 CONNECT：%r" % buf.split(b"\r\n", 1)[0])
    return s


def probe_direct(host, port, timeout=8):
    t0 = time.time()
    try:
        s = socket.create_connection((host, port), timeout=timeout)
        s.settimeout(4)
        try:
            banner = s.recv(128).decode(errors="replace").strip()
        except Exception:
            banner = ""
        s.close()
        return "OPEN %dms %s" % (int((time.time() - t0) * 1000), banner)
    except Exception as e:
        return "FAIL %dms %r" % (int((time.time() - t0) * 1000), e)


def run(t, cmd, timeout=40):
    chan = t.open_session(timeout=10)
    chan.settimeout(timeout)
    chan.exec_command(cmd)
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
    chan.close()
    return out.decode(errors="replace").rstrip()


SECTIONS = {
    "keys": [
        ("主机密钥指纹", "for f in /etc/ssh/ssh_host_*.pub; do ssh-keygen -lf $f; done; echo '--- 原始公钥 ---'; cat /etc/ssh/ssh_host_*_key.pub"),
        ("密钥文件时间", "ls -la --time-style=long-iso /etc/ssh/ssh_host_*"),
    ],
    "auth": [
        ("生效配置", "sshd -T 2>/dev/null | grep -Ei '^(port|listenaddress|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|permitemptypasswords|usepam|maxauthtries|allowusers|denyusers)'"),
        ("防火墙", "iptables -S 2>/dev/null | head -30; echo '--- 封禁组件 ---'; systemctl is-active fail2ban 2>/dev/null; faillock --user root 2>/dev/null | tail -5"),
        ("监听端口", "ss -ltnp 2>/dev/null | sort -k4"),
    ],
    "log": [
        ("成功登录", "journalctl -u ssh -u sshd --since today --no-pager 2>/dev/null | grep Accepted | tail -25"),
        ("失败的口令认证", "journalctl -u ssh -u sshd --since today --no-pager 2>/dev/null | grep 'Failed password' | tail -25"),
        ("来源 IP 统计", "journalctl -u ssh -u sshd --since today --no-pager 2>/dev/null | grep -oE 'from [0-9.]+' | sort | uniq -c | sort -rn | head -15"),
        ("连接被关闭（未完成认证）", "journalctl -u ssh -u sshd --since today --no-pager 2>/dev/null | grep -oE 'Connection closed by +[0-9.]+' | awk '{print $NF}' | sort | uniq -c | sort -rn | head -15"),
        ("重启/密钥重生成线索", "journalctl --list-boots 2>/dev/null | tail -5; journalctl -u ssh -u sshd --since today --no-pager 2>/dev/null | head -12"),
    ],
    "probe": [
        ("端口与指纹", "cat /etc/os-release | head -2; uptime; sshd -V 2>&1 | head -1"),
        ("docker", "docker ps --format '{{.Names}} | {{.Image}} | {{.Ports}}' 2>/dev/null"),
    ],
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--user", default="root")
    ap.add_argument("--port", type=int, default=22)
    ap.add_argument("--proxy", default=os.environ.get("SSH_PROXY", ""),
                    help="HTTP 代理 host:port，留空表示直连")
    ap.add_argument("--section", default="all", choices=["probe", "auth", "keys", "log", "all"])
    ap.add_argument("--pw-env", default="SSH_TEST_PW")
    args = ap.parse_args()

    pw = os.environ.get(args.pw_env, "")
    proxy = parse_proxy(args.proxy)

    print("## 直连测试（本机网络路径）")
    for p in (22, 443, 80, 8443):
        print("   %s:%-5d %s" % (args.host, p, probe_direct(args.host, p)))
    print("   对照: github.com:22    %s" % probe_direct("github.com", 22))
    print("   对照: ssh.github.com:443 %s" % probe_direct("ssh.github.com", 443))

    print("\n## 经代理 %s 连接 %s:%d" % (proxy or "(直连)", args.host, args.port))
    try:
        sock = tunnel(proxy, args.host, args.port)
    except Exception as e:
        sys.exit("   隧道建立失败：%r" % e)
    t = paramiko.Transport(sock)
    t.start_client(timeout=20)
    print("   服务端版本: %s" % t.remote_version)

    try:
        t.auth_none(args.user)
        print("   认证方式: none（服务端未要求认证，异常）")
    except paramiko.BadAuthenticationType as e:
        print("   认证方式: %s" % ", ".join(e.allowed_types))
    except paramiko.AuthenticationException as e:
        print("   认证方式: 查询被拒 %s" % e)

    if not pw:
        print("   未提供口令（环境变量 %s 为空），跳过登录取证" % args.pw_env)
        return
    try:
        t.auth_password(args.user, pw)
        print("   口令认证: 成功（口令有效）")
    except paramiko.AuthenticationException as e:
        print("   口令认证: 失败 -> %s（口令错误或该用户不允许口令登录）" % e)
        return

    want = ["probe", "auth", "keys", "log"] if args.section == "all" else [args.section]
    for sec in want:
        for name, cmd in SECTIONS[sec]:
            print("\n########## [%s] %s ##########" % (sec, name))
            print(run(t, cmd))
    t.close()


if __name__ == "__main__":
    main()
