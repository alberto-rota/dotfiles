#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["textual>=1.0,<9"]
# ///
"""Drive the real app at several terminal sizes and assert no line of the
rendered screen exceeds the terminal width (i.e. nothing wrapped or overflowed).
"""
import asyncio
import os
import sys
from pathlib import Path

# Resolved from this file, not hardcoded: the harness has to run from any
# checkout (and from the setup UI's own directory).
_HERE = Path(__file__).resolve().parent
os.environ.setdefault("DOTFILES", str(_HERE.parent))
sys.path.insert(0, str(_HERE))
import configure as C  # noqa: E402

SIZES = [(200, 50), (120, 40), (100, 30), (88, 30), (80, 24), (70, 24), (60, 20), (50, 20), (40, 16), (32, 14)]
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
            await pilot.pause(0.7)          # let the preview worker land
            # The compositor's own view of the screen: if any segment line is
            # wider than the terminal, something overflowed.
            screen = app.screen._compositor
            widest = 0
            for strip in screen.render_strips():
                widest = max(widest, strip.cell_length)
            narrow = app.query_one("#body").has_class("narrow")
            grid = app.query_one("#palette", C.PaletteGrid)
            cell_w, label_room, show_labels = grid._metrics()
            ok = widest <= w
            status = "PASS" if ok else "FAIL"
            print(f"{status}  {w:>3}x{h:<3} screen widest={widest:<4} "
                  f"stacked={'yes' if narrow else 'no ':<3} "
                  f"swatch={cell_w} names={'full' if show_labels else 'hidden'}")
            if not ok:
                fails.append(f"{w}x{h}: {widest} > {w}")

            # Clicking a swatch must select THAT swatch. The mapping depends on
            # the live cell width, which _metrics() varies with the panel, so
            # this is checked at every size rather than once: the bug it exists
            # for was on_click dividing by the SWATCH_W constant while the grid
            # was actually drawing 3-cell swatches, which put every click one or
            # two swatches to the left, and further left towards the row's end.
            grid.set_active("primary")
            # animate=False, and settle before measuring: an animated scroll
            # is still moving when the first click is dispatched, which lands it
            # on the wrong row.
            grid.scroll_visible(animate=False)
            await pilot.pause()
            await pilot.pause(0.2)
            # Only the rows actually on screen can be clicked. On a short
            # terminal the controls panel scrolls and the lower half of the grid
            # is genuinely below its edge; clicking there would land on whatever
            # is underneath, which tests the harness rather than the widget.
            panel = app.query_one("#controls").content_region
            top = max(0, panel.y - grid.region.y)
            bottom = min(grid.rows, panel.y + panel.height - grid.region.y)
            missed = []
            for row in range(top, bottom):
                for col in range(grid.columns):
                    idx = row * grid.columns + col
                    swatch = palette[idx]
                    # the middle of the cell, where a person would really click
                    await pilot.click(grid, offset=(col * cell_w + cell_w // 2, row))
                    if grid.values["primary"] != swatch.hex:
                        got = next((f"{s2.group}/{s2.name}" for s2 in palette
                                    if s2.hex == grid.values["primary"]), "?")
                        missed.append(f"r{row}c{col} {swatch.group}/{swatch.name}->{got}")
            tried = max(0, bottom - top) * grid.columns
            if missed:
                print(f"      click misses ({len(missed)}/{tried}): {'; '.join(missed[:4])}")
                fails.append(f"{w}x{h}: {len(missed)} click misses")
            elif tried:
                print(f"       clicked {tried} swatches at cell width {cell_w}, all correct")

asyncio.run(main())
print()
print("FAILURES:", fails if fails else "none")
sys.exit(1 if fails else 0)
