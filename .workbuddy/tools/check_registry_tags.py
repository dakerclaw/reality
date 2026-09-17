#!/usr/bin/env python3
"""列出 GHCR 上 xray-core / sing-box 的**全部** tag（带分页），并检查目标 tag 是否存在。

GHCR 的 tags/list 默认按字典序返回并截断，必须用 n=?&last=? 翻页，
否则会看不到日期式（25.x/26.x）或 v1.12+ 的新 tag。
"""
import json
import re
import ssl
import sys
import urllib.request

CTX = ssl.create_default_context()
PROXY = None


def http_json(url, headers=None):
    handlers = [urllib.request.HTTPSHandler(context=CTX)]
    if PROXY:
        handlers.append(urllib.request.ProxyHandler({"http": PROXY, "https": PROXY}))
    op = urllib.request.build_opener(*handlers)
    req = urllib.request.Request(url, headers=headers or {})
    with op.open(req, timeout=45) as r:
        return json.loads(r.read().decode()), dict(r.headers)


def all_tags(repo, limit=2000):
    tok = http_json(f"https://ghcr.io/token?scope=repository:{repo}:pull")[0]["token"]
    h = {"Authorization": f"Bearer {tok}", "Accept": "application/json"}
    tags, last = [], None
    while len(tags) < limit:
        url = f"https://ghcr.io/v2/{repo}/tags/list?n=100"
        if last:
            url += f"&last={last}"
        data, hdrs = http_json(url, h)
        page = data.get("tags") or []
        if not page:
            break
        tags.extend(page)
        last = page[-1]
        if len(page) < 100:
            break
    return sorted(set(tags))


def vkey(t):
    m = re.match(r"^v?(\d+)\.(\d+)(?:\.(\d+))?", t)
    return tuple(int(x) if x else 0 for x in m.groups()) if m else (0, 0, 0)


def main():
    global PROXY
    if len(sys.argv) > 1:
        PROXY = sys.argv[1]

    for repo in ("xtls/xray-core", "sagernet/sing-box"):
        tags = all_tags(repo)
        plain = [t for t in tags if re.match(r"^v?\d+\.\d+\.\d+$", t)]
        plain.sort(key=vkey, reverse=True)
        print(f"### {repo}: 共 {len(tags)} 个 tag")
        print("  纯版本号 tag(降序, 前 20): " + ", ".join(plain[:20]))
        for probe in ("26.3.27", "v26.3.27", "25.12.8", "v1.14.1", "1.14.1", "v1.12.23"):
            if probe in tags:
                print(f"  [存在] {probe}")
        print("  最新 8 个非标准 tag: " + ", ".join(sorted(tags)[-8:]))
        print()


if __name__ == "__main__":
    main()
