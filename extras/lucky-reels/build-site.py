"""Build the GitHub Pages copy of Lucky Reels.

extras/lucky-reels/index.html is written for the claude.ai artifact viewer, which adds the
document skeleton itself. This wraps it in a full HTML document and writes lucky-reels/index.html
at the repository root, which GitHub Pages serves as /lucky-reels/.

Run from anywhere: python3 extras/lucky-reels/build-site.py
"""
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SOURCE = HERE / "index.html"
TARGET = ROOT / "lucky-reels" / "index.html"

HEAD = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="robots" content="noindex">
<style>
:root { color-scheme: dark; padding-top: env(safe-area-inset-top, 0px); padding-bottom: env(safe-area-inset-bottom, 0px); }
body { margin: 0; font: 14px system-ui, -apple-system, sans-serif; }
img { max-width: 100%; }
[hidden] { display: none !important; }
</style>
</head>
<body>
"""
FOOT = "\n</body>\n</html>\n"

body = SOURCE.read_text(encoding="utf-8")
TARGET.parent.mkdir(parents=True, exist_ok=True)
TARGET.write_text(HEAD + body + FOOT, encoding="utf-8")
print(f"wrote {TARGET.relative_to(ROOT)}")
