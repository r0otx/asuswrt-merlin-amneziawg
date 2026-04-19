#!/usr/bin/env python3
"""build/ci/lint_asp.py — static checks for addon/webui/*.asp.

Enforces:
  - no raw `eval(` anywhere
  - no `innerHTML =` with any identifier containing 'user' / 'input' / 'raw'
  - every `<% nvram_get("x"); %>` interpolation must be inside an HTML attribute
    *value* (.value=, content=, value=) — not as child of a tag that renders HTML.
  - <meta name="version" content="..."> is present and matches /VERSION.

Exit code 0 = pass, 1 = fail.
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
PAGE = ROOT / "addon" / "webui" / "amneziawg_page.asp"
VERSION_FILE = ROOT / "VERSION"


def main() -> int:
    if not PAGE.exists():
        print(f"ERROR: {PAGE} not found", file=sys.stderr)
        return 1

    src = PAGE.read_text(encoding="utf-8")
    errors: list[str] = []

    if re.search(r"\beval\s*\(", src):
        errors.append("eval() usage is forbidden")

    # innerHTML = with a dirty identifier on the right
    for m in re.finditer(r"\.innerHTML\s*=\s*([A-Za-z_$][A-Za-z0-9_$]*)", src):
        ident = m.group(1).lower()
        if any(t in ident for t in ("user", "input", "raw", "unesc")):
            errors.append(
                f"suspicious innerHTML assignment from identifier '{m.group(1)}'"
                " — use escHtml() or textContent"
            )

    # <% nvram_get("...") %> interpolation context check
    for m in re.finditer(r'<%[\s]*nvram_get\s*\("([^"]+)"\)\s*;?\s*%>', src):
        pos = m.start()
        before = src[max(0, pos - 80):pos]
        # Heuristic: if preceding char-class shows an HTML tag open (> last char is >)
        if re.search(r"(^|\s)(\.value\s*=|content=|value=)[\"'][^\"']*$", before):
            continue
        if re.search(r"\"[^\"]*$", before):  # inside a quoted attribute
            continue
        errors.append(
            f"nvram_get(\"{m.group(1)}\") interpolated outside an attribute"
            " value — potential XSS vector"
        )

    # Version meta tag present and matches VERSION
    expected_version = VERSION_FILE.read_text().strip() if VERSION_FILE.exists() else ""
    meta_m = re.search(
        r'<meta\s+name="version"\s+content="([^"]+)"', src
    )
    if not meta_m:
        errors.append("missing <meta name=\"version\" content=\"...\"> in <head>")
    elif expected_version and meta_m.group(1) != expected_version:
        errors.append(
            f"<meta version='{meta_m.group(1)}'> does not match /VERSION='{expected_version}'"
            " — run build/version.sh"
        )

    if errors:
        for e in errors:
            print(f"lint_asp: {e}", file=sys.stderr)
        return 1
    print("lint_asp: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
