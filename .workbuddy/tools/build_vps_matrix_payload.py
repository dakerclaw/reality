#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把本地生成的引擎配置矩阵打包成一个可在 VPS 上直接 bash 执行的脚本。

产物：.workbuddy/tools/vps_matrix_check.sh
用法：python .workbuddy/tools/build_vps_matrix_payload.py
然后：SSH_TEST_PW=... python .workbuddy/tools/vps_ssh_run.py --host <ip> --file .workbuddy/tools/vps_matrix_check.sh --timeout 1800
"""
import base64
import glob
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MATRIX = os.path.join(ROOT, ".workbuddy", "tools", "engine-matrix")
OUT = os.path.join(ROOT, ".workbuddy", "tools", "vps_matrix_check.sh")

XRAY = "ghcr.io/xtls/xray-core:26.3.27"
SB = "ghcr.io/sagernet/sing-box:v1.14.1"
NGINX = "nginx:1.30.5"
HAPROXY = "haproxy:3.4.4"
CERTBOT = "certbot/certbot:v5.8.0"
PYIMG = "python:3.14-alpine"


def blocks(patterns):
    out = []
    for pat in patterns:
        for path in sorted(glob.glob(os.path.join(MATRIX, pat))):
            name = os.path.basename(path)
            data = base64.b64encode(open(path, "rb").read()).decode()
            out.append((name, data))
    return out


def main():
    files = blocks(["*.json", "*.haproxy"])
    parts = []
    parts.append(r"""#!/usr/bin/env bash
# 自动生成：在 VPS 上用**新版本镜像**校验 reality.sh 生成的全部配置文件。
# 只读校验，不部署、不改动宿主机的任何服务。
set -u
exec 2>&1

M=/root/reality-matrix
rm -rf "${M}"; mkdir -p "${M}"; cd "${M}" || exit 1

echo "########## 0. 环境 ##########"
uname -sr
docker version --format 'docker server {{.Server.Version}}' 2>&1 | head -1
date -Is
echo

echo "########## 1. 落盘 ${TOTAL} 个待校验文件 ##########"
""")
    for name, data in files:
        parts.append("base64 -d > %s <<'B64EOF'\n%s\nB64EOF\n" % (name, data))

    parts.append(r"""
ls -1 | wc -l
echo

echo "########## 2. 拉取目标镜像 ##########"
for img in @@XRAY@@ @@SB@@ @@NGINX@@ @@HAPROXY@@ @@CERTBOT@@ @@PYIMG@@; do
  if docker pull -q "$img" >/dev/null 2>&1; then echo "pull OK   $img"; else echo "pull FAIL $img"; fi
done
echo

echo "########## 3. 版本确认 ##########"
echo "-- xray:";     docker run --rm @@XRAY@@ version 2>&1 | tr -d '\r' | head -4
echo "-- sing-box:"; docker run --rm @@SB@@ version 2>&1 | tr -d '\r' | head -3
echo "-- nginx:";    docker run --rm @@NGINX@@ nginx -v 2>&1 | tr -d '\r'
echo "-- haproxy:";  docker run --rm @@HAPROXY@@ haproxy -v 2>&1 | tr -d '\r' | head -2
echo "-- certbot:";  docker run --rm --entrypoint certbot @@CERTBOT@@ --version 2>&1 | tr -d '\r'
echo "-- python:";   docker run --rm @@PYIMG@@ python -V 2>&1 | tr -d '\r'
echo

echo "########## 4. 探测各引擎的校验子命令 ##########"
printf '{}' > /tmp/probe.json
pick_mode() { # image  candidate...
  local img=$1; shift
  local v out
  for v in "$@"; do
    out=$(timeout 40 docker run --rm -v /tmp/probe.json:/tmp/c.json "$img" $v /tmp/c.json 2>&1)
    case "$out" in
      *"not defined"*|*"Unknown command"*|*"unknown command"*) continue ;;
    esac
    printf '%s' "$v"; return 0
  done
  return 1
}
XMODE=$(pick_mode @@XRAY@@ "run -test -c" "test -c") || XMODE=""
SMODE=$(pick_mode @@SB@@ "check -c" "run -c") || SMODE=""
echo "xray 校验模式 = '${XMODE}'"
echo "sing-box 校验模式 = '${SMODE}'"
echo

