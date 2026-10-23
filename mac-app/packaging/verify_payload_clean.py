#!/usr/bin/env python3
"""打包前最後一道:payload 裡不准有私人識別。

## 為什麼不是一行 grep

`build_dmg.sh` 原本用一行 `grep -rniIE 'yuanfang|袁方|善彰|...'` 做這件事。
問題是**那行 grep 把要擋的東西全部明文列出來,而這是公開 repo** —— 守門本身
成了那份資訊最集中、最好找的清單。

這支改成兩層,都不揭露任何識別:

  **形狀**  —— 任何 `*.ts.net` 主機名、任何 `/Users/<人名>`、tailnet IP。
              附帶好處:連**別人的** tailnet 也擋得到。
  **雜湊**  —— 形狀攔不到的具名識別(人格名、本名、信箱網域)只存
              salted SHA-256。掃描時把候選詞取出來比雜湊。

新增一條:
    python3 -c "import hashlib;print(hashlib.sha256(b'pocket-payload-v1:'+input().strip().lower().encode()).hexdigest())"

⚠️ 失敗訊息**不印命中的原文**:這支會在發行流程裡跑,輸出可能被貼進 issue
或 CI 日誌。要看原文在本機帶 `PAYLOAD_VERBOSE=1`。
"""
import hashlib
import os
import re
import sys
from pathlib import Path

SHAPES = {
    "tailnet 主機名": re.compile(r"[\w-]+\.[\w-]+\.ts\.net"),
    "家目錄路徑": re.compile(r"/Users/(?!you\b)[A-Za-z][\w.-]*"),
    "tailnet IP": re.compile(
        r"(?<![\d.])100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}(?![\d.])"),
}
PLACEHOLDER = re.compile(r"your|example|sample|placeholder|<|__|\byou\b|100\.64\.0\.1", re.I)

_SALT = b"pocket-payload-v1:"
SECRET_HASHES = {
    "117a022d11d806320a7197ea2539bc64f95800121bc5efe1cf357e85b65df6be": "具名識別",
    "1cef57c06a758d2eb325dce86f15564d06cbc1005a20169a37be8f3f94940147": "具名識別",
    "385aa16540a87da91c1f83d08033a56e9579df1d69227a3dba5a3679fd7d7e90": "具名識別",
    "3a7302cef0f053c038225f4f2671602e78af0348462d5810e23e65db842596ef": "具名識別",
    "3aa6be5d4e64b1cd1475e4cb5e1c1a4bd1bb8220ec2a7f49899b4c4f71690fc9": "具名識別",
    "59f1a1288cf45b1150419bf97a709e622ff76997b040c950aa31b083881c3814": "具名識別",
    "70d510be3f8e732a1f8cb52a077746fb9070fc06cee8ad3690ddecbea3e4746f": "具名識別",
    "7b4e20f5d1cc11da69d6bfa88a4ca1d051a2759546f435a4e5d97e05a2ee2261": "具名識別",
    "a0a5ee02668bf70375828b75ce57f88e552007e21cfcd7d64cc84d46e4c6545d": "具名識別",
    "b0d7cca578e7783c4dd81f03b79aa4df8f7151c431800a0658e08555fa207c16": "具名識別",
    "f1f44efb104fce842e70b333d138fa07de5d87c2f2e16ff9284e881f97d79ac0": "具名識別",
}
_WORD = re.compile(r"[A-Za-z][\w.-]{2,}|[一-鿿]{2,4}")


def _h(s: str) -> str:
    return hashlib.sha256(_SALT + s.strip().lower().encode()).hexdigest()


def scan(root: Path):
    hits = []
    for f in sorted(root.rglob("*")):
        if not f.is_file():
            continue
        try:
            t = f.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        rel = f.relative_to(root)
        for label, rx in SHAPES.items():
            real = [m for m in rx.findall(t) if not PLACEHOLDER.search(m)]
            if real:
                hits.append((str(rel), label, real[0]))
        for m in _WORD.finditer(t):
            lab = SECRET_HASHES.get(_h(m.group(0)))
            if lab:
                hits.append((str(rel), lab, m.group(0)))
    return hits


def main():
    root = Path(sys.argv[1])
    hits = scan(root)
    if not hits:
        print(f"  ✓ payload 消毒驗證通過({sum(1 for _ in root.rglob('*'))} 項)")
        return 0
    verbose = os.environ.get("PAYLOAD_VERBOSE") == "1"
    print(f"✗ payload 消毒後仍有私人識別 {len(hits)} 處:", file=sys.stderr)
    for rel, label, ex in hits[:10]:
        extra = f"  例:{ex}" if verbose else ""
        print(f"    {rel}: {label}{extra}", file=sys.stderr)
    if not verbose:
        print("  (本機帶 PAYLOAD_VERBOSE=1 可看原文;預設不印,"
              "因為這段輸出可能被貼進 issue 或 CI 日誌)", file=sys.stderr)
    return 1


if __name__ == "__main__":
    if len(sys.argv) != 2 or not Path(sys.argv[1]).is_dir():
        print("usage: verify_payload_clean.py <payload-dir>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main())
