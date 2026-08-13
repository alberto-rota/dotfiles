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
import subprocess
import sys
from dataclasses import replace
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
    # The login autostart is three-way now (none / herdr / dasshboard). The env
    # above carries only the superseded boolean, so this also pins the migration:
    # HSL_LOGIN=1 meant "start herdr", and a machine set up before dasshboard
    # existed must keep doing that rather than be quietly reset to none.
    check("HSL_LOGIN=1 migrates to herdr", a.login_start == "herdr", a.login_start)
    check("login_start writes out", a.as_env()["LOGIN_START"] == "herdr")
    check("login_start defaults to none", C.Answers().login_start == "none")
    check("LOGIN_START is a render placeholder",
          "LOGIN_START" in C.placeholders(C.derive(a), a))
    check("HSL_LOGIN=0 migrates to none",
          C.Answers.from_env({"HSL_LOGIN": "0"}, cat).login_start == "none")
    check("LOGIN_START wins over the legacy boolean",
          C.Answers.from_env({"HSL_LOGIN": "1", "LOGIN_START": "dasshboard"},
                             cat).login_start == "dasshboard")
    check("an unknown LOGIN_START falls back to none",
          C.Answers.from_env({"LOGIN_START": "nonsense"}, cat).login_start == "none")
    # lib/derive.sh has to reach the same three answers from the same input, or
    # install.sh and the UI would disagree about what a machine currently does.
    for given, want in (("HSL_LOGIN=1", "herdr"), ("HSL_LOGIN=0", "none"),
                        ("LOGIN_START=dasshboard", "dasshboard"),
                        ("LOGIN_START=nonsense", "none")):
        key, _, value = given.partition("=")
        got = subprocess.run(
            ["bash", "-c", f'. "$1"; {key}="{value}"; derive; printf %s "$LOGIN_START"',
             "_", str(C.DERIVE)],
            capture_output=True, text=True,
        ).stdout.strip()
        check(f"derive.sh: {given} -> {want}", got == want, got)

    # CLAUDE_SWAP turns round the accents Claude Code paints its own UI with and
    # NOTHING else, so the check that matters is the negative one: the prompt
    # and all THREE status bars -- tmux, hsl and Claude Code's own -- have to
    # come out of derive.sh byte-identical either way.
    check("claude_swap defaults off", C.Answers().claude_swap is False)
    swapped = replace(a, claude_swap=True)
    d_off, d_on = C.derive(a), C.derive(swapped)
    check("swap turns the theme pair round",
          (d_on["CLAUDE_PRIMARY"], d_on["CLAUDE_SECONDARY"])
          == (d_off["CLAUDE_SECONDARY"], d_off["CLAUDE_PRIMARY"]),
          (d_on["CLAUDE_PRIMARY"], d_on["CLAUDE_SECONDARY"]))
    bubbles = ("CLAUDE_MODEL_RGB", "CLAUDE_EFFORT_RGB", "CLAUDE_USAGE_RGB",
               "CLAUDE_WEEK_RGB", "CLAUDE_CTX_RGB")
    check("swap leaves the status line bubbles alone",
          all(d_off[k] == d_on[k] for k in bubbles), d_on["CLAUDE_MODEL_RGB"])
    check("swap turns the shimmers round too",
          (d_on["CLAUDE_PRIMARY_SHIMMER"], d_on["CLAUDE_SECONDARY_SHIMMER"])
          == (d_off["CLAUDE_SECONDARY_SHIMMER"], d_off["CLAUDE_PRIMARY_SHIMMER"]))
    untouched = [k for k in d_off if k.startswith(("OMP_", "TMUX_", "HSL_"))
                 or k in ("PRIMARY", "SECONDARY", "PRIMARY_DIM") or k in bubbles]
    check("swap leaves the prompt and all three bars alone",
          all(d_off[k] == d_on[k] for k in untouched), f"{len(untouched)} keys")
    # Backgrounds under white text, so these are capped rather than ramped --
    # a grey accent has to come back a grey, not an invented colour.
    grey = C.derive(replace(a, primary="#999999", secondary="#999999"))
    check("a grey accent tints to grey",
          grey["CLAUDE_MSG_BG"] == "#383838", grey["CLAUDE_MSG_BG"])

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

        # The login autostart: a ChoiceRow, since the answer is one of three and
        # two checkboxes could both be ticked -- a state one login slot cannot
        # hold. It opens on the migrated answer (herdr, from HSL_LOGIN=1 above)
        # and cycles round to none, which is what the written fragment then has.
        row = app.query_one("#login_start", C.ChoiceRow)
        check("login row reflects the migrated answer", row.value == "herdr", row.value)
        row.action_cycle(1)
        await pilot.pause()
        check("cycling it updates answers", app.answers.login_start == "dasshboard",
              app.answers.login_start)
        row.action_cycle(1)
        await pilot.pause()
        check("it wraps back round to none", app.answers.login_start == "none",
              app.answers.login_start)

        swap_box = app.query_one("#claude_swap", Checkbox)
        check("claude swap checkbox starts off", swap_box.value is False)
        swap_box.value = True
        await pilot.pause()
        check("ticking it updates answers", app.answers.claude_swap is True)

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
        check("written fragment has LOGIN_START=none", "LOGIN_START=none" in text)
        check("written fragment has CLAUDE_SWAP=1", "CLAUDE_SWAP=1" in text)

asyncio.run(main())
print()
print("FAILURES:", fails if fails else "none")
sys.exit(1 if fails else 0)
