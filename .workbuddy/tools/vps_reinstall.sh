#!/bin/bash
# 重装 reality 最新版，并保留原有凭据（私钥 / short_id / service_path / public_key / 用户 UUID）。
#
# 用法：
#   SERVER=203.0.113.10 BK_DIR=/root/reality-uninstall-backup-<stamp> bash vps_reinstall.sh
#
# 环境变量：
#   SERVER          必填。--server 的值（IP 或域名）。
#   BK_DIR          卸载前备份目录（含 reality/config 与 reality/users）。
#   EXPECT_CFG_SHA  可选。config 的 sha256，给出则强制校验（防止凭据被悄悄轮换）。
#   EXPECT_USR_SHA  可选。users 的 sha256。
#   REPO_RAW        可选。脚本下载地址。
#   CORE/SECURITY/TRANSPORT/DOMAIN/CAMOUFLAGE/PORT/HTTP_PORT/BBR/TGBOT
#                   可选。覆盖部署形态，默认与出厂一致的 reality+tcp+8443/8080。
#
# 本脚本刻意不含任何主机地址或密钥，可安全入库；具体部署值全部由调用方注入。
#
# 关键顺序：必须在安装器读取配置之前把 config 与 users 放回 /opt/reality。
#   main 流程是 generate_file_list → ... → parse_config_file → parse_users_file → build_config。
#   parse_config_file 只在 config 不可读、或四个凭据字段有空值时调用 generate_keys，
#   所以放回一份完整的 config 就会原样沿用密钥，不会被轮换。
#   parse_users_file 会 touch users，因此 users 也必须先放回，否则用户表被建成空表。
set -u

SERVER="${SERVER:-}"
BK_DIR="${BK_DIR:-}"
EXPECT_CFG_SHA="${EXPECT_CFG_SHA:-}"
EXPECT_USR_SHA="${EXPECT_USR_SHA:-}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/dakerclaw/reality/main/reality.sh}"
CORE="${CORE:-sing-box}"
SECURITY="${SECURITY:-reality}"
TRANSPORT="${TRANSPORT:-tcp}"
DOMAIN="${DOMAIN:-www.fastly.com}"
CAMOUFLAGE="${CAMOUFLAGE:-www.fastly.com}"
PORT="${PORT:-8443}"
HTTP_PORT="${HTTP_PORT:-8080}"
BBR="${BBR:-true}"
TGBOT="${TGBOT:-true}"

LATEST=/root/reality-latest.sh

if [ -z "${SERVER}" ]; then
  echo "!! 必须给出 SERVER（--server 的值）"
  exit 1
fi
if [ ! -d "${BK_DIR}" ]; then
  echo "!! 备份目录不存在：${BK_DIR}"
  exit 1
fi

echo "########## 0. 准备最新脚本 ##########"
if [ ! -s "${LATEST}" ]; then
  echo "  本地无 ${LATEST}，重新下载"
  curl -fsSL -m 60 -o "${LATEST}" "${REPO_RAW}" || { echo "!! 下载失败"; exit 1; }
fi
if ! bash -n "${LATEST}"; then echo "!! ${LATEST} 语法检查失败"; exit 1; fi
echo "  ${LATEST}: size=$(stat -c %s "${LATEST}") md5=$(md5sum "${LATEST}" | cut -d' ' -f1)"

echo
echo "########## 1. 还原凭据（必须早于安装器读配置） ##########"
install -d -m 700 /opt/reality
cp -a "${BK_DIR}/reality/config" /opt/reality/config
cp -a "${BK_DIR}/reality/users"  /opt/reality/users
chmod 600 /opt/reality/config /opt/reality/users
# 网站也一并还原：generate_website 只在 index.html 缺失时写占位页，已存在绝不覆盖
if [ -d "${BK_DIR}/reality/website" ]; then
  mkdir -p /opt/reality/website
  cp -a "${BK_DIR}/reality/website/." /opt/reality/website/
fi

CFG=$(sha256sum /opt/reality/config | cut -d' ' -f1)
USR=$(sha256sum /opt/reality/users  | cut -d' ' -f1)
echo "  config sha256 = ${CFG}"
echo "  users  sha256 = ${USR}"
if [ -n "${EXPECT_CFG_SHA}" ] && [ "${CFG}" != "${EXPECT_CFG_SHA}" ]; then
  echo "!! config 与备份不一致，中止重装"; exit 1
