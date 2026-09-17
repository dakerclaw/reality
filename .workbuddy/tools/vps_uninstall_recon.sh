#!/bin/bash
# reality 卸载前只读侦察：不删除、不修改任何东西
echo "############ 1. 时间与主机 ############"
date; hostname; uname -r; echo

echo "############ 2. /opt 目录 ############"
ls -la /opt/ 2>/dev/null
echo
for d in /opt/reality /opt/reality-ezpz; do
  if [ -d "$d" ]; then
    echo "--- $d （$(du -sh "$d" 2>/dev/null | cut -f1)） ---"
    ls -la "$d"
    echo "    [子目录]"
    find "$d" -maxdepth 2 -type d 2>/dev/null | sed 's/^/      /'
    echo "    [关键文件]"
    for f in config users docker-compose.yml reality.sh .env; do
      [ -e "$d/$f" ] && echo "      $f  $(stat -c '%s bytes  %y' "$d/$f" 2>/dev/null)"
    done
    echo "    [website]"
    [ -d "$d/website" ] && ls -la "$d/website" && du -sh "$d/website"
    echo
  else
    echo "--- $d 不存在"
  fi
done

echo "############ 3. Docker 容器 ############"
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>&1
echo
echo "--- compose 项目（含停止的） ---"
docker compose ls -a 2>&1
echo
echo "--- 所有容器名 + compose 项目标签 ---"
docker ps -a --format '{{.Names}} | project={{.Label "com.docker.compose.project"}} | workdir={{.Label "com.docker.compose.project.working_dir"}}' 2>&1

echo
echo "############ 4. Docker 卷 / 网络 / 镜像 ############"
docker volume ls 2>&1
echo "--- networks ---"
docker network ls 2>&1
echo "--- images ---"
docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}' 2>&1

echo
echo "############ 5. 监听端口 ############"
ss -tlnp 2>/dev/null | head -25

echo
echo "############ 6. systemd 单元（reality 相关） ############"
systemctl list-units --all --no-pager 2>/dev/null | grep -i -E "reality|ezpz|xray|sing|xray" || echo "(无)"
echo "--- systemd 文件 ---"
ls -la /etc/systemd/system/ 2>/dev/null | grep -i -E "reality|ezpz|xray|sing" || echo "(无)"

echo
echo "############ 7. sysctl drop-in ############"
ls -la /etc/sysctl.d/ 2>/dev/null
for f in /etc/sysctl.d/99-reality.conf /etc/sysctl.d/99-reality-ezpz.conf; do
  [ -f "$f" ] && echo "--- $f ---" && cat "$f"
done

echo
echo "############ 8. 计划任务 ############"
crontab -l 2>&1 | head -20
echo "--- /etc/cron.d ---"
ls -la /etc/cron.d/ 2>/dev/null

echo
echo "############ 9. 相关文件痕迹 ############"
echo "--- 带 reality/ezpz 字样的文件（/etc /usr/local /root，深度3） ---"
find /etc /usr/local /root -maxdepth 3 -iname "*reality*" -o -maxdepth 3 -iname "*ezpz*" 2>/dev/null | head -30
echo "--- /tmp 中的备份包 ---"
ls -la /tmp/*reality* /tmp/*ezpz* 2>/dev/null || echo "(无)"

echo
echo "############ 10. fail2ban（本会话装的加固件，非 reality 本体） ############"
systemctl is-active fail2ban 2>&1
fail2ban-client status 2>&1 | head -8
echo "--- 白名单中记录的出口 IP ---"
grep -E "ignoreip|bantime" /etc/fail2ban/jail.local 2>/dev/null | head -10

echo
echo "############ 11. Docker 本体 ############"
docker --version 2>&1
systemctl is-enabled docker 2>&1
echo "--- 除本项目外是否还有其他容器 ---"
docker ps -a --format '{{.Names}}' 2>&1

echo
echo "############ 12. 8443/8080 对外可达性（本机视角） ############"
curl -sS -m 8 -k -o /dev/null -w "8443 TLS: %{http_code}\n" https://www.fastly.com:443 2>&1 >/dev/null
echo "(略)"

echo
echo "############ 侦察结束（未做任何修改） ############"
