#!/bin/sh
# 第二轮：certbot 镜像（用 --entrypoint 绕开它自带的 certbot ENTRYPOINT）
# 以及 python 镜像能升到哪个版本（python-telegram-bot==13.5 需要 imghdr）
set -u

CERT=certbot/certbot:v5.8.0

echo "########## A. certbot v5.8.0 基础信息 ##########"
docker run --rm --entrypoint sh "$CERT" -c '
  head -3 /etc/os-release
  echo -n "apk     : "; command -v apk || echo "NO APK"
  echo -n "certbot : "; certbot --version 2>&1
  echo -n "python  : "; python --version 2>&1 || true
' 2>&1

echo
echo "########## B. certbot Dockerfile 里那行 apk add 是否可解 ##########"
docker run --rm --entrypoint sh "$CERT" -c '
  apk add --no-cache --simulate docker-cli-compose curl uuidgen 2>&1 | tail -12
  echo "simulate-exit=$?"
' 2>&1

echo
echo "########## C. certbot v5.8.0 是否仍支持本项目用到的命令行参数 ##########"
docker run --rm --entrypoint sh "$CERT" -c '
  certbot certonly --help all 2>&1 | grep -E -- "--(standalone|key-type|elliptic-curve|agree-tos|register-unsafely-without-email|deploy-hook)\b" | head -12
' 2>&1

echo
echo "########## D. python 各版本 × python-telegram-bot==13.5 ##########"
for PV in 3.11-alpine 3.12-alpine 3.13-alpine; do
  echo "---- python:$PV ----"
  docker run --rm "python:$PV" sh -c '
    python -V
    pip install --no-cache-dir --quiet python-telegram-bot==13.5 qrcode[pil]==7.4.2 >/tmp/pip.log 2>&1
    echo "pip-exit=$?"
    python -c "import telegram; print(\"  telegram\", telegram.__version__)" 2>&1 | tail -3
    python -c "from telegram.ext import Updater, CommandHandler, MessageHandler, Filters; print(\"  ext/Updater/Filters ok\")" 2>&1 | tail -3
  ' 2>&1
done

echo
echo "########## DONE ##########"
