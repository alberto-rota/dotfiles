#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# # Capped at the tested major on purpose: install.sh runs this unattended while
# # setting up a machine, so a breaking Textual release must not be able to turn
# # "install my dotfiles" into a traceback. Bump it after trying the new major.
# dependencies = ["textual>=1.0,<9"]
# ///
"""The dotfiles setup UI: pick the colours, the machine name and the toggles,
watching oh-my-posh, the two status bars and herdr change as you do.

Run by install.sh through `uv run --script`, which is why the dependencies are
declared in the PEP 723 header above: nothing has to be installed on the machine
by hand, and nothing is left behind on it either.

    uv run --script tui/configure.py --out /tmp/answers.env    # the real thing
    uv run --script tui/configure.py --dump                    # previews to stdout

The current answers come in through the environment (PRIMARY, SECONDARY,
MACHINE, SHOW_*, OMP_*), and the chosen ones go out as a shell fragment in
theme.env format, which install.sh sources. Exit 0 = confirmed, 10 = cancelled.

What makes the previews trustworthy rather than a drawing of what the config is
*supposed* to look like:

  * the status bar is the string lib/derive.sh assembles -- the same function
    install.sh calls to render the real hsl status line -- interpreted
    here by a small tmux-format renderer, with the `#(...)` segments actually
    executed (a rendered copy of gpu-status.sh really does run nvidia-smi).
    Only herdr's bar is shown: tmux's is built from the same toggles by the same
    code, so previewing both said the same thing twice;
  * the prompt is `oh-my-posh print` on a rendered copy of the real template;
  * the Claude Code line is the rendered status line script itself, run against
    a sample statusLine payload;
  * only the herdr pane is a drawing, because there is no way to make herdr
    render one frame into a string. Its colours (accent, and the darkened
    surface_dim behind the selected row) are the real derived values.
"""

from __future__ import annotations

import argparse
import colorsys
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, replace
from pathlib import Path

from rich.style import Style
from rich.text import Text
from textual import events, on, work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Container, Horizontal, VerticalScroll
from textual.message import Message
from textual.widgets import Button, Checkbox, Footer, Header, Input, Label, Static

DOTFILES = Path(os.environ.get("DOTFILES") or Path(__file__).resolve().parent.parent)
DERIVE = DOTFILES / "lib" / "derive.sh"
TOOLS = DOTFILES / "lib" / "tools.sh"

HEX_RE = re.compile(r"^#[0-9a-fA-F]{6}$")
BARE_HEX_RE = re.compile(r"^[0-9a-fA-F]{6}$")
MACHINE_RE = re.compile(r"^[A-Za-z0-9._-]{1,24}$")
# Only for painting the "neutral" choice in the UI; lib/derive.sh owns the value
# that actually gets rendered (and honours $NEUTRAL_FG if it is set).
NEUTRAL_FG = os.environ.get("NEUTRAL_FG", "#d6deeb")

# Stand-ins for the two accent colours while a helper script (gpu-status.sh and
# friends) is rendered and run. The colours are swapped into its OUTPUT
# afterwards, so nvidia-smi is not re-run for every keystroke on the colour
# field -- only when something that actually changes the reading does.
P_SENTINEL = "<<PRIMARY>>"
S_SENTINEL = "<<SECONDARY>>"

HELPER_TEMPLATES = {
    "gpu-status.sh": "tmux/gpu-status.sh.in",
    "slurm-status.sh": "tmux/slurm-status.sh.in",
    "other-sessions.sh": "tmux/other-sessions.sh.in",
}
HELPER_TTL = 15.0  # seconds a helper's output is reused for

# Same trick for the Claude status line, whose five bubble colours are baked
# into the rendered script: render it once with sentinels, run it (it shells out
# to jq eight times), then paint the output. Recolouring costs nothing.
CLAUDE_SENTINELS = ("<<C1>>", "<<C2>>", "<<C3>>", "<<C4>>", "<<C5>>")
CLAUDE_RGB_KEYS = ("CLAUDE_MODEL_RGB", "CLAUDE_EFFORT_RGB", "CLAUDE_USAGE_RGB",
                   "CLAUDE_WEEK_RGB", "CLAUDE_CTX_RGB")
# A plausible statusLine payload, so the bar shows real bars and a real clock
# rather than the "no data" dashes every field falls back to.
CLAUDE_SAMPLE = {
    "model": {"display_name": "Claude Opus 5 (1M context)"},
    "effort": {"level": "high"},
    "context_window": {"used_percentage": 46},
    "rate_limits": {
        "five_hour": {"used_percentage": 38},
        "seven_day": {"used_percentage": 61},
    },
    "cost": {"total_cost_usd": 12.34},
}

# ---------------------------------------------------------------------------
# answers
# ---------------------------------------------------------------------------
# What a per-component oh-my-posh colour answer may say, and what the leading
# glyph's mode may be. Both mirror lib/derive.sh, which resolves them to hex.
ACCENT_CHOICES = ("primary", "secondary", "neutral")
ICON_MODES = ("fixed", "slurm")


# ---------------------------------------------------------------------------
# the tool catalogue -- lib/tools.sh, same arrangement as lib/derive.sh
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class Tool:
    id: str
    label: str
    group: str


@dataclass(frozen=True)
class Swatch:
    """One palette entry: "pink", "#ff6188", "monokai"."""
    name: str
    hex: str
    group: str


# What each catalogue group is called in the UI. An unknown group falls back to
# its own name, so adding one to lib/tools.sh needs no edit here.
GROUP_LABELS = {
    "providers": "toolchains",
    "shell": "shell",
    "gpu": "gpu",
    "editor": "editor",
    "python": "python (uv tools)",
    "net": "network",
    "herdr": "herdr",
}


def load_catalogue() -> list[Tool]:
    """`lib/tools.sh --list` -> id|label|group|selected, in install order."""
    try:
        proc = subprocess.run(
            ["bash", str(TOOLS), "--list"], capture_output=True, text=True, timeout=30
        )
    except (OSError, subprocess.SubprocessError):
        return []
    if proc.returncode != 0:
        return []
    out: list[Tool] = []
    for line in proc.stdout.splitlines():
        parts = line.split("|")
        if len(parts) >= 3 and parts[0]:
            out.append(Tool(parts[0], parts[1], parts[2]))
    return out


