#!/usr/bin/env python3
"""推送前本地自检（30 秒内完成）"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BAD = []


def read(rel):
    with open(os.path.join(ROOT, rel), "r", encoding="utf-8") as f:
        return f.read()


def strip_comments(s):
    s = re.sub(r"//[^\n]*", "", s)
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    return s


def strip_strings(s):
    return re.sub(r'"(?:\\.|[^"\\])*"', '""', s)


def check_brackets(rel):
    raw = read(rel)
    t = strip_strings(strip_comments(raw))
    for op, cl in [("{", "}"), ("(", ")"), ("[", "]")]:
        if t.count(op) != t.count(cl):
            BAD.append("%s: %s%s 不配平 %d/%d" % (rel, op, cl, t.count(op), t.count(cl)))


def check_objc(rel):
    raw = read(rel)
    t = strip_comments(raw)
    blocks = t.count("@implementation") + t.count("@interface")
    if blocks != t.count("@end"):
        BAD.append("%s: @interface+@implementation(%d)/@end(%d) 不配平" %
                   (rel, blocks, t.count("@end")))
    impls = re.findall(r"@implementation\s+(\w+)", t)
    if len(impls) != len(set(impls)):
        BAD.append("%s: 同一类有多个 @implementation" % rel)
    for ext in re.finditer(r"@interface\s+(\w+)\s*\(\s*\)", t):
        own_impl = t.find("@implementation " + ext.group(1))
        if own_impl >= 0 and ext.start() > own_impl:
            BAD.append("%s: %s 类扩展出现在自己的 @implementation 之后" % (rel, ext.group(1)))
    # 格式串 NSString 实参误用 %s
    for m in re.finditer(r"(?:stringWithFormat|appendFormat)\s*\(", t):
        seg = t[m.start():m.start() + 900]
        cut = seg.find(";")
        if cut > 0:
            seg = seg[:cut + 1]
        if "%s" in seg and ".UTF8String" not in seg and "char *" not in seg:
            BAD.append("%s: 格式串含 %%s 且未见 .UTF8String" % rel)
    # 禁用 ARC 桥接错误
    for v in re.findall(r"\(\s*void\s*\*\s*\)\s*([A-Za-z_]\w*)", t):
        if v not in ("old", "orig", "imp") and "IMP" not in v:
            BAD.append("%s: (void *)%s 需要 (__bridge void *)" % (rel, v))


def check_version():
    ctl = read("control")
    hdr = read("MGManager.h")
    workflow = read(".github/workflows/build.yml")
    v1 = re.search(r"^Version:\s*(\S+)", ctl, re.M).group(1)
    v2 = re.search(r'MG_VERSION\s+@"([0-9.]+)"', hdr).group(1)
    if v1 != v2:
        BAD.append("版本号不一致 control=%s header=%s" % (v1, v2))
    if "Version: %s" % v1 not in workflow:
        BAD.append("CI workflow 版本号未同步")


def check_files():
    for rel in ("control", "layout/DEBIAN/postinst", "MGLiveSkin.plist"):
        b = open(os.path.join(ROOT, rel), "rb").read()
        if b"\r\n" in b:
            BAD.append("%s 含 CRLF" % rel)
    post = os.path.join(ROOT, "layout/DEBIAN/postinst")
    if not open(post, "rb").read().startswith(b"#!/bin/bash"):
        BAD.append("postinst 缺 shebang")


def check_static_used():
    src = read("MGManager.m")
    t = strip_comments(src)
    for name in re.findall(r"^static\s+[\w\s\*]+\b(MG\w+)\s*\(", t, re.M):
        uses = len(re.findall(r"\b" + re.escape(name) + r"\b", t))
        if uses < 2:
            BAD.append("MGManager.m: static %s 定义后未使用" % name)


for f in ("Tweak.x", "MGManager.m"):
    check_brackets(f)
    check_objc(f)
check_version()
check_files()
check_static_used()

if BAD:
    print("🛑 自检失败:")
    for b in BAD:
        print("  -", b)
    sys.exit(1)
print("✅ 本地自检通过")
