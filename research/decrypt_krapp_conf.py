#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
decrypt_krapp_conf.py — 解密 PGR（库洛）官方启动器内嵌的 Assets/KRApp.conf。

来源：安装器 NSIS 包里的 KRLauncher.zip → <版本>/Assets/KRApp.conf
格式：base64( XOR(utf8-json, 0x63) )
（0x63 由首字节反推：'{' ^ 0x18 = 0x63）

用法：
  python3 research/decrypt_krapp_conf.py <KRApp.conf> [--json-out FILE]

输出：解密后的 JSON（含 gameId / appId / appKey / configUrl /
backUpConfigUrl / launcherConfigUrl / cdn 等）。
"""

import sys
import json
import base64

KEY = 0x63


def decrypt(path: str) -> str:
    raw = open(path, "rb").read()
    blob = base64.b64decode(raw, validate=False)
    data = bytes(b ^ KEY for b in blob)
    return data.decode("utf-8-sig", "replace")


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    txt = decrypt(argv[1])
    if "--json-out" in argv:
        out = argv[argv.index("--json-out") + 1]
        obj = json.loads(txt)
        with open(out, "w", encoding="utf-8") as f:
            json.dump(obj, f, indent=2, ensure_ascii=False)
        print(f"written {out}")
    print(txt)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
