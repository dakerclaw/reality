#!/bin/sh
# 第三轮：能否把 python 基础镜像升到最新（3.14）而仍跑得动 tgbot.py。
# python-telegram-bot 13.x 依赖 3.13 被移除的 stdlib 模块 imghdr，
# 这里验证 PyPI 上的 standard-imghdr 回填包能否补上。
set -u

echo "########## 0. VPS 上 tgbot.py 的位置 ##########"
ls -l /opt/reality/tgbot/tgbot.py /opt/reality/tgbot.py 2>&1
TG=$(ls /opt/reality/tgbot/tgbot.py /opt/reality/tgbot.py 2>/dev/null | head -1)
echo "TG=$TG"

echo
echo "########## 1. python:3.14-alpine + standard-imghdr + python-telegram-bot==13.5 ##########"
docker run --rm -v /opt/reality:/mnt/reality:ro -e TGBOT_TOKEN=dummy -e TG_PATH="$TG" python:3.14-alpine sh -c '
  set -e
  python -V
  pip install --no-cache-dir --quiet standard-imghdr python-telegram-bot==13.5 qrcode[pil]==7.4.2
  echo "--- imports ---"
  python -c "import imghdr; print(\"  imghdr ok ->\", imghdr.__file__)"
  python -c "import telegram; print(\"  telegram\", telegram.__version__)"
  python -c "from telegram.ext import Updater, CommandHandler, MessageHandler, Filters, CallbackQueryHandler; print(\"  telegram.ext ok\")"
  python -c "import qrcode; print(\"  qrcode ok\")"
  echo "--- py_compile 真实 tgbot.py ---"
  if [ -n "$TG_PATH" ] && [ -f "$TG_PATH" ]; then
    python -m py_compile "$TG_PATH" && echo "  py_compile ok: $TG_PATH"
  else
    echo "  未找到 tgbot.py，跳过"
  fi
' 2>&1 | tail -25

echo
echo "########## 2. 同样条件下换成 python-telegram-bot==13.15（13.x 末版）##########"
docker run --rm -v /opt/reality:/mnt/reality:ro -e TG_PATH="$TG" python:3.14-alpine sh -c '
  python -V
  pip install --no-cache-dir --quiet standard-imghdr python-telegram-bot==13.15 qrcode[pil]==7.4.2 >/tmp/p.log 2>&1 || { echo "pip FAIL"; tail -5 /tmp/p.log; exit 0; }
  python -c "import telegram; print(\"  telegram\", telegram.__version__)" 2>&1 | tail -4
  python -c "from telegram.ext import Updater, CommandHandler, MessageHandler, Filters, CallbackQueryHandler; print(\"  telegram.ext ok\")" 2>&1 | tail -4
  if [ -n "$TG_PATH" ] && [ -f "$TG_PATH" ]; then python -m py_compile "$TG_PATH" && echo "  py_compile ok"; fi
' 2>&1 | tail -15

echo
echo "########## DONE ##########"
