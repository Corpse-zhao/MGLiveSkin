#!/usr/bin/env python3
"""全量推送 MGLiveSkin 源码到 GitHub（REST API，规避 Windows git push 代理问题）。
用法: GH_TOKEN=xxx python tools/push_repo.py "commit message"
"""
import base64
import io
import json
import os
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"
REPO = "Corpse-zhao/MGLiveSkin"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP_DIRS = {".git", ".theos", "packages", "outputs", "__pycache__"}
SKIP_FILES = {".DS_Store"}
TEXT_EXT = {".m", ".h", ".x", ".plist", ".md", ".yml", ".yaml", ".py", ".sh", ".txt", ""}
EXEC_NAMES = {"postinst", "prerm", "preinst", "postrm", "extrainst_"}

TOKEN = os.environ.get("GH_TOKEN", "")
if not TOKEN:
    sys.exit("请设置 GH_TOKEN")


def call(method, path, data=None, expect=(200, 201, 204)):
    body = json.dumps(data).encode("utf-8") if data is not None else None
    req = urllib.request.Request(API + path, data=body, method=method,
                                 headers={"Authorization": "token " + TOKEN,
                                          "Accept": "application/vnd.github+json",
                                          "Content-Type": "application/json",
                                          "User-Agent": "mgliveskin-push"})
    try:
        with urllib.request.urlopen(req, timeout=40) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:600]
        if e.code not in expect:
            raise RuntimeError("%s %s -> HTTP %d: %s" % (method, path, e.code, detail))
        return {}


def local_files():
    out = {}
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if fn in SKIP_FILES:
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, ROOT).replace("\\", "/")
            with open(full, "rb") as f:
                data = f.read()
            ext = os.path.splitext(fn)[1].lower()
            if ext in TEXT_EXT and b"\r\n" in data:
                data = data.replace(b"\r\n", b"\n")
                print("~ CRLF->LF", rel)
            mode = "100755" if (fn in EXEC_NAMES or ext == ".sh") else "100644"
            out[rel] = (data, mode)
    return out


def ensure_repo():
    try:
        call("GET", "/repos/" + REPO)
        print("仓库已存在")
    except RuntimeError:
        print("创建仓库...")
        call("POST", "/user/repos", {"name": "MGLiveSkin", "private": False,
                                     "description": "MG Live 车辆图片换装 tweak (roothide)"},
             expect=(201,))
    try:
        call("GET", "/repos/%s/git/ref/heads/main" % REPO)
    except RuntimeError:
        print("仓库为空，建初始提交...")
        call("PUT", "/repos/%s/contents/.init" % REPO,
             {"message": "init", "content": base64.b64encode(b"init\n").decode()},
             expect=(201, 200))


def main():
    msg = sys.argv[1] if len(sys.argv) > 1 else "update MGLiveSkin"
    ensure_repo()
    files = local_files()
    print("本地文件数:", len(files))
    entries = []
    for rel, (data, mode) in sorted(files.items()):
        blob = call("POST", "/repos/%s/git/blobs" % REPO,
                    {"content": base64.b64encode(data).decode(), "encoding": "base64"})
        entries.append({"path": rel, "mode": mode, "type": "blob", "sha": blob["sha"]})
        print("  +", rel, mode)
    tree = call("POST", "/repos/%s/git/trees" % REPO, {"tree": entries})
    ref = call("GET", "/repos/%s/git/ref/heads/main" % REPO)
    parent = ref["object"]["sha"]
    commit = call("POST", "/repos/%s/git/commits" % REPO,
                  {"message": msg, "tree": tree["sha"], "parents": [parent]})
    call("PATCH", "/repos/%s/git/refs/heads/main" % REPO, {"sha": commit["sha"], "force": False})

    remote = call("GET", "/repos/%s/git/trees/main?recursive=1" % REPO)
    remote_files = {i["path"] for i in remote["tree"] if i["type"] == "blob"}
    local_set = set(files)
    if remote_files != local_set:
        print("!! 远端与本地不一致")
        print("  缺少:", sorted(local_set - remote_files))
        print("  多余:", sorted(remote_files - local_set))
        sys.exit(1)
    print("✅ 推送完成，远端文件数:", len(remote_files))
    print("commit:", commit["sha"])


if __name__ == "__main__":
    main()
