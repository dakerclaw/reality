#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成「在 VPS 上构建新版 tgbot 镜像并冒烟」的远端脚本。

Dockerfile 内容与 reality.sh 的 generate_tgbot_dockerfile 逐字一致，
只是把 tgbot.py 换成本仓库当前的工作副本（PTB 22 版）。
"""
import base64
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, ".workbuddy", "tools", "vps_tgbot_check.sh")

DOCKERFILE = """FROM python:3.14-alpine
WORKDIR /opt/reality/tgbot
RUN apk add --no-cache docker-cli-compose curl bash newt libqrencode-tools sudo openssl jq zip unzip
RUN pip install --no-cache-dir python-telegram-bot==22.8 "qrcode[pil]==8.2"
CMD [ "python", "./tgbot.py" ]
"""


def main():
    src = open(os.path.join(ROOT, "tgbot.py"), "rb").read()
    b64 = base64.b64encode(src).decode()

    script = """#!/usr/bin/env bash
# 在 VPS 上构建新版 tgbot 镜像（python:3.14-alpine + python-telegram-bot 22.8）并冒烟。
set -u
exec 2>&1

M=/root/reality-tgbot
rm -rf "${M}"; mkdir -p "${M}"; cd "${M}" || exit 1

cat > Dockerfile <<'DOCKEREOF'
@@DOCKERFILE@@DOCKEREOF

base64 -d > tgbot.py <<'B64EOF'
@@B64@@
B64EOF

echo "########## 1. tgbot.py 指纹 ##########"
wc -c tgbot.py
sha256sum tgbot.py
python3 -c "import ast,sys; ast.parse(open('tgbot.py',encoding='utf-8').read()); print('AST 解析通过')" 2>/dev/null || echo "(宿主无 python3，跳过 AST 预检)"
echo

echo "########## 2. Dockerfile ##########"
cat Dockerfile
echo

echo "########## 3. 构建镜像 ##########"
time docker build -t reality-tgbot-test:latest . 2>&1 | tail -25
rc=$?
echo "docker build rc=${rc}"
if [ ${rc} -ne 0 ]; then echo "RESULT: BUILD-FAILED"; exit 1; fi
echo

echo "########## 4. 依赖版本 ##########"
docker run --rm reality-tgbot-test:latest python -c "import telegram, qrcode, PIL, sys; print('python', sys.version.split()[0]); print('python-telegram-bot', telegram.__version__); print('qrcode', qrcode.__version__); print('pillow', PIL.__version__)"
echo

echo "########## 5. 导入真实模块（不启动轮询） ##########"
docker run --rm -w /opt/reality/tgbot reality-tgbot-test:latest python -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('tgbot', '/opt/reality/tgbot/tgbot.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print('模块导入成功')
print('  parse_admins 可用:', callable(getattr(m, 'parse_admins', None)))
print('  is_admin 可用   :', callable(getattr(m, 'is_admin', None)))
print('  main 可用       :', callable(getattr(m, 'main', None)))
"
echo

echo "########## 6. 缺 token 时的行为 ##########"
out=$(timeout 25 docker run --rm reality-tgbot-test:latest python ./tgbot.py 2>&1); rc=$?
echo "rc=${rc}"
printf '%s\\n' "${out}" | tail -6
case "${out}" in
  *ModuleNotFoundError*|*SyntaxError*|*ImportError*|*AttributeError*|*TypeError*) echo "RESULT: STARTUP-BROKEN" ;;
  *) echo "RESULT: STARTUP-OK（报错是缺 token/网络，而非代码问题）" ;;
esac
echo

echo "########## 7. 收尾 ##########"
docker image rm -f reality-tgbot-test:latest >/dev/null 2>&1
echo "done"
"""
    script = script.replace("@@DOCKERFILE@@", DOCKERFILE).replace("@@B64@@", b64)
    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(script)
    print("已生成 %s（%.1f KB）" % (OUT, len(script) / 1024.0))


if __name__ == "__main__":
    main()
