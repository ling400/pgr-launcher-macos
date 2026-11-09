#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
parse_pe.py - 纯 Python 的 PE 分析器（不依赖 pefile）。

用途：解析战双帕弥什官方 Windows 安装器 pclauncher.exe
  python3 research/parse_pe.py /tmp/pclauncher.exe [--dump-strings]

输出：
  1) DOS/PE/可选头/COFF 关键字段
  2) 节表 + 每节 sha256/熵（识别打包/压缩：熵 > 7.2 基本可判压缩或加密）
  3) 打包器指纹（NSIS / Electron / CEF / .NET / Inno / MSI / 自研）
  4) 字符串提取：ASCII + UTF-16LE，URL/域名/JSON/区域关键词过滤
  5) --dump-strings 时把全部字符串写到 research/samples/
"""

import sys
import re
import json
import hashlib
import math
import os
import struct
from collections import Counter

ASCII_MIN = 5
UTF16_MIN = 4


def entropy(data: bytes) -> float:
    if not data:
        return 0.0
    c = Counter(data)
    n = len(data)
    return -sum((v / n) * math.log2(v / n) for v in c.values())


# ---------------------------------------------------------------- PE parsing
def parse_pe(path: str) -> dict:
    with open(path, "rb") as f:
        raw = f.read()

    out = {"file": os.path.abspath(path), "size": len(raw),
           "sha256": hashlib.sha256(raw).hexdigest(),
           "md5": hashlib.md5(raw).hexdigest()}

    if raw[:2] != b"MZ":
        out["error"] = "not MZ"
        return out, raw

    e_lfanew = struct.unpack_from("<I", raw, 0x3C)[0]
    out["e_lfanew"] = e_lfanew
    if raw[e_lfanew:e_lfanew + 4] != b"PE\0\0":
        out["error"] = "no PE signature at e_lfanew"
        return out, raw
    out["dos_stub"] = raw[0x40:e_lfanew].decode("latin-1", "replace").strip("\0")

    coff = e_lfanew + 4
    (machine, nsect, timestamp, symoff, nsyms, opt_size,
     characteristics) = struct.unpack_from("<HHIIIHH", raw, coff)
    machine_map = {0x14c: "i386 (x86)", 0x8664: "AMD64 (x64)", 0xaa64: "ARM64"}
    out["machine"] = machine_map.get(machine, hex(machine))
    out["nsections"] = nsect
    out["timestamp"] = timestamp

    opt = coff + 20
    magic = struct.unpack_from("<H", raw, opt)[0]
    out["opt_magic"] = {0x10b: "PE32", 0x20b: "PE32+"}.get(magic, hex(magic))
    if magic == 0x10b:
        (subsystem_off, subsys_major_off) = (opt + 68, opt + 48)
        dll_char_off = opt + 70
    else:
        (subsystem_off, subsys_major_off) = (opt + 68, opt + 48)
        dll_char_off = opt + 70
    out["linker_version"] = "%d.%d" % (
        struct.unpack_from("<B", raw, opt + 2)[0],
        struct.unpack_from("<B", raw, opt + 3)[0])
    out["subsystem"] = struct.unpack_from("<H", raw, subsystem_off)[0]
    out["subsystem_name"] = {2: "GUI", 3: "CUI"}.get(out["subsystem"], "?")
    out["dll_characteristics"] = hex(struct.unpack_from("<H", raw, dll_char_off)[0])
    out["image_base"] = struct.unpack_from("<I", raw, opt + 28)[0] if magic == 0x10b else struct.unpack_from("<Q", raw, opt + 24)[0]

    # data directories
    dd_off = opt + (96 if magic == 0x10b else 112)
    nrva = struct.unpack_from("<I", raw, dd_off - 4)[0]
    dirs = {}
    names = ["export", "import", "resource", "exception", "security", "reloc",
             "debug", "arch", "globalptr", "tls", "load_config", "bound_import",
             "iat", "delay_import", "com_descriptor", "reserved"]
    for i in range(min(nrva, 16)):
        rva, size = struct.unpack_from("<II", raw, dd_off + i * 8)
        if rva or size:
            dirs[names[i] if i < len(names) else str(i)] = {"rva": rva, "size": size}
    out["data_directories"] = dirs

    sec_off = opt + opt_size
    sections = []
    for i in range(nsect):
        base = sec_off + i * 40
        name = raw[base:base + 8].rstrip(b"\0").decode("latin-1", "replace")
        vsize, vaddr, rsize, raddr = struct.unpack_from("<IIII", raw, base + 8)
        chars = struct.unpack_from("<I", raw, base + 36)[0]
        data = raw[raddr:raddr + rsize]
        sections.append({
            "name": name, "vaddr": vaddr, "vsize": vsize,
            "rawptr": raddr, "rawsize": rsize,
            "entropy": round(entropy(data), 4),
            "hash": hashlib.sha256(data).hexdigest()[:16],
            "characteristics": hex(chars),
            "is_code": bool(chars & 0x20),
            "is_exec": bool(chars & 0x20000000),
        })
    out["sections"] = sections
    out["overlay_size"] = max(0, len(raw) - max((s["rawptr"] + s["rawsize"]) for s in sections))
    return out, raw


# ---------------------------------------------------------------- strings
def extract_ascii(raw: bytes, minlen=ASCII_MIN):
    pat = re.compile(rb"[\x20-\x7e]{%d,}" % minlen)
    for m in pat.finditer(raw):
        yield m.start(), m.group().decode("ascii")


def extract_utf16le(raw: bytes, minlen=UTF16_MIN):
    # 逐个 2 字节对齐扫描，允许 1 字节偏移也扫（有些字符串不对齐）
    pat = re.compile((r"(?:[\x20-\x7e]\x00){%d,}" % minlen).encode())
    seen = set()
    for off in (0, 1):
        for m in pat.finditer(raw, off):
            s = m.group().decode("utf-16le", "ignore")
            if s not in seen:
                seen.add(s)
                yield m.start(), s


# ---------------------------------------------------------------- fingerprints
PACKER_SIGS = [
    ("NSIS (Nullsoft Scriptable Install System)",
     [b"NullsoftInst", b"NSIS Error", b"nsis_", b"Nullsoft Install System"]),
    ("Inno Setup", [b"Inno Setup", b"InnoSetup", b"Setup.dat"]),
    ("Electron", [b"electron.asar", b"Electron", b"chrome-sandbox", b"v8_context_snapshot"]),
    ("CEF/Chromium", [b"CefSharp", b"libcef.dll", b"cef.pak", b"Chrome_RenderWidgetHostHWND"]),
    (".NET / CLR", [b"mscoree.dll", b"_CorExeMain", b"BSJB", b"System.Private.CoreLib"]),
    ("Unity", [b"UnityPlayer.dll", b"UnityPlayer", b"unity default resources"]),
    ("Unreal", [b"UnrealEngine", b"UE4Game", b"UE5Game"]),
    ("InstallShield/MSI", [b"InstallShield", b"MSIExec", b"Windows Installer"]),
    ("VMProtect/Themida",
     [b"VMProtect", b"Themida", b".vmp0", b".themida"]),
    ("Enigma/PECompact/UPX", [b"UPX0", b"UPX1", b"PECompact", b"Enigma"]),
]

# 战双相关关键词（ASCII 与 UTF-16 都找）
KEYWORDS = [
    "kurogame", "kuro", "pgr", "zspms", "punishing", "grayraven", "gray-raven",
    "launcher", "gamestarter", "version", "manifest", "cdn", "update", "client",
    "install", "patch", "reslist", "asset", "https://", "http://",
    "steam", "epic", "windows", "webview", "cef", "electron",
]
URL_RE = re.compile(rb"(?:https?|ftp)://[\x21-\x7e]{4,300}", re.I)
DOMAIN_RE = re.compile(rb"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
                       rb"(?:com|net|org|cn|io|cc|tv|co|game|games|xyz|top|vip|info|club|app)\b", re.I)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    path = sys.argv[1]
    dump = "--dump-strings" in sys.argv
    info, raw = parse_pe(path)
    if "error" in info and "sections" not in info:
        print(json.dumps(info, indent=2, ensure_ascii=False))
        return 1

    print("=" * 78)
    print("PE 基础信息")
    print("=" * 78)
    for k in ("file", "size", "sha256", "md5", "machine", "opt_magic",
              "linker_version", "subsystem_name", "image_base", "e_lfanew",
              "nsections", "overlay_size"):
        print(f"  {k:16s}: {info[k]}")
    print(f"  timestamp       : {info['timestamp']} (unixtime, UTC)")
    print(f"  data_directories: {json.dumps(info['data_directories'], ensure_ascii=False)}")
    print(f"  dos stub        : {info.get('dos_stub','')!r}")

    print("\n" + "=" * 78)
    print("节表（熵 > 7.2 表示高度压缩/加密；NSIS 的 .ndata 通常是 LZMA 压缩体）")
    print("=" * 78)
    print(f"  {'name':10s} {'vaddr':>10s} {'rawptr':>10s} {'rawsize':>12s} {'entropy':>8s}  flags")
    for s in info["sections"]:
        fl = ("C" if s["is_code"] else "-") + ("X" if s["is_exec"] else "-")
        print(f"  {s['name']:10s} {s['vaddr']:#010x} {s['rawptr']:#010x} "
              f"{s['rawsize']:>12,d} {s['entropy']:>8.3f}  {fl}")

    print("\n" + "=" * 78)
    print("打包器 / 框架指纹")
    print("=" * 78)
    hits = []
    for label, sigs in PACKER_SIGS:
        found = [s.decode("latin-1") for s in sigs if s in raw]
        if found:
            hits.append({"packer": label, "evidence": found})
            print(f"  [HIT] {label}: {found}")
    if not hits:
        print("  (无已知打包器签名)")

    # NSIS 专有：定位 NSIS 数据块头（'NullsoftInst' 之后是 LZMA/bzip2 头）
    idx = raw.find(b"NullsoftInst")
    if idx >= 0:
        print(f"\n  NSIS firstheader at file offset {idx:#x}: {raw[idx:idx+32]!r}")

    # ------------------------------------------------------------ strings
    print("\n" + "=" * 78)
    print("URL / 域名 / 关键词 提取")
    print("=" * 78)
    urls = Counter()
    for m in URL_RE.finditer(raw):
        urls[m.group().decode("latin-1")] += 1
    # UTF-16LE URL 扫描
    for off in (0, 1):
        for m in re.finditer((r"(?:h\x00t\x00t\x00p\x00s?\x00:\x00/\x00/\x00"
                              r"[\x21-\x7e]\x00{4,400})").encode("latin-1"), raw, off):
            urls[m.group().decode("utf-16le", "ignore")] += 1

    print(f"  -- 直接出现在文件中的 URL（{len(urls)} 个）--")
    for u, c in sorted(urls.items(), key=lambda kv: -kv[1]):
        print(f"     x{c:<3d} {u}")

    domains = Counter(d.decode("latin-1").lower() for d in DOMAIN_RE.findall(raw))
    print(f"\n  -- 出现的域名（{len(domains)} 个，按频率）--")
    for d, c in domains.most_common(80):
        print(f"     x{c:<4d} {d}")

    # 关键词命中（ASCII 上下文）
    print("\n  -- 关键词 ASCII 命中计数 --")
    low = raw.lower()
    for kw in KEYWORDS:
        n = low.count(kw.encode("latin-1"))
        if n:
            print(f"     {kw:14s} x{n}")

    print("\n  -- 关键词 UTF-16LE 命中计数 --")
    for kw in KEYWORDS:
        n = raw.count(kw.encode("utf-16le"))
        if n:
            print(f"     {kw:14s} x{n}")

    if dump:
        os.makedirs("research/samples", exist_ok=True)
        ascii_lines = [s for _, s in extract_ascii(raw)]
        utf16_lines = [s for _, s in extract_utf16le(raw)]
        with open("research/samples/pclauncher.strings.ascii.txt", "w",
                  encoding="utf-8", errors="replace") as f:
            f.write("\n".join(ascii_lines))
        with open("research/samples/pclauncher.strings.utf16le.txt", "w",
                  encoding="utf-8", errors="replace") as f:
            f.write("\n".join(utf16_lines))
        print(f"\n  已写出 research/samples/pclauncher.strings.ascii.txt "
              f"({len(ascii_lines)} 行)")
        print(f"  已写出 research/samples/pclauncher.strings.utf16le.txt "
              f"({len(utf16_lines)} 行)")

    with open("research/samples/pclauncher.pe.json", "w", encoding="utf-8") as f:
        json.dump(info, f, indent=2, ensure_ascii=False)
    print("\n  PE 结构 JSON -> research/samples/pclauncher.pe.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
