#!/bin/bash
# reality 的端到端验证：证明「流量真的走了 REALITY 隧道」。
#
# 只从远端自身的 /opt/reality/config 与 users 取参数，本脚本不含任何主机地址或
# 密钥，可安全入库。
#
# 为什么需要反向对照：客户端容器跑在 VPS 本机，它的出口 IP 与「直接在 VPS 上 curl」
# 本来就是同一个，所以「curl 得到 http=200」这件事单独看什么都证明不了 —— 分不清
# 是走了隧道还是碰巧被放行。做法是：
#   正向：正确凭据 → http=200，且出口 IP 与直连一致（说明确有出口）
#   反向：分别把 public_key / uuid / short_id 各改坏 1 个字符 → 三次都必须失败，
#         并且要确认失败原因是 REALITY/握手层，而不是「容器没起来」这种假失败。
# 客户端 route.final 指向唯一的 vless 出站，且入站只监听 127.0.0.1:11080，
# 因此 curl 走这个 socks5 时除了隧道没有别的路径。
set -u

IMAGE=ghcr.io/sagernet/sing-box:v1.14.1
WORK=/root/reality-e2e
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  [OK] $1"; }
no(){ FAIL=$((FAIL+1)); echo "  [NG] $1"; }
chk(){ if [ "$2" = "$3" ]; then ok "$1 => $3"; else no "$1: 期望[$2] 实际[$3]"; fi; }

echo "########## 1. 容器稳定性（check ≠ run，只有真跑得住才算数） ##########"
for c in reality-engine-1 reality-nginx-1 tgbot-tgbot-1; do
  printf '  %-20s state=%-8s restart=%-3s started=%s\n' "$c" \
    "$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)" \
    "$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null)" \
    "$(docker inspect -f '{{.State.StartedAt}}' "$c" 2>/dev/null)"
done
for c in reality-engine-1 reality-nginx-1; do
  chk "${c} 处于 running" "running" "$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)"
done
chk "reality 项目是 running(2)" "running(2)" \
  "$(docker compose ls 2>/dev/null | awk '$1=="reality"{print $2}')"

echo
echo "########## 2. 引擎日志（FATAL 必须为 0） ##########"
docker logs reality-engine-1 2>&1 | sed -r 's/\x1b\[[0-9;]*m//g' | tail -8 | cut -c1-155 | sed 's/^/  | /'
for kw in FATAL 'download_detour' 'empty direct outbound'; do
  chk "日志中 ${kw} 计数" "0" "$(docker logs reality-engine-1 2>&1 | grep -c -- "${kw}" || true)"
done

echo
echo "########## 3. 从 config/users 取客户端参数（不回显密钥） ##########"
UUID=$(awk -F= 'NF>1{print $2}' /opt/reality/users | head -1 | tr -d '[:space:]')
SID=$(grep '^short_id='   /opt/reality/config | cut -d= -f2)
PBK=$(grep '^public_key=' /opt/reality/config | cut -d= -f2)
SNI=$(grep '^domain='     /opt/reality/config | cut -d= -f2)
SRV=$(grep '^server='     /opt/reality/config | cut -d= -f2)
PORT=$(grep '^port='      /opt/reality/config | cut -d= -f2)
echo "  uuid=${UUID:0:8}…(len ${#UUID})   short_id len=${#SID}   public_key len=${#PBK}"
echo "  sni=${SNI}   server=${SRV}   port=${PORT}"
if [ -z "${UUID}" ] || [ -z "${SID}" ] || [ -z "${PBK}" ] || [ -z "${SRV}" ]; then
  echo "!! 参数缺失，无法继续"; exit 1
fi
# uuid 改坏：把首字符换掉（仍是合法 UUID 形状）
WRONG_UUID="$(printf '%s' "${UUID}" | cut -c1 | tr '0123456789abcdef' '123456789abcdef0')$(printf '%s' "${UUID}" | cut -c2-)"
# public_key 改坏：保持 43 字符 URL-safe 形状，只改最后一个字符
WRONG_PBK="$(printf '%s' "${PBK}" | cut -c1-42)$([ "$(printf '%s' "${PBK}" | cut -c43)" = "A" ] && echo B || echo A)"
# short_id 改坏：首字符换掉
WRONG_SID="$(printf '%s' "${SID}" | cut -c1 | tr '0123456789abcdef' '123456789abcdef0')$(printf '%s' "${SID}" | cut -c2-)"
echo "  wrong_uuid 前 8 位=${WRONG_UUID:0:8}   wrong_pbk len=${#WRONG_PBK}   wrong_sid 前 4 位=${WRONG_SID:0:4}"
[ "${WRONG_UUID}" != "${UUID}" ] && ok "wrong_uuid 确实不同" || no "wrong_uuid 未改变"
[ "${WRONG_PBK}"  != "${PBK}"  ] && ok "wrong_pbk 确实不同"  || no "wrong_pbk 未改变"
[ "${WRONG_SID}"  != "${SID}"  ] && ok "wrong_sid 确实不同"  || no "wrong_sid 未改变"

mkdir -p "${WORK}"
gen_config() {
  cat > "${WORK}/client.json" <<JSON
{
  "log": { "level": "info" },
  "inbounds": [
    { "type": "mixed", "tag": "in", "listen": "127.0.0.1", "listen_port": 11080 }
  ],
  "outbounds": [
    {
      "type": "vless", "tag": "out",
      "server": "${SRV}", "server_port": ${PORT},
      "uuid": "$2", "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true, "server_name": "${SNI}",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": { "enabled": true, "public_key": "$3", "short_id": "$4" }
      }
    }
  ],
  "route": { "final": "out" }
}
JSON
}