def privilege_summary() -> str:
    """The one-liner lib/tools.sh prints about sudo on this machine, so the
    Tools panel can say why the plan chose apt over cargo (or the reverse)."""
    try:
        proc = subprocess.run(
            ["bash", str(TOOLS), "--priv"], capture_output=True, text=True, timeout=15
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    for line in proc.stdout.splitlines():
        key, sep, value = line.partition("=")
        if sep and key == "PRIV_SUMMARY":
            return value
    return ""


@dataclass(frozen=True)
class Answers:
    primary: str = "#00ff00"
    secondary: str = "#ff7803"
    machine: str = "machine"
    show_host: bool = True
    show_gpu: bool = True
    show_temp: bool = True
    show_slurm: bool = True
    show_datetime: bool = True
    # oh-my-posh, per component: which of the two accents (or neither) paints it.
    omp_icon_mode: str = "fixed"
    omp_icon: str = "secondary"
    omp_text: str = "primary"
    omp_chevron_ok: str = "primary"
    omp_chevron_error: str = "secondary"
    # The panel every prompt pill is drawn on. Not one of the three accent
    # choices above and not a palette swatch either: it sits *behind* them, so
    # the palette (all light, all picked to take black text) holds no usable
    # value for it. #212224 is the Monokai Pro background this theme was built
    # around; the other answer people actually want is #000000, to match a
    # terminal whose own background is black.
    omp_pill_bg: str = "#212224"
    # Start hsl (bin/hsl: herdr plus the status line, on every platform now)
    # from ~/.bashrc at login. Off by
    # default: it is the one answer that changes what opening a terminal does,
    # and shell/hsl-login.sh.in carries a wall of guards because of it.
    hsl_login: bool = False
    # The tools, held as "everything in the catalogue" plus "the ones switched
    # off" rather than as one field per tool: the catalogue is lib/tools.sh's to
    # define, and a dataclass field per entry would mean editing this file every
    # time one is added. Tuples because the dataclass is frozen (and hashable).
    tool_ids: tuple[str, ...] = ()
    tools_off: tuple[str, ...] = ()

    def wants(self, tool_id: str) -> bool:
        return tool_id not in self.tools_off

    def with_tool(self, tool_id: str, on: bool) -> "Answers":
        off = set(self.tools_off)
        off.discard(tool_id) if on else off.add(tool_id)
        # Sorted by catalogue order, so as_shell() output is stable between runs
        # that reached the same answers by a different sequence of clicks.
        order = {t: i for i, t in enumerate(self.tool_ids)}
        return replace(self, tools_off=tuple(sorted(off, key=lambda t: order.get(t, 0))))

    @classmethod
    def from_env(cls, env: dict[str, str], catalogue: "list[Tool] | None" = None) -> "Answers":
        def flag(name: str, default: bool) -> bool:
            return env.get(name, "1" if default else "0").strip() == "1"

        def choice(name: str, default: str, allowed=ACCENT_CHOICES) -> str:
            value = env.get(name, "").strip().lower()
            return value if value in allowed else default

        d = cls()
        primary = env.get("PRIMARY", d.primary)
        secondary = env.get("SECONDARY", d.secondary)
        pill_bg = env.get("OMP_PILL_BG", d.omp_pill_bg)
        machine = env.get("MACHINE", "") or _hostname()
        # Answers saved before per-component colours existed still describe a
        # look; lib/derive.sh migrates them, and so does this, so opening the UI
        # on an already-set-up machine shows what that machine currently has.
        legacy_icon = "secondary" if flag("OMP_COLOR_ICON", True) else "neutral"
        legacy_text = "primary" if flag("OMP_COLOR_TEXT", True) else "neutral"
        chevron_on = flag("OMP_COLOR_CHEVRON", True)
        # Absent means on, matching tool_selected() in lib/tools.sh -- which is
        # what makes a tool added to the catalogue turn itself on for a machine
        # whose theme.env predates it.
        catalogue = catalogue or []
        tool_ids = tuple(t.id for t in catalogue)
        tools_off = tuple(
            t.id for t in catalogue if env.get(f"TOOL_{t.id.upper()}", "1").strip() == "0"
        )
        return cls(
            tool_ids=tool_ids,
            tools_off=tools_off,
            primary=primary if HEX_RE.match(primary) else d.primary,
            secondary=secondary if HEX_RE.match(secondary) else d.secondary,
            machine=machine if MACHINE_RE.match(machine) else d.machine,
            show_host=flag("SHOW_HOST", d.show_host),
            show_gpu=flag("SHOW_GPU", d.show_gpu),
            show_temp=flag("SHOW_TEMP", d.show_temp),
            show_slurm=flag("SHOW_SLURM", d.show_slurm),
            show_datetime=flag("SHOW_DATETIME", d.show_datetime),
            hsl_login=flag("HSL_LOGIN", d.hsl_login),
            omp_icon_mode=choice("OMP_ICON_MODE", d.omp_icon_mode, ICON_MODES),
            omp_icon=choice("OMP_ICON", legacy_icon),
            omp_text=choice("OMP_TEXT", legacy_text),
            omp_chevron_ok=choice("OMP_CHEVRON_OK", "primary" if chevron_on else "neutral"),
            omp_chevron_error=choice("OMP_CHEVRON_ERROR", "secondary" if chevron_on else "neutral"),
            omp_pill_bg=pill_bg if HEX_RE.match(pill_bg) else d.omp_pill_bg,
        )

    def as_env(self) -> dict[str, str]:
        # SHOW_TEMP is a sub-toggle of SHOW_GPU: with no GPU pill there is no
        # temperature to gate, and install.sh's wizard forces it off the same
        # way, so the two front-ends save identical answers.
        temp = self.show_temp and self.show_gpu
        tools = {f"TOOL_{t.upper()}": _b(self.wants(t)) for t in self.tool_ids}
        return {
            "PRIMARY": self.primary,
            "SECONDARY": self.secondary,
            "MACHINE": self.machine,
            "SHOW_HOST": _b(self.show_host),
            "SHOW_GPU": _b(self.show_gpu),
            "SHOW_TEMP": _b(temp),
            "SHOW_SLURM": _b(self.show_slurm),
            "SHOW_DATETIME": _b(self.show_datetime),
            "HSL_LOGIN": _b(self.hsl_login),
            "OMP_ICON_MODE": self.omp_icon_mode,
            "OMP_ICON": self.omp_icon,
            "OMP_TEXT": self.omp_text,
            "OMP_CHEVRON_OK": self.omp_chevron_ok,
            "OMP_CHEVRON_ERROR": self.omp_chevron_error,
            "OMP_PILL_BG": self.omp_pill_bg,
            # Last, so the fragment install.sh sources reads in the same order
            # theme.env is written in: the look first, then the tool answers.
            **tools,
        }

    def as_shell(self) -> str:
        env = self.as_env()
        quoted = {"PRIMARY", "SECONDARY", "MACHINE", "OMP_PILL_BG"}  # validated
        lines = [
            "# Written by dotfiles/tui/configure.py, sourced by install.sh.",
            *(f'{k}="{v}"' if k in quoted else f"{k}={v}" for k, v in env.items()),
        ]
        return "\n".join(lines) + "\n"


def _b(value: bool) -> str:
    return "1" if value else "0"


def _hostname() -> str:
    name = (os.uname().nodename or "machine").split(".")[0]
    return name if MACHINE_RE.match(name) else "machine"


# ---------------------------------------------------------------------------
# lib/derive.sh -- the single source of truth for everything computed
# ---------------------------------------------------------------------------
LEGACY_KEYS = ("OMP_COLOR_ICON", "OMP_COLOR_TEXT", "OMP_COLOR_CHEVRON")


def derive(answers: Answers) -> dict[str, str]:
    """Run lib/derive.sh in emit mode and parse its KEY=value lines."""
    env = dict(os.environ)
    # The pre-per-component answers were already folded into `answers` when the
    # UI started; leaving them in the environment would let derive.sh migrate
    # them a second time, on top of the choices being made right now.
    for key in LEGACY_KEYS:
        env.pop(key, None)
    env.update(answers.as_env())
    proc = subprocess.run(
        ["bash", str(DERIVE)], env=env, capture_output=True, text=True, timeout=15
    )
    if proc.returncode != 0:
        raise RuntimeError(f"lib/derive.sh failed: {proc.stderr.strip()}")
    out: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        key, sep, value = line.partition("=")
        if sep:
            out[key] = value
    return out


def palette_columns(derived: dict[str, str]) -> int:
    try:
        return max(1, int(derived.get("PALETTE_COLUMNS", "8")))
    except ValueError:
        return 8


def palette_from(derived: dict[str, str]) -> list[Swatch]:
    """The swatches, as lib/derive.sh defines them: name:hex:scheme, ...

    The scheme is the third field because each row of eight IS one real palette
    (monokai, catppuccin, ...) and the grid labels its rows with it.
    """
    entries: list[Swatch] = []
    for field in derived.get("PALETTE", "").split():
        parts = field.split(":")
        if len(parts) >= 2 and HEX_RE.match(parts[1]):
            entries.append(Swatch(parts[0], parts[1].lower(),
                                  parts[2] if len(parts) > 2 else ""))
    return entries


def palette_rows_from(derived: dict[str, str]) -> list[str]:
    """The scheme names, in row order."""
    return derived.get("PALETTE_ROWS", "").split()


def render_template(rel: str, mapping: dict[str, str]) -> str:
    """install.sh's render(), in Python: strip #>> lines, substitute @NAME@.

    Longest placeholder first, same specific-before-general order install.sh's
    sed uses, so @PRIMARY@ can never eat the front of @PRIMARY_DIM@.
    """
    text = (DOTFILES / rel).read_text(encoding="utf-8")
    body = "".join(l for l in text.splitlines(keepends=True) if not l.startswith("#>>"))
    for key in sorted(mapping, key=len, reverse=True):
        body = body.replace(f"@{key}@", mapping[key])
    return body


def placeholders(derived: dict[str, str], answers: Answers) -> dict[str, str]:
    """The same set of substitutions install.sh's render() performs."""
    env = answers.as_env()
    xdg = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return {
        "PRIMARY": derived["PRIMARY"],
        "PRIMARY_DIM": derived["PRIMARY_DIM"],
        "SECONDARY": derived["SECONDARY"],
        "MACHINE": derived["MACHINE"],
        "MACHINE_LOWER": derived["MACHINE_LOWER"],
        "USER": derived["USER_NAME"],
        "HERDR_CONFIG": f"{xdg}/herdr",
        "SHOW_TEMP": env["SHOW_TEMP"],
        "HSL_LOGIN": env["HSL_LOGIN"],
        "OMP_ICON_COLOR": derived["OMP_ICON_COLOR"],
        "OMP_ICON_COLOR_JOB": derived["OMP_ICON_COLOR_JOB"],
        "CLAUDE_MODEL_RGB": derived["CLAUDE_MODEL_RGB"],
        "CLAUDE_EFFORT_RGB": derived["CLAUDE_EFFORT_RGB"],
        "CLAUDE_USAGE_RGB": derived["CLAUDE_USAGE_RGB"],
        "CLAUDE_WEEK_RGB": derived["CLAUDE_WEEK_RGB"],
        "CLAUDE_CTX_RGB": derived["CLAUDE_CTX_RGB"],
        "OMP_TEXT_COLOR": derived["OMP_TEXT_COLOR"],
        "OMP_CHEVRON_FG": derived["OMP_CHEVRON_FG"],
        "OMP_CHEVRON_ERR": derived["OMP_CHEVRON_ERR"],
        "OMP_PATH_COLOR": derived["OMP_PATH_COLOR"],
        "OMP_TIME_COLOR": derived["OMP_TIME_COLOR"],
        "OMP_PY_COLOR": derived["OMP_PY_COLOR"],
        "OMP_GIT_CLEAN": derived["OMP_GIT_CLEAN"],
        "OMP_GIT_BEHIND": derived["OMP_GIT_BEHIND"],
        "OMP_GIT_AHEAD": derived["OMP_GIT_AHEAD"],
        "OMP_GIT_DIVERGED": derived["OMP_GIT_DIVERGED"],
        "OMP_GIT_DIRTY": derived["OMP_GIT_DIRTY"],
        # An answer used verbatim rather than a derived value, so it comes from
        # as_env() like SHOW_TEMP does -- there is nothing for derive.sh to do to
        # it beyond the validation from_env() already applied.
        "OMP_PILL_BG": env["OMP_PILL_BG"],
        "TMUX_STATUS_LEFT": derived["TMUX_STATUS_LEFT"],
        "TMUX_STATUS_RIGHT": derived["TMUX_STATUS_RIGHT"],
        "HSL_STATUS_LEFT": derived["HSL_STATUS_LEFT"],
        "HSL_STATUS_RIGHT": derived["HSL_STATUS_RIGHT"],
    }


# ---------------------------------------------------------------------------
# tmux status-format renderer
# ---------------------------------------------------------------------------
INVALID = object()

TMUX_NAMED = {
    "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
    "brightblack", "brightred", "brightgreen", "brightyellow", "brightblue",
    "brightmagenta", "brightcyan", "brightwhite", "terminal",
}


def parse_color(spec: str):
    """A tmux colour, or INVALID -- which makes tmux discard the whole style.

    That last part is load-bearing: the right-hand side of the tmux bar contains
    a deliberate "bg=#00000t0" typo, kept because tmux dropping that one style is
    what makes the space it covers invisible. Reproducing the discard here is
    what makes the preview show the same thing the real bar does.
    """
    spec = spec.strip()
    if spec in ("default", "terminal"):
        return None
    if HEX_RE.match(spec):
        return spec.lower()
    if spec in TMUX_NAMED:
        return spec
    m = re.fullmatch(r"colou?r(\d{1,3})", spec)
    if m and int(m.group(1)) <= 255:
        return f"color({m.group(1)})"
    return INVALID


@dataclass(frozen=True)
class BarStyle:
    fg: str | None = None
    bg: str | None = None
    bold: bool = False

    def rich(self) -> Style:
        return Style(color=self.fg, bgcolor=self.bg, bold=self.bold)


def parse_style(spec: str, current: BarStyle) -> BarStyle | None:
    """`#[fg=...,bg=...,bold]` -> a new style, or None if tmux would drop it."""
    style = current
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if part == "default":
            style = BarStyle()
        elif part == "bold":
            style = replace(style, bold=True)
        elif part in ("nobold", "nobright"):
            style = replace(style, bold=False)
        elif part.startswith(("fg=", "bg=")):
            colour = parse_color(part[3:])
            if colour is INVALID:
                return None
            style = replace(style, **{"fg" if part[0] == "f" else "bg": colour})
        elif part in ("none", "nounderscore", "noitalics", "noreverse", "italics",
                      "underscore", "reverse", "dim", "blink", "align=left",
                      "align=right", "align=centre", "align=center"):
            pass  # nothing the preview needs to show differently
        else:
            return None  # unknown attribute: tmux discards the entire style
    return style


def render_bar_format(fmt: str, resolve, now: float | None = None) -> Text:
    """Interpret one tmux status-format string into styled text.

    `#(command)` output is spliced back into the format and keeps being parsed,
    exactly as tmux does it -- a helper that ends on `#[fg=...]` really does
    colour what follows it in the bar.
    """
    text = Text()
    style = BarStyle()
    buf: list[str] = []
    expansions = 0
    when = time.localtime(now) if now is not None else time.localtime()

    def flush() -> None:
        if buf:
            text.append("".join(buf), style=style.rich())
            buf.clear()

    i = 0
    while i < len(fmt):
        ch = fmt[i]
        if ch == "#" and i + 1 < len(fmt):
            nxt = fmt[i + 1]
            if nxt == "#":
                buf.append("#")
                i += 2
                continue
            if nxt == "[":
                end = fmt.find("]", i)
                if end != -1:
                    flush()
                    new = parse_style(fmt[i + 2:end], style)
                    if new is not None:
                        style = new
                    i = end + 1
                    continue
            if nxt == "(":
                end = _matching_paren(fmt, i + 1)
                if end != -1:
                    out = ""
                    if expansions < 8:  # a helper that emits #() cannot loop forever
                        expansions += 1
                        out = resolve(fmt[i + 2:end])
                    fmt = fmt[:i] + out + fmt[end + 1:]
                    continue
            if nxt == "{":
                end = fmt.find("}", i)
                if end != -1:  # #{session_name} & co: nothing meaningful to preview
                    i = end + 1
                    continue
        if ch == "%" and i + 1 < len(fmt):
            code = fmt[i + 1]
            if code == "%":
                buf.append("%")
                i += 2
                continue
            if code.isalpha():
                buf.append(time.strftime("%" + code, when))
                i += 2
                continue
        buf.append(ch)
        i += 1

    flush()
    return text


def _matching_paren(fmt: str, open_idx: int) -> int:
    depth = 0
    for j in range(open_idx, len(fmt)):
        if fmt[j] == "(":
            depth += 1
        elif fmt[j] == ")":
            depth -= 1
            if depth == 0:
                return j
    return -1


def compose_bar(left: Text, right: Text, width: int, bg: str) -> Text:
    """left + the status-style background + right, in exactly `width` cells.

    The preview pane is narrower than the terminal the real bar lives in, so
    something has to give. It is the right-hand end, which is what tmux itself
    clips when a bar does not fit -- and it keeps the host pill, the part being
    configured, where it belongs.
    """
    width = max(width, 10)
    left = left.copy()
    if left.cell_len > width:
        left.truncate(width, overflow="ellipsis")
    right = right.copy()
    if right.cell_len > width - left.cell_len:
        right.truncate(max(0, width - left.cell_len), overflow="ellipsis")
    out = Text(no_wrap=True, overflow="ellipsis")
    out.append_text(left)
    out.append(" " * max(0, width - left.cell_len - right.cell_len), Style(bgcolor=bg))
    out.append_text(right)
    # Both halves are clipped above, but an ellipsis substituted into a
    # double-width cell can still land one over; the bar must be exact.
    if out.cell_len > width:
        out.truncate(width, overflow="ellipsis")
    return out


# ---------------------------------------------------------------------------
# the previews
# ---------------------------------------------------------------------------
class Previewer:
    """Renders the four preview panes. Lives on the worker thread."""

    def __init__(self) -> None:
        self._tmpdir = Path(tempfile.mkdtemp(prefix="dotfiles-preview."))
        self._helpers: dict[str, tuple[float, str, str]] = {}  # name -> (when, key, out)

    def cleanup(self) -> None:
        shutil.rmtree(self._tmpdir, ignore_errors=True)

    # -- helper scripts -----------------------------------------------------
    def _helper_output(self, name: str, show_temp: str) -> str:
        """Run a rendered copy of a status helper, with the colours left as
        sentinels so the result can be re-used across colour changes."""
        key = f"{name}:{show_temp}"
        cached = self._helpers.get(name)
        if cached and cached[1] == key and time.monotonic() - cached[0] < HELPER_TTL:
            return cached[2]

        rel = HELPER_TEMPLATES[name]
        script = self._tmpdir / name
        script.write_text(
            render_template(rel, {
                "PRIMARY": P_SENTINEL,
                "SECONDARY": S_SENTINEL,
                "SHOW_TEMP": show_temp,
            }),
            encoding="utf-8",
        )
        script.chmod(0o755)
        try:
            proc = subprocess.run(
                ["bash", str(script)], capture_output=True, text=True, timeout=5
            )
            out = proc.stdout.strip("\n")
        except (OSError, subprocess.SubprocessError):
            out = ""
        self._helpers[name] = (time.monotonic(), key, out)
        return out

    def _resolver(self, show_temp: str, primary: str, secondary: str):
        def resolve(command: str) -> str:
            name = os.path.basename(command.strip().strip("'\""))
            if name not in HELPER_TEMPLATES:
                return ""
            out = self._helper_output(name, show_temp)
            return out.replace(P_SENTINEL, primary).replace(S_SENTINEL, secondary)

        return resolve

    # -- panes --------------------------------------------------------------
    def statusline(self, derived: dict[str, str], answers: Answers, width: int) -> Text:
        """The hsl bar, the only one previewed: tmux's is assembled from the
        same toggles and stays in sync by construction (see lib/derive.sh), so
        showing both said the same thing twice."""
        env = answers.as_env()
        resolve = self._resolver(env["SHOW_TEMP"], derived["PRIMARY"], derived["SECONDARY"])
        return fit_block(compose_bar(
            render_bar_format(derived["HSL_STATUS_LEFT"], resolve),
            render_bar_format(derived["HSL_STATUS_RIGHT"], resolve),
            width, derived["PRIMARY"],
        ), width)

    def claude(self, derived: dict[str, str], answers: Answers, width: int) -> Text:
        """The real Claude Code status line: the rendered script, run against a
        sample statusLine payload, with the ramp painted into its output."""
        if not shutil.which("jq"):
            return Text("needs jq on PATH (the status line script parses its "
                        "JSON with it)", style="red")
        cached = self._helpers.get("claude")
        if cached and time.monotonic() - cached[0] < HELPER_TTL:
            out = cached[2]
        else:
            script = self._tmpdir / "statusline-command.sh"
            mapping = dict(zip(CLAUDE_RGB_KEYS, CLAUDE_SENTINELS))
            script.write_text(
                render_template("claude/statusline-command.sh.in", mapping), encoding="utf-8"
            )
            script.chmod(0o755)
            payload = dict(CLAUDE_SAMPLE)
            now = int(time.time())
            payload["rate_limits"] = {
                "five_hour": {**CLAUDE_SAMPLE["rate_limits"]["five_hour"],
                              "resets_at": now + 2 * 3600},
                "seven_day": {**CLAUDE_SAMPLE["rate_limits"]["seven_day"],
                              "resets_at": now + 3 * 86400},
            }
            try:
                proc = subprocess.run(
                    ["bash", str(script)], input=json.dumps(payload),
                    capture_output=True, text=True, timeout=10,
                )
                out = proc.stdout
            except (OSError, subprocess.SubprocessError) as exc:
                return Text(f"status line failed: {exc}", style="red")
            self._helpers["claude"] = (time.monotonic(), "claude", out)
        for sentinel, key in zip(CLAUDE_SENTINELS, CLAUDE_RGB_KEYS):
            out = out.replace(sentinel, derived[key])
        return fit_block(Text.from_ansi(out.rstrip("\n")), width)

    def posh(self, derived: dict[str, str], answers: Answers, width: int) -> Text:
        """The real prompt: oh-my-posh rendering a real copy of the template."""
        mapping = placeholders(derived, answers)
        if not shutil.which("oh-my-posh"):
            return self._posh_fallback(derived, answers, width)
        config = self._tmpdir / "omp.json"
        config.write_text(
            render_template("oh-my-posh/albe-monokai2.omp.json.in", mapping), encoding="utf-8"
        )
        try:
            proc = subprocess.run(
                ["oh-my-posh", "print", "primary", "--config", str(config),
                 # The real width, floored only enough that oh-my-posh has
                 # something to work with: it right-aligns its second block to
                 # whatever it is told, so a stale 40 here produced a line 92
                 # cells wide in a 46-cell pane, which then wrapped.
                 "--shell", "universal", "--terminal-width", str(max(width, 20))],
                capture_output=True, text=True, timeout=10,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            return Text(f"oh-my-posh failed: {exc}", style="red")
        if proc.returncode != 0:
            return self._posh_fallback(derived, answers, width)
        # OSC (the console title) would otherwise leak into the pane as text.
        clean = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)", "", proc.stdout)
        # Clipped here, not just by the caller: oh-my-posh pads its right-aligned
        # block out to the terminal width it was given and can still hand back a
        # line wider than the pane.
        return fit_block(Text.from_ansi(clean.rstrip("\n")), width)

    def _posh_fallback(self, derived: dict[str, str], answers: Answers, width: int) -> Text:
        """oh-my-posh is not on PATH yet (a machine being set up for the first
        time): draw the machine segment and the chevron line by hand."""
        panel = answers.omp_pill_bg
        out = Text()
        out.append(" ", Style(color=derived["OMP_ICON_COLOR"], bgcolor=panel))
        out.append(f" {derived['MACHINE_LOWER']} ", Style(color=derived["OMP_TEXT_COLOR"], bgcolor=panel))
        out.append(" ~/dotfiles ", Style(color=derived["OMP_PATH_COLOR"], bgcolor=panel))
        out.append("\n")
        out.append("╰─", Style(color=panel))
        out.append(" ", Style(color=derived["OMP_CHEVRON_FG"]))
        out.append("  (oh-my-posh not installed yet -- drawn by hand)", Style(dim=True))
        return fit_block(out, width)

    def plan(self, derived: dict[str, str], answers: Answers, width: int) -> Text:
        """What the tools phase would do, from `lib/tools.sh --plan` -- the same
        resolution install_tools() performs, so this pane cannot promise a route
        the installer would not take.

        Cached on the tool answers alone: it shells out to `command -v` a couple
        of dozen times and to `herdr plugin list`, and none of that changes when
        the only thing the user touched was a colour.
        """
        key = "|".join(answers.tools_off)
        cached = self._helpers.get("plan")
        if cached and cached[1] == key and time.monotonic() - cached[0] < HELPER_TTL:
            out = cached[2]
        else:
            env = dict(os.environ)
            env.update(answers.as_env())
            try:
                proc = subprocess.run(
                    ["bash", str(TOOLS), "--plan"], env=env,
                    capture_output=True, text=True, timeout=30,
                )
                out = proc.stdout
            except (OSError, subprocess.SubprocessError) as exc:
                return Text(f"plan failed: {exc}", style="red")
            self._helpers["plan"] = (time.monotonic(), key, out)

        accent = derived["PRIMARY"]
        marks = {
            "present": ("✓", Style(color="#6a9955")),      # already here
            "install": ("→", Style(color=accent, bold=True)),
            "blocked": ("✗", Style(color="#ff5555")),      # no route
            "skip":    ("·", Style(dim=True)),
        }
        text = Text(no_wrap=True, overflow="ellipsis")
        # 2 cells of glyph, then the id, then what is left for the route. The id
        # column was a fixed 19, which on its own overflowed a pane under ~22
        # cells; below that the route is dropped rather than wrapped.
        id_w = min(19, max(6, width - 12))
        body_w = width - 2 - id_w - 1
        rows = 0
        for line in out.splitlines():
            parts = line.split("|")
            if len(parts) < 4:
                continue
            tool_id, status, method, detail = parts[0], parts[1], parts[2], parts[3]
            glyph, style = marks.get(status, ("?", Style()))
            if rows:
                text.append("\n")
            rows += 1
            text.append(f"{glyph} ", style)
            name = Text(tool_id, Style(dim=(status == "skip")))
            if name.cell_len > id_w:
                name.truncate(id_w, overflow="ellipsis")
            else:
                name.append(" " * (id_w - name.cell_len))
            text.append_text(name)
            if body_w >= 6:
                body = detail if method == "-" else f"{method}  {detail}"
                line_text = Text(body, Style(dim=True) if status != "install" else style)
                if line_text.cell_len > body_w:
                    line_text.truncate(body_w, overflow="ellipsis")
                text.append(" ")
                text.append_text(line_text)
        if not rows:
            return Text("no plan (lib/tools.sh unreadable?)", style="red")
        return fit_block(text, width)

    def herdr(self, derived: dict[str, str], width: int) -> Text:
        """A drawing, unlike the other panes -- herdr cannot render one frame
        into a string. Every colour in it is a real derived value though:
        `accent` (the SECONDARY -- herdr's one accent token, which the config
        sets so the active tab label reads in the secondary) paints that tab,
        the window and pane borders and the agent labels on them, and
        `surface_dim` (the darkened primary) paints both the sidebar rail and
        the selected workspace row -- the one token herdr routes both of those
        through, which is why it has to be darkened.
        """
        accent = derived["SECONDARY"]
        dim = derived["PRIMARY_DIM"]
        secondary = derived["SECONDARY"]
        machine = derived["MACHINE_LOWER"]
        user = derived["USER_NAME"]
        panel = "#282828"   # gruvbox, herdr's base theme here
        fg = "#ebdbb2"
        muted = "#928374"

        # No floor here any more: it used to be max(width - 2, 44), which drew a
        # 46-cell box into whatever pane it was given and overflowed every
        # narrower one by up to 26 cells.
        if width < 26:
            # Short on purpose: the old wording was itself 31 cells and
            # overflowed the very panes it was apologising for.
            return Text("(too narrow)", style="dim")
        inner = width - 2
        side_w = min(24, max(8, inner // 3))
        body_w = inner - side_w - 1          # -1 for the divider column

        border = Style(color=accent)
        out = Text()

        def hline(left: str, right: str, junction: str) -> None:
            out.append(left, border)
            out.append("─" * side_w, border)
            out.append(junction, border)
            out.append("─" * body_w, border)
            out.append(right + "\n", border)

        def row(sidebar: Text, body: Text) -> None:
            out.append("│", border)
            out.append_text(_fit(sidebar, side_w, panel))
            out.append("│", Style(color=accent, bgcolor=panel))
            out.append_text(_fit(body, body_w, panel))
            out.append("│\n", border)

        def side(label: str, style: Style, rail: str = "▌", rail_style=None) -> Text:
            t = Text()
            t.append(rail, rail_style or Style(color=dim, bgcolor=panel))
            t.append(label, style)
            return t

        def body(label: str, style: Style | None = None) -> Text:
            return Text(label, style or Style(color=fg, bgcolor=panel))

        title = Text()
        title.append(" herdr ", Style(color=accent, bold=True))
        title.append(f"{user}@{machine} ", Style(color=muted))
        hline("╭", "╮", "┬")
        # The tab bar: the active tab is black-on-accent (herdr's one accent
        # token), and an unnamed first tab is called after this machine by the
        # herdr-workspace-prefix feeder rather than showing its number.
        tab_bar = Text()
        tab_bar.append(" ", Style(bgcolor=panel))
        tab_bar.append(f" {machine} ", Style(color="#000000", bgcolor=accent))
        tab_bar.append(" 2 ", Style(color=muted, bgcolor="#3c3836"))
        tab_bar.append(" + ", Style(color=muted, bgcolor=panel))
        row(side(" SPACES", Style(color=muted, bgcolor=panel, bold=True)),
            tab_bar)
        # The selected workspace: name on surface_dim, the marker glyph in front
        # of it in the secondary colour (herdr-workspace-prefix's token).
        selected = Text()
        selected.append("▌", Style(color=dim, bgcolor=panel))
        selected.append("  ", Style(color=secondary, bgcolor=dim, bold=True))
        selected.append(f"{machine}", Style(color="#ffffff", bgcolor=dim, bold=True))
        row(selected, body("  $ ./install.sh"))
        row(side("   dotfiles", Style(color=fg, bgcolor=panel)),
            body("  uv 0.11 already installed"))
        row(side("   research", Style(color=fg, bgcolor=panel)),
            body("  Starting the setup UI ..."))
        row(side("   scratch", Style(color=fg, bgcolor=panel)),
            body("  "))
        # A split, with the agent label drawn on the pane border (herdr's
        # show_agent_labels_on_pane_borders, which our config turns on).
        divider = Text()
        divider.append("─" * 2, Style(color=accent, bgcolor=panel))
        divider.append(" claude ", Style(color=accent, bgcolor=panel, bold=True))
        divider.append("─" * max(0, body_w - 10), Style(color=accent, bgcolor=panel))
        row(side(" AGENTS", Style(color=muted, bgcolor=panel, bold=True)), divider)
        row(side("   claude", Style(color=fg, bgcolor=panel)),
            body("  > implementing the setup UI"))
        row(side("   codex", Style(color=fg, bgcolor=panel)),
            body("  \u25cf running (2m14s)", Style(color=secondary, bgcolor=panel)))
        row(side("", Style(color=fg, bgcolor=panel)), body(""))
        hline("╰", "╯", "┴")
        # The window title sits on the top border, as herdr draws it.
        return fit_block(_overlay_title(out, title, 2), width)

    # -- helpers ------------------------------------------------------------



def readable_on_dark(hex_colour: str, min_lightness: float = 0.45) -> str:
    """The colour, lifted just enough to read as chrome on the app background.

    The palette is all light enough already; this is for a custom hex like
    #003300, which as a pane border would be the grey-on-grey the default
    $panel border already was.
    """
    if not HEX_RE.match(hex_colour):
        return hex_colour
    r, g, b = (int(hex_colour[i:i + 2], 16) / 255 for i in (1, 3, 5))
    h, l, sat = colorsys.rgb_to_hls(r, g, b)
    if l >= min_lightness:
        return hex_colour
    r, g, b = colorsys.hls_to_rgb(h, min_lightness, sat)
    return "#%02x%02x%02x" % (round(r * 255), round(g * 255), round(b * 255))


def fit_block(text: Text, width: int) -> Text:
    """Clip every line to `width` and turn wrapping off outright.

    The backstop for the whole preview column. Rich's default is to *wrap* a
    line that does not fit, which in a preview pane silently doubles its height,
    shoves everything below it down and makes the panel jump as you type -- and a
    wrapped status bar is a lie about what the real bar looks like anyway. Each
    pane below also sizes its own content; this is what guarantees it, so one
    arithmetic slip cannot reflow the layout.
    """
    width = max(width, 4)
    out = Text(no_wrap=True, overflow="ellipsis")
    for i, line in enumerate(text.split("\n")):
        piece = line.copy()
        if piece.cell_len > width:
            piece.truncate(width, overflow="ellipsis")
        piece.no_wrap = True
        piece.overflow = "ellipsis"
        if i:
            out.append("\n")
        out.append_text(piece)
    return out


def _fit(text: Text, width: int, bg: str) -> Text:
    """Pad or clip a cell to exactly `width`, keeping the panel background."""
    out = text.copy()
    if out.cell_len > width:
        out.truncate(width, overflow="ellipsis")
    out.append(" " * max(0, width - out.cell_len), Style(bgcolor=bg))
    return out


def _overlay_title(block: Text, title: Text, column: int) -> Text:
    """Write a title into the first line of a box drawing, over the border."""
    lines = block.split("\n")
    if not lines:
        return block
    head = lines[0]
    if head.cell_len <= column + title.cell_len:
        return block
    out = Text()
    out.append_text(head[:column])
    out.append_text(title)
    out.append_text(head[column + title.cell_len:])
    rest = Text("\n").join(lines[1:])
    out.append("\n")
    out.append_text(rest)
    return out

# ---------------------------------------------------------------------------
# widgets
# ---------------------------------------------------------------------------
# The preview panes, by widget id. refresh_previews() sizes each one from its
# own widget, so this is the list of things that have to exist in compose().
PREVIEW_PANES = ("posh", "hsl-bar", "claude", "herdr", "plan")

SWATCH_W = 4
# Which accent the grid is editing. Deliberately its own tuple rather than a
# slice of ACCENT_CHOICES: these are targets, not colour names.
TARGET_CHOICES = ("primary", "secondary")


def ink_on(hex_colour: str) -> str:
    """Black or white, whichever will read on that background."""
    if not HEX_RE.match(hex_colour):
        return "#ffffff"
    r, g, b = (int(hex_colour[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return "#000000" if (0.2126 * r + 0.7152 * g + 0.0722 * b) > 0.5 else "#ffffff"


class PaletteGrid(Static):
    """All six schemes in one grid: eight swatches a row, the scheme named
    beside it, and BOTH accents marked in place -- P for primary, S for
    secondary, PS where they are the same colour.

    One grid rather than the two it replaces. Two widgets meant two six-line
    grids plus two pointer lines each, which is most of a 46-column panel spent
    showing the same 48 colours twice; marking both accents in one grid is
    smaller *and* says more, since you can see how the two sit relative to each
    other. Arrows and digits move whichever accent is being edited; `p`/`s`, the
    "editing" row above, or just clicking a swatch choose which that is.
    """

    can_focus = True
    BINDINGS = [
        Binding("left", "step(-1)", "prev colour", show=False),
        Binding("right", "step(1)", "next colour", show=False),
        Binding("up", "step_row(-1)", "row up", show=False),
        Binding("down", "step_row(1)", "row down", show=False),
        Binding("p", "target('primary')", "edit primary", show=False),
        Binding("s", "target('secondary')", "edit secondary", show=False),
    ]

    class Picked(Message):
        def __init__(self, field: str, hex_: str) -> None:
            super().__init__()
            self.field = field
            self.hex = hex_

    class TargetChanged(Message):
        def __init__(self, field: str) -> None:
            super().__init__()
            self.field = field

    def __init__(self, palette: list[Swatch], rows: list[str], primary: str,
                 secondary: str, columns: int = 8, **kwargs) -> None:
        super().__init__(**kwargs)
        self.palette = palette
        self.columns = max(1, columns)
        # Fall back to synthesised row labels if derive.sh gave none, so the
        # widget still renders rather than collapsing to zero rows.
        self.row_labels = rows or [
            s.group for i, s in enumerate(palette) if i % self.columns == 0
        ]
        self.values = {"primary": primary.lower(), "secondary": secondary.lower()}
        self.active = "primary"

    @property
    def rows(self) -> int:
        return (len(self.palette) + self.columns - 1) // self.columns

    def set_value(self, field: str, value: str) -> None:
        self.values[field] = value.lower()
        self.refresh_row()

    def set_active(self, field: str) -> None:
        if field in self.values:
            self.active = field
            self.refresh_row()

    def on_mount(self) -> None:
        # One line per scheme now: the marker lives inside the swatch, so there
        # is no pointer line to pay for.
        self.styles.height = self.rows
        self.refresh_row()

    def on_resize(self, event: events.Resize) -> None:
        # Cell width and whether the scheme names fit are both decided from the
        # panel's actual width, so a small terminal narrows the swatches instead
        # of wrapping each row onto two lines.
        self.refresh_row()

    def _metrics(self) -> tuple[int, int, bool]:
        """(cell width, cells left for the label, show labels at all).

        The scheme names take priority over swatch width: eight 4-cell swatches
        plus " catppuccin" wants 43 cells and the controls panel has 41, which
        silently cut the two longest names to "catppucc" and "tokyonig". So the
        swatches give up a cell instead -- 3 wide still reads perfectly well --
        and names are shown in FULL or not at all. A half-name is worse than no
        name, since the heading names the scheme you are on anyway.
        """
        avail = self.content_size.width or 41
        longest = max((len(name) for name in self.row_labels), default=0)
        want = longest + 1                      # the separating space
        cell = SWATCH_W
        if self.columns * cell + want > avail:
            cell = max(1, (avail - want) // self.columns)
        if cell < 2:                            # not worth this much for a name
            cell = max(1, avail // self.columns)
        room = max(0, avail - self.columns * cell)
        return cell, room, room >= want

    def _index_of(self, field: str) -> int:
        want = self.values.get(field, "")
        for i, swatch in enumerate(self.palette):
            if swatch.hex == want:
                return i
        return -1

    def label_for(self, field: str) -> str:
        """"monokai / pink", or "custom" for a hand-typed hex."""
        idx = self._index_of(field)
        if idx < 0:
            return "custom"
        swatch = self.palette[idx]
        return f"{swatch.group} / {swatch.name}" if swatch.group else swatch.name

    def refresh_row(self) -> None:
        p_idx = self._index_of("primary")
        s_idx = self._index_of("secondary")
        cell_w, label_room, show_labels = self._metrics()
        out = Text(no_wrap=True, overflow="ellipsis")
        for row in range(self.rows):
            for col in range(self.columns):
                i = row * self.columns + col
                if i >= len(self.palette):
                    break
                hex_ = self.palette[i].hex
                mark = ""
                if i == p_idx and i == s_idx:
                    mark = "PS"
                elif i == p_idx:
                    mark = "P"
                elif i == s_idx:
                    mark = "S"
                # A 2-cell marker cannot fit a 1-cell swatch; keep the accent
                # being edited visible in preference to the other one.
                if len(mark) > cell_w:
                    mark = mark[0] if self.active == "primary" else mark[-1]
                    mark = mark[:cell_w]
                text = f"{mark:^{cell_w}}" if mark else " " * cell_w
                out.append(text, Style(bgcolor=hex_, color=ink_on(hex_), bold=True))
            # The row holding the accent being edited is named in full brightness;
            # the rest stay dim, so the eye lands on where you are. Dropped
            # entirely when the swatches have eaten the width -- the heading
            # names the current scheme anyway.
            if show_labels:
                label = self.row_labels[row] if row < len(self.row_labels) else ""
                here = self.active == "primary" and p_idx // self.columns == row \
                    or self.active == "secondary" and s_idx // self.columns == row
                out.append(f" {label}", Style(dim=not here, bold=here))
            if row < self.rows - 1:
                out.append("\n")
        self.update(out)

    def action_step(self, delta: int) -> None:
        idx = self._index_of(self.active)
        if idx < 0:
            idx = 0 if delta > 0 else len(self.palette) - 1
        else:
            idx = (idx + delta) % len(self.palette)
        self._pick(idx)

    def action_step_row(self, delta: int) -> None:
        idx = self._index_of(self.active)
        idx = 0 if idx < 0 else (idx + delta * self.columns) % len(self.palette)
        self._pick(idx)

    def action_target(self, field: str) -> None:
        self.set_active(field)
        self.post_message(self.TargetChanged(field))

    def _pick(self, idx: int) -> None:
        if 0 <= idx < len(self.palette):
            self.set_value(self.active, self.palette[idx].hex)
            self.post_message(self.Picked(self.active, self.palette[idx].hex))

    def on_click(self, event: events.Click) -> None:
        self.focus()
        # The live cell width, NOT the SWATCH_W constant. _metrics() narrows the
        # swatches to keep the scheme names whole -- 3 cells at the default panel
        # width, 2 on a very small terminal -- so dividing by 4 landed one or two
        # swatches to the left of wherever you clicked, and further left the
        # nearer the right-hand end of the row you got.
        cell_w, _room, _labels = self._metrics()
        x, y = int(event.x), int(event.y)
        if x >= self.columns * cell_w:
            return                      # the scheme label, not a swatch
        self._pick(y * self.columns + x // cell_w)

    def on_key(self, event: events.Key) -> None:
        # Digits pick within the row the active accent is already on, so 1-8
        # stays meaningful across all six schemes.
        if event.character and event.character.isdigit():
            n = int(event.character)
            if 1 <= n <= self.columns:
                event.stop()
                row = max(self._index_of(self.active), 0) // self.columns
                self._pick(row * self.columns + n - 1)


class ChoiceRow(Static):
    """One line: a label and the current choice, cycled with left/right, enter
    or a click. Used for the per-component oh-my-posh colours, where a RadioSet
    each would cost five lines apiece in a panel that has none to spare.

    The choice is shown painted in the colour it names, so the row doubles as
    its own legend."""

    can_focus = True
    BINDINGS = [
        Binding("left", "cycle(-1)", "previous", show=False),
        Binding("right", "cycle(1)", "next", show=False),
        Binding("enter", "cycle(1)", "next", show=False),
        Binding("space", "cycle(1)", "next", show=False),
    ]

    class Picked(Message):
        def __init__(self, field: str, value: str) -> None:
            super().__init__()
            self.field = field
            self.value = value

    def __init__(self, field: str, label: str, choices: tuple[str, ...], value: str,
                 colours: dict[str, str] | None = None, **kwargs) -> None:
        super().__init__(**kwargs)
        self.field = field
        self.label = label
        self.choices = choices
        self.value = value if value in choices else choices[0]
        self.colours = colours or {}

    def set_colours(self, colours: dict[str, str]) -> None:
        self.colours = colours
        self.refresh_row()

    def set_value(self, value: str) -> None:
        if value in self.choices:
            self.value = value
            self.refresh_row()

    def on_mount(self) -> None:
        self.refresh_row()

    def refresh_row(self) -> None:
        out = Text()
        out.append(f"{self.label:<16}", Style(dim=self.disabled))
        swatch = self.colours.get(self.value)
        if swatch:
            out.append("  ", Style(bgcolor=swatch))
            out.append(" ")
        out.append(self.value, Style(bold=not self.disabled, dim=self.disabled))
        self.update(out)

    def action_cycle(self, delta: int) -> None:
        if self.disabled:
            return
        idx = (self.choices.index(self.value) + delta) % len(self.choices)
        self.value = self.choices[idx]
        self.refresh_row()
        self.post_message(self.Picked(self.field, self.value))

    def on_click(self) -> None:
        self.focus()
        self.action_cycle(1)


# ---------------------------------------------------------------------------
# the app
# ---------------------------------------------------------------------------
class SetupApp(App):
    TITLE = "dotfiles setup"
    SUB_TITLE = "colours, machine name and status-line components"
    CSS = """
    #body { height: 1fr; }
    /* White, not Textual's default $panel: that is a grey on a grey background
       and the pane borders were all but invisible. The section headings take
       the chosen primary instead (_sync_chrome repaints them on every colour
       change), so the chrome frames the previews without competing with them. */
    #controls { width: 46; padding: 0 1; border-right: solid white; }
    /* overflow-y: scroll, not auto: with auto the scrollbar appears *because*
       of what was just rendered, taking two cells off every pane after they
       were drawn to the wider figure -- which is what made the herdr box, drawn
       to fill its width exactly, wrap all eleven of its lines. Reserving it
       always keeps content_size stable from the first layout. */
    #previews { width: 1fr; padding: 0 1; overflow-x: hidden; overflow-y: scroll; }
    /* Below NARROW_AT the two columns cannot both be useful -- 46 for the
       controls leaves the previews a sliver -- so they stack instead. Set from
       on_resize(); app CSS outranks Horizontal's own layout: horizontal. */
    #body.narrow { layout: vertical; }
    #body.narrow > #controls {
      width: 1fr; height: auto; max-height: 70%;
      border-right: none; border-bottom: solid white;
    }
    #body.narrow > #previews { width: 1fr; height: 1fr; }
    /* Nothing in either column may wrap: a wrapped preview is a lie about what
       the real bar looks like, and a wrapped heading or palette row silently
       changes the widget's height and makes the whole panel jump. Content is
       clipped to the width instead (see fit_block, and PaletteGrid._metrics).
       The .hint rule is the deliberate exception below. */
    #previews Static { text-wrap: nowrap; }
    .section, ChoiceRow, PaletteGrid, Checkbox { text-wrap: nowrap; }
    .section { color: $accent; text-style: bold; padding: 1 0 0 0; }
    .field { height: 1; }
    .field Label { width: 10; content-align: left middle; }
    .field Input { width: 1fr; height: 1; border: none; background: $boost; padding: 0 1; }
    .field Input:focus { background: $panel; }
    .field Input.-invalid { color: $error; }
    /* One line per scheme (six), the selection marker living inside the
       swatch. PaletteGrid.on_mount() sets the real height from the palette
       length, which wins over this; the value here just keeps the CSS from
       claiming something visibly different before it does. */
    PaletteGrid { height: 6; padding: 0; }
    PaletteGrid:focus { background: $boost; }
    ChoiceRow { height: 1; padding: 0; }
    ChoiceRow:focus { background: $boost; }
    Checkbox { height: 1; border: none; padding: 0; background: transparent; }
    Checkbox:focus { text-style: bold; }
    .preview { border: round white; padding: 0 1; height: auto; margin-bottom: 1; }
    .preview.wide { padding: 0; }
    #buttons { height: 3; align: center middle; padding: 0 1; }
    #buttons Button { margin: 0 1; }
    #status { height: 1; padding: 0 1; color: $error; }
    /* The one place wrapping is wanted: these are prose, and they carry their
       own newlines where a break is meant. Kept short enough to fit a 44-cell
       panel so they do not wrap in practice either. */
    .hint { height: auto; color: $text-muted; }
    """
    # Below this many columns the side-by-side split stops being worth it.
    # 46 for the controls plus roughly 40 before a preview says anything useful.
    NARROW_AT = 88

    BINDINGS = [
        Binding("ctrl+s", "install", "Install"),
        Binding("escape", "cancel", "Quit"),
        Binding("ctrl+q", "cancel", "Quit", show=False),
    ]

    def __init__(self, answers: Answers, palette: list[Swatch], out: Path | None,
                 columns: int = 8, catalogue: list[Tool] | None = None,
                 priv: str = "", palette_rows: list[str] | None = None):
        super().__init__()
        self.answers = answers
        self.palette = palette
        self.palette_rows = palette_rows or []
        self.columns = columns
        self.catalogue = catalogue or []
        self.priv = priv
        self.out = out
        self.confirmed = False
        self.previewer = Previewer()
        self._debounce = None
        self._syncing = False
        # False until on_mount() finishes (NOT named _ready: App already has a
        # _ready() method of its own). Textual posts Input.Changed for an
        # Input's initial value as it mounts, and _hex_typed() treats a change as
        # "the user is working on this accent" and points the grid at it -- so
        # without this the secondary box, simply by mounting last, would leave
        # the grid editing secondary before the user had touched anything.
        self._inputs_live = False

    # -- layout -------------------------------------------------------------
    def compose(self) -> ComposeResult:
        yield Header()
        with Horizontal(id="body"):
            with VerticalScroll(id="controls"):
                yield Static("Colours", classes="section", id="colour-title")
                # Which accent the grid edits. A ChoiceRow rather than anything
                # new: it already cycles on arrows/enter/click and paints its
                # value in the colour it names.
                yield ChoiceRow("palette_target", "editing", TARGET_CHOICES,
                                "primary", id="palette_target")
                with Horizontal(classes="field"):
                    yield Label("primary")
                    yield Input(value=self.answers.primary, id="primary-hex", max_length=7)
                with Horizontal(classes="field"):
                    yield Label("secondary")
                    yield Input(value=self.answers.secondary, id="secondary-hex", max_length=7)
                yield PaletteGrid(self.palette, self.palette_rows, self.answers.primary,
                                  self.answers.secondary, columns=self.columns,
                                  id="palette")
                yield Static(Text("p / s picks which accent the grid moves",
                                  style="italic"), classes="hint")

                yield Static("Machine name", classes="section")
                with Horizontal(classes="field"):
                    yield Label("name")
                    yield Input(value=self.answers.machine, id="machine", max_length=24)

                yield Static("Status line (herdr + tmux)", classes="section")
                yield Checkbox("hostname pill", self.answers.show_host, id="show_host")
                yield Checkbox("GPU usage pill", self.answers.show_gpu, id="show_gpu")
                yield Checkbox("└ GPU temperature", self.answers.show_temp, id="show_temp")
                yield Checkbox("Slurm job pill", self.answers.show_slurm, id="show_slurm")
                yield Checkbox("date / time pill", self.answers.show_datetime, id="show_datetime")

                yield Static("Shell login", classes="section")
                yield Checkbox("start herdr at login", self.answers.hsl_login,
                               id="hsl_login")
                yield Static(Text("herdr, plus the status line where hsl is\n"
                                  "installed. NO_HSL=1 skips it.", style="italic"),
                             classes="hint")

                yield Static("oh-my-posh prompt", classes="section")
                # The panel, not an accent -- hence a hex box here rather than a
                # fourth ACCENT_CHOICES row, and here rather than up in Colours,
                # where it would read as a third accent and pick up the palette
                # grid's P/S markers.
                with Horizontal(classes="field"):
                    yield Label("panel")
                    yield Input(value=self.answers.omp_pill_bg, id="pill-hex", max_length=7)
                yield ChoiceRow("omp_icon_mode", "glyph mode", ICON_MODES,
                                self.answers.omp_icon_mode, id="omp_icon_mode")
                yield ChoiceRow("omp_icon", "  glyph colour", ACCENT_CHOICES,
                                self.answers.omp_icon, id="omp_icon")
                yield ChoiceRow("omp_text", "machine text", ACCENT_CHOICES,
                                self.answers.omp_text, id="omp_text")
                yield ChoiceRow("omp_chevron_ok", "chevrons ok", ACCENT_CHOICES,
                                self.answers.omp_chevron_ok, id="omp_chevron_ok")
                yield ChoiceRow("omp_chevron_error", "chevrons error", ACCENT_CHOICES,
                                self.answers.omp_chevron_error, id="omp_chevron_error")
                yield Static("", id="glyph-hint", classes="hint")

                if self.catalogue:
                    yield Static("Tools to install", classes="section")
                    if self.priv:
                        yield Static(Text(self.priv, style="italic"), classes="hint")
                    # Grouped, with the group name as a faint separator: the
                    # list is nineteen long and reads as a wall otherwise. The
                    # order is lib/tools.sh's, which is the install order.
                    seen: set[str] = set()
                    for tool in self.catalogue:
                        if tool.group not in seen:
                            seen.add(tool.group)
                            yield Static(
                                Text(GROUP_LABELS.get(tool.group, tool.group), style="dim"),
                                classes="hint",
                            )
                        yield Checkbox(tool.label, self.answers.wants(tool.id),
                                       id=f"tool-{tool.id}")

            with VerticalScroll(id="previews"):
                with Container(classes="preview") as posh_box:
                    posh_box.border_title = "oh-my-posh"
                    yield Static(id="posh")
                with Container(classes="preview wide") as bar_box:
                    bar_box.border_title = "hsl status line"
                    yield Static(id="hsl-bar")
                with Container(classes="preview wide") as claude_box:
                    claude_box.border_title = "claude code status line"
                    yield Static(id="claude")
                with Container(classes="preview") as herdr_box:
                    herdr_box.border_title = "herdr"
                    yield Static(id="herdr")
                if self.catalogue:
                    with Container(classes="preview wide") as plan_box:
                        plan_box.border_title = "install plan"
                        yield Static(id="plan")
        yield Static("", id="status")
        with Horizontal(id="buttons"):
            yield Button("Install  (ctrl+s)", variant="success", id="install")
            yield Button("Quit  (esc)", variant="error", id="quit")
        yield Footer()

    def on_mount(self) -> None:
        self._sync_temp_enabled()
        self._sync_titles()
        self._sync_choices()
        self._sync_chrome()
        self._apply_layout(self.size.width)
        self.refresh_previews()
        # Everything mounted, so Input.Changed from here on is the user typing.
        self._inputs_live = True
        # Keeps the clock in the bar ticking and the GPU reading fresh while the
        # UI sits open, without which the pane looks frozen.
        self.set_interval(10.0, self.refresh_previews)

    # -- input --------------------------------------------------------------
    @on(Input.Changed, "#primary-hex")
    def _primary_typed(self, event: Input.Changed) -> None:
        self._hex_typed(event, "primary")

    @on(Input.Changed, "#secondary-hex")
    def _secondary_typed(self, event: Input.Changed) -> None:
        self._hex_typed(event, "secondary")

    @on(Input.Changed, "#pill-hex")
    def _pill_typed(self, event: Input.Changed) -> None:
        """The panel. Deliberately not routed through _hex_typed(): that one also
        moves the palette grid onto the accent being typed, and this is not one of
        the two accents the grid can point at."""
        if self._syncing:
            return
        value = event.value.strip()
        if BARE_HEX_RE.match(value):
            value = f"#{value}"
        if HEX_RE.match(value):
            event.input.remove_class("-invalid")
            self.answers = replace(self.answers, omp_pill_bg=value.lower())
            self._clear_error()
            self.schedule_preview()
        else:
            event.input.add_class("-invalid")

    def _hex_typed(self, event: Input.Changed, field: str) -> None:
        if self._syncing:
            return
        value = event.value.strip()
        if BARE_HEX_RE.match(value):  # a "#" is easy to leave off
            value = f"#{value}"
        if HEX_RE.match(value):
            event.input.remove_class("-invalid")
            self.answers = replace(self.answers, **{field: value.lower()})
            grid = self.query_one("#palette", PaletteGrid)
            grid.set_value(field, value)
            # Typing into a hex box is itself a statement about which accent you
            # are working on, so the grid follows the cursor rather than leaving
            # the arrows pointed at the other one. Only for real typing though:
            # see _inputs_live, and mount-time Changed events have no focus either.
            if self._inputs_live and event.input.has_focus:
                grid.set_active(field)
                self.query_one("#palette_target", ChoiceRow).set_value(field)
            self._sync_titles()
            self._sync_choices()
            self._sync_chrome()
            self._clear_error()
            self.schedule_preview()
        else:
            event.input.add_class("-invalid")

    @on(PaletteGrid.TargetChanged)
    def _target_changed(self, event: PaletteGrid.TargetChanged) -> None:
        self.query_one("#palette_target", ChoiceRow).set_value(event.field)
        self._sync_titles()

    @on(PaletteGrid.Picked)
    def _swatch_picked(self, event: PaletteGrid.Picked) -> None:
        self.answers = replace(self.answers, **{event.field: event.hex})
        self._syncing = True
        try:
            box = self.query_one(f"#{event.field}-hex", Input)
            box.value = event.hex
            box.remove_class("-invalid")
        finally:
            self._syncing = False
        self._sync_titles()
        self._sync_choices()
        self._sync_chrome()
        self._clear_error()
        self.schedule_preview()

    @on(Input.Changed, "#machine")
    def _machine_typed(self, event: Input.Changed) -> None:
        value = event.value.strip()
        if MACHINE_RE.match(value):
            event.input.remove_class("-invalid")
            self.answers = replace(self.answers, machine=value)
            self._clear_error()
            self.schedule_preview()
        else:
            event.input.add_class("-invalid")

    @on(ChoiceRow.Picked)
    def _choice_picked(self, event: ChoiceRow.Picked) -> None:
        # The "editing" row is not an answer -- it only steers the grid, so it
        # must not be replace()d onto Answers (there is no such field).
        if event.field == "palette_target":
            self.query_one("#palette", PaletteGrid).set_active(event.value)
            self._sync_titles()
            return
        self.answers = replace(self.answers, **{event.field: event.value})
        if event.field == "omp_icon_mode":
            self._sync_choices()
        self.schedule_preview()

    @on(Checkbox.Changed)
    def _toggled(self, event: Checkbox.Changed) -> None:
        field = event.checkbox.id
        if not field:
            return
        # The tool checkboxes are the catalogue's, not fields on Answers, so
        # they carry a "tool-" prefix and go through with_tool() instead.
        if field.startswith("tool-"):
            self.answers = self.answers.with_tool(field[5:], bool(event.value))
            self.schedule_preview()
            return
        self.answers = replace(self.answers, **{field: bool(event.value)})
        if field == "show_gpu":
            self._sync_temp_enabled()
        self.schedule_preview()

    def _sync_temp_enabled(self) -> None:
        # SHOW_TEMP only means anything while the GPU pill is shown.
        self.query_one("#show_temp", Checkbox).disabled = not self.answers.show_gpu

    def _sync_choices(self) -> None:
        """Paint each choice in the colour it names, and grey out the glyph
        colour while the glyph is in slurm mode -- there the two accents are
        both spoken for (primary outside a job, secondary inside one)."""
        colours = {
            "primary": self.answers.primary,
            "secondary": self.answers.secondary,
            "neutral": NEUTRAL_FG,
        }
        for row in self.query(ChoiceRow):
            # The "editing" row names the two accents too, so it takes the same
            # swatches; only the glyph-mode row (fixed/slurm) has none.
            named = row.choices is ACCENT_CHOICES or row.choices is TARGET_CHOICES
            row.set_colours(colours if named else {})
        slurm = self.answers.omp_icon_mode == "slurm"
        glyph = self.query_one("#omp_icon", ChoiceRow)
        glyph.disabled = slurm
        glyph.refresh_row()
        self.query_one("#glyph-hint", Static).update(
            Text("glyph reports the job: primary normally,\nsecondary inside a Slurm allocation"
                 if slurm else "", style="italic")
        )

    def _sync_chrome(self) -> None:
        """Only the section headings follow the chosen primary; the borders stay
        white (set in CSS) so a preview pane is framed by something that is
        neither one of the two accents nor the background's own grey."""
        colour = readable_on_dark(self.answers.primary)
        for heading in self.query(".section"):
            heading.styles.color = colour

    def _sync_titles(self) -> None:
        """The heading names the scheme of the accent being edited.

        Only that one: both at once ("catppuccin / rosewater" twice) is 43 cells
        before the word "Colours", so it was getting clipped in a 41-cell panel.
        The other accent is still readable from its S marker in the grid and its
        own hex box.
        """
        grid = self.query_one("#palette", PaletteGrid)
        title = Text("Colours  ", style="bold")
        title.append(grid.label_for(grid.active), Style(bold=False))
        self.query_one("#colour-title", Static).update(title)

    @on(Button.Pressed, "#install")
    def _install_pressed(self) -> None:
        self.action_install()

    @on(Button.Pressed, "#quit")
    def _quit_pressed(self) -> None:
        self.action_cancel()

    def on_resize(self, event: events.Resize) -> None:
        self._apply_layout(event.size.width)
        self.schedule_preview()

    def _apply_layout(self, width: int) -> None:
        """Stack the two columns on a terminal too narrow to hold both."""
        try:
            self.query_one("#body").set_class(width < self.NARROW_AT, "narrow")
        except Exception:
            pass

    # -- previews -----------------------------------------------------------
    def schedule_preview(self, delay: float = 0.12) -> None:
        """Coalesce keystrokes: one render per pause, not one per character."""
        if self._debounce is not None:
            self._debounce.stop()
        self._debounce = self.set_timer(delay, self.refresh_previews)

    def refresh_previews(self) -> None:
        """Ask each pane's own widget how wide it is, and render to that.

        Emphatically not one estimate shared by all of them. It used to be
        `#previews`.content_size minus a hardcoded 4 (a round border plus the
        containers' horizontal padding) -- but `.preview.wide` has no padding,
        and the VerticalScroll's scrollbar takes two cells more, so the single
        figure was right for the three wide panes and two cells too generous for
        the other two. The herdr box is drawn to fill its width *exactly*, so
        those two cells wrapped every one of its eleven lines in half.

        Textual has already worked all of that out per widget; content_size is
        the answer, and it costs nothing to ask.
        """
        widths: dict[str, int] = {}
        for pane in PREVIEW_PANES:
            try:
                got = self.query_one(f"#{pane}").content_size.width
            except Exception:
                continue
            if got > 0:
                widths[pane] = got
        self._render(self.answers, widths)

    @work(thread=True, exclusive=True, group="preview")
    def _render(self, answers: Answers, widths: dict[str, int]) -> None:
        def w(pane: str) -> int:
            # The fallback is only ever used for the frame before the first
            # layout, when the widgets genuinely have no size yet; a Resize
            # follows immediately and re-renders with the real figures.
            return max(widths.get(pane, 60), 4)

        try:
            derived = derive(answers)
            panes = {
                "posh": self.previewer.posh(derived, answers, w("posh")),
                "hsl-bar": self.previewer.statusline(derived, answers, w("hsl-bar")),
                "claude": self.previewer.claude(derived, answers, w("claude")),
                "herdr": self.previewer.herdr(derived, w("herdr")),
            }
            if self.catalogue:
                panes["plan"] = self.previewer.plan(derived, answers, w("plan"))
            # Nothing reaches a pane un-clipped: see fit_block().
            panes = {k: fit_block(v, w(k)) for k, v in panes.items()}
        except Exception as exc:  # a broken preview must not take the UI down
            panes = {"posh": Text(f"preview failed: {exc}", style="red")}
        used = {pane: w(pane) for pane in panes}
        self.call_from_thread(self._apply, panes, used)

    def _apply(self, panes: dict[str, Text], used: dict[str, int] | None = None) -> None:
        for widget_id, text in panes.items():
            try:
                self.query_one(f"#{widget_id}", Static).update(text)
            except Exception:
                pass
        # A pane's width can still move between the worker reading it and the
        # result landing -- a resize arriving mid-render. If any did, draw once
        # more against the settled figures; it converges on the next pass, since
        # that one renders to exactly the widths this one just observed.
        for pane, was in (used or {}).items():
            try:
                now = self.query_one(f"#{pane}").content_size.width
            except Exception:
                continue
            if now > 0 and now != was:
                self.schedule_preview(0.05)
                break

    # -- finishing ----------------------------------------------------------
    def _clear_error(self) -> None:
        self.query_one("#status", Static).update("")

    def _error(self, message: str) -> None:
        self.query_one("#status", Static).update(message)

    def action_install(self) -> None:
        for selector, ok, message in (
            ("#primary-hex", HEX_RE.match(self.answers.primary), "Primary colour is not a #rrggbb value."),
            ("#secondary-hex", HEX_RE.match(self.answers.secondary), "Secondary colour is not a #rrggbb value."),
            ("#pill-hex", HEX_RE.match(self.answers.omp_pill_bg), "Prompt panel is not a #rrggbb value."),
            ("#machine", MACHINE_RE.match(self.answers.machine), "Machine name: 1-24 of [A-Za-z0-9._-]."),
        ):
            if not ok:
                self._error(message)
                self.query_one(selector, Input).focus()
                return
        if self.out is not None:
            self.out.write_text(self.answers.as_shell(), encoding="utf-8")
        self.confirmed = True
        self.exit()

    def action_cancel(self) -> None:
        self.confirmed = False
        self.exit()


# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------
def dump(answers: Answers, width: int) -> None:
    """Print the previews to stdout, no UI. For checking a change to this file
    (and for machines where a full-screen app is not wanted)."""
    from rich.console import Console

    console = Console(width=width, force_terminal=True)
    previewer = Previewer()
    try:
        derived = derive(answers)
        for title, pane in (
            ("oh-my-posh", previewer.posh(derived, answers, width)),
            ("hsl status line", previewer.statusline(derived, answers, width)),
            ("claude code status line", previewer.claude(derived, answers, width)),
            ("herdr", previewer.herdr(derived, width)),
            (f"install plan  ({privilege_summary()})",
             previewer.plan(derived, answers, width)),
        ):
            # no_wrap on the heading too: "install plan (no sudo -- ...)" is
            # longer than a narrow --width and wrapped onto a second line.
            console.print(Text(title, style="bold"), no_wrap=True, overflow="ellipsis")
            console.print(fit_block(pane, width), no_wrap=True)
            console.print()
    finally:
        previewer.cleanup()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="dotfiles setup UI")
    parser.add_argument("--out", type=Path, help="write the chosen answers here (shell fragment)")
    parser.add_argument("--dump", action="store_true", help="print the previews and exit")
    parser.add_argument("--width", type=int, default=100, help="width for --dump")
    args = parser.parse_args(argv)

    # The catalogue has to be loaded before the answers: Answers.from_env reads
    # one TOOL_<ID> per catalogue entry, so without it every tool would look
    # deselected and as_shell() would write nothing about them at all.
    catalogue = load_catalogue()
    answers = Answers.from_env(dict(os.environ), catalogue)
    try:
        derived = derive(answers)
        palette = palette_from(derived)
        palette_rows = palette_rows_from(derived)
        columns = palette_columns(derived)
    except Exception as exc:
        print(f"cannot run {DERIVE}: {exc}", file=sys.stderr)
        return 1

    if args.dump:
        dump(answers, args.width)
        return 0

    app = SetupApp(answers, palette, args.out, columns=columns,
                   catalogue=catalogue, priv=privilege_summary(),
                   palette_rows=palette_rows)
    try:
        app.run()
    finally:
        app.previewer.cleanup()
    return 0 if app.confirmed else 10


if __name__ == "__main__":
    sys.exit(main())
