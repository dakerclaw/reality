#!/bin/bash
# reality 重装后的端到端验证。
#
# 只从远端自身的 /opt/reality/config 与 users 取参数，本脚本不含任何主机地址或密钥，
# 可安全入库。
#
# 做法：在 VPS 上跑一个 sing-box 客户端容器（--network host，本地 11080 起 socks5），
# route.final 指向唯一的 vless 出站 —— 也就是说 curl 走这个代理时，除了 REALITY 隧道
# 没有别的路径。因此：
#   正向：正确凭据 → curl 返回 200，证明隧道真的通
#   反向：故意写错 public_key → curl 必须失败，证明上面那条不是因为「碰巧把流量放行了」
# 一正一反同时成立，才算证明成功。
# 另外把新生成的 engine.conf 与卸载前备份做 jq -S 结构化对比。
set -u

IMAGE=ghcr.io/sagernet/sing-box:v1.14.1
WORK=/root/reality-e2e
BK="${1:-}"

echo "########## 1. 容器稳定性（check ≠ run，只有真跑得住才算数） ##########"
for c in reality-engine-1 reality-nginx-1 tgbot-tgbot-1; do
  printf '  %-20s state=%-8s restart=%-3s started=%s\n' "$c" \
    "$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)" \
    "$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null)" \
    "$(docker inspect -f '{{.State.StartedAt}}' "$c" 2>/dev/null)"
done

echo
echo "########## 2. 引擎日志（FATAL/ERROR 必须为 0） ##########"
echo "--- 日志尾部 ---"
docker logs reality-engine-1 2>&1 | tail -15 | sed 's/^/  /'
echo "--- 关键字计数 ---"
for kw in FATAL ERROR 'download_detour' 'empty direct outbound'; do
  printf '  %-24s = %s\n' "${kw}" "$(docker logs reality-engine-1 2>&1 | grep -c -- "${kw}" || true)"
done

echo
echo "########## 3. engine.conf：新生成 vs 卸载前备份（jq -S 结构化对比） ##########"
if [ -n "${BK}" ] && [ -r "${BK}/reality/engine.conf" ]; then
  if diff <(jq -S . "${BK}/reality/engine.conf" 2>/dev/null) <(jq -S . /opt/reality/engine.conf 2>/dev/null) > /tmp/e2e-diff.txt 2>&1; then
    echo "  结构完全一致（逐键相同）"
  else
    echo "  存在差异，明细如下："
    sed 's/^/    /' /tmp/e2e-diff.txt | head -60
  fi
  echo "--- 字节数 ---"
  echo "  备份: $(stat -c %s "${BK}/reality/engine.conf")  现在: $(stat -c %s /opt/reality/engine.conf)"
else
  echo "  未给出备份目录，跳过"
fi

echo
echo "########## 4. 从 config/users 取客户端参数（不回显密钥） ##########"
UUID=$(awk -F= 'NF>1{print $2}' /opt/reality/users | head -1 | tr -d '[:space:]')
SID=$(grep '^short_id=' /opt/reality/config | cut -d= -f2)
PBK=$(grep '^public_key=' /opt/reality/config | cut -d= -f2)
SNI=$(grep '^domain=' /opt/reality/config | cut -d= -f2)
SRV=$(grep '^server=' /opt/reality/config | cut -d= -f2)
PORT=$(grep '^port=' /opt/reality/config | cut -d= -f2)
echo "  uuid=${UUID:0:8}… (len ${#UUID})   short_id len=${#SID}   public_key len=${#PBK}"
echo "  sni=${SNI}   server=${SRV}   port=${PORT}"
if [ -z "${UUID}" ] || [ -z "${SID}" ] || [ -z "${PBK}" ]; then
  echo "!! 参数缺失，无法继续"; exit 1
fi

# 故意写错的公钥：保持 43 字符 URL-safe 形状，只改最后一个字符
WRONG_PBK="$(echo "${PBK}" | cut -c1-42)$( [ "$(echo "${PBK}" | cut -c43)" = "A" ] && echo B || echo A )"
echo "  wrong_key len=${#WRONG_PBK}（仅用于反向对照，与真钥差 1 字符）"

mkdir -p "${WORK}"
gen_config() {
  cat > "$1" <<JSON
{
  "log": { "level": "info" },
  "inbounds": [
    { "type": "mixed", "tag": "in", "listen": "127.0.0.1", "listen_port": 11080 }
  ],
  "outbounds": [
    {
      "type": "vless", "tag": "out",
      "server": "${SRV}", "server_port": ${PORT},
      "uuid": "${UUID}", "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true, "server_name": "${SNI}",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": { "enabled": true, "public_key": "$2", "short_id": "${SID}" }
      }
    }
  ],
  "route": { "final": "out" }
}
JSON
}

run_probe() {
  local label="$1" key="$2" expect="$3"
  gen_config "${WORK}/client.json" "${key}"
  if ! jq . "${WORK}/client.json" >/dev/null 2>&1; then
    echo "  !! 客户端配置 JSON 无效"; return 1
  fi
  docker rm -f reality-e2e >/dev/null 2>&1 || true
  if ! docker run -d --name reality-e2e --network host \
      -v "${WORK}/client.json:/etc/sing-box/config.json:ro" \
      "${IMAGE}" run -c /etc/sing-box/config.json >/dev/null 2>&1; then
    echo "  !! 客户端容器启动失败"; return 1
  fi
  # 等端口就绪
  local i=0
  while [ "${i}" -lt 20 ]; do
    ss -tln 2>/dev/null | grep -q ':11080 ' && break
    i=$((i + 1)); sleep 0.5
  done
  sleep 1
  echo "  [${label}] 客户端容器: $(docker inspect -f '{{.State.Status}}' reality-e2e 2>/dev/null)"
  local code
  code=$(curl -sS -m 25 -x socks5h://127.0.0.1:11080 -o /dev/null -w '%{http_code}' https://www.cloudflare.com/cdn-cgi/trace 2>"${WORK}/curl.err" || true)
  local rc=$?
  echo "  [${label}] 经代理请求 cloudflare: http=${code:-<空>} curl_rc=${rc}"
  if [ -s "${WORK}/curl.err" ]; then sed 's/^/    curl stderr: /' "${WORK}/curl.err" | head -3; fi
  echo "  [${label}] 经代理取出口 IP: $(curl -sS -m 25 -x socks5h://127.0.0.1:11080 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -m1 '^ip=' || echo '<失败>')"
  echo "  [${label}] 客户端日志（出站连接成败）:"
  docker logs reality-e2e 2>&1 | grep -iE 'outbound|connected|error|reality|handshake|timeout|refused' | tail -6 | sed 's/^/    /'
  docker rm -f reality-e2e >/dev/null 2>&1
  echo "  [${label}] 结论：$([ -n "${code}" ] && [ "${code}" != "000" ] && echo PASS || echo FAIL)（期望 ${expect}）"
  return 0
}

echo
echo "########## 5. 正向：正确凭据 ##########"
echo "  对照基准：直连出口 IP = $(curl -sS -m 15 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -m1 '^ip=' || echo '<取不到>')"
run_probe "正向" "${PBK}" "http=200"

echo
echo "########## 6. 反向对照：故意写错 public_key ##########"
run_probe "反向" "${WRONG_PBK}" "必须失败"

rm -rf "${WORK}"
echo
echo "########## 验证结束（临时文件已清理） ##########"