# 跑一次探针。$1=标签 $2=uuid $3=pubkey $4=shortid $5=期望(up|down)
run_probe() {
  local label="$1" uuid="$2" pbk="$3" sid="$4" expect="$5"
  local status listening code ip rc
  gen_config x "${uuid}" "${pbk}" "${sid}"
  docker rm -f reality-e2e >/dev/null 2>&1 || true
  if ! docker run -d --name reality-e2e --network host \
      -v "${WORK}/client.json:/etc/sing-box/config.json:ro" \
      "${IMAGE}" run -c /etc/sing-box/config.json >/dev/null 2>&1; then
    no "[${label}] 客户端容器启动失败"; return
  fi
  local i=0
  while [ "${i}" -lt 30 ]; do
    ss -tln 2>/dev/null | grep -q ':11080 ' && break
    i=$((i + 1)); sleep 0.5
  done
  sleep 1
  status=$(docker inspect -f '{{.State.Status}}' reality-e2e 2>/dev/null)
  listening=$(ss -tln 2>/dev/null | grep -c ':11080 ')
  echo "  [${label}] 客户端容器=${status}  11080 监听=${listening}"

  code=$(curl -sS -m 25 -x socks5h://127.0.0.1:11080 -o /dev/null \
           -w '%{http_code}' https://www.cloudflare.com/cdn-cgi/trace 2>"${WORK}/curl.err" || true)
  rc=$?
  ip=$(curl -sS -m 25 -x socks5h://127.0.0.1:11080 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -m1 '^ip=' | cut -d= -f2)
  ip=${ip:-<失败>}
  echo "  [${label}] 经代理 http=${code:-<空>} curl_rc=${rc}  出口IP=${ip}"
  if [ -s "${WORK}/curl.err" ]; then
    head -2 "${WORK}/curl.err" | cut -c1-140 | sed "s/^/    curl: /"
  fi
  echo "  [${label}] 客户端日志（原始尾部，已去 ANSI）:"
  docker logs reality-e2e 2>&1 | sed -r 's/\x1b\[[0-9;]*m//g' | tail -12 | cut -c1-150 | sed 's/^/    /'
  PROBE_ATTEMPT="$(docker logs reality-e2e 2>&1 | grep -c 'outbound connection to' || true)"
  PROBE_ERRLOG="$(docker logs reality-e2e 2>&1 | sed -r 's/\x1b\[[0-9;]*m//g' \
                    | grep -ciE 'error|reality|handshake|closed|reset|eof|broken|refused|timeout' || true)"
  docker rm -f reality-e2e >/dev/null 2>&1

  chk "[${label}] 容器确实在跑（排除假失败）" "running" "${status}"
  chk "[${label}] 11080 确实在听（排除假失败）" "1" "${listening}"
  # 关键一步：先证明客户端真的把流量交给了隧道。否则「失败」可能只是它压根没发出站，
  # 那样反向对照就没有意义。错 uuid 时服务端是静默拒绝，客户端只会留 INFO 行，
  # 所以这里用「是否有出站尝试」而不是「是否有 ERROR 行」来把关。
  if [ "${PROBE_ATTEMPT}" -gt 0 ]; then
    ok "[${label}] 客户端确实发起了隧道出站尝试（${PROBE_ATTEMPT} 次）"
  else
    no "[${label}] 客户端没有发出站尝试，失败原因可疑"
  fi
  echo "    [i] 显式错误/REALITY 日志行数 = ${PROBE_ERRLOG}"
  if [ "${expect}" = "up" ]; then
    chk "[${label}] http 状态码" "200" "${code}"
    if [ -n "${BASELINE_IP}" ] && [ "${BASELINE_IP}" != "<取不到>" ]; then
      chk "[${label}] 出口 IP 与直连基准一致" "${BASELINE_IP}" "${ip}"
    else
      echo "  [i] 直连基准取不到，跳过出口 IP 比对"
    fi
  else
    if [ "${code}" = "000" ] || [ -z "${code}" ]; then
      ok "[${label}] 正如期望地失败了（http=${code:-<空>}）"
    else
      no "[${label}] 竟然成功了（http=${code}）—— 反向对照未成立"
    fi
  fi
}

echo
echo "########## 4. 正向：正确凭据 ##########"
BASELINE_IP=$(curl -sS -m 15 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -m1 '^ip=' | cut -d= -f2 || echo '<取不到>')
echo "  直连出口 IP 基准 = ${BASELINE_IP}"
run_probe "正向" "${UUID}" "${PBK}" "${SID}" "up"

echo
echo "########## 5. 反向对照 A：public_key 改坏 1 个字符 ##########"
run_probe "反A-公钥错" "${UUID}" "${WRONG_PBK}" "${SID}" "down"

echo
echo "########## 6. 反向对照 B：uuid 改坏 1 个字符 ##########"
run_probe "反B-UUID错" "${WRONG_UUID}" "${PBK}" "${SID}" "down"

echo
echo "########## 7. 反向对照 C：short_id 改坏 1 个字符 ##########"
run_probe "反C-短ID错" "${UUID}" "${PBK}" "${WRONG_SID}" "down"

echo
echo "########## 8. 清理 ##########"
docker rm -f reality-e2e >/dev/null 2>&1 || true
rm -rf "${WORK}"
echo "  已删除容器 reality-e2e 与目录 ${WORK}"
echo "  仍在运行的容器: $(docker ps --format '{{.Names}}' | tr '\n' ' ')"

echo
echo "PASS=${PASS} FAIL=${FAIL}"
if [ "${FAIL}" -eq 0 ]; then echo "RESULT: e2e ALL GREEN"; else echo "RESULT: e2e has ${FAIL} failure(s)"; fi
