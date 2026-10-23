#!/usr/bin/env python3
"""Sanitize the bundled bridge payload before it ships in the DMG.

The bridge payload carries comments, docstrings and machine-specific defaults
that reference the developer's own personas, hostnames and paths. None of that
belongs in a distributable. This rewrites the payload COPY only — the bridge
repo itself is never touched, so production stays byte-identical.

## 替換表不在這個 repo 裡(2026-10-23 搬出去)

原本 `REPLACEMENTS` 是一張明文表,直接列出 tailnet 名、tailnet IP、家目錄、
人格名、本名、信箱 —— **而這是公開 repo**。也就是說:這支負責「不要把私人
資訊裝進發行物」的腳本,自己就是那份資訊最集中、最好找的清單。

消毒需要明文才能比對替換,所以不能像出鏡守門那樣改成雜湊。正解是把表搬到
repo 外:

    ~/.pocket-release-secrets/sanitize-table.json      (0600)
    或 $POCKET_SANITIZE_TABLE 指定

**表不存在就中止**,絕不「跳過消毒繼續打包」—— 那會安靜地把私人資訊裝進 DMG,
而失敗的打包只是浪費十分鐘。

repo 裡保留的是**不含任何識別的形狀規則**(任何 `*.ts.net` 主機名、任何
`/Users/<人名>`),所以即使沒有私人表,明顯的東西仍會被中性化。
"""
import json
import os
import re
import sys
from pathlib import Path

# 不含任何識別的形狀規則 —— 這些可以留在公開 repo 裡。
SHAPE_RULES = [
    (re.compile(r"[\w-]+\.[\w-]+\.ts\.net"), "your-host.your-tailnet.ts.net"),
    (re.compile(r"/Users/(?!you\b)[A-Za-z][\w.-]*"), "/Users/you"),
    (re.compile(r"(?<![\d.])100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}(?![\d.])"),
     "100.64.0.1"),
]

TABLE_PATH = os.environ.get("POCKET_SANITIZE_TABLE") or os.path.expanduser(
    "~/.pocket-release-secrets/sanitize-table.json")


def load_replacements():
    """載入私人替換表。沒有就中止 —— 不消毒而繼續打包是最糟的結果。"""
    try:
        with open(TABLE_PATH, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        sys.exit(f"✗ 找不到替換表 {TABLE_PATH}\n"
                 f"  這支腳本需要它才能消毒 payload。它刻意不在 repo 裡 ——\n"
                 f"  那張表本身就是一份私人識別清單,不該公開。\n"
                 f"  用 POCKET_SANITIZE_TABLE 指定其他路徑。")
    except Exception as exc:
        sys.exit(f"✗ 替換表讀不起來({exc});寧可不出貨,也不要漏消毒。")
    rep = [tuple(x) for x in data.get("replacements", [])]
    if not rep:
        sys.exit("✗ 替換表是空的 —— 不正常,中止。")
    # 長的先換(順序決定正確性:短的先換會把長的切斷)
    rep.sort(key=lambda kv: len(kv[0]), reverse=True)
    return rep


TEXT_SUFFIXES = {".py", ".sh", ".md", ".txt", ".toml", ".cfg", ".ini", ".json",
                 ".yaml", ".yml", ".example", ".service", ""}


def main(payload: Path) -> int:
    replacements = load_replacements()
    changed = 0
    for f in sorted(payload.rglob("*")):
        if not f.is_file() or f.suffix.lower() not in TEXT_SUFFIXES:
            continue
        try:
            s = f.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue  # binary or unreadable — the gate still greps it with -I
        out = s
        for old, new in replacements:
            out = out.replace(old, new)
        for rx, sub in SHAPE_RULES:          # 私人表之外的保險絲
            out = rx.sub(sub, out)
        if out != s:
            f.write_text(out, encoding="utf-8")
            changed += 1
    print(f"  sanitized: {changed} files rewritten "
          f"({len(replacements)} 條私人規則 + {len(SHAPE_RULES)} 條形狀規則)")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2 or not Path(sys.argv[1]).is_dir():
        print("usage: sanitize_bridge_payload.py <payload-dir>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(Path(sys.argv[1])))
