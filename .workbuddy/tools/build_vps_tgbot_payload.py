#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成「在 VPS 上构建新版 tgbot 镜像并冒烟」的远端脚本。

Dockerfile 内容与 reality.sh 的 generate_tgbot_dockerfile 逐字一致，
只是把 tgbot.py 换成本仓库当前的工作副本（PTB 22 版）。

几个必须踩住的坑（都由第一版实测暴露出来）：
  * 真实部署把仓库根 **绑定挂载** 成 /opt/reality（compose 里的 `- ../:/opt/reality`），
    所以镜像里**没有** tgbot.py —— 冒烟容器必须同样把 tgbot.py 挂进去，否则一律
    FileNotFoundError，而且「启动失败」会被误判成 OK。
  * `time docker build ... | tail -25` 之后的 `$?` 是 **tail** 的退出码（本脚本没有
    pipefail），必须把 docker 的退出码单独取出来，否则构建失败也报 rc=0。
  * `qrcode` 没有 `__version__`，版本探测要用 importlib.metadata。
  * 「缺 token」是负向测试：必须同时断言**提示文本**与**退出码 1**，不能只要不崩就算过。
"""
import base64
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, ".workbuddy", "tools", "vps_tgbot_check.sh")

DOCKERFILE = """FROM python:3.14-alpine
WORKDIR /opt/reality/tgbot
RUN apk add --no-cache docker-cli-compose curl bash libqrencode-tools sudo openssl jq zip unzip
RUN pip install --no-cache-dir python-telegram-bot==22.8 "qrcode[pil]==8.2"
CMD [ "python", "./tgbot.py" ]
"""


def main():
    src = open(os.path.join(ROOT, "tgbot.py"), "rb").read()
    b64 = base64.b64encode(src).decode()

    script = """#!/usr/bin/env bash
# 在 VPS 上构建新版 tgbot 镜像（python:3.14-alpine + python-telegram-bot 22.8）并冒烟。
# 全程在 /root/reality-tgbot 独立目录内进行：不碰 /opt/reality、不碰运行中的容器。
set -u
exec 2>&1
fails=0

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
# 注意：不能写成 `docker build ... | tail`，那样 $? 是 tail 的退出码。
if docker build -t reality-tgbot-test:latest . > build.log 2>&1; then build_rc=0; else build_rc=$?; fi
tail -20 build.log
echo "docker build rc=${build_rc}（命中缓存层数：$(grep -c CACHED build.log)）"
if [ "${build_rc}" -ne 0 ]; then
  echo "RESULT: BUILD-FAILED"
  exit 1
fi
echo

echo "########## 4. 依赖版本（对照 Dockerfile 的 pin） ##########"
docker run --rm reality-tgbot-test:latest python -c "
import sys, importlib.metadata as md
print('python', sys.version.split()[0])
print('python-telegram-bot', md.version('python-telegram-bot'))
print('qrcode', md.version('qrcode'))
print('pillow', md.version('pillow'))
import telegram, qrcode, PIL
print('模块导入 OK')
" 2>&1 | tee deps.txt
for want in 'python-telegram-bot 22.8' 'qrcode 8.2'; do
  if grep -qF "${want}" deps.txt; then echo "OK  ${want}"; else echo "FAIL 期望 ${want}"; fails=$((fails + 1)); fi
done
echo

echo "########## 5. 导入真实模块（不启动轮询） ##########"
echo "  按真实部署的挂载方式把 tgbot.py 映到 /opt/reality/tgbot/tgbot.py"
out=$(docker run --rm -w /opt/reality/tgbot \
      -v "${M}/tgbot.py":/opt/reality/tgbot/tgbot.py:ro \
      reality-tgbot-test:latest python -c "
import importlib.util
spec = importlib.util.spec_from_file_location('tgbot', '/opt/reality/tgbot/tgbot.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print('模块导入成功')
print('  parse_admins 可用:', callable(getattr(m, 'parse_admins', None)))
print('  is_admin 可用   :', callable(getattr(m, 'is_admin', None)))
print('  main 可用       :', callable(getattr(m, 'main', None)))
" 2>&1); rc=$?
printf '%s\\n' "${out}"
if [ "${rc}" -eq 0 ] && printf '%s' "${out}" | grep -q '模块导入成功'; then
  echo "OK  模块可导入"
else
  echo "FAIL 模块导入失败（rc=${rc}）"; fails=$((fails + 1))
fi
echo

echo "########## 6. 缺 token 时的行为（负向测试） ##########"
out=$(timeout 30 docker run --rm -w /opt/reality/tgbot \
      -v "${M}/tgbot.py":/opt/reality/tgbot/tgbot.py:ro \
      reality-tgbot-test:latest python ./tgbot.py 2>&1); rc=$?
echo "rc=${rc}"
printf '%s\\n' "${out}" | tail -6
case "${out}" in
  *"BOT_TOKEN environment variable is not set."*)
    if [ "${rc}" -eq 1 ]; then
      echo "OK  缺 token 时打印预期提示并以 1 退出"
    else
      echo "FAIL 提示正确但退出码 ${rc}（期望 1）"; fails=$((fails + 1))
    fi ;;
  *Traceback*|*FileNotFoundError*|*ModuleNotFoundError*|*ImportError*|*SyntaxError*|*AttributeError*|*TypeError*)
    echo "FAIL 启动即崩（代码或环境问题）"; fails=$((fails + 1)) ;;
  *)
    echo "FAIL 输出不符预期（既非缺 token 提示，也非已知异常）"; fails=$((fails + 1)) ;;
esac
echo

echo "########## 7. 收尾 ##########"
docker image rm -f reality-tgbot-test:latest >/dev/null 2>&1
if [ "${fails}" -eq 0 ]; then echo "RESULT: ALL-GREEN"; else echo "RESULT: HAS-FAILURES (${fails})"; fi
"""
    script = script.replace("@@DOCKERFILE@@", DOCKERFILE).replace("@@B64@@", b64)
    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(script)
    print("已生成 %s（%.1f KB）" % (OUT, len(script) / 1024.0))


if __name__ == "__main__":
    main()
