#!/usr/bin/env python3
"""把含中文的 Swift 字面字串包進 L10n.t()。

⚠️ **為什麼不是正則**：Swift 的字串插值可以巢狀字串 ——
    "剩 \(secs/60):\(String(format: "%02d", s))"
正則的 `(?:[^"\\]|\\.)*?` 會在 `"%02d` 的第一個引號就截斷，於是：
  ‧ 抽出半截 key，
  ‧ 包出語法壞掉的程式碼，
  ‧ 而「先檢查安不安全再包」也沒用 —— 檢查看到的已經是半截了。
（2026-10-18 實測踩到，main.swift 與 Onboarding.swift 當場編不過。）

所以這裡走一個真的掃描器：逐字元走，認得跳脫、認得 `\(` 進插值、插值裡可以
再有完整字串。只有**掃完整個字面字串**才會去包它。
"""
import io, re, sys

def scan_string(src, i):
    """src[i] == '"'。回傳 (結束索引 exclusive, 內容, 是否含巢狀字串)。"""
    assert src[i] == '"'
    j = i + 1
    nested = False
    while j < len(src):
        c = src[j]
        if c == "\\":
            if j + 1 < len(src) and src[j + 1] == "(":
                depth = 0
                j += 1
                while j < len(src):
                    if src[j] == "(":
                        depth += 1
                    elif src[j] == ")":
                        depth -= 1
                        if depth == 0:
                            break
                    elif src[j] == '"':
                        nested = True
                        j, _, n2 = scan_string(src, j)
                        nested = nested or n2
                        continue
                    j += 1
                j += 1
                continue
            j += 2
            continue
        if c == '"':
            return j + 1, src[i + 1:j], nested
        j += 1
    return len(src), src[i + 1:], nested   # 未閉合（不該發生）

CJK = re.compile(r'[一-鿿]')

def wrap_line(line, skipped, fname):
    if line.strip().startswith("//"):
        return line, 0
    out = []
    i = 0
    n = 0
    while i < len(line):
        c = line[i]
        if c != '"':
            out.append(c); i += 1; continue
        end, body, nested = scan_string(line, i)
        lit = line[i:end]
        already = "".join(out).rstrip().endswith(("L10n.t(", "L10n.raw("))
        if CJK.search(body) and not already:
            if nested:
                skipped.append((fname, body[:50]))
                out.append(lit)
            else:
                out.append(f"L10n.t({lit})"); n += 1
        else:
            out.append(lit)
        i = end
    return "".join(out), n

if __name__ == "__main__":
    total = 0
    skipped = []
    for f in sys.argv[1:]:
        s = io.open(f, encoding="utf-8").read()
        lines = []
        n = 0
        for ln in s.split("\n"):
            w, k = wrap_line(ln, skipped, f)
            lines.append(w); n += k
        io.open(f, "w", encoding="utf-8").write("\n".join(lines))
        print(f"{n:>4}  {f}")
        total += n
    print(f"合計 {total} | 跳過（含巢狀字串，要人工拆）{len(skipped)}")
    for f, b in skipped:
        print(f"   skip: {f}: {b}")
