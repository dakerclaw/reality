#!/bin/sh
# 在 VPS 上实测候选新镜像是否可用 / 是否与生成本项目的配置兼容。
# 只做 pull + 一次性容器，不动现有部署。
set -u

XRAY=ghcr.io/xtls/xray-core:26.3.27
SING=ghcr.io/sagernet/sing-box:v1.14.1
NGX=nginx:1.30.5
HAP=haproxy:3.4.4
CERT=certbot/certbot:v5.8.0
PY=python:3.14-alpine

echo "########## 1. 拉取 ##########"
for img in "$XRAY" "$SING" "$NGX" "$HAP" "$CERT" "$PY"; do
  printf '%-46s ' "$img"
  if docker pull -q "$img" >/dev/null 2>&1; then echo OK; else echo FAIL; fi
done

echo
echo "########## 2. 引擎版本 ##########"
echo "-- xray --";   docker run --rm "$XRAY" version 2>&1 | head -3
echo "-- sing-box --"; docker run --rm "$SING" version 2>&1 | head -3

echo
echo "########## 3. 基础镜像版本 ##########"
echo -n "nginx: ";    docker run --rm "$NGX" nginx -v 2>&1
echo -n "haproxy: ";  docker run --rm "$HAP" haproxy -v 2>&1 | head -1
echo -n "python: ";   docker run --rm "$PY" python -V 2>&1
echo "-- certbot --"
docker run --rm "$CERT" sh -c 'head -3 /etc/os-release; echo -n "apk: "; command -v apk || echo "NO APK"; certbot --version' 2>&1

echo
echo "########## 4. certbot Dockerfile 的 apk add 是否可解 ##########"
docker run --rm "$CERT" sh -c 'apk add --no-cache --simulate docker-cli-compose curl uuidgen 2>&1 | tail -8' 2>&1

echo
echo "########## 5. python-telegram-bot==13.5 在新 python 镜像上能否安装/导入 ##########"
docker run --rm "$PY" sh -c '
  pip install --no-cache-dir --quiet python-telegram-bot==13.5 qrcode[pil]==7.4.2 2>&1 | tail -20
  echo "--- import test ---"
  python -c "import telegram; print(\"telegram\", telegram.__version__)" 2>&1
  python -c "from telegram.ext import Updater, CommandHandler; print(\"ext ok\")" 2>&1
' 2>&1 | tail -30

echo
echo "########## 6. haproxy 3.4.4 语法校验（本项目用到的全部指令，取条件分支的并集）##########"
cat > /tmp/hap-test.cfg <<'CFG'
global
  ssl-default-bind-options ssl-min-ver TLSv1.2
defaults
  option http-server-close
  timeout connect 5s
  timeout client 50s
  timeout client-fin 1s
  timeout server-fin 1s
  timeout server 50s
  timeout tunnel 50s
  timeout http-keep-alive 1s
  timeout queue 15s
frontend http
  mode http
  bind :::8080 v4v6
  use_backend certbot if { path_beg /.well-known/acme-challenge }
  acl letsencrypt-acl path_beg /.well-known/acme-challenge
  redirect scheme https if !letsencrypt-acl
  use_backend default
frontend tls
  bind :::8443 v4v6 ssl crt /usr/local/etc/haproxy/server.pem alpn h2,http/1.1
  mode http
  http-request set-header Host example.com
  use_backend certbot if { path_beg /.well-known/acme-challenge }
  use_backend engine if { path_beg /abcd1234 }
  use_backend default
frontend tlsraw
  bind :::8443 v4v6
  mode tcp
  use_backend engine
backend engine
  retry-on conn-failure empty-response response-timeout
  mode http
  server engine engine:8443 check tfo proto h2 ssl verify none
backend engine2
  retry-on conn-failure empty-response response-timeout
  mode tcp
  server engine engine:8443 check tfo
backend certbot
  mode http
  server certbot certbot:80
backend default
  mode http
  server nginx nginx:80
CFG
docker run --rm -v /tmp/hap-test.cfg:/tmp/hap-test.cfg:ro "$HAP" haproxy -c -f /tmp/hap-test.cfg 2>&1
rm -f /tmp/hap-test.cfg

echo
echo "########## 7. nginx 1.30.5 默认站点语法 ##########"
docker run --rm "$NGX" nginx -t 2>&1

echo
echo "########## DONE ##########"
