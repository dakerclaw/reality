#!/bin/bash
# 只读侦察：fail2ban 安装前需要知道的信息
echo "###1 系统"
cat /etc/os-release | head -3
uname -r

echo
echo "###2 包管理与网络"
command -v apt-get && apt-get -v 2>/dev/null | head -1
echo "--- 源可达性(HEAD deb.debian.org) ---"
timeout 12 bash -c 'exec 3<>/dev/tcp/deb.debian.org/80 && echo "deb.debian.org:80 OK"' 2>&1 || echo "deb.debian.org:80 FAIL"

echo
echo "###3 fail2ban 现状"
command -v fail2ban-client || echo "(未安装 fail2ban-client)"
systemctl is-active fail2ban 2>&1
systemctl is-enabled fail2ban 2>&1
ls -la /etc/fail2ban/ 2>/dev/null || echo "(无 /etc/fail2ban 目录)"

echo
echo "###4 日志后端"
ls -la /var/log/auth.log 2>/dev/null || echo "(无 /var/log/auth.log)"
systemctl is-active systemd-journald 2>&1
dpkg -l python3-systemd 2>/dev/null | tail -1 || echo "(python3-systemd 未安装)"
ls /usr/lib/python3/dist-packages/systemd 2>/dev/null | head -2 || echo "(无 python systemd 模块)"

echo
echo "###5 封禁动作可用性（iptables / nftables）"
for c in iptables ip6tables nft; do printf "%s: " "$c"; command -v $c || echo MISSING; done
iptables -V 2>&1 | head -1
echo "--- action.d 中相关动作 ---"
ls /etc/fail2ban/action.d/ 2>/dev/null | grep -E '^(iptables-multiport|nftables-multiport|nftables)\.conf$' || echo "(fail2ban 未安装，动作文件尚未就位)"

echo
echo "###6 已有 jail 配置"
cat /etc/fail2ban/jail.d/*.conf 2>/dev/null || echo "(无 jail.d/*.conf)"
grep -E '^\s*(backend|banaction|ignoreip|maxretry|findtime|bantime)\s*=' /etc/fail2ban/jail.conf 2>/dev/null | head -20

echo
echo "###7 sshd 监听与当前封禁面"
ss -ltnp 2>/dev/null | grep -E ':22\b'
echo "--- ipset/nft set 现状 ---"
nft list sets 2>/dev/null | head -10 || echo "(nft 不可用或无 set)"
ipset list 2>/dev/null | head -5 || echo "(无 ipset)"

echo
echo "###8 今日爆破来源 TOP10"
journalctl -u ssh -u sshd --since today --no-pager 2>/dev/null | grep -oE 'from [0-9.]+' | sort | uniq -c | sort -rn | head -10

echo
echo "###9 当前登录会话（避免误封自己）"
who 2>/dev/null
last -n 8 2>/dev/null
