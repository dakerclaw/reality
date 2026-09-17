#!/bin/bash
# 清理当前部署用不到的旧 Docker 镜像。
# 铁律：删之前先查引用 —— ancestor 过滤命中容器就跳过并告警，绝不删还在用的东西。
set -u

CANDIDATES=(
  "nginx:1.24.0"
  "ghcr.io/sagernet/sing-box:v1.12.23"
  "python:3.11-alpine"
  "python:3.12-alpine"
  "python:3.13-alpine"
  "haproxy:3.4.4"
  "certbot/certbot:v5.8.0"
  "ghcr.io/xtls/xray-core:26.3.27"
)

echo "########## 0. 清理前基线 ##########"
docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}' 2>&1 | sed 's/^/  /'
echo "--- 磁盘占用 ---"
docker system df 2>&1 | sed 's/^/  /'

echo
echo "########## 1. 逐个检查引用并删除 ##########"
REMOVED=0
SKIPPED=0
FAILED=0
for img in "${CANDIDATES[@]}"; do
  if ! docker image inspect "${img}" >/dev/null 2>&1; then
    echo "  --  ${img}：不存在，跳过"
    continue
  fi
  refs=$(docker ps -a --filter "ancestor=${img}" -q 2>/dev/null | wc -l)
  if [ "${refs}" -ne 0 ]; then
    echo "  !! ${img}：仍被 ${refs} 个容器引用，跳过"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  if docker rmi "${img}" >/dev/null 2>&1; then
    echo "  OK 已删除 ${img}"
    REMOVED=$((REMOVED + 1))
  else
    echo "  !! ${img}：删除失败（可能被其他镜像层依赖）"
    FAILED=$((FAILED + 1))
  fi
done

echo
echo "########## 2. 悬空层与构建缓存 ##########"
echo "--- docker image prune（仅悬空层） ---"
docker image prune -f 2>&1 | sed 's/^/  /'
echo "--- docker builder prune ---"
docker builder prune -f 2>&1 | sed 's/^/  /'

echo
echo "########## 3. 清理后核验 ##########"
echo "--- 剩余镜像 ---"
docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}' 2>&1 | sed 's/^/  /'
echo "--- 磁盘占用 ---"
docker system df 2>&1 | sed 's/^/  /'
echo "--- 在跑的服务必须完好 ---"
docker ps --format '{{.Names}}\t{{.Status}}' 2>&1 | sed 's/^/  /'
echo "--- 端口 ---"
ss -tln 2>/dev/null | grep -E ':(8443|8080) ' | sed 's/^/  /'
echo "  fail2ban = $(systemctl is-active fail2ban 2>&1)"

echo
echo "统计：删除 ${REMOVED} 个，跳过 ${SKIPPED} 个，失败 ${FAILED} 个"
echo "########## 清理阶段结束 ##########"
