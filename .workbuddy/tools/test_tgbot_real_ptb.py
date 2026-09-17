#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用**真实**的 python-telegram-bot 22.8 驱动 tgbot.py（不是桩件）。

.selftest_tgbot.py 用假 telegram 模块跑纯逻辑，这里换真的：
  * 真的 telegram.ext.Application / CommandHandler / CallbackQueryHandler / filters
  * 真的 telegram.Update / Message / Chat / User / CallbackQuery 数据结构
  * 真的 qrcode + PIL
只把「会真的发网络请求 / 真的调用 reality.sh」的几处替换掉（bot 的发送方法与脚本
执行函数）。这样能抓住 PTB 13 → 22 迁移里 API 层面的错配。

用法：
  C:/Users/shang/.workbuddy/binaries/python/envs/default/Scripts/python.exe .workbuddy/tools/test_tgbot_real_ptb.py
"""
import asyncio
import importlib.util
import os
import subprocess
import sys
from datetime import datetime
from types import SimpleNamespace

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TBOT = os.path.join(ROOT, "tgbot.py")
PY = sys.executable

import telegram  # noqa: E402
from telegram import (  # noqa: E402
    CallbackQuery,
    Chat,
    Message,
    MessageEntity,
    Update,
    User,
)
from telegram.ext import (  # noqa: E402
    Application,
    CallbackQueryHandler,
    CommandHandler,
    MessageHandler,
    filters,
)

passed = 0
failed = []


def check(name, got, want):
    global passed
    if got == want:
        passed += 1
        print("  PASS  %-52s %r" % (name, got))
    else:
        failed.append(name)
        print("  FAIL  %-52s got=%r want=%r" % (name, got, want))


def check_true(name, cond):
    check(name, bool(cond), True)


# --------------------------------------------------------------------------
# 假 bot：只拦掉真正会联网的方法
# --------------------------------------------------------------------------
class FakeBot:
    def __init__(self):
        self.messages = []
        self.photos = []
        self.answers = 0

    async def send_message(self, chat_id=None, text=None, reply_markup=None, **kw):
        self.messages.append({"chat_id": chat_id, "text": text, "reply_markup": reply_markup})
        return SimpleNamespace(message_id=len(self.messages))

    async def send_photo(self, chat_id=None, photo=None, caption=None, reply_markup=None, **kw):
        data = photo.read() if hasattr(photo, "read") else b""
        self.photos.append({"chat_id": chat_id, "caption": caption, "bytes": len(data),
                            "reply_markup": reply_markup})
        return SimpleNamespace(message_id=len(self.photos))

    async def answer_callback_query(self, *a, **kw):
        self.answers += 1
        return True


BOT = FakeBot()


def make_update(text=None, username="alice", uid=111, callback=None):
    chat = Chat(id=uid, type="private", username=username)
    user = User(id=uid, first_name="A", is_bot=False, username=username)
    entities = None
    if text and text.startswith('/'):
        entities = [MessageEntity(type=MessageEntity.BOT_COMMAND, offset=0,
                                  length=len(text.split()[0]))]
    msg = Message(message_id=1, date=datetime.now(), chat=chat, from_user=user,
                  text=text, entities=entities)
    msg.set_bot(BOT)
    if callback is None:
        return Update(update_id=1, message=msg)
    query = CallbackQuery(id="q1", from_user=user, chat_instance="c1", data=callback,
                          message=msg)
    query.set_bot(BOT)
    return Update(update_id=2, callback_query=query)


def make_context():
    return SimpleNamespace(bot=BOT, user_data={}, args=[], chat_data={})


def load_module(env=None):
    old = {}
    for k, v in (env or {}).items():
        old[k] = os.environ.get(k)
        os.environ[k] = v
    spec = importlib.util.spec_from_file_location("tgbot_under_test", TBOT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    for k, v in old.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v
    return mod


async def _val(value):
    return value


async def _failing_get_users(reality_error):
    raise reality_error


def main():
    global BOT
    print("== 0. 真实依赖版本 ==")
    check("python-telegram-bot 版本", telegram.__version__, "22.8")
    check("python 主版本 >= 3.13", sys.version_info >= (3, 13), True)

    print("\n== 1. 模块导入（真实 PTB，无任何桩件） ==")
    mod = load_module({"BOT_ADMIN": "alice,123456789"})
    check_true("tgbot.py 可被真实 telegram 导入", hasattr(mod, "Application"))
    check("BOT_ADMINS 解析", sorted(mod.BOT_ADMINS), ["alice"])
    check("BOT_ADMIN_IDS 解析", sorted(mod.BOT_ADMIN_IDS), [123456789])

    print("\n== 2. parse_admins ==")
    pa = mod.parse_admins
    check("空串", pa(""), (set(), set()))
    check("单个用户名", pa("bob"), ({"bob"}, set()))
    check("带 @ 与大写", pa("@Bob"), ({"bob"}, set()))
    check("混合", pa(" bob , 9876543210 "), ({"bob"}, {9876543210}))
    check("15 位以内按 ID", pa("123456789012345"), (set(), {123456789012345}))
    check("16 位按用户名", pa("1234567890123456"), ({"1234567890123456"}, set()))
    check("重复项去重", pa("bob,Bob,bob"), ({"bob"}, set()))

    print("\n== 3. is_admin ==")
    ia = mod.is_admin
    check("按用户名命中", ia(SimpleNamespace(id=5, username="alice")), True)
    check("用户名大小写不敏感", ia(SimpleNamespace(id=5, username="ALICE")), True)
    check("按数字 ID 命中", ia(SimpleNamespace(id=123456789, username=None)), True)
    check("无用户名且非 ID", ia(SimpleNamespace(id=5, username=None)), False)
    check("陌生人", ia(SimpleNamespace(id=6, username="mallory")), False)
    check("chat 为 None", ia(None), False)

    print("\n== 4. Handler 注册（真实 Application） ==")
    app = Application.builder().token("123456:AAHfake-token-for-tests").build()
    app.add_handler(CommandHandler("start", mod.start))
    app.add_handler(CallbackQueryHandler(mod.button))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, mod.user_input))
    check("注册了 3 个 handler", len(app.handlers[0]), 3)
    check_true("run_polling 存在", hasattr(app, "run_polling"))
    check_true("bot 属性可读", app.bot is not None)

    print("\n== 5. filters 行为（真实过滤器对象） ==")
    f = filters.TEXT & ~filters.COMMAND
    check("普通文本被放行", f.check_update(make_update(text="hello")), True)
    check("/start 被挡住", f.check_update(make_update(text="/start")), False)

    print("\n== 6. 异步 handler 真实执行 ==")
    ctx = make_context()

    asyncio.run(mod.start(make_update(), ctx))
    check_true("start 发出了菜单", "Reality User Management Bot" in BOT.messages[-1]["text"])
    kb = BOT.messages[-1]["reply_markup"].inline_keyboard
    check("菜单 3 个按钮", [row[0].callback_data for row in kb],
          ["show_user", "add_user", "delete_user"])

    asyncio.run(mod.start(make_update(username="mallory", uid=999), ctx))
    check("非管理员被拒", BOT.messages[-1]["text"],
          "You are not authorized to use this bot.")

    asyncio.run(mod.button(make_update(callback="add_user"), ctx))
    check("add_user 进入等待输入态", ctx.user_data.get("expected_input"), "username")
    check_true("回调被 answer", BOT.answers >= 1)

    # 把会调用 reality.sh 的函数全部替换掉
    mod.get_users = lambda: _val(["alice"])
    mod.get_configs = lambda u: _val(["vless://" + "x" * 60])
    created = []
    mod.add_user_via_script = lambda u: _val(created.append(u))
    deleted = []
    mod.delete_user_via_script = lambda u: _val(deleted.append(u))

    BOT.messages.clear()
    asyncio.run(mod.user_input(make_update(text="newuser"), ctx))
    check("新用户被创建", created, ["newuser"])
    check_true("回报已创建", any("is created" in m["text"] for m in BOT.messages))
    check_true("随后发配置二维码", len(BOT.photos) >= 1)

    ctx.user_data["expected_input"] = "username"
    BOT.messages.clear()
    asyncio.run(mod.user_input(make_update(text="bad-name!"), ctx))
    check_true("非法用户名被拒", any("can only contains" in m["text"] for m in BOT.messages))

    ctx.user_data["expected_input"] = "username"
    BOT.messages.clear()
    asyncio.run(mod.user_input(make_update(text="alice"), ctx))
    check_true("重名被拒", any("exists" in m["text"] for m in BOT.messages))

    mod.get_users = lambda: _failing_get_users(mod.RealityError("exit status 1"))
    ctx.user_data["expected_input"] = "username"
    BOT.messages.clear()
    asyncio.run(mod.user_input(make_update(text="okname"), ctx))
    check_true("RealityError 被兜住", any("reality failed" in m["text"] for m in BOT.messages))

    mod.get_users = lambda: _failing_get_users(RuntimeError("boom"))
    ctx.user_data["expected_input"] = "username"
    BOT.messages.clear()
    asyncio.run(mod.user_input(make_update(text="okname"), ctx))
    check_true("其它异常也被兜住", any("Unexpected error" in m["text"] for m in BOT.messages))

    print("\n== 7. 删除流程 ==")
    mod.get_users = lambda: _val(["alice", "bob"])
    BOT.messages.clear()
    asyncio.run(mod.button(make_update(callback="delete_user!bob"), ctx))
    check("删除前先问确认", BOT.messages[-1]["text"], 'Are you sure to delete "bob"?')
    BOT.messages.clear()
    asyncio.run(mod.button(make_update(callback="approve_delete!bob"), ctx))
    check("确认后真的删", deleted, ["bob"])

    mod.get_users = lambda: _val(["alice"])
    BOT.messages.clear()
    asyncio.run(mod.button(make_update(callback="delete_user!alice"), ctx))
    check_true("唯一用户拒绝删除", "only user" in BOT.messages[-1]["text"])

    print("\n== 8. 二维码与超长 caption ==")
    png = mod.render_qr("vless://demo@example.com:8443?security=reality#demo")
    check_true("render_qr 产出 PNG", png.read(4) == b"\x89PNG")

    mod.get_users = lambda: _val(["alice"])
    mod.get_configs = lambda u: _val(["vless://short"])
    BOT.photos.clear()
    BOT.messages.clear()
    asyncio.run(mod.show_user(make_update(), ctx, "alice"))
    check("短配置只发一张图", len(BOT.photos), 1)
    check_true("短配置走 caption", "alice" in (BOT.photos[0]["caption"] or ""))
    check_true("二维码字节非空", BOT.photos[0]["bytes"] > 100)

    mod.get_configs = lambda u: _val(["{" + "y" * 2000 + "}"])
    mod.is_ipv6_config = lambda c: True
    BOT.photos.clear()
    BOT.messages.clear()
    asyncio.run(mod.show_user(make_update(), ctx, "alice"))
    check("超长配置仍发图", len(BOT.photos), 1)
    check("超长配置补发文本", len(BOT.messages), 1)
    check_true("图注退化为标签", BOT.photos[0]["caption"].startswith("IPv6 config"))

    print("\n== 9. main() 的两个守卫（子进程） ==")
    r = subprocess.run([PY, TBOT], capture_output=True, text=True,
                       env={**os.environ, "BOT_TOKEN": "", "BOT_ADMIN": "alice"})
    check("缺 BOT_TOKEN 退出码", r.returncode, 1)
    check_true("缺 BOT_TOKEN 有提示", "BOT_TOKEN" in (r.stderr or ""))

    r = subprocess.run([PY, TBOT], capture_output=True, text=True,
                       env={**os.environ, "BOT_TOKEN": "123:ABC", "BOT_ADMIN": ""})
    check("缺 BOT_ADMIN 退出码", r.returncode, 1)
    check_true("缺 BOT_ADMIN 有提示", "BOT_ADMIN" in (r.stderr or ""))

    print("\n%d passed, %d failed" % (passed, len(failed)))
    for name in failed:
        print("  failed: " + name)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
