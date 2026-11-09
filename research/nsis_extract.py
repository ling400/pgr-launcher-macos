#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
nsis_extract.py — 战双帕弥什（PGR）官方 PC 安装器解包器（纯 Python，无第三方依赖）。

支持的格式：NSIS 3.x Unicode，非 solid + raw DEFLATE 数据块（PGR 的
pclauncher.exe / PGR_install_x.y.z.exe 都是这种）。

用法：
  python3 research/nsis_extract.py <installer.exe> [--out-dir DIR] [--list-only]

流程（与 7-Zip NsisIn.cpp 的 Open2/Parse 对齐）：
 1. 在文件里找 0xEFBEADDE + "NullsoftInst" 签名；header 起点 = 签名起点 - 4。
 2. firstheader: flags(4) | magic(16) | headerSize(4) | arcSize(4)
    数据流起点 = header 起点 + 28；先读 u32 判断压缩方式。
    - u32 == headerSize          → 头未压缩
    - u32 最高位为 1 且第 3 字节 0x80 → 非 solid，头块单独压缩：
      compSize = u32 & 0x7fffffff，压缩流从 (数据流起点+4) 开始
    - 否则视为 raw deflate
 3. 头块解压后：4 字节 + 8 个 block header（本类安装器为 8 字节：
    Offset u32, Num u32），顺序：
    pages, sections, entries, strings, langtables, ctlcolors, font, data
 4. entries 区每条命令固定 28 字节：opcode + 6*params。EW_EXTRACTFILE(20)：
    param[1] = 文件名（Unicode 字符串表字符偏移），param[2] = 数据块偏移。
 5. 数据块：在 data 起点 (数据流起点 + 4 + compHeaderSize) + pos 处读 u32：
    最高位 1 → 该块 raw DEFLATE 压缩，解压得内容；否则原样存储。
 6. Unicode 字符串表：strings block 起始到 langtables 起始，UTF-16LE，
    以 0x0000 分隔。
