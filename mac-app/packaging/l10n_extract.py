#!/usr/bin/env python3
"""抽出桌面端所有「要翻的中文字串」，產生/合併 Localizable.strings。

為什麼要有這支：330 條字串散在 21 個檔裡，手工維護一定會漏。這支做兩件事：

  1. `--check`：列出**還沒被 L10n.t()/L10n.raw() 包起來**的中文字串。
     收工前跑一次，就知道還有多少沒處理。
  2. `--sync`：把已包起來的 key 併進 en.lproj / zh-Hant.lproj，
     **既有譯文一律保留**（只補新 key、只標記消失的舊 key，不覆蓋）。

慣例：key = 繁體中文原字串（與 iOS 的 L10n 一致）。所以 zh-Hant 的值等於 key，
存在的意義是讓 Bundle 知道 zh-Hant 這個語言「有表」，進而正確挑語言。
"""
import re, io, os, sys, glob, collections

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = sorted(glob.glob(os.path.join(ROOT, "Sources/**/*.swift"), recursive=True))
RES = os.path.join(ROOT, "packaging/Resources")
LANGS = ["en", "zh-Hant"]

CJK = re.compile(r'"((?:[^"\\]|\\.)*?[一-鿿](?:[^"\\]|\\.)*?)"')
WRAPPED = re.compile(r'L10n\.(?:t|raw)\(\s*"((?:[^"\\]|\\.)*?)"')

def code_lines(path):
    """去掉註解行 —— 註解裡的中文不是要翻的東西。"""
    out = []
    for ln in io.open(path, encoding="utf-8"):
        s = ln.strip()
        if s.startswith("//"):
            continue
        out.append(ln)
    return "".join(out)

def scan():
    wrapped, bare = set(), collections.defaultdict(list)
    for f in SRC:
        if f.endswith("L10n.swift"):
            continue
        code = code_lines(f)
        w = {runtime_key(x) for x in WRAPPED.findall(code)}
        wrapped |= w
        for m in CJK.findall(code):
            if runtime_key(m) not in w:
                bare[os.path.relpath(f, ROOT)].append(m)
    return wrapped, bare

INTERP = re.compile(r'\\\((?:[^()]|\([^()]*\))*\)')

def runtime_key(src):
    """把 Swift 原始碼裡的字面字串轉成**執行期真正的 key**。

    `String.LocalizationValue` 會把 `\\(x)` 變成 `%@` —— 所以 .strings 的 key
    也必須是 `%@`，否則查表永遠落空而且不會有人發現（因為回退就是中文原字串，
    看起來一切正常）。這個坑第一次 sync 就踩到了。
    """
    return INTERP.sub("%@", src)

def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

def load(lang):
    """讀既有譯文。只認 "key" = "value"; 這一種行。"""
    p = os.path.join(RES, f"{lang}.lproj/Localizable.strings")
    if not os.path.exists(p):
        return {}
    txt = io.open(p, encoding="utf-8").read()
    return dict(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', txt, re.M))

def validate(wrapped):
    """擋掉抽壞的 key。

    由來:`L10n.t("已登入\\(x.map { " · \\($0)" } ?? "") …")` 這種**插值裡包
    巢狀字串**的寫法,正則會在第一個內層引號就斷掉,抽出半截 key。而查表落空
    時會靜默回退成中文 —— 畫面看起來一切正常,沒人會發現那句永遠翻不了。
    所以寧可在這裡紅。
    """
    bad = [k for k in wrapped if k.count("\\(") or k.rstrip().endswith("{")]
    if bad:
        print("✗ 抽到不完整的 key(插值裡有巢狀字串?把它先算成變數再插):")
        for k in bad:
            print("   ", k)
        sys.exit(2)

def sync(wrapped):
    for lang in LANGS:
        have = load(lang)
        d = os.path.join(RES, f"{lang}.lproj")
        os.makedirs(d, exist_ok=True)
        new = [k for k in sorted(wrapped) if k not in have]
        gone = [k for k in have if k not in wrapped]
        lines = [f"/* Pocket desktop — {lang}. key = 繁體中文原字串（與 iOS L10n 一致）。",
                 "   由 packaging/l10n_extract.py --sync 產生；既有譯文不會被覆蓋。 */", ""]
        for k in sorted(wrapped):
            v = have.get(k, k if lang != "en" else "")
            if lang == "en" and not v:
                lines.append(f'/* TODO translate */ "{esc(k)}" = "{esc(k)}";')
            else:
                lines.append(f'"{esc(k)}" = "{esc(v)}";')
        io.open(os.path.join(d, "Localizable.strings"), "w", encoding="utf-8").write("\n".join(lines) + "\n")
        print(f"  {lang}: {len(wrapped)} keys (+{len(new)} new, {len(gone)} stale dropped)")

if __name__ == "__main__":
    wrapped, bare = scan()
    total_bare = sum(len(v) for v in bare.values())
    validate(wrapped)
    if "--sync" in sys.argv:
        print(f"▸ sync {len(wrapped)} wrapped keys")
        sync(wrapped)
    print(f"\n已包起來: {len(wrapped)}    還沒包: {total_bare}")
    if "--check" in sys.argv and bare:
        for f, items in sorted(bare.items(), key=lambda kv: -len(kv[1])):
            print(f"  {len(items):>4}  {f}")
        sys.exit(1 if total_bare else 0)
