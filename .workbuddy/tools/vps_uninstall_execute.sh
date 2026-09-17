#!/bin/bash
# reality 卸载（已确认范围）
#   删除：容器 / compose 项目 / 网络 / 镜像 / 构建缓存 / /opt/reality* / sysctl drop-in
#   保留：宿主机 apt nginx、fail2ban、Docker 本体、/root 下的备份包
# 不使用 set -e：单项失败要记录并继续，最后统一汇报，避免半途中断留下残骸。

FAILURES=()

note_fail() { FAILURES+=("$1"); echo "  !! $1"; }
hr() { echo "------------------------------------------------------------"; }

echo "########## 0. 卸载前基线 ##########"
echo "--- 容器 ---"
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>&1
echo "--- compose 项目 ---"
docker compose ls -a 2>&1
echo "--- 镜像 ---"
docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' 2>&1
echo "--- 网络 ---"
docker network ls --format '{{.Name}}' 2>&1
echo "--- 8443/8080 占用 ---"
ss -tlnp 2>/dev/null | grep -E ':8443|:8080' || echo "(未占用)"
echo "--- 当前拥塞控制 / qdisc ---"
echo "cc      = $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
echo "qdisc   = $(sysctl -n net.core.default_qdisc 2>/dev/null)"
echo "file-max= $(sysctl -n fs.file-max 2>/dev/null)"
echo "--- 磁盘占用 ---"
df -h / | tail -1
docker system df 2>&1 | head -6

hr
echo "########## 1. 停止并移除容器（compose down） ##########"
# 逐个用显式 -p，不依赖目录名推断；两组项目名都试，覆盖改名前后。
for spec in "/opt/reality-ezpz:reality-ezpz" "/opt/reality-ezpz:reality" \
            "/opt/reality-ezpz/tgbot:tgbot" "/opt/reality:reality" "/opt/reality/tgbot:tgbot"; do
  dir="${spec%%:*}"; proj="${spec##*:}"
  [ -d "$dir" ] || continue
  [ -f "$dir/docker-compose.yml" ] || continue
  echo "--- down: project=${proj} dir=${dir} ---"
  docker compose --project-directory "$dir" -p "$proj" down --remove-orphans --timeout 5 2>&1 \
    || note_fail "compose down 失败: ${proj} @ ${dir}"
done

echo "--- 兜底：按名字删除残留容器 ---"
for c in $(docker ps -a --format '{{.Names}}' | grep -E '^(reality|tgbot)' ); do
  echo "  rm -f $c"
  docker rm -f "$c" >/dev/null 2>&1 || note_fail "删除容器失败: $c"
done

hr
echo "########## 2. 移除镜像 ##########"
for img in "tgbot-tgbot:latest" "ghcr.io/sagernet/sing-box:v1.12.23" "nginx:1.24.0"; do
  docker image inspect "$img" >/dev/null 2>&1 || { echo "  (不存在) $img"; continue; }
  inuse=$(docker ps -a --filter "ancestor=${img}" -q | wc -l)
  if [ "$inuse" -gt 0 ]; then
    note_fail "跳过 $img：仍被 ${inuse} 个容器引用"
    continue
  fi
  if docker rmi "$img" >/dev/null 2>&1; then echo "  已删除 $img"; else note_fail "删除镜像失败: $img"; fi
done
echo "--- 清理悬空镜像层 ---"
docker image prune -f 2>&1 | tail -2
echo "--- 清理构建缓存（tgbot 镜像构建产生） ---"
docker builder prune -f 2>&1 | tail -2

hr
echo "########## 3. 移除网络残留 ##########"
for n in reality-ezpz_reality reality_reality tgbot_tgbot; do
  if docker network inspect "$n" >/dev/null 2>&1; then
    if docker network rm "$n" >/dev/null 2>&1; then echo "  已删除网络 $n"; else note_fail "删除网络失败: $n"; fi
  else
    echo "  (不存在或已随 down 移除) $n"
  fi
done

