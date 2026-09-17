#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""delete_confirm_gate.py 的行为测试：给一段命令行，看钩子给出什么决策。

用法：
  python test_delete_gate.py
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GATE = r"C:\Users\shang\.workbuddy\hooks\delete_confirm_gate.py"
PY = r"C:\Users\shang\.workbuddy\binaries\python\versions\3.13.12\python.exe"

passed = failed = 0


def run(cmd, tool="Bash"):
    payload = json.dumps({"session_id": "t", "hook_event_name": "PreToolUse",
                          "tool_name": tool, "tool_input": {"command": cmd}})
    p = subprocess.run([PY, GATE], input=payload, capture_output=True, text=True,
                       encoding="utf-8")
    out = (p.stdout or "").strip()
    if not out:
        return "none", "no decision"
    try:
        d = json.loads(out)
    except ValueError:
        return "badjson", out[:120]
    dec = d.get("hookSpecificOutput", {}).get("permissionDecision", "?")
    reason = d.get("hookSpecificOutput", {}).get("permissionDecisionReason", "")
    return dec, reason


def check(name, cmd, expect, tool="Bash"):
    global passed, failed
    got, reason = run(cmd, tool)
    ok = got == expect
    if ok:
        passed += 1
        print("  PASS  %-46s -> %s" % (name, got))
    else:
        failed += 1
        print("  FAIL  %-46s -> %s (expected %s)  %s" % (name, got, expect, reason))


def main():
    # 造两个目录：小目录 12 个文件，大目录 640 个文件
    base = tempfile.mkdtemp(prefix="delgate-")
    small = os.path.join(base, "small")
    big = os.path.join(base, "big")
    os.makedirs(small)
    for i in range(12):
        open(os.path.join(small, "f%02d" % i), "w").close()
    os.makedirs(big)
    for i in range(640):
        open(os.path.join(big, "f%03d" % i), "w").close()
    sp, bp = small.replace("\\", "/"), big.replace("\\", "/")

    print("—— 非删除命令：完全不干预 ——")
    check("echo", "echo hello world", "none")
    check("ls", "ls -la /tmp", "none")
    check("grep", "grep -rn 'remove' .selftest2.sh", "none")
    check("cat-file", "cat .gitignore", "none")
    check("quoted-rm-string", 'echo "rm -rf /"', "none")
    check("git-status", "git status --short", "none")

    print("—— 小规模删除：放行 ——")
    check("rm small dir (12)", "rm -rf " + sp, "allow")
    check("rm single file", "rm -f /tmp/delgate-one.txt", "allow")
    check("rm two files", "rm -f /tmp/a.txt /tmp/b.txt", "allow")
    check("rm unresolved var", 'rm -rf "${OUT}"', "allow")
    check("rmdir small", "rmdir " + sp + "/emptydir", "allow")
    check("ps remove-item small", "Remove-Item -Recurse -Force " + sp, "allow", "PowerShell")

    print("—— 大规模删除：要求确认 ——")
    check("rm big dir (640)", "rm -rf " + bp, "ask")
    check("rm big dir chained", "cd /d/WorkBuddy && rm -rf " + bp, "ask")
    check("rm big then small", "rm -rf " + sp + " && rm -rf " + bp, "ask")
    check("find -delete big", "find " + bp + " -delete", "ask")

    print("—— 灾难性模式：无条件确认 ——")
    check("rm -rf /", "rm -rf /", "ask")
    check("rm -rf /*", "rm -rf /*", "ask")
    check("rm -rf ~", "rm -rf ~", "ask")
    check("rm -rf $HOME", "rm -rf $HOME", "ask")
    check("rm -rf /usr", "rm -rf /usr", "ask")
    check("rm --no-preserve-root", "rm -rf --no-preserve-root /", "ask")
    check("rm -rf /c/", "rm -rf /c/", "ask")
    check("find / -delete", "find / -delete", "ask")

    shutil.rmtree(base)
    print("\n%d passed, %d failed" % (passed, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
