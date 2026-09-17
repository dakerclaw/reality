#!/usr/bin/env python3
"""查询本项目所用各官方镜像的最新稳定版本。

数据源（权威优先）：
  1. GitHub Releases API          -> XTLS/Xray-core, SagerNet/sing-box
  2. Docker Hub /v2/.../tags      -> library/nginx, library/haproxy,
                                     library/python, certbot/certbot
     (按 last_updated 倒序取，才能拿到真正最新的 tag)

网络：本沙箱自带出口代理对部分域名会随机 502；
      可用 --proxy http://host:port 走代理重试。
结果打印到 stdout，并写入同目录 latest_images.txt。
"""
import argparse
import json
import re
import ssl
import sys
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

OUT = Path(__file__).with_name("latest_images.txt")
TIMEOUT = 45
CTX = ssl.create_default_context()

PROXY = None


def opener():
    if PROXY:
        h = urllib.request.ProxyHandler({"http": PROXY, "https": PROXY})
        return urllib.request.build_opener(h, urllib.request.HTTPSHandler(context=CTX))
    return urllib.request.build_opener(urllib.request.HTTPSHandler(context=CTX))


def get_json(url, headers=None, retries=3):
    last = None
    for i in range(retries):
        try:
            req = urllib.request.Request(url, headers=headers or {})
            with opener().open(req, timeout=TIMEOUT) as r:
                return json.loads(r.read().decode("utf-8"))
        except Exception as e:  # noqa: BLE001
            last = e
    raise last


# ---------- GitHub Releases ----------

def gh_latest(repo):
    d = get_json(f"https://api.github.com/repos/{repo}/releases/latest")
    return d["tag_name"], d.get("published_at", "")


def gh_release_tags(repo):
    d = get_json(f"https://api.github.com/repos/{repo}/releases?per_page=20")
    return [(x["tag_name"], x.get("published_at", ""), x.get("prerelease", False)) for x in d]


# ---------- Docker Hub ----------

def dh_recent_tags(repo, pages=2, page_size=100):
    """按 last_updated 倒序返回 (tag, last_updated)。"""
    out = []
    for p in range(1, pages + 1):
        url = (
            f"https://hub.docker.com/v2/repositories/{repo}/tags"
            f"?page_size={page_size}&page={p}&ordering=last_updated"
        )
        d = get_json(url)
        for r in d.get("results", []):
            out.append((r["name"], r.get("last_updated", "")))
        if not d.get("next"):
            break
    return out


def pick(tags, pred, limit=12):
    seen = []
    for t, ts in tags:
        if pred(t):
            seen.append((t, ts))
        if len(seen) >= limit:
            break
    return seen


def ver_key(tag):
    m = re.match(r"^v?(\d+)\.(\d+)(?:\.(\d+))?", tag)
    if not m:
        return (0, 0, 0)
    return tuple(int(x) if x else 0 for x in m.groups())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--proxy", default=None)
    args = ap.parse_args()
    global PROXY
    PROXY = args.proxy

    L = []
    L.append("# 官方源最新版本查询")
    L.append(f"# 采集时间: {datetime.now().isoformat(timespec='seconds')}")
    L.append(f"# 代理: {PROXY or '(系统默认)'}")
    L.append("")

    # 1. Xray-core
    try:
        tag, pub = gh_latest("XTLS/Xray-core")
        L.append(f"[Xray-core] releases/latest = {tag}  ({pub})")
        L.append("  最近 release 序列:")
        for t, p, pre in gh_release_tags("XTLS/Xray-core"):
            L.append(f"    - {t}  {p}{'  [pre]' if pre else ''}")
    except Exception as e:  # noqa: BLE001
        L.append(f"[Xray-core] ERROR {type(e).__name__}: {e}")
    L.append("")

    # 2. sing-box
    try:
        tag, pub = gh_latest("SagerNet/sing-box")
        L.append(f"[sing-box] releases/latest = {tag}  ({pub})")
        L.append("  最近 release 序列:")
        for t, p, pre in gh_release_tags("SagerNet/sing-box"):
            L.append(f"    - {t}  {p}{'  [pre]' if pre else ''}")
    except Exception as e:  # noqa: BLE001
        L.append(f"[sing-box] ERROR {type(e).__name__}: {e}")
    L.append("")

    # 3. nginx
    try:
        tags = dh_recent_tags("library/nginx")
        L.append("[nginx] 最近更新的 tag(前 20):")
        for t, ts in tags[:20]:
            L.append(f"    - {t}  {ts}")
        stable = [t for t, _ in tags if re.match(r"^\d+\.\d+\.\d+$", t)]
        alpine = [t for t, _ in tags if re.match(r"^\d+\.\d+\.\d+-alpine$", t)]
        L.append(f"  -> 最新稳定: {stable[:6]}")
        L.append(f"  -> 最新 alpine: {alpine[:6]}")
    except Exception as e:  # noqa: BLE001
        L.append(f"[nginx] ERROR {type(e).__name__}: {e}")
    L.append("")

    # 4. haproxy
    try:
        tags = dh_recent_tags("library/haproxy")
        L.append("[haproxy] 最近更新的 tag(前 20):")
        for t, ts in tags[:20]:
            L.append(f"    - {t}  {ts}")
        stable = [t for t, _ in tags if re.match(r"^\d+\.\d+\.\d+$", t)]
        L.append(f"  -> 最新稳定: {stable[:8]}")
        # 取一下 3.x / 2.8 系列
        allt = [t for t, _ in tags]
        L.append(f"  -> 含 2.8 的: {[t for t in allt if t.startswith('2.8')][:8]}")
        L.append(f"  -> 含 3. 的: {[t for t in allt if t.startswith('3.')][:8]}")
    except Exception as e:  # noqa: BLE001
        L.append(f"[haproxy] ERROR {type(e).__name__}: {e}")
    L.append("")

    # 5. python alpine
    try:
        tags = dh_recent_tags("library/python")
        al = [t for t, _ in tags if re.match(r"^3\.\d+(\.\d+)?-alpine$", t)]
        L.append("[python] 最近更新的 alpine tag(前 20):")
        for t, ts in tags[:20]:
            L.append(f"    - {t}  {ts}")
        L.append(f"  -> 3.x-alpine: {al[:12]}")
        L.append(f"  -> 排序后最高: {sorted(set(al), key=ver_key, reverse=True)[:8]}")
    except Exception as e:  # noqa: BLE001
        L.append(f"[python] ERROR {type(e).__name__}: {e}")
    L.append("")

    # 6. certbot
    try:
        tags = dh_recent_tags("certbot/certbot")
        L.append("[certbot] 最近更新的 tag(前 20):")
        for t, ts in tags[:20]:
            L.append(f"    - {t}  {ts}")
        v = [t for t, _ in tags if re.match(r"^v\d+\.\d+\.\d+$", t)]
        L.append(f"  -> vX.Y.Z: {v[:8]}")
    except Exception as e:  # noqa: BLE001
        L.append(f"[certbot] ERROR {type(e).__name__}: {e}")
    L.append("")

    text = "\n".join(L)
    print(text)
    OUT.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    sys.exit(main())
