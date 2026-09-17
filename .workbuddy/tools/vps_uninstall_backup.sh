#!/bin/bash
# reality 卸载前备份：只读取与打包，不删除、不停服务。
# 覆盖两代布局：/opt/reality（当前）与 /opt/reality-ezpz（旧路径）。
set -u
STAMP=$(date +%Y-%m-%d_%H-%M-%S)
NAME="reality-uninstall-backup-${STAMP}"
OUT="/root/${NAME}"
mkdir -p "${OUT}"

echo "=== 1. 归档安装目录全量 ==="
FOUND=0
for d in /opt/reality /opt/reality-ezpz; do
  if [ -d "$d" ]; then
    FOUND=1
    cp -a "$d" "${OUT}/$(basename "$d")"
    echo "  已复制 $d -> ${OUT}/$(basename "$d")  （$(du -sh "${OUT}/$(basename "$d")" | cut -f1)）"
    echo "    --- 凭据文件指纹 ---"
    for f in config users; do
      if [ -f "$d/$f" ]; then
        echo "      $f: size=$(stat -c %s "$d/$f")  sha256=$(sha256sum "$d/$f" | cut -d' ' -f1)"
      fi
    done
    echo "    --- website ---"
    ls -la "$d/website" 2>/dev/null | sed 's/^/      /'
    if [ -f "$d/website/index.html" ]; then
      echo "      index.html: size=$(stat -c %s "$d/website/index.html")  sha256=$(sha256sum "$d/website/index.html" | cut -d' ' -f1)"
    fi
    echo "    --- tgbot ---"
    ls -la "$d/tgbot" 2>/dev/null | sed 's/^/      /'
  else
    echo "  $d 不存在"
  fi
done
if [ "${FOUND}" -eq 0 ]; then
  echo "  !! 两套布局都不存在 —— 无可备份内容"
fi

echo
echo "=== 2. sysctl drop-in ==="
for f in /etc/sysctl.d/99-reality.conf /etc/sysctl.d/99-reality-ezpz.conf; do
  if [ -f "$f" ]; then cp -a "$f" "${OUT}/" && echo "  收录 $f"; else echo "  $f 不存在"; fi
done
{
  echo "cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  echo "qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)"
  echo "avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"
} > "${OUT}/kernel-runtime.txt"

echo
echo "=== 3. 运行状态快照 ==="
docker compose ls -a > "${OUT}/docker-compose-ls.txt" 2>&1
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}\tproject={{.Label "com.docker.compose.project"}}' > "${OUT}/docker-ps-a.txt" 2>&1
docker images --format '{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}' > "${OUT}/docker-images.txt" 2>&1
docker network ls > "${OUT}/docker-networks.txt" 2>&1
ss -tlnp > "${OUT}/listening-ports.txt" 2>&1
: > "${OUT}/compose-config.txt"
for p in /opt/reality /opt/reality/tgbot /opt/reality-ezpz /opt/reality-ezpz/tgbot; do
  [ -d "$p" ] || continue
  echo "########## ${p} ##########" >> "${OUT}/compose-config.txt"
  docker compose --project-directory "${p}" config >> "${OUT}/compose-config.txt" 2>&1
done

cat > "${OUT}/RESTORE-NOTES.txt" <<'NOTES'
这是 reality 卸载前的全量备份。恢复凭据的方式：

  install -d -m 700 /opt/reality
  cp -a reality/config /opt/reality/config      # 私钥 / short_id / service_path / public_key
  cp -a reality/users  /opt/reality/users       # 用户 UUID 表
  chmod 600 /opt/reality/config /opt/reality/users

随后运行安装脚本（相同的 --core/--security/--transport/--domain/--server/--port/
--http-port 参数）即可：脚本会 parse_config_file 读入这份 config，沿用其中的密钥，
只重新生成 engine.conf / compose / 网站占位页等派生物。

若想把网站也还原：
  mkdir -p /opt/reality/website && cp -a reality/website/. /opt/reality/website/

注意：备份内含 REALITY 私钥，属敏感文件，不要放到仓库或公开位置。
NOTES

echo
echo "=== 4. 打包 ==="
cd /root
tar -czf "${OUT}.tar.gz" "${NAME}" && ARCHIVE="${OUT}.tar.gz"
ls -la "${ARCHIVE}"

echo
echo "=== 5. 校验 ==="
sha256sum "${ARCHIVE}"
echo "--- 归档内文件清单（前 40 项） ---"
tar -tzf "${ARCHIVE}" | head -40
echo "--- 归档内文件总数 ---"
tar -tzf "${ARCHIVE}" | wc -l

echo
echo "ARCHIVE_PATH=${ARCHIVE}"
echo "BACKUP_DIR=${OUT}"
