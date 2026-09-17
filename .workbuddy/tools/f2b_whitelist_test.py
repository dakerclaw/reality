#!/usr/bin/env python3
"""白名单实测：从「自己的代理出口 IP」故意做 6 次错误口令登录，验证 fail2ban 不会封它。

受控点：
  * 本机代理的出口 IP 已在 fail2ban 的 ignoreip 白名单中（部署时由 WHITELIST 指定）；
  * 演练前已把 sshd 的 bantime 临时压到 60 秒，万一白名单失效也只是 60 秒自动解锁；
  * 演练前已暂停 recidive（避免升级为「全网端口封一周」）。

判定标准：
  1) 重连依然成功（说明没被封锁）；
  2) Banned IP list 里没有该出口 IP；
  3) sshd jail 的 "Currently failed" 未因这 6 次失败而增加（说明失败事件在计数前就被忽略）。

所有地址都从环境变量取，脚本里不写死任何主机：
  VPS_HOST（必填）、VPS_PORT（默认 22）、VPS_USER（默认 root）、
  SSH_PROXY（host:port，留空表示直连）。
"""
import os
import socket
import sys
import time

import paramiko

HOST = os.environ.get("VPS_HOST", "")
USER = os.environ.get("VPS_USER", "root")
PORT = int(os.environ.get("VPS_PORT", "22"))
PROXY = tuple(os.environ.get("SSH_PROXY", "").split(":")) if os.environ.get("SSH_PROXY") else None
if PROXY:
    PROXY = (PROXY[0], int(PROXY[1]))
BADPW = "definitely-not-the-password-xyz"
N = 6

if not HOST:
    sys.exit("环境变量 VPS_HOST 为空")
GOOD = os.environ.get("SSH_TEST_PW", "")
if not GOOD:
    sys.exit("环境变量 SSH_TEST_PW 为空")


def tunnel(host, port, timeout=20):
    if PROXY is None:
        return socket.create_connection((host, port), timeout=timeout)
    s = socket.create_connection(PROXY, timeout=timeout)
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


def connect(pw):
    sock = tunnel(HOST, PORT)
    t = paramiko.Transport(sock)
    t.start_client(timeout=20)
    t.auth_password(USER, pw)
    return t


def run(t, cmd, timeout=40):
    chan = t.open_session(timeout=15)
    chan.settimeout(timeout)
    chan.exec_command(cmd)
    out = b""
    end = time.time() + timeout
    while time.time() < end:
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


print("== 阶段 1：定位本次复盘会话的出口 IP ==")
t = connect(GOOD)
egress = run(t, "echo \"SSH_CLIENT=$SSH_CLIENT\"")
print("   " + egress.replace("\n", "\n   "))
src_ip = egress.split("SSH_CLIENT=")[1].split()[0] if "SSH_CLIENT=" in egress else ""
print("   本会话源 IP = %s" % src_ip)

before_status = run(t, "fail2ban-client status sshd")
before_failed = 0
for line in before_status.splitlines():
    if "Currently failed" in line:
        before_failed = int(line.split(":")[-1].strip())
print("   演练前 Currently failed = %d" % before_failed)
t.close()

print("\n== 阶段 2：从该出口 IP 故意做 %d 次错误口令登录 ==" % N)
for i in range(1, N + 1):
    try:
        sock = tunnel(HOST, PORT)
        tt = paramiko.Transport(sock)
        tt.start_client(timeout=20)
        try:
            tt.auth_password(USER, BADPW)
            print("   #%d 意外成功（不应该）" % i)
        except paramiko.AuthenticationException:
            print("   #%d 认证被拒（预期）" % i)
        tt.close()
    except Exception as e:
        print("   #%d 异常 %r" % (i, e))
    time.sleep(1.5)

print("\n   等待 fail2ban 消费 journal（8 秒）…")
time.sleep(8)

print("\n== 阶段 3：重连并检查（若被封则自动重试，最长 150 秒）==")
t = None
deadline = time.time() + 150
waited = 0
while time.time() < deadline:
    try:
        t = connect(GOOD)
        print("   ✓ 重连成功（未被封锁）—— 等待了 %d 秒" % waited)
        break
    except paramiko.AuthenticationException:
        print("   ✗ 口令被拒（不该发生，口令无误）")
        break
    except Exception as e:
        waited += 10
        print("   … 连不上（%s），等 10 秒重试" % type(e).__name__)
        time.sleep(10)

if t is None:
    print("\n  !! 无法重连，白名单很可能未生效。60 秒后会自动解锁，请等待后重试。")
    sys.exit(2)

status = run(t, "fail2ban-client status sshd")
after_failed = 0
for line in status.splitlines():
    if "Currently failed" in line:
        after_failed = int(line.split(":")[-1].strip())

banned_line = ""
for line in status.splitlines():
    if "Banned IP list" in line:
        banned_line = line

ignored = run(t, "fail2ban-client get sshd ignoreip")
hit_log = run(t, "journalctl -u ssh -u sshd --since '5 minutes ago' --no-pager 2>/dev/null "
                 "| grep -c 'Failed password for root from %s'" % src_ip)

print("\n   Banned IP list : %s" % banned_line.strip())
print("   Currently failed: 演练前=%d  演练后=%d" % (before_failed, after_failed))
print("   该 IP 在 5 分钟内产生的 Failed password 行数（journal 原始记录）: %s" % hit_log.strip())
print("   白名单内容:")
for l in ignored.splitlines():
    print("     " + l)

verdict = []
verdict.append(("重连成功（未被锁）", True))
verdict.append(("出口 IP 不在封禁列表", src_ip not in banned_line))
verdict.append(("失败计数未增加（事件在计数前被忽略）", after_failed <= before_failed))
verdict.append(("白名单确实包含该出口 IP", src_ip in ignored))

print("\n== 结论 ==")
for name, ok in verdict:
    print("   [%s] %s" % ("PASS" if ok else "FAIL", name))

print("\n== 阶段 4：恢复正式配置（bantime 回 7200、recidive 重新启用）==")
print(run(t, "systemctl restart fail2ban; sleep 4; "
            "echo '--服务--'; systemctl is-active fail2ban; systemctl is-enabled fail2ban; "
            "echo '--jail--'; fail2ban-client status; "
            "echo '--bantime--'; fail2ban-client get sshd bantime; "
            "echo '--ignoreip--'; fail2ban-client get sshd ignoreip"))
t.close()

sys.exit(0 if all(ok for _, ok in verdict) else 1)