"""

import os
import re
import sys
import zlib
import struct
import hashlib

SIG = b"\xef\xbe\xad\xdeNullsoftInst"
BHO_NAMES = ["pages", "sections", "entries", "strings",
             "langtables", "ctlcolors", "font", "data"]
# 与 7-Zip NsisIn.cpp 的 EW_* 顺序一致（NSIS-3 Unicode）
EW_EXTRACTFILE = 20
EW_CREATEDIR = 11
EW_SETFLAG = 13
OPNAMES = {0: "EW_INVALID", 1: "EW_RET", 2: "EW_NOP", 3: "EW_ABORT",
           4: "EW_QUIT", 5: "EW_CALL", 6: "EW_UPDATETEXT", 7: "EW_SLEEP",
           8: "EW_BRINGTOFRONT", 9: "EW_CHDETAILSVIEW", 10: "EW_SETFILEATTR",
           11: "EW_CREATEDIR", 12: "EW_IFFILEEXISTS", 13: "EW_SETFLAG",
           14: "EW_IFFLAG", 15: "EW_GETFLAG", 16: "EW_RENAME",
           17: "EW_GETFULLPATHNAME", 18: "EW_SEARCHPATH",
           19: "EW_GETTEMPFILENAME", 20: "EW_EXTRACTFILE", 21: "EW_DELETEFILE",
           22: "EW_MESSAGEBOX", 23: "EW_RMDIR", 24: "EW_STRLEN",
           25: "EW_ASSIGNVAR", 26: "EW_STRCMP", 27: "EW_READENVSTR",
           28: "EW_INTCMP", 29: "EW_INTOP", 30: "EW_INTFMT",
           31: "EW_PUSHPOP", 32: "EW_FINDWINDOW", 33: "EW_SENDMESSAGE",
           34: "EW_ISWINDOW", 35: "EW_GETDLGITEM", 36: "EW_SETCTLCOLORS",
           37: "EW_SETBRANDINGIMAGE", 38: "EW_CREATEFONT",
           39: "EW_SHOWWINDOW", 40: "EW_SHELLEXEC", 41: "EW_EXECUTE",
           42: "EW_GETFILETIME", 43: "EW_GETDLLVERSION", 44: "EW_REGISTERDLL"}


class NsisError(Exception):
    pass


def parse_nsis(raw: bytes):
    i = raw.find(SIG)
    if i < 0:
        raise NsisError("NullsoftInst signature not found")
    pos = i - 4
    flags = struct.unpack_from("<I", raw, pos)[0]
    header_size, arc_size = struct.unpack_from("<II", raw, pos + 20)
    dso = pos + 28                      # data stream offset
    first = struct.unpack_from("<I", raw, dso)[0]

    info = {"nsis_offset": pos, "flags": flags,
            "header_size": header_size, "arc_size": arc_size,
            "data_stream_offset": dso, "first_u32": first,
            "method": None, "compressed_header_size": None,
            "header_offset": None}

    # ---- 头部块压缩方式
    if first == header_size:
        info["method"] = "stored"
        hdr = raw[dso + 4:dso + 4 + header_size]
        data_base = dso + 4 + header_size
    elif raw[dso + 3] == 0x80:
        # 非 solid：SS SS SS 80 | 压缩流。压缩方式看 sig[4]：
        #   0x5D 开头 → LZMA（带 props/dict），否则 raw DEFLATE
        comp = first & 0x7FFFFFFF
        info["compressed_header_size"] = comp
        if raw[dso + 4] == 0x5D or raw[dso + 4] in (0x00, 0x01):
            raise NsisError("non-solid LZMA not supported by this script "
                            "(PGR installers use deflate)")
        info["method"] = "deflate-nonsolid"
        hdr = zlib.decompress(raw[dso + 4:dso + 4 + comp], -15)
        data_base = dso + 4 + comp
    else:
        # solid 流（LZMA/deflate），头部与数据同一压缩流
        info["method"] = "solid-unknown"
        raise NsisError("solid stream installers not supported")
    info["header_offset"] = dso
    info["data_base"] = data_base
    if len(hdr) != header_size:
        raise NsisError(f"header size mismatch {len(hdr)} != {header_size}")

    # ---- 头块内 block headers
    is64 = False
    if len(hdr) >= 4 + 12 * 8:
        is64 = True
        for k in range(8):
            if struct.unpack_from("<I", hdr, 4 + 12 * k + 4)[0] != 0:
                is64 = False
                break
    bho = 12 if is64 else 8
    blocks = {}
    order = []
    for k, name in enumerate(BHO_NAMES):
        off = struct.unpack_from("<I", hdr, 4 + bho * k)[0]
        num = struct.unpack_from("<I", hdr, 4 + bho * k + bho - 4)[0]
        blocks[name] = {"offset": off, "num": num, "index": k}
        order.append((name, off, num))
    info["is64"] = is64
    info["bho_size"] = bho
    info["blocks"] = blocks
    for name, off, num in order:
        if off:
            ranges = [x[1] for x in order if x[1] > off]
            end = min(ranges) if ranges else len(hdr)
            limit = len(hdr)
            for name2, off2, num2 in order:
                if off2 > off and off2 < limit:
                    limit = off2
            blocks[name]["size"] = limit - off
    info["header_sha256"] = hashlib.sha256(hdr).hexdigest()

    # ---- 字符串表
    s_off = blocks["strings"]["offset"]
    lt_off = blocks["langtables"]["offset"]
    stbl = hdr[s_off:lt_off]
    is_unicode = (struct.unpack_from("<H", stbl, 0)[0] == 0) if len(stbl) >= 2 else False
    info["unicode"] = is_unicode
    info["strings"] = split_unicode_strings(stbl) if is_unicode else []

    # ---- entries（固定 28 字节记录）
    e_off = blocks["entries"]["offset"]
    e_num = blocks["entries"]["num"]
    entries = []
    for k in range(e_num):
        rec = struct.unpack_from("<7i", hdr, e_off + k * 28)
        entries.append(rec)
    info["entries"] = entries

    # ---- 文件项 + 提取
    files = []
    for rec in entries:
        if rec[0] != EW_EXTRACTFILE:
            continue
        name_idx = rec[2]
        data_pos = rec[3]
        mtime_lo, mtime_hi = rec[4], rec[5]
        mtime = (mtime_hi << 32) + (mtime_lo & 0xFFFFFFFF)
        files.append({"name": resolve_string(info, name_idx),
                      "name_char_offset": name_idx,
                      "pos": data_pos, "mtime": mtime})
    info["files"] = files
    return info, hdr, raw


def split_unicode_strings(blob: bytes):
    """把 UTF-16LE 字符串表拆成 [(char_offset, text)]，char_offset 就是
    命令里 param 使用的字符偏移。"""
    out = []
    i = 0
    n = len(blob)
    while i + 1 < n:
        start = i
        chars = []
        while i + 1 < n:
            ch = blob[i] | (blob[i + 1] << 8)
            i += 2
            if ch == 0:
                break
            chars.append(ch)
        out.append((start // 2, "".join(chr(c) if c < 0x110000 else "?" for c in chars)))
    return out


def resolve_string(info, char_off):
    for off, s in info["strings"]:
        if off == char_off:
            return s
    # 有些字符串只引用前缀（如 "\x03X" 指向 $INSTDIR）；退回扫描最近一条
    for off, s in info["strings"]:
        if off >= char_off:
            return s
    return f"<str@{char_off}>"


def sanitize_name(s: str) -> str:
    """NSIS 字符串里的前缀变量（$INSTDIR 等）会以 0x02/0x03 开头的字符
    编码出现；只保留 Windows 允许的文件名部分。"""
    s = re.sub(r"[\x00-\x1f]", "", s)
    s = s.replace("\\", "/")
    return s.lstrip("/")


def extract_file(info, raw, f: dict) -> bytes:
    base = info["data_base"] + f["pos"]
    size = struct.unpack_from("<I", raw, base)[0]
    if (size >> 31) & 1:
        comp = size & 0x7FFFFFFF
        return zlib.decompress(raw[base + 4:base + 4 + comp], -15)
    return raw[base + 4:base + 4 + size]


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    path = argv[1]
    out_dir = None
    list_only = "--list-only" in argv
    if "--out-dir" in argv:
        out_dir = argv[argv.index("--out-dir") + 1]

    raw = open(path, "rb").read()
    print(f"# {path}  ({len(raw):,} bytes)")
    print(f"# sha256 {hashlib.sha256(raw).hexdigest()}")
    info, hdr, _ = parse_nsis(raw)
    print(f"NSIS header @ {info['nsis_offset']:#x}  method={info['method']}  "
          f"header_size={info['header_size']}  arc_size={info['arc_size']:,}")
    print(f"unicode={info['unicode']}  is64={info['is64']}  "
          f"entries={len(info['entries'])}")
    print(f"strings table: {info['blocks']['strings']}")
    print(f"data_base={info['data_base']:#x}")
    print()
    print(f"{'pos':>12}  {'size':>12}  {'md5':16}  name")
    total = 0
    for f in info["files"]:
        try:
            data = extract_file(info, raw, f)
        except Exception as e:  # noqa: BLE001
            print(f"{f['pos']:>12}  {'ERR':>12}  {'':16}  {f['name']} ({e})")
            continue
        total += len(data)
        md5 = hashlib.md5(data).hexdigest()
        f["size"] = len(data)
        f["md5"] = md5
        name = sanitize_name(f["name"])
        print(f"{f['pos']:>12}  {len(data):>12,}  {md5:16}  {name}")
        if out_dir and not list_only:
            dest = os.path.join(out_dir, os.path.basename(name) or f"file_{f['pos']}")
            os.makedirs(os.path.dirname(dest) or out_dir, exist_ok=True)
            with open(dest, "wb") as fh:
                fh.write(data)
    print(f"\ntotal {len(info['files'])} files, {total:,} bytes")
    if out_dir and not list_only:
        print(f"extracted to {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