hr
echo "########## 4. 移除配置目录 ##########"
for d in /opt/reality-ezpz /opt/reality; do
  if [ -e "$d" ]; then
    echo "  rm -rf $d （$(du -sh "$d" 2>/dev/null | cut -f1)）"
    rm -rf "$d" || note_fail "删除目录失败: $d"
  else
    echo "  (不存在) $d"
  fi
done

hr
echo "########## 5. 移除 sysctl drop-in 并还原运行时参数 ##########"
for f in /etc/sysctl.d/99-reality-ezpz.conf /etc/sysctl.d/99-reality.conf; do
  if [ -f "$f" ]; then
    cp -a "$f" "/root/removed-$(basename "$f").bak" && echo "  已备份到 /root/removed-$(basename "$f").bak"
    rm -f "$f" && echo "  已删除 $f" || note_fail "删除失败: $f"
  fi
done

echo "--- 可用拥塞控制算法 ---"
avail=$(sysctl -n net.tcp_available_congestion_control 2>/dev/null)
echo "  $avail"
target_cc="cubic"
echo "$avail" | grep -qw cubic || target_cc=$(echo "$avail" | awk '{print $1}')
echo "  目标 cc = $target_cc"
sysctl -qw "net.ipv4.tcp_congestion_control=${target_cc}" \
  && echo "  cc -> $(sysctl -n net.ipv4.tcp_congestion_control)" \
  || note_fail "回退拥塞控制失败"
sysctl -qw "net.core.default_qdisc=fq_codel" \
  && echo "  qdisc -> $(sysctl -n net.core.default_qdisc)" \
  || note_fail "回退 qdisc 失败"
echo "--- 卸载 bbr 模块（若未被占用） ---"
modprobe -r tcp_bbr 2>&1 && echo "  tcp_bbr 已卸载" || echo "  (模块仍被占用或已内置，保持不变)"
echo "--- 重新加载 sysctl ---"
sysctl --system >/dev/null 2>&1 && echo "  sysctl --system OK" || note_fail "sysctl --system 失败"

hr
echo "########## 6. 卸载后验证 ##########"
echo "--- 容器（应为空） ---"
left=$(docker ps -a --format '{{.Names}}' 2>&1)
[ -z "$left" ] && echo "  ✓ 无任何容器" || { echo "$left" | sed 's/^/  /'; note_fail "仍有残留容器"; }
echo "--- compose 项目（应为空） ---"
docker compose ls -a 2>&1 | tail -n +1
echo "--- 相关镜像（应无上述三个） ---"
docker images --format '{{.Repository}}:{{.Tag}}' 2>&1
echo "--- 相关网络（应无） ---"
docker network ls --format '{{.Name}}' 2>&1
echo "--- 端口 8443 / 8080（应释放） ---"
ss -tlnp 2>/dev/null | grep -E ':8443|:8080' && note_fail "8443/8080 仍被占用" || echo "  ✓ 8443/8080 已释放"
echo "--- 目录（应不存在） ---"
for d in /opt/reality-ezpz /opt/reality; do
  [ -e "$d" ] && note_fail "目录仍存在: $d" || echo "  ✓ $d 不存在"
done
echo "--- sysctl 文件（应不存在） ---"
ls /etc/sysctl.d/ 2>/dev/null
echo "--- 内核参数现状 ---"
echo "  cc      = $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "  qdisc   = $(sysctl -n net.core.default_qdisc)"
echo "  file-max= $(sysctl -n fs.file-max)"
echo "--- 保留项自检 ---"
echo "  宿主机 nginx : $(systemctl is-active nginx 2>&1) / 端口80 $(ss -tln 2>/dev/null | grep -c ':80 ')"
echo "  fail2ban     : $(systemctl is-active fail2ban 2>&1)"
echo "  docker       : $(systemctl is-active docker 2>&1)"
echo "  备份包       : $(ls /root/reality-uninstall-backup-*.zip 2>/dev/null | tr '\n' ' ')"
echo "--- 磁盘 ---"
df -h / | tail -1

hr
echo "########## 卸载结束 ##########"
if [ ${#FAILURES[@]} -eq 0 ]; then
  echo "结果：全部项目成功，无失败项。"
  exit 0
else
  echo "结果：有 ${#FAILURES[@]} 项失败："
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
