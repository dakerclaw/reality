#!/bin/bash
# ============================================================================
# f2b_harden.sh —— Debian 13 上安装并配置 fail2ban（含 SSH 白名单）
#
# 用途：在 VPS 上一次性装好 fail2ban，封禁 SSH 暴力破解，同时把自己的出口 IP
#       加入白名单。可重复执行（幂等）。
#
# 用法（在 VPS 上以 root 执行）：
#     WHITELIST="1.2.3.4 5.6.7.8" bash f2b_harden.sh
#   不传 WHITELIST 时只保留回环地址。
#
# 执行后自检：
#     fail2ban-client status              # 应列出 sshd（及 recidive）
#     fail2ban-client get sshd ignoreip   # 应含你的出口 IP
#     fail2ban-client set sshd banip 203.0.113.99    # 演练封禁（RFC5737 保留地址）
#     nft list table inet f2b-table                  # 确认落到内核
#     fail2ban-client set sshd unbanip 203.0.113.99  # 撤销演练
#
# 注意：白名单只是「免于被封」，不等于免密登录；它不改变 sshd 的认证要求。
# ============================================================================
set -u
export DEBIAN_FRONTEND=noninteractive

WL_EXTRA="${WHITELIST:-}"
IGNOREIP="127.0.0.1/8 ::1"
for ip in $WL_EXTRA; do IGNOREIP="$IGNOREIP $ip"; done

echo "== 1/4 安装 fail2ban + python3-systemd（Debian 13 无 auth.log，需 systemd 后端）=="
apt-get update -qq
apt-get install -y -qq fail2ban python3-systemd

echo
echo "== 2/4 写入 /etc/fail2ban/jail.local（白名单: $IGNOREIP）=="
[ -f /etc/fail2ban/jail.local ] && cp -a /etc/fail2ban/jail.local "/root/jail.local.bak-$(date +%Y%m%d-%H%M%S)"

cat > /etc/fail2ban/jail.local <<EOF
# 由 f2b_harden.sh 生成：$(date '+%F %T')
[DEFAULT]
# SSH 白名单：以下来源永不封禁（注意：白名单只是免封，不等于免密登录）
ignoreip = $IGNOREIP
findtime = 10m
maxretry = 5
bantime  = 2h

[sshd]
enabled      = true
# Debian 13 无 /var/log/auth.log，必须走 journald
backend      = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd
port         = ssh
maxretry     = 4
findtime     = 10m
bantime      = 2h

# 惯犯：被 sshd jail 反复封禁的来源，升级为全网端口封禁一周
[recidive]
enabled   = true
backend   = auto
logpath   = /var/log/fail2ban.log
banaction = %(banaction_allports)s
bantime   = 1w
findtime  = 1d
maxretry  = 3
EOF

echo
echo "== 3/4 语法校验（失败即回滚）=="
if ! fail2ban-client -t; then
  rm -f /etc/fail2ban/jail.local
  systemctl restart fail2ban
  echo "!! 配置校验失败，已回滚"; exit 1
fi

# recidive 依赖 fail2ban.log，缺失时裁掉该段以免服务起不来
if [ ! -f /var/log/fail2ban.log ] && ! systemctl is-active --quiet fail2ban; then
  echo "(recidive 前置条件不足，移除该 jail)"
  sed -i '/^# 惯犯/,$d' /etc/fail2ban/jail.local
fi

echo
echo "== 4/4 启用并验证 =="
systemctl enable --now fail2ban
systemctl restart fail2ban
sleep 4
systemctl is-active fail2ban; systemctl is-enabled fail2ban
fail2ban-client status
fail2ban-client status sshd
echo "--- 白名单 ---"; fail2ban-client get sshd ignoreip
echo "--- 参数 ---"
for k in bantime findtime maxretry; do printf "  %-9s: " "$k"; fail2ban-client get sshd $k; done
echo "--- 内核规则 ---"; nft list table inet f2b-table 2>/dev/null || iptables -S | grep f2b
echo
echo "完成。如需增删白名单（立即生效，不用重启）："
echo "    fail2ban-client set sshd addignoreip  <IP>"
echo "    fail2ban-client set sshd delignoreip  <IP>"
echo "    fail2ban-client set recidive addignoreip <IP>   # recidive 有独立列表"
