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

from textual.widgets import Checkbox, Input  # noqa: E402

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

    # DASSH_SWAP is CLAUDE_SWAP's shape applied to dasshboard's own [theme]
    # table: primary/accent follow this machine's primary/secondary unless
    # told to swap, and nothing else moves.
    check("dassh_swap defaults off", C.Answers().dassh_swap is False)
    d_dassh_off = C.derive(a)
    d_dassh_on = C.derive(replace(a, dassh_swap=True))
    check("unswapped: dasshboard primary/accent follow primary/secondary",
          (d_dassh_off["DASSH_PRIMARY"], d_dassh_off["DASSH_ACCENT"])
          == (d_dassh_off["PRIMARY"], d_dassh_off["SECONDARY"]))
    check("dassh swap turns dasshboard's pair round",
          (d_dassh_on["DASSH_PRIMARY"], d_dassh_on["DASSH_ACCENT"])
          == (d_dassh_off["DASSH_ACCENT"], d_dassh_off["DASSH_PRIMARY"]),
          (d_dassh_on["DASSH_PRIMARY"], d_dassh_on["DASSH_ACCENT"]))
    check("dassh swap leaves claude_swap's keys alone",
          d_dassh_off["CLAUDE_PRIMARY"] == d_dassh_on["CLAUDE_PRIMARY"])

    # The disk pill and the progress-bar answers it shares with the GPU pill.
    check("show_disk defaults on", C.Answers().show_disk is True)
    check("disk_mountpoint defaults to /", C.Answers().disk_mountpoint == "/")
    check("bar_width defaults to 8", C.Answers().bar_width == 8)
    check("bar_color defaults to primary", C.Answers().bar_color == "primary")
    disk_env = {"SHOW_DISK": "0", "DISK_MOUNTPOINT": "/data", "BAR_WIDTH": "12",
                "BAR_COLOR": "secondary"}
    b = C.Answers.from_env(disk_env, cat)
    check("SHOW_DISK round-trips in", b.show_disk is False)
    check("DISK_MOUNTPOINT round-trips in", b.disk_mountpoint == "/data", b.disk_mountpoint)
    check("BAR_WIDTH round-trips in", b.bar_width == 12, b.bar_width)
    check("BAR_COLOR round-trips in", b.bar_color == "secondary", b.bar_color)
    check("as_env writes SHOW_DISK back out", b.as_env()["SHOW_DISK"] == "0")
    check("as_env writes DISK_MOUNTPOINT back out", b.as_env()["DISK_MOUNTPOINT"] == "/data")
    check("as_env writes BAR_WIDTH back out", b.as_env()["BAR_WIDTH"] == "12")
    check("as_env writes BAR_COLOR back out", b.as_env()["BAR_COLOR"] == "secondary")
    # Bad values fall back to the default rather than raising or aborting --
    # same rule as an unrecognised LOGIN_START above.
    check("a relative DISK_MOUNTPOINT falls back to /",
          C.Answers.from_env({"DISK_MOUNTPOINT": "relative/path"}, cat).disk_mountpoint == "/")
    check("an out-of-range BAR_WIDTH falls back to 8",
          C.Answers.from_env({"BAR_WIDTH": "999"}, cat).bar_width == 8)
    check("a non-numeric BAR_WIDTH falls back to 8",
          C.Answers.from_env({"BAR_WIDTH": "nope"}, cat).bar_width == 8)
    check("an unknown BAR_COLOR falls back to primary",
          C.Answers.from_env({"BAR_COLOR": "neutral"}, cat).bar_color == "primary")
    check("BAR_WIDTH is a render placeholder", "BAR_WIDTH" in C.placeholders(C.derive(a), a))
    check("BAR_COLOR_HEX is a render placeholder",
          "BAR_COLOR_HEX" in C.placeholders(C.derive(a), a))
    # lib/derive.sh has to reach the same fallback from the same bad input, or
    # install.sh and the UI would disagree about what a machine currently does.
    for assign, out_var, want in (
        ("BAR_WIDTH=999", "BAR_WIDTH", "8"),
        ("BAR_WIDTH=nope", "BAR_WIDTH", "8"),
        ("BAR_COLOR=nonsense", "BAR_COLOR_HEX", "#00ff00"),
        ("BAR_COLOR=secondary", "BAR_COLOR_HEX", "#ff7803"),
        ("DISK_MOUNTPOINT=relative/path", "DISK_MOUNTPOINT", "/"),
    ):
        got = subprocess.run(
            ["bash", "-c",
             f'. "$1"; PRIMARY=#00ff00; SECONDARY=#ff7803; {assign}; derive; '
             f'printf %s "${out_var}"',
             "_", str(C.DERIVE)],
            capture_output=True, text=True,
        ).stdout.strip()
        check(f"derive.sh: {assign} -> {out_var}={want}", got == want, got)

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

        dassh_swap_box = app.query_one("#dassh_swap", Checkbox)
        check("dasshboard swap checkbox starts off", dassh_swap_box.value is False)
        dassh_swap_box.value = True
        await pilot.pause()
        check("ticking it updates answers", app.answers.dassh_swap is True)

        # The disk pill: a checkbox, a mountpoint Input disabled while it's
        # off, and the width/colour it shares with the GPU pill's own bars.
        disk_box = app.query_one("#show_disk", Checkbox)
        mount_input = app.query_one("#disk-mountpoint", Input)
        check("disk pill checkbox starts on", disk_box.value is True)
        check("mountpoint input starts enabled", mount_input.disabled is False)
        disk_box.value = False
        await pilot.pause()
        check("unticking it updates answers", app.answers.show_disk is False)
        check("mountpoint input disables with it", mount_input.disabled is True)
        disk_box.value = True
        await pilot.pause()
        check("mountpoint input re-enables", mount_input.disabled is False)

        mount_input.value = "/data"
        await pilot.pause()
        check("typing a mountpoint updates answers",
              app.answers.disk_mountpoint == "/data", app.answers.disk_mountpoint)
        mount_input.value = "not absolute"
        await pilot.pause()
        check("an invalid mountpoint is flagged, not applied",
              "-invalid" in mount_input.classes and app.answers.disk_mountpoint == "/data")

        width_input = app.query_one("#bar-width", Input)
        check("bar width input starts at the default", width_input.value == "8")
        width_input.value = "14"
        await pilot.pause()
        check("typing a bar width updates answers", app.answers.bar_width == 14)
        width_input.value = "0"
        await pilot.pause()
        check("an out-of-range width is flagged, not applied",
              "-invalid" in width_input.classes and app.answers.bar_width == 14)

        bar_color_row = app.query_one("#bar_color", C.ChoiceRow)
        check("bar colour defaults to primary", bar_color_row.value == "primary")
        bar_color_row.action_cycle(1)
        await pilot.pause()
        check("cycling it updates answers", app.answers.bar_color == "secondary")

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
        check("written fragment has DASSH_SWAP=1", "DASSH_SWAP=1" in text)
        check("written fragment has SHOW_DISK=1", "SHOW_DISK=1" in text)
        check("written fragment keeps the mountpoint", 'DISK_MOUNTPOINT="/data"' in text)
        check("written fragment has BAR_WIDTH=14", "BAR_WIDTH=14" in text)
        check("written fragment has BAR_COLOR=secondary", "BAR_COLOR=secondary" in text)

asyncio.run(main())
print()
print("FAILURES:", fails if fails else "none")
sys.exit(1 if fails else 0)
