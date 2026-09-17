#!/bin/bash
# 卸载 reality。分步校验，任一步不达预期就中止 —— 绝不用非预期版本的脚本做破坏性操作。
# 故意不使用 set -e：需要「校验失败即中止，而不是继续往下删」的显式流程。
set -u

LATEST=/root/reality-latest.sh
EXPECT_SIZE=130017
EXPECT_MD5=bf83058516b5ba0dfd0a7abd85412124
URL=https://raw.githubusercontent.com/dakerclaw/reality/main/reality.sh

echo "############ 1. 获取最新脚本并校验 ############"
rm -f "${LATEST}"
if ! curl -fsSL -m 60 -o "${LATEST}" "${URL}"; then
  echo "!! 下载失败，中止卸载"
  exit 1
fi
SIZE=$(stat -c %s "${LATEST}")
MD5=$(md5sum "${LATEST}" | cut -d' ' -f1)
echo "  实际 size=${SIZE}   md5=${MD5}"
echo "  期望 size=${EXPECT_SIZE}   md5=${EXPECT_MD5}"
if [ "${SIZE}" != "${EXPECT_SIZE}" ] || [ "${MD5}" != "${EXPECT_MD5}" ]; then
  echo "!! 脚本指纹与预期不符，中止卸载"
  exit 1
fi
if ! bash -n "${LATEST}"; then
  echo "!! 语法检查失败，中止卸载"
  exit 1
fi
echo "  OK：指纹与语法均通过（与本地 HEAD 926f4c0 同版本）"

echo
echo "############ 2. 确认卸载目标（globals） ############"
grep -nE '^(config_path|compose_project|tgbot_project)=' "${LATEST}" | sed 's/^/  /'

echo
echo "############ 3. 执行卸载 ############"
bash "${LATEST}" --uninstall
echo "  --uninstall 退出码 = $?"

echo
echo "############ 4. 卸载后核验（独立复核，不采信执行脚本的自我报告） ############"
echo "--- 容器 ---"
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qiE 'reality|tgbot'; then
  docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | grep -iE 'reality|tgbot' | sed 's/^/  !! 残留: /'
else
  echo "  无 reality/tgbot 容器残留"
fi
echo "--- compose 项目 ---"
docker compose ls -a 2>&1 | sed 's/^/  /'
echo "--- 安装目录 ---"
for d in /opt/reality /opt/reality-ezpz; do
  if [ -e "$d" ]; then echo "  !! ${d} 仍存在"; else echo "  ${d} 已删除"; fi
done
echo "--- sysctl drop-in ---"
for f in /etc/sysctl.d/99-reality.conf /etc/sysctl.d/99-reality-ezpz.conf; do
  if [ -e "$f" ]; then echo "  !! ${f} 仍存在"; else echo "  ${f} 已删除"; fi
done
echo "--- 端口 8443/8080 ---"
if ss -tln 2>/dev/null | grep -qE ':(8443|8080) '; then
  ss -tln | grep -E ':(8443|8080) ' | sed 's/^/  !! 仍占用: /'
else
  echo "  8443/8080 已释放"
fi
echo "--- 项目网络 ---"
if docker network ls 2>/dev/null | grep -qiE 'reality|tgbot'; then
  docker network ls | grep -iE 'reality|tgbot' | sed 's/^/  !! 残留: /'
else
  echo "  项目网络已删除"
fi
echo "--- 保留项自检（不该被删的必须还活着） ---"
echo "  fail2ban = $(systemctl is-active fail2ban 2>&1)"
echo "  docker   = $(systemctl is-active docker 2>&1)"
echo "  sshd     = $(systemctl is-active ssh 2>&1)"
echo "--- 运行时内核参数（drop-in 删了，但运行时值会保留到重启） ---"
echo "  cc    = $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
echo "  qdisc = $(sysctl -n net.core.default_qdisc 2>/dev/null)"

echo
echo "############ 卸载阶段结束 ############"
