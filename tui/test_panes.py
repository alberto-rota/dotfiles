#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["textual>=1.0,<9"]
# ///
"""Does any preview pane overflow the container it is drawn in?

The check test_narrow.py cannot make. That one asserts no rendered line is wider
than the *terminal*, which a pane wrapping inside its own bordered box passes
happily -- wrapping does not make the screen wider, it makes the box taller. So
this compares each pane's content against the widget actually holding it:

  * every line must fit the Static's content width, and
  * the Static must be exactly as tall as its content has lines; taller means
    Textual wrapped something.
"""
import asyncio
import os
import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent
os.environ.setdefault("DOTFILES", str(_HERE.parent))
sys.path.insert(0, str(_HERE))
import configure as C  # noqa: E402

SIZES = [(200, 50), (140, 44), (120, 40), (100, 34), (88, 30),
         (80, 24), (70, 24), (60, 20), (50, 20), (40, 16)]
PANES = ("posh", "hsl-bar", "claude", "herdr", "plan")
fails = []


async def main():
    cat = C.load_catalogue()
    a = C.Answers.from_env(dict(os.environ), cat)
    derived = C.derive(a)
    palette = C.palette_from(derived)
    rows = C.palette_rows_from(derived)

    for w, h in SIZES:
        app = C.SetupApp(a, palette, None, columns=C.palette_columns(derived),
                         catalogue=cat, priv=C.privilege_summary(), palette_rows=rows)
        async with app.run_test(size=(w, h)) as pilot:
            await pilot.pause()
            await pilot.pause(0.8)          # let the preview worker land
            bad = []
            for pane in PANES:
                try:
                    widget = app.query_one(f"#{pane}")
                except Exception:
                    continue
                avail = widget.content_size.width
                if avail <= 0:
                    continue
                content = widget.render()
                lines = content.split("\n")
                widest = max((ln.cell_length for ln in lines), default=0)
                if widest > avail:
                    bad.append(f"{pane} content {widest} > box {avail}")
                # Taller than its own line count == Textual wrapped it.
                drawn = widget.size.height
                if drawn > len(lines):
                    bad.append(f"{pane} drawn {drawn} lines vs {len(lines)} logical")
            status = "PASS" if not bad else "FAIL"
            print(f"{status}  {w:>3}x{h:<3} " + ("; ".join(bad) if bad else "all panes fit"))
            fails.extend(f"{w}x{h}: {b}" for b in bad)

asyncio.run(main())
print()
print("FAILURES:", len(fails))
for f in fails[:12]:
    print("  ", f)
sys.exit(1 if fails else 0)
