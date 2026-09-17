#!/bin/bash
# reality 卸载前只读侦察：不删除、不修改任何东西。
# 覆盖两代布局：/opt/reality（当前）与 /opt/reality-ezpz（改名前的旧路径）。
echo "############ 0. 时间与主机 ############"
date; hostname; uname -r; echo

echo "############ 1. /opt 目录总览 ############"
ls -la /opt/ 2>/dev/null
echo
for d in /opt/reality /opt/reality-ezpz; do
  if [ -d "$d" ]; then
    echo "--- $d （$(du -sh "$d" 2>/dev/null | cut -f1)） ---"
    ls -la "$d"
    echo "    [子目录 maxdepth 2]"
    find "$d" -maxdepth 2 -type d 2>/dev/null | sed 's/^/      /'
    echo "    [关键文件]"
    for f in config users docker-compose.yml docker-compose.yaml reality.sh website; do
      [ -e "$d/$f" ] && echo "      $f  $(stat -c '%s bytes  mtime=%y' "$d/$f" 2>/dev/null)"
    done
    echo "    [tgbot 子目录]"
    [ -d "$d/tgbot" ] && ls -la "$d/tgbot"
    echo
  else
    echo "--- $d 不存在"
    echo
  fi
done

echo "############ 2. 安装参数（config） ############"
for d in /opt/reality /opt/reality-ezpz; do
  [ -f "$d/config" ] || continue
  echo "--- $d/config ---"
  # 私钥类只显示长度指纹，避免明文外泄
  sed -E 's/^(private_key=).*/\1<REDACTED>/; s/^(short_id=).*/\1<REDACTED>/' "$d/config"
  echo "    [长度指纹] private_key=$(awk -F= '/^private_key=/{print length($2)}' "$d/config" 2>/dev/null) short_id=$(awk -F= '/^short_id=/{print length($2)}' "$d/config" 2>/dev/null)"
  echo
  echo "--- $d/users （仅统计） ---"
  if [ -f "$d/users" ]; then
    echo "  行数: $(wc -l < "$d/users")"
    echo "  首行: $(head -1 "$d/users")"
  else
    echo "  (无)"
  fi
  echo
done

echo "############ 3. 远端脚本版本 ############"
for d in /opt/reality /opt/reality-ezpz; do
  [ -f "$d/reality.sh" ] && echo "$(md5sum "$d/reality.sh" 2>/dev/null)   $d/reality.sh"
done
echo "--- 远端脚本的仓库坐标 ---"
for d in /opt/reality /opt/reality-ezpz; do
  [ -f "$d/reality.sh" ] && { echo "  $d:"; grep -nE '^(repo_owner|repo_name|repo_branch)=' "$d/reality.sh" | sed 's/^/    /'; }
done

echo
echo "############ 4. Docker 容器 ############"
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>&1
echo
echo "--- 容器名 + compose 标签 ---"
docker ps -a --format '{{.Names}} | project={{.Label "com.docker.compose.project"}} | workdir={{.Label "com.docker.compose.project.working_dir"}}' 2>&1
echo
echo "--- compose 项目（含已停止） ---"
docker compose ls -a 2>&1
echo
echo "--- 重启计数 ---"
for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null); do
  echo "  $c: restart=$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null) state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)"
done

echo
echo "############ 5. Docker 卷 / 网络 / 镜像 ############"
echo "--- volumes ---"; docker volume ls 2>&1
echo "--- networks ---"; docker network ls 2>&1 | head -20
echo "--- images ---"; docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}' 2>&1

echo
echo "############ 6. 监听端口 ############"
ss -tlnp 2>/dev/null | head -30

echo
echo "############ 7. systemd 单元 ############"
systemctl list-units --all --no-pager 2>/dev/null | grep -i -E "reality|ezpz|xray|sing-box|haproxy" || echo "(无相关单元)"
ls -la /etc/systemd/system/ 2>/dev/null | grep -i -E "reality|ezpz|xray|sing" || echo "(systemd 目录无相关文件)"

echo
echo "############ 8. sysctl drop-in ############"
ls -la /etc/sysctl.d/ 2>/dev/null
for f in /etc/sysctl.d/99-reality.conf /etc/sysctl.d/99-reality-ezpz.conf; do
  if [ -f "$f" ]; then echo "--- $f ---"; cat "$f"; else echo "--- $f 不存在"; fi
done
echo "--- 运行时拥塞控制 ---"
echo "  cc    = $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
echo "  qdisc = $(sysctl -n net.core.default_qdisc 2>/dev/null)"
echo "  avail = $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"

echo
echo "############ 9. 计划任务 ############"
crontab -l 2>&1 | head -20
echo "--- /etc/cron.d ---"; ls -la /etc/cron.d/ 2>/dev/null

echo
echo "############ 10. 文件痕迹 ############"
echo "--- /etc /usr/local /root 下带 reality/ezpz 字样（深度 3） ---"
find /etc /usr/local /root -maxdepth 3 \( -iname "*reality*" -o -iname "*ezpz*" \) 2>/dev/null | head -40
echo "--- /root 下的备份包 ---"
ls -la /root/*.zip /root/*.tar.gz /root/*.tar /root/.env 2>/dev/null | head -20 || echo "(无)"

echo
echo "############ 11. fail2ban（本会话加固件，非 reality 本体） ############"
echo "  is-active  = $(systemctl is-active fail2ban 2>&1)"
echo "  is-enabled = $(systemctl is-enabled fail2ban 2>&1)"
fail2ban-client status 2>&1 | head -8
echo "--- jail.local 关键项 ---"
grep -E "^ *ignoreip|^ *bantime|^ *findtime|^ *maxretry" /etc/fail2ban/jail.local 2>/dev/null | head -20

echo
echo "############ 12. Docker 本体 ############"
docker --version 2>&1
docker compose version 2>&1
if command -v docker-compose >/dev/null 2>&1; then
  echo "docker-compose(legacy 名) = $(docker-compose version --short 2>/dev/null || echo '存在但版本未知')"
else
  echo "docker-compose(legacy 名) = 不存在"
fi
echo "  docker is-enabled = $(systemctl is-enabled docker 2>&1)"

echo
echo "############ 13. 端口监听自检 ############"
for p in 8443 8080 80 443 22; do
  if ss -tln 2>/dev/null | grep -q ":$p "; then echo "  端口 $p: 监听中"; else echo "  端口 $p: 未监听"; fi
done

echo
echo "############ 侦察结束（未做任何修改） ############"