fi
if [ -n "${EXPECT_USR_SHA}" ] && [ "${USR}" != "${EXPECT_USR_SHA}" ]; then
  echo "!! users 与备份不一致，中止重装"; exit 1
fi
echo "  OK：凭据已还原$([ -n "${EXPECT_CFG_SHA}" ] && echo '且与备份逐字节一致')"
echo "  --- 还原后的关键字段 ---"
grep -E '^(core|security|transport|domain|camouflage|server|port|http_port|safenet|bbr|warp|tgbot|tgbot_admins)=' /opt/reality/config | sed 's/^/    /'
echo "    public_key  = $(grep '^public_key=' /opt/reality/config | cut -d= -f2)"
echo "    private_key = <len $(awk -F= '/^private_key=/{print length($2)}' /opt/reality/config)>"
echo "    short_id    = <len $(awk -F= '/^short_id=/{print length($2)}' /opt/reality/config)>"
echo "    users       = $(tr '\n' ' ' < /opt/reality/users)"

echo
echo "########## 2. 运行最新版安装器 ##########"
echo "  形态：${CORE} / ${SECURITY} / ${TRANSPORT} / ${DOMAIN} / ${PORT} / ${HTTP_PORT} / BBR=${BBR} / tgbot=${TGBOT}"
echo "  （tgbot token 与 admins 不在命令行给出，由还原的 config 提供）"
echo "----------------------------------------------------------------"
bash "${LATEST}" \
  --core "${CORE}" \
  --security "${SECURITY}" \
  --transport "${TRANSPORT}" \
  --domain "${DOMAIN}" \
  --camouflage "${CAMOUFLAGE}" \
  --server "${SERVER}" \
  --port "${PORT}" \
  --http-port "${HTTP_PORT}" \
  --enable-bbr "${BBR}" \
  --enable-tgbot "${TGBOT}"
RC=$?
echo "----------------------------------------------------------------"
echo "  安装器退出码 = ${RC}"

echo
echo "########## 3. 凭据是否被轮换 ##########"
CFG2=$(sha256sum /opt/reality/config | cut -d' ' -f1)
USR2=$(sha256sum /opt/reality/users  | cut -d' ' -f1)
echo "  config sha256 = ${CFG2}"
echo "  users  sha256 = ${USR2}"
if [ "${CFG2}" = "${CFG}" ] && [ "${USR2}" = "${USR}" ]; then
  echo "  OK：凭据未被轮换，老客户端可继续使用"
else
  echo "  !! 凭据发生变化，差异字段如下："
  diff <(sed -E 's/^(private_key|short_id|tgbot_token)=.*/\1=<redacted>/' "${BK_DIR}/reality/config") \
       <(sed -E 's/^(private_key|short_id|tgbot_token)=.*/\1=<redacted>/' /opt/reality/config) || true
fi

echo
echo "########## 4. 服务状态核验 ##########"
echo "--- 容器 ---"
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>&1 | sed 's/^/  /'
echo "--- compose 项目 ---"
docker compose ls -a 2>&1 | sed 's/^/  /'
echo "--- 端口 ---"
ss -tln 2>/dev/null | grep -E ':(8443|8080|80) ' | sed 's/^/  /'
echo "--- 内核参数 ---"
echo "  cc    = $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
echo "  qdisc = $(sysctl -n net.core.default_qdisc 2>/dev/null)"
echo "  drop-in: $(ls /etc/sysctl.d/ 2>/dev/null | grep -i reality || echo '(缺失!)')"
echo "--- 保留项 ---"
echo "  fail2ban = $(systemctl is-active fail2ban 2>&1)"
echo "  docker   = $(systemctl is-active docker 2>&1)"
echo "  sshd     = $(systemctl is-active ssh 2>&1)"
echo "--- 安装目录 ---"
ls -la /opt/reality 2>&1 | sed 's/^/  /'
echo "--- 落地脚本版本 ---"
md5sum /opt/reality/reality.sh 2>/dev/null

echo
echo "########## 重装阶段结束 ##########"
