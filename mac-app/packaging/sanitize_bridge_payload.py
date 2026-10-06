#!/usr/bin/env python3
"""Sanitize the bundled bridge payload before it ships in the DMG.

The bridge repo is a private, production codebase: comments, docstrings and a
handful of machine-specific defaults reference the developer's own personas,
hostnames and paths. None of that belongs in a distributable. This script
rewrites the payload COPY only (build/Pocket.app/Contents/Resources/bridge) —
the bridge repo itself is never touched, so production stays byte-identical.

Functional literals (default persona ids, cron label maps, report regexes,
legacy dir maps) are safe to neutralize here: they only ever match sessions
that exist on the developer's machine, so on an end-user install the renamed
values are behaviourally equivalent (both resolve to "not present").

Ordered, explicit replacements — no clever heuristics. The hard gate in
build_dmg.sh re-greps the payload afterwards and aborts the build if any
pattern survives, so a new leak in the bridge repo fails the release instead
of shipping.
"""
import sys
from pathlib import Path

# Order matters: longest/most specific first.
REPLACEMENTS = [
    # paths / hosts / tailnet
    ("/Users/xcash/apps/hermes-openwebui-bridge", "/path/to/bridge"),
    ("/Users/xcash", "/Users/you"),
    ("pocket.tsai.cash", "your-bridge.example.com"),
    ("tsai.cash", "example.com"),
    ("tail905550.ts.net", "your-tailnet.ts.net"),
    ("tail905550", "your-tailnet"),
    ("100.67.0.12", "100.64.0.1"),
    # personas (ids first, then display names; case variants explicit so the
    # gate's case-insensitive grep can never out-match the sanitizer)
    ("YUANFANG", "PERSONA_MAIN"),
    ("YuanFang", "PersonaMain"),
    ("Yuanfang", "PersonaMain"),
    ("yuanfang", "persona-main"),
    ("PANTIANQING", "PERSONA_EDITOR"),
    ("PanTianQing", "PersonaEditor"),
    ("Pantianqing", "PersonaEditor"),
    ("pantianqing", "persona-editor"),
    ("SHUIJING", "PERSONA_ANALYST"),
    ("ShuiJing", "PersonaAnalyst"),
    ("Shuijing", "PersonaAnalyst"),
    ("shuijing", "persona-analyst"),
    ("袁方", "主人格"),
    ("潘天晴", "編輯人格"),
    ("水鏡", "分析人格"),
    ("善彰", "機主"),
    ("XCash", "Owner"),
    ("xcash", "owner"),
    ("flipermag.com", "example.com"),
    ("FLIPERMAG", "EXAMPLE"),
    ("FLiPER", "editor-desk"),
    ("FLIPER", "EDITOR"),
    ("Fliper", "Editor"),
    ("fliper", "editor"),
]

TEXT_SUFFIXES = {".py", ".sh", ".md", ".txt", ".toml", ".cfg", ".ini", ".json",
                 ".yaml", ".yml", ".example", ".service", ""}


def main(payload: Path) -> int:
    changed = 0
    for f in sorted(payload.rglob("*")):
        if not f.is_file() or f.suffix.lower() not in TEXT_SUFFIXES:
            continue
        try:
            s = f.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue  # binary or unreadable — the gate still greps it with -I
        out = s
        for old, new in REPLACEMENTS:
            out = out.replace(old, new)
        if out != s:
            f.write_text(out, encoding="utf-8")
            changed += 1
    print(f"  sanitized: {changed} files rewritten")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2 or not Path(sys.argv[1]).is_dir():
        print("usage: sanitize_bridge_payload.py <payload-dir>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(Path(sys.argv[1])))
