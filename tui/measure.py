#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["textual>=1.0,<9"]
# ///
"""Every preview pane at a range of widths: does any line exceed the budget?"""
import os
import sys
from pathlib import Path

# Resolved from this file, not hardcoded: the harness has to run from any
# checkout (and from the setup UI's own directory).
_HERE = Path(__file__).resolve().parent
os.environ.setdefault("DOTFILES", str(_HERE.parent))
sys.path.insert(0, str(_HERE))
import configure as C  # noqa: E402

WIDTHS = [120, 90, 76, 60, 46, 36, 28, 20]
cat = C.load_catalogue()
a = C.Answers.from_env(dict(os.environ), cat)
derived = C.derive(a)
palette = C.palette_from(derived)
rows = C.palette_rows_from(derived)
pv = C.Previewer()

def widest(text):
    return max((line.cell_len for line in text.split("\n")), default=0)

print(f"{'pane':<16}" + "".join(f"{w:>7}" for w in WIDTHS))
print("-" * (16 + 7 * len(WIDTHS)))
panes = {
    "posh":       lambda w: pv.posh(derived, a, w),
    "statusline": lambda w: pv.statusline(derived, a, w),
    "claude":     lambda w: pv.claude(derived, a, w),
    "claude-chat": lambda w: pv.chat(derived, w),
    "herdr":      lambda w: pv.herdr(derived, w),
    "dassh":      lambda w: pv.dassh(derived, w),
    "plan":       lambda w: pv.plan(derived, a, w),
}
bad = []
for name, fn in panes.items():
    cells = []
    for w in WIDTHS:
        try:
            got = widest(fn(w))
        except Exception as exc:
            got = -1
            print(f"  !! {name}@{w}: {exc}")
        over = got - w
        cells.append(f"{got:>4}{'!' if over > 0 else ' '}  ")
        if over > 0:
            bad.append((name, w, got))
    print(f"{name:<16}" + "".join(cells))

# the palette grid is its own widget, sized by the controls panel
print()
grid = C.PaletteGrid(palette, rows, a.primary, a.secondary, columns=8)
grid.refresh_row = grid.refresh_row  # no-op, just to be explicit
try:
    from rich.text import Text
    # rebuild what refresh_row would produce without mounting
    import io
    grid.values = {"primary": a.primary, "secondary": a.secondary}
    grid.active = "primary"
    # call the render builder directly
    grid.update = lambda t: setattr(grid, "_last", t)
    grid.refresh_row()
    print(f"{'palette grid':<16}{widest(grid._last):>4}  (controls panel inner width is ~44)")
    if widest(grid._last) > 44:
        bad.append(("palette-grid", 44, widest(grid._last)))
except Exception as exc:
    print("palette grid: ", exc)

pv.cleanup()
print()
if bad:
    print("OVERFLOWS:")
    for name, w, got in bad:
        print(f"  {name}: budget {w}, produced {got}  (+{got - w})")
    sys.exit(1)
print("no overflow at any width")