echo "########## 5. xray 引擎配置校验 ##########"
xp=0; xf=0
for f in xray__*.json; do
  if [ -z "${XMODE}" ]; then echo "SKIP ${f} (无可用校验子命令)"; continue; fi
  out=$(timeout 60 docker run --rm -v "${M}/${f}":/tmp/c.json @@XRAY@@ ${XMODE} /tmp/c.json 2>&1); rc=$?
  if [ ${rc} -eq 0 ]; then
    xp=$((xp + 1))
    printf 'PASS %-46s %s\n' "${f}" "$(printf '%s' "${out}" | tr -d '\r' | grep -iE 'warn|deprecat' | head -1)"
  else
    xf=$((xf + 1)); echo "FAIL ${f} (rc=${rc})"; printf '%s\n' "${out}" | tr -d '\r' | head -12
  fi
done
echo "xray: ${xp} 通过 / ${xf} 失败"
echo

echo "########## 6. sing-box 引擎配置校验 ##########"
sp=0; sf=0
for f in sing-box__*.json; do
  if [ -z "${SMODE}" ]; then echo "SKIP ${f} (无可用校验子命令)"; continue; fi
  out=$(timeout 60 docker run --rm -v "${M}/${f}":/tmp/c.json @@SB@@ ${SMODE} /tmp/c.json 2>&1); rc=$?
  if [ ${rc} -eq 0 ]; then
    sp=$((sp + 1))
    printf 'PASS %-46s %s\n' "${f}" "$(printf '%s' "${out}" | tr -d '\r' | grep -iE 'warn|deprecat' | head -1)"
  else
    sf=$((sf + 1)); echo "FAIL ${f} (rc=${rc})"; printf '%s\n' "${out}" | tr -d '\r' | head -14
  fi
done
echo "sing-box: ${sp} 通过 / ${sf} 失败"
echo

echo "########## 7. haproxy 配置校验 ##########"
hp=0; hf=0
for f in *.haproxy; do
  out=$(timeout 40 docker run --rm -v "${M}/${f}":/etc/haproxy/haproxy.cfg @@HAPROXY@@ haproxy -c -f /etc/haproxy/haproxy.cfg 2>&1); rc=$?
  if [ ${rc} -eq 0 ]; then
    hp=$((hp + 1))
    printf 'PASS %-46s %s\n' "${f}" "$(printf '%s' "${out}" | tr -d '\r' | grep -iE 'warn|deprecat' | head -1)"
  else
    hf=$((hf + 1)); echo "FAIL ${f} (rc=${rc})"; printf '%s\n' "${out}" | tr -d '\r' | head -10
  fi
done
echo "haproxy: ${hp} 通过 / ${hf} 失败"
echo

echo "########## 8. nginx ##########"
mkdir -p "${M}/website"
printf '<!doctype html><title>reality</title><h1>reality</h1>' > "${M}/website/index.html"
docker run --rm -v "${M}/website":/usr/share/nginx/html @@NGINX@@ nginx -t 2>&1 | tr -d '\r'
docker run --rm -d --name reality-nginx-probe -v "${M}/website":/usr/share/nginx/html @@NGINX@@ >/dev/null 2>&1
sleep 2
echo "-- 首页响应："
timeout 10 docker exec reality-nginx-probe curl -sS -o /dev/null -w 'http_code=%{http_code}\n' http://127.0.0.1/ 2>&1 | tr -d '\r'
docker rm -f reality-nginx-probe >/dev/null 2>&1
echo

echo "########## 9. 结论 ##########"
echo "xray    ${xp} 通过 / ${xf} 失败"
echo "sing-box ${sp} 通过 / ${sf} 失败"
echo "haproxy ${hp} 通过 / ${hf} 失败"
if [ ${xf} -eq 0 ] && [ ${sf} -eq 0 ] && [ ${hf} -eq 0 ]; then
  echo "RESULT: ALL-GREEN"
else
  echo "RESULT: HAS-FAILURES"
fi
""")

    body = "".join(parts)
    body = body.replace("${TOTAL}", str(len(files)))
    for token, value in (("@@XRAY@@", XRAY), ("@@SB@@", SB), ("@@NGINX@@", NGINX),
                         ("@@HAPROXY@@", HAPROXY), ("@@CERTBOT@@", CERTBOT),
                         ("@@PYIMG@@", PYIMG)):
        body = body.replace(token, value)
    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(body)
    print("已生成 %s" % OUT)
    print("  内嵌文件 %d 个，脚本大小 %.1f KB" % (len(files), len(body) / 1024.0))


if __name__ == "__main__":
    main()
