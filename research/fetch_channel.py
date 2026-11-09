#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fetch_channel.py — 复现 PGR（战双帕弥什）官方 CDN 配置/清单/文件下载。

只依赖标准库（urllib），不需要安装任何东西。
渠道参数来自 research/samples/channels.json（由安装器内嵌 KRApp.conf 解密得到）。

用法：
  # 1. 看某个渠道的远端配置（game index.json）
  python3 research/fetch_channel.py config cn
  python3 research/fetch_channel.py config global
  python3 research/fetch_channel.py config bilibili

  # 2. 下载并校验该渠道的完整文件清单 indexFile.json（~13.7MB）
  python3 research/fetch_channel.py manifest cn --save research/samples/cn_indexFile.json

  # 3. 按清单里的相对路径下载单个文件并校验 md5
  python3 research/fetch_channel.py file cn PGR.exe --save /tmp/PGR.exe
  python3 research/fetch_channel.py file global version.json

  # 4. 拉启动器自更新配置（launcher.zip 版本/大小/md5）
  python3 research/fetch_channel.py launcher cn

说明：
- 单文件 URL = <CDN 根> + <config.baseUrl> + <relative path>（清单条目没有 fromFolder 时）。
  若条目带 fromFolder，则 = <CDN 根> + <fromFolder> + <dest>。
- CDN 根从 config 的 cdnList 里按 P 权重挑一个；P=0 表示不参与加权，但仍可直接用。
- 所有请求都支持 Range（206），ETag 是小写/大写 MD5。
"""

import json
import sys
import hashlib
import gzip
import urllib.request
import urllib.error
import os

HERE = os.path.dirname(os.path.abspath(__file__))
CHANNELS = os.path.join(HERE, "samples", "channels.json")
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) pgr-research/1.0"


def load_channels():
    with open(CHANNELS, encoding="utf-8") as f:
        return json.load(f)


def http_get(url, timeout=60):
    req = urllib.request.Request(url, headers={
        "User-Agent": UA,
        "Accept-Encoding": "gzip, deflate",
        "Accept": "*/*",
    })
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = r.read()
        enc = (r.headers.get("Content-Encoding") or "").lower()
        if "gzip" in enc:
            data = gzip.decompress(data)
        return data, dict(r.headers), r.status


def pick_cdn(ch):
    nodes = [n for n in ch["cdnList"] if n.get("P", 0) > 0]
    if not nodes:
        nodes = ch["cdnList"]
    # 取权重最高（P 最大）的节点，避免随机性
    return max(nodes, key=lambda n: n.get("P", 0))["url"].rstrip("/")


def abs_url(ch, base_url_or_folder):
    return pick_cdn(ch) + "/" + base_url_or_folder.lstrip("/")


def fetch_config(ch, url=None):
    url = url or ch["configUrl"]
    data, hdrs, status = http_get(url)
    cfg = json.loads(data)
    d = cfg["default"]
    c = d["config"]
    print(f"# {ch['name']}  ({ch['gameId']}/{ch['appId']})")
    print(f"configUrl      : {url}  [{status}]")
    print(f"remote version : {c['version']}   size={c['size']:,}   indexFileMd5={c['indexFileMd5']}")
    print(f"baseUrl        : {c['baseUrl']}")
    print(f"indexFile      : {c['indexFile']}")
    print(f"patchType      : {c.get('patchType')}   patch 源版本: "
          f"{[p['version'] for p in c.get('patchConfig', [])]}")
    z = c.get("zipConfig")
    if z:
        print(f"zipConfig      : version={z['version']} size={z['size']:,} "
              f"unCompressSize={z['unCompressSize']:,} indexFileMd5={z['indexFileMd5']}")
    print(f"cdnList        : " + ", ".join(f"{n['url']}(P={n.get('P')})" for n in d["cdnList"]))
    return cfg


def fetch_index(ch, save=None):
    cfg = fetch_config(ch)
    c = cfg["default"]["config"]
    url = abs_url(ch, c["indexFile"])
    data, hdrs, status = http_get(url, timeout=180)
    md5 = hashlib.md5(data).hexdigest()
    ok = md5 == c["indexFileMd5"]
    print(f"\nGET {url}  [{status}] {len(data):,} bytes")
    print(f"md5={md5}  expected={c['indexFileMd5']}  {'MATCH' if ok else 'MISMATCH'}")
    res = json.loads(data)["resource"]
    total = sum(r["size"] for r in res)
    print(f"files={len(res):,}  total={total:,} B ({total/1e9:.2f} GB)  "
          f"AntiCheatExpert={'YES' if any('AntiCheat' in r['dest'] for r in res) else 'NO'}")
    if save:
        with open(save, "wb") as f:
            f.write(data)
        print(f"saved -> {save}")
    return cfg, res


def find_entry(ch, cfg, rel, res):
    # res: indexFile 里的 resource 数组（逻辑全量清单），只用于拿 md5/size
    m = {r["dest"]: r for r in res}
    if rel not in m:
        cand = [k for k in m if k.endswith(rel)]
        if not cand:
            raise SystemExit(f"manifest 中没有 {rel}")
        rel = cand[0]
    e = m[rel]
    cfgdef = cfg["default"]
    c = cfgdef["config"]
    # 优先 config 级 baseUrl（与 indexFile 同源的下载目录）
    url = pick_cdn(ch) + "/" + c["baseUrl"].lstrip("/") + rel
    return rel, e, url


def fetch_file(ch, rel, save=None):
    cfg, res = fetch_index(ch)
    rel, e, url = find_entry(ch, cfg, rel, res)
    print(f"\nGET {url}")
    data, hdrs, status = http_get(url, timeout=180)
    md5 = hashlib.md5(data).hexdigest()
    ok = md5 == e["md5"]
    print(f"[{status}] {len(data):,} bytes  md5={md5} expected={e['md5']} "
          f"{'MATCH' if ok else 'MISMATCH'}")
    if not ok:
        print("提示：若 404，说明该条目是打包在 N.krzip 里的文件，"
              "需先去 zipConfig 的 zipInfos 找到所属 krzip 再解压（见 docs/PGR-CLIENT.md）。")
    if save:
        with open(save, "wb") as f:
            f.write(data)
        print(f"saved -> {save}")
    return data


def fetch_launcher(ch):
    url = ch.get("launcherConfigUrl")
    data, hdrs, status = http_get(url)
    d = json.loads(data)["default"]
    r = d["resource"]
    print(f"# {ch['name']} launcher self-update")
    print(f"GET {url} [{status}]")
    print(f"launcher version : {r['version']}")
    print(f"launcher.zip     : {r['path']}")
    print(f"                   size={r['size']:,} md5={r['md5']} fileCheckListMd5={r['fileCheckListMd5']}")
    for comp in json.loads(data).get("experiment", {}).get("componentList", []):
        print(f"component        : {comp['Id']} version={comp['version']} "
              f"size={comp['size']:,} md5={comp['md5']}")
    return data


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 1
    cmd = argv[1]
    chans = load_channels()
    name = argv[2]
    if name not in chans:
        print(f"未知渠道 {name}，可选: {list(chans)}")
        return 1
    ch = chans[name]
    save = None
    if "--save" in argv:
        save = argv[argv.index("--save") + 1]
    if cmd == "config":
        fetch_config(ch)
    elif cmd == "manifest":
        fetch_index(ch, save)
    elif cmd == "file":
        if len(argv) < 4:
            print("需要文件相对路径，如 PGR.exe / version.json")
            return 1
        fetch_file(ch, argv[3], save)
    elif cmd == "launcher":
        fetch_launcher(ch)
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
