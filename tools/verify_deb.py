#!/usr/bin/env python3
"""本地解包校验 deb: python tools/verify_deb.py packages/xxx.deb"""
import io
import lzma
import struct
import sys
import tarfile

path = sys.argv[1]
raw = open(path, "rb").read()
assert raw[:8] == b"!<arch>\n", "not a deb"
off, control_text, payload = 8, None, None
while off < len(raw):
    hdr = raw[off:off + 60]
    if len(hdr) < 60:
        break
    name = hdr[0:16].decode().strip()
    size = int(hdr[48:58].decode().strip())
    off += 60
    body = raw[off:off + size]
    off += size + (size % 2)
    if name.startswith("control.tar"):
        with tarfile.open(fileobj=io.BytesIO(body)) as tf:
            control_text = tf.extractfile("./control").read().decode()
            for n in tf.getnames():
                if n.endswith("postinst"):
                    mode = tf.extractfile(n) and [m for m in tf.getmembers() if m.name == n][0].mode
                    print("postinst mode:", oct(mode) if mode else "?")
    if name.startswith("data.tar"):
        payload = body

print("=== control ===")
print(control_text)
assert "iphoneos-arm64e" in control_text
assert "Version: 0.1.3" in control_text

tarbytes = None
for opener in (
    lambda b: tarfile.open(fileobj=io.BytesIO(b), mode="r:gz"),
    lambda b: tarfile.open(fileobj=io.BytesIO(b), mode="r:xz"),
    lambda b: tarfile.open(fileobj=lzma.LZMAFile(io.BytesIO(b), format=lzma.FORMAT_ALONE), mode="r:"),
):
    try:
        with opener(payload) as tf:
            names = tf.getnames()
            dylib = None
            plist_bytes = None
            for n in names:
                if n.endswith(".dylib"):
                    dylib = tf.extractfile(n).read()
                if n.endswith("MGLiveSkin.plist"):
                    plist_bytes = tf.extractfile(n).read()
            tarbytes = (names, dylib, plist_bytes)
        break
    except Exception:
        continue
assert tarbytes, "payload 解不开"
names, dylib, plist_bytes = tarbytes
print("=== payload ===")
for n in sorted(names):
    if not n.endswith("/"):
        print("  ", n)
print("=== filter plist ===")
print(plist_bytes.decode("utf-8", "replace") if plist_bytes else "缺失!")
assert b"com.saicmotor.mgapp" in (plist_bytes or b"")

assert dylib[:4] in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"), "not fat"
n = struct.unpack(">I", dylib[4:8])[0]
off, subs = 8, []
for _ in range(n):
    ct, cs, o, sz, al = struct.unpack(">IIIII", dylib[off:off + 20])
    off += 20
    subs.append(cs & 0x00FFFFFF)
print("cpusubtypes:", subs, "(0=arm64, 2=arm64e)")
assert 0 in subs and 2 in subs


def has(s):
    return s.encode("utf-8") in dylib or s.encode("utf-16-le") in dylib


for kw in ("com.saicmotor.mgapp", "0.1.3", "MGLiveSkin"):
    print("关键字", kw, has(kw))
    assert has(kw)
print("✅ 校验通过")
