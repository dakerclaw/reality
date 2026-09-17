#!/bin/sh
# 只读侦察：确认 VPS 上的 docker 可用、磁盘余量、现有镜像。
set -u
echo "== date =="; date -Is
echo "== docker =="; docker version --format '{{.Server.Version}}' 2>&1
echo "== compose =="; docker compose version --short 2>&1
echo "== disk / =="; df -h / | tail -1
echo "== 现有镜像 =="; docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' 2>&1
echo "== 运行中容器 =="; docker ps --format '{{.Names}} {{.Image}}' 2>&1
echo "== 出口连通性 =="
for h in ghcr.io registry-1.docker.io hub.docker.com; do
  if getent hosts "$h" >/dev/null 2>&1; then echo "  DNS ok: $h"; else echo "  DNS FAIL: $h"; fi
done
echo "== DONE =="
