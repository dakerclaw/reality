#!/bin/bash
# reality 卸载前备份：只读取与打包，不删除、不停服务
set -u
STAMP=$(date +%Y-%m-%d_%H-%M-%S)
OUT="/root/reality-uninstall-backup-${STAMP}"
mkdir -p "${OUT}"

echo "=== 1. 归档 /opt/reality-ezpz 全量 ==="
cp -a /opt/reality-ezpz "${OUT}/reality-ezpz"
cp -a /etc/sysctl.d/99-reality-ezpz.conf "${OUT}/" 2>/dev/null && echo "  sysctl drop-in 已收录"

echo "=== 2. 记录 compose 配置与运行状态 ==="
docker compose ls -a > "${OUT}/docker-compose-ls.txt" 2>&1
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' > "${OUT}/docker-ps-a.txt" 2>&1
docker images --format '{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}' > "${OUT}/docker-images.txt" 2>&1
docker network ls > "${OUT}/docker-networks.txt" 2>&1
ss -tlnp > "${OUT}/listening-ports.txt" 2>&1
: > "${OUT}/compose-config.txt"
for p in /opt/reality-ezpz /opt/reality-ezpz/tgbot; do
  echo "########## ${p} ##########" >> "${OUT}/compose-config.txt"
  docker compose --project-directory "${p}" config >> "${OUT}/compose-config.txt" 2>&1
done

echo "=== 3. 打包 ==="
cd /root
if command -v zip >/dev/null 2>&1; then
  zip -rq "${OUT}.zip" "reality-uninstall-backup-${STAMP}" && ARCHIVE="${OUT}.zip"
else
  tar -czf "${OUT}.tar.gz" "reality-uninstall-backup-${STAMP}" && ARCHIVE="${OUT}.tar.gz"
fi

echo "=== 4. 校验 ==="
ls -la "${ARCHIVE}"
sha256sum "${ARCHIVE}"
echo "--- 归档内文件清单 ---"
if command -v zip >/dev/null 2>&1; then unzip -l "${ARCHIVE}" | head -30; else tar -tzf "${ARCHIVE}" | head -30; fi
echo
echo "--- 关键文件确认 ---"
ls -la "${OUT}/reality-ezpz/"
echo
echo "ARCHIVE_PATH=${ARCHIVE}"
