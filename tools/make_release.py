#!/usr/bin/env python3
"""发布 deb 到 GitHub Release: GH_TOKEN=xxx python tools/make_release.py packages/xxx.deb"""
import glob
import json
import os
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"
REPO = "Corpse-zhao/MGLiveSkin"
VER = "0.1.8"
TAG = "v" + VER
TOKEN = os.environ.get("GH_TOKEN", "")
if not TOKEN:
    sys.exit("请设置 GH_TOKEN")


def call(method, url, data=None, headers=None, raw_body=None, content_type=None):
    body = raw_body if raw_body is not None else (json.dumps(data).encode() if data is not None else None)
    h = {"Authorization": "token " + TOKEN, "Accept": "application/vnd.github+json",
         "User-Agent": "mgliveskin-release"}
    if content_type:
        h["Content-Type"] = content_type
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, data=body, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            out = r.read()
            return json.loads(out) if out else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:500]
        if e.code == 422 and "already_exists" in detail and method == "POST":
            return None
        raise RuntimeError("HTTP %d: %s" % (e.code, detail))


deb = sys.argv[1] if len(sys.argv) > 1 else sorted(glob.glob("packages/*.deb"))[-1]
assert os.path.exists(deb), deb
assert VER in os.path.basename(deb), "文件名不含版本号，拒绝发布: " + deb
name = os.path.basename(deb)
print("发布", deb)

body_text = """MGLiveSkin %s — MG Live 车辆图片换装（roothide / arm64e）

**本版更新（0.1.8）**
- 新增「锁定当前大小 / 解锁大小」：按页面各自记住尺寸，锁定后图片大小不再随缩放变化，位置仍可拖动
- 锁定时「① 框选车图区域」「自定义大小」会同步更新锁定值，不会被旧值压回去
- 诊断新增 `[lock]` 行，与 `[region]` / `[lastAdjust]` 一起定位尺寸问题

安装：Sileo 添加源后直接安装，或手机浏览器打开下方 deb 链接用 Filza 安装；装完**杀掉 MG Live 后台重开**。
使用：爱车页 / 车辆状态页 → 点右侧「换装」悬浮球 →「① 框选车图区域」拖框 →「② 替换车辆图片」选图 →「微调位置 / 大小」或「自定义大小」→「锁定当前大小」。
诊断：菜单「导出视图树（诊断）」后把 /var/mobile/Documents/MGLiveSkin/viewtree.txt 发回。
恢复：菜单「恢复原车图」（区域、锁定、图片、尺寸记录一并清空）。日志同目录 log.txt。
""" % VER

rel = call("POST", API + "/repos/%s/releases" % REPO,
           {"tag_name": TAG, "target_commitish": "main", "name": "MGLiveSkin " + VER,
            "body": body_text, "draft": False, "prerelease": False})
if rel is None:
    rel = call("GET", API + "/repos/%s/releases/tags/%s" % (REPO, TAG))
rid = rel["id"]

assets = call("GET", API + "/repos/%s/releases/%d/assets" % (REPO, rid))
for a in assets:
    if a["name"] == name:
        call("DELETE", API + "/repos/%s/releases/assets/%d" % (REPO, a["id"]))
local_size = os.path.getsize(deb)
url = "https://uploads.github.com/repos/%s/releases/%d/assets?name=%s" % (REPO, rid, name)
data = open(deb, "rb").read()
up = call("POST", url, raw_body=data, content_type="application/vnd.debian.binary-package")
assert up.get("size") == local_size, "上传大小不一致"
print("✅ 发布成功")
print(rel.get("html_url", ""))
print("直链: https://github.com/%s/releases/download/%s/%s" % (REPO, TAG, name))
