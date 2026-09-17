#!/usr/bin/env bash
# 在「22 端口被整体拦 + DNS 解析到的那个 IP 连不通」的网络下把 main 推上 GitHub。
#
# 关键发现（2026-09-17 实测）：
#   * 本机直连 github.com:443 时通时断，但 **换一个 GitHub IP 就稳定**：
#     `git -c http.curloptResolve=github.com:443:<ip>` 可以让 6 个已知 IP 全部一次成功。
#     已知可用 IP：140.82.112.3 140.82.113.3 140.82.114.3 140.82.116.3
#                  20.27.177.113 20.200.245.247 20.26.156.215
#   * git 版本要 ≥ 2.30 才有 http.curloptResolve（本机 2.55.0）。
#   * 沙箱自带出口代理对本仓库的 git 会随机 502；局域网代理已不存在。
#
# 每轮都重新 ls-remote 核对，远端 SHA == 本地 HEAD 才算成功。
# 用法：bash .workbuddy/tools/push_retry.sh [每个 IP 尝试的轮数，默认 2]
export PATH="/c/Users/shang/.workbuddy/binaries/PortableGit/versions/1.2.0/usr/bin:/c/Users/shang/.workbuddy/binaries/PortableGit/versions/1.2.0/mingw64/bin:/c/Windows/System32:/c/Windows:$PATH"

cd "$(dirname "$0")/../.." || exit 1
ROUNDS=${1:-2}
URL=https://github.com/dakerclaw/reality.git
LOCAL=$(git rev-parse HEAD)
IPS="140.82.112.3 140.82.113.3 140.82.114.3 140.82.116.3 20.27.177.113 20.200.245.247 20.26.156.215"

# 清掉代理环境变量 = 直连；HTTP/1.1 更抗中间设备干扰；低速就早退，别干等。
clean() { env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy \
          GIT_TERMINAL_PROMPT=0 "$@"; }
g() { clean git -c "http.curloptResolve=github.com:443:$1" \
              -c http.version=HTTP/1.1 -c http.lowSpeedLimit=200 -c http.lowSpeedTime=20 "${@:2}"; }

echo "本地 HEAD=${LOCAL}  开始 $(date -Is)"
for round in $(seq 1 "${ROUNDS}"); do
  for ip in ${IPS}; do
    g "${ip}" push "${URL}" HEAD:main 2>&1 | tail -3
    REMOTE=$(g "${ip}" ls-remote "${URL}" refs/heads/main 2>/dev/null | cut -f1)
    echo "轮 ${round} / IP ${ip}: 远端=${REMOTE:-取不到}  ($(date +%H:%M:%S))"
    if [ "${REMOTE}" = "${LOCAL}" ]; then
      echo "SUCCESS 远端=${REMOTE}"
      exit 0
    fi
  done
done
echo "FAILED 本地=${LOCAL}（推送可能其实已成功，只是核对那一步没连上；再跑一次本脚本即可确认）"
exit 1
