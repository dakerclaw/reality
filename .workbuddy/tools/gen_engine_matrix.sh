#!/usr/bin/env bash
# 用 reality.sh 里真实的 generate_engine_config / generate_haproxy_config 生成
# 一个「合法组合」矩阵的配置文件，供在 VPS 上用**新镜像**做 check / -test 校验。
#
# 只生成 TUI 允许的组合（非法组合根本不会部署，校验它们没有意义）：
#   ws/tuic/hysteria2 + reality       -> 非法
#   tuic/hysteria2/shadowtls + xray   -> 非法
#
# 输出：
#   <core>__<transport>__<security>.json      引擎配置
#   <core>__<transport>__<security>.haproxy   haproxy.cfg（仅 reality 之外且非 shadowtls 时）
#   manifest.txt
#
# 用法：bash .workbuddy/tools/gen_engine_matrix.sh
export PATH="/c/Users/shang/.workbuddy/binaries/PortableGit/versions/1.2.0/usr/bin:/c/Users/shang/.workbuddy/binaries/PortableGit/versions/1.2.0/mingw64/bin:$PATH"
set +e

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="${ROOT}/.workbuddy/tools/engine-matrix"
PY="C:/Users/shang/.workbuddy/binaries/python/envs/default/Scripts/python.exe"
LIB=/tmp/rl-matrix-lib.sh

CUT=$(grep -n '^if ! parse_args' "${ROOT}/reality.sh" | cut -d: -f1)
head -n $((CUT - 1)) "${ROOT}/reality.sh" > "${LIB}"
# shellcheck disable=SC1090
source "${LIB}"
set +e; set +u

# 真 X25519 密钥对。**不能用占位字符串**：xray 会在解析期直接拒绝
# （Failed to build REALITY config. > invalid "privateKey"），sing-box 同理
# （initialize inbound[0]: invalid private key），会让全部 reality 组合假失败。
# PKCS#8 DER 的末 32 字节 = 原始私钥标量；SPKI DER 的末 32 字节 = 原始公钥。
# 两者都要做 URL-safe base64 且**去掉填充**（43 字符），这才是 xray/sing-box 的格式。
MATRIX_KEYDIR=$(mktemp -d)
openssl genpkey -algorithm X25519 -out "${MATRIX_KEYDIR}/k.pem" 2>/dev/null
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
MATRIX_PRIV=$(openssl pkey -in "${MATRIX_KEYDIR}/k.pem" -outform DER 2>/dev/null | tail -c 32 | b64url)
MATRIX_PUB=$(openssl pkey -in "${MATRIX_KEYDIR}/k.pem" -pubout -outform DER 2>/dev/null | tail -c 32 | b64url)
if [[ ${#MATRIX_PRIV} -ne 43 || ${#MATRIX_PUB} -ne 43 ]]; then
  echo "!! X25519 密钥生成异常（priv=${#MATRIX_PRIV} pub=${#MATRIX_PUB}），reality 组合将假失败" >&2
fi

rm -rf "${OUT}"; mkdir -p "${OUT}"
path[engine]="${OUT}/engine.conf"
: > "${OUT}/manifest.txt"

CORE_LIST="xray sing-box"
TRANSPORT_LIST="tcp http grpc ws tuic hysteria2 shadowtls"
SECURITY_LIST="reality selfsigned letsencrypt"

valid_combo() { # core transport security
  [[ $2 == ws && $3 == reality ]] && return 1
  [[ $2 == tuic && $3 == reality ]] && return 1
  [[ $2 == hysteria2 && $3 == reality ]] && return 1
  [[ $2 == tuic && $1 == xray ]] && return 1
  [[ $2 == hysteria2 && $1 == xray ]] && return 1
  [[ $2 == shadowtls && $1 == xray ]] && return 1
  return 0
}

engine_probe() { # core transport security
  config[core]=$1
  config[transport]=$2
  config[security]=$3
  config[domain]=www.microsoft.com
  config[camouflage]=www.microsoft.com
  config[server]=203.0.113.9
  config[port]=8443
  config[http_port]=8080
  config[service_path]=rand0mpath
  config[safenet]=OFF
  config[warp]=OFF
  config[private_key]=${MATRIX_PRIV}
  config[public_key]=${MATRIX_PUB}
  config[short_id]=deadbeef
  declare -gA users=()
  users[alice]=11111111-2222-3333-4444-555555555555
  generate_engine_config
  cat "${path[engine]}"
}

ok=0; skipped=0
for core in ${CORE_LIST}; do
  for transport in ${TRANSPORT_LIST}; do
    for security in ${SECURITY_LIST}; do
      name="${core}__${transport}__${security}"
      if ! valid_combo "${core}" "${transport}" "${security}"; then
        printf 'SKIP %s (组合在 TUI 里被禁止)\n' "${name}" >> "${OUT}/manifest.txt"
        skipped=$((skipped + 1))
        continue
      fi
      body=$( engine_probe "${core}" "${transport}" "${security}" 2>/dev/null )
      if [[ -z ${body} ]]; then
        printf 'FAIL %s (空输出)\n' "${name}" >> "${OUT}/manifest.txt"
        skipped=$((skipped + 1))
        continue
      fi
      printf '%s' "${body}" > "${OUT}/${name}.json"
      printf 'GEN  %s\n' "${name}" >> "${OUT}/manifest.txt"
      ok=$((ok + 1))

      # haproxy 只在非 reality 且非 shadowtls 时生成
      if [[ ${security} != reality && ${transport} != shadowtls ]]; then
        config[core]=${core}; config[transport]=${transport}
        config[security]=${security}; config[server]=203.0.113.9
        config[service_path]=rand0mpath
        path[haproxy]="${OUT}/${name}.haproxy"
        generate_haproxy_config 2>/dev/null
      fi
    done
  done
done

# 生成物必须是合法 JSON，一次批量校验（避免每个组合都起一个 Windows 进程）。
# 注意：这里用的是 Windows 版 python，必须把手上的 POSIX 路径转成 Windows 路径，
# 否则 os.listdir('/d/...') 直接 FileNotFoundError。
OUT_WIN=$(cygpath -w "${OUT}" 2>/dev/null || printf '%s' "${OUT}")
"${PY}" - "${OUT_WIN}" <<'PYEOF'
import json, os, sys
out = sys.argv[1]
bad, good = [], 0
for fn in sorted(os.listdir(out)):
    if not fn.endswith(".json"):
        continue
    p = os.path.join(out, fn)
    try:
        json.load(open(p, encoding="utf-8"))
        good += 1
    except Exception as exc:  # noqa: BLE001
        bad.append("%s: %s" % (fn, exc))
        os.remove(p)
with open(os.path.join(out, "jsoncheck.txt"), "w", encoding="utf-8") as fh:
    fh.write("合法 JSON: %d\n" % good)
    for b in bad:
        fh.write("非法: %s\n" % b)
print("合法 JSON: %d ；非法: %d" % (good, len(bad)))
for b in bad:
    print("  非法: " + b)
PYEOF

rm -f "${OUT}/engine.conf"
rm -rf "${MATRIX_KEYDIR}"
echo "生成组合: ${ok}   跳过: ${skipped}   输出目录: ${OUT}"
echo "---- 生成清单 ----"
cat "${OUT}/manifest.txt"
echo "---- 产出文件 ----"
ls -1 "${OUT}" | sed -n '1,60p'
