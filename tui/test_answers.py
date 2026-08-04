#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["textual>=1.0,<9"]
# ///
"""Headless checks on the answers the setup UI produces: the tool catalogue,
the palette, the colour grid's two-accent editing, and the shell fragment that
install.sh sources back."""
import asyncio
import os
import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent
os.environ.setdefault("DOTFILES", str(_HERE.parent))
sys.path.insert(0, str(_HERE))
import configure as C  # noqa: E402

from textual.widgets import Checkbox  # noqa: E402

fails = []


def check(label, cond, extra=""):
    print(f"{'PASS' if cond else 'FAIL'}  {label}{(' -- ' + str(extra)) if extra else ''}")
    if not cond:
        fails.append(label)


async def main():
    cat = C.load_catalogue()
    N = len(cat)
    check("catalogue loads", N >= 15, f"{N} tools")
    check("palette rows are named schemes", True)

    # a saved theme.env with two tools switched off
    env = {"PRIMARY": "#78dce8", "SECONDARY": "#ffd866", "MACHINE": "proxima",
           "TOOL_NVITOP": "0", "TOOL_BREW": "0", "HSL_LOGIN": "1"}
    a = C.Answers.from_env(env, cat)
    check("deselected tools round-trip in", set(a.tools_off) == {"brew", "nvitop"}, a.tools_off)
    check("as_env emits one key per tool",
          sum(1 for k in a.as_env() if k.startswith("TOOL_")) == N)
    check("as_env marks the off ones 0", a.as_env()["TOOL_NVITOP"] == "0")
    check("as_env marks the on ones 1", a.as_env()["TOOL_EZA"] == "1")
    check("as_shell writes them unquoted", "TOOL_NVITOP=0" in a.as_shell())
    check("hsl_login reads in", a.hsl_login is True)
    check("hsl_login writes out", a.as_env()["HSL_LOGIN"] == "1")
    check("hsl_login defaults off", C.Answers().hsl_login is False)
    check("HSL_LOGIN is a render placeholder",
          "HSL_LOGIN" in C.placeholders(C.derive(a), a))

    derived = C.derive(a)
    palette = C.palette_from(derived)
    check("derive.sh yields 48 swatches", len(palette) == 48, len(palette))
    rows = C.palette_rows_from(derived)
    check("six named schemes", rows == ["monokai", "catppuccin", "dracula",
                                        "nord", "tokyonight", "neon"], rows)
    check("hexes unique across schemes", len({s.hex for s in palette}) == 48)
    check("every swatch carries its scheme", all(s.group in rows for s in palette))
    check("catppuccin mauve present",
          C.Swatch("mauve", "#cba6f7", "catppuccin") in palette)
    check("defaults live in real schemes",
          {s.hex: s.group for s in palette}.get("#00ff00") == "neon"
          and {s.hex: s.group for s in palette}.get("#ff7803") == "monokai")

    app = C.SetupApp(a, palette, None, columns=C.palette_columns(derived),
                     catalogue=cat, priv=C.privilege_summary(), palette_rows=rows)
    async with app.run_test(size=(140, 60)) as pilot:
        await pilot.pause()
        boxes = {w.id: w for w in app.query(Checkbox) if w.id and w.id.startswith("tool-")}
        check("a checkbox per tool", len(boxes) == N, len(boxes))
        check("nvitop unchecked", boxes["tool-nvitop"].value is False)
        check("eza checked", boxes["tool-eza"].value is True)

        # toggle two and confirm the answers follow
        boxes["tool-eza"].value = False
        boxes["tool-nvitop"].value = True
        await pilot.pause()
        check("toggling off updates answers", "eza" in app.answers.tools_off,
              app.answers.tools_off)
        check("toggling on updates answers", "nvitop" not in app.answers.tools_off,
              app.answers.tools_off)
        check("tools_off stays in catalogue order",
              list(app.answers.tools_off) == ["brew", "eza"], app.answers.tools_off)

        # one shared grid, six lines, both accents marked in it
        grid = app.query_one("#palette", C.PaletteGrid)
        check("grid is 6 scheme rows", grid.rows == 6, grid.rows)
        check("grid labels both accents",
              grid.label_for("primary") == "monokai / cyan"
              and grid.label_for("secondary") == "monokai / yellow",
              (grid.label_for("primary"), grid.label_for("secondary")))
        check("editing target defaults to primary", grid.active == "primary")
        # p/s switches which accent the arrows move
        grid.action_target("secondary")
        await pilot.pause()
        check("p/s switches target", grid.active == "secondary")
        check("editing row follows the grid",
              app.query_one("#palette_target", C.ChoiceRow).value == "secondary")
        before = app.answers.primary
        grid.action_step(1)
        await pilot.pause()
        check("arrows now move secondary only",
              app.answers.primary == before and app.answers.secondary != "#ffd866",
              (app.answers.primary, app.answers.secondary))
        # a marker for each accent is actually rendered
        painted = str(app.query_one("#palette").render())
        check("P and S markers rendered", "P" in painted and "S" in painted)

        box = app.query_one("#hsl_login", Checkbox)
        check("hsl checkbox reflects the answer", box.value is True)
        box.value = False
        await pilot.pause()
        check("unticking it updates answers", app.answers.hsl_login is False)

        # the plan pane rendered something
        await pilot.pause(0.6)
        plan = app.query_one("#plan").render()
        check("plan pane populated", len(str(plan)) > 50, repr(str(plan)[:40]))

        # writing the answers out
        import tempfile
        out = Path(tempfile.mkdtemp(prefix="dotfiles-test.")) / "out.env"
        app.out = out
        app.action_install()
        await pilot.pause()
        text = out.read_text()
        check("written fragment has TOOL_EZA=0", "TOOL_EZA=0" in text)
        check("written fragment has TOOL_NVITOP=1", "TOOL_NVITOP=1" in text)
        check("written fragment keeps colours", 'PRIMARY="#78dce8"' in text)
        check("written fragment has HSL_LOGIN=0", "HSL_LOGIN=0" in text)

asyncio.run(main())
print()
print("FAILURES:", fails if fails else "none")
sys.exit(1 if fails else 0)
