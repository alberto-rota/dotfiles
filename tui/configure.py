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
    install.sh calls to render the real herdr-statusline config -- interpreted
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
    "gpu-status.sh": "herdr/plugins/herdr-statusline/gpu-status.sh.in",
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


# What each catalogue group is called in the UI. An unknown group falls back to
# its own name, so adding one to lib/tools.sh needs no edit here.
GROUP_LABELS = {
    "providers": "toolchains",
    "shell": "shell",
    "gpu": "gpu",
    "editor": "editor",
    "python": "python (uv tools)",
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
            omp_icon_mode=choice("OMP_ICON_MODE", d.omp_icon_mode, ICON_MODES),
            omp_icon=choice("OMP_ICON", legacy_icon),
            omp_text=choice("OMP_TEXT", legacy_text),
            omp_chevron_ok=choice("OMP_CHEVRON_OK", "primary" if chevron_on else "neutral"),
            omp_chevron_error=choice("OMP_CHEVRON_ERROR", "secondary" if chevron_on else "neutral"),
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
            "OMP_ICON_MODE": self.omp_icon_mode,
            "OMP_ICON": self.omp_icon,
            "OMP_TEXT": self.omp_text,
            "OMP_CHEVRON_OK": self.omp_chevron_ok,
            "OMP_CHEVRON_ERROR": self.omp_chevron_error,
            # Last, so the fragment install.sh sources reads in the same order
            # theme.env is written in: the look first, then the tool answers.
            **tools,
        }

    def as_shell(self) -> str:
        env = self.as_env()
        quoted = {"PRIMARY", "SECONDARY", "MACHINE"}  # validated, so "..." is safe
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


def palette_from(derived: dict[str, str]) -> list[tuple[str, str]]:
    """The swatches, as lib/derive.sh defines them (name:hex name:hex ...)."""
    entries = []
    for field in derived.get("PALETTE", "").split():
        name, _, hex_ = field.partition(":")
        if HEX_RE.match(hex_):
            entries.append((name, hex_.lower()))
    return entries


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
    out = Text()
    out.append_text(left)
    out.append(" " * max(0, width - left.cell_len - right.cell_len), Style(bgcolor=bg))
    out.append_text(right)
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
        """herdr-statusline, the only bar previewed: tmux's is assembled from the
        same toggles and stays in sync by construction (see lib/derive.sh), so
        showing both said the same thing twice."""
        env = answers.as_env()
        resolve = self._resolver(env["SHOW_TEMP"], derived["PRIMARY"], derived["SECONDARY"])
        return compose_bar(
            render_bar_format(derived["HSL_STATUS_LEFT"], resolve),
            render_bar_format(derived["HSL_STATUS_RIGHT"], resolve),
            width, derived["PRIMARY"],
        )

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
        text = Text.from_ansi(out.rstrip("\n"))
        if text.cell_len > width:
            text.truncate(width, overflow="ellipsis")
        return text

    def posh(self, derived: dict[str, str], answers: Answers, width: int) -> Text:
        """The real prompt: oh-my-posh rendering a real copy of the template."""
        mapping = placeholders(derived, answers)
        if not shutil.which("oh-my-posh"):
            return self._posh_fallback(derived)
        config = self._tmpdir / "omp.json"
        config.write_text(
            render_template("oh-my-posh/albe-monokai2.omp.json.in", mapping), encoding="utf-8"
        )
        try:
            proc = subprocess.run(
                ["oh-my-posh", "print", "primary", "--config", str(config),
                 "--shell", "universal", "--terminal-width", str(max(width, 40))],
                capture_output=True, text=True, timeout=10,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            return Text(f"oh-my-posh failed: {exc}", style="red")
        if proc.returncode != 0:
            return self._posh_fallback(derived)
        # OSC (the console title) would otherwise leak into the pane as text.
        clean = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)", "", proc.stdout)
        return Text.from_ansi(clean.rstrip("\n"))

    def _posh_fallback(self, derived: dict[str, str]) -> Text:
        """oh-my-posh is not on PATH yet (a machine being set up for the first
        time): draw the machine segment and the chevron line by hand."""
        panel = "#212224"
        out = Text()
        out.append(" ", Style(color=derived["OMP_ICON_COLOR"], bgcolor=panel))
        out.append(f" {derived['MACHINE_LOWER']} ", Style(color=derived["OMP_TEXT_COLOR"], bgcolor=panel))
        out.append(" ~/dotfiles ", Style(color="#5fafd7", bgcolor=panel))
        out.append("\n")
        out.append("╰─", Style(color=panel))
        out.append(" ", Style(color=derived["OMP_CHEVRON_FG"]))
        out.append("  (oh-my-posh not installed yet -- drawn by hand)", Style(dim=True))
        return out

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
        text = Text()
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
            text.append(f"{tool_id:<19}", Style(dim=(status == "skip")))
            body = detail if method == "-" else f"{method}  {detail}"
            line_text = Text(body, Style(dim=True) if status != "install" else style)
            if line_text.cell_len > max(width - 22, 12):
                line_text.truncate(max(width - 22, 12), overflow="ellipsis")
            text.append_text(line_text)
        if not rows:
            return Text("no plan (is lib/tools.sh readable?)", style="red")
        return text

    def herdr(self, derived: dict[str, str], width: int) -> Text:
        """A drawing, unlike the other panes -- herdr cannot render one frame
        into a string. Every colour in it is a real derived value though:
        `accent` (the primary) paints the window and pane borders and the agent
        labels on them, and `surface_dim` (the darkened primary) paints both the
        sidebar rail and the selected workspace row -- the one token herdr routes
        both of those through, which is why it has to be darkened.
        """
        accent = derived["PRIMARY"]
        dim = derived["PRIMARY_DIM"]
        secondary = derived["SECONDARY"]
        machine = derived["MACHINE_LOWER"]
        user = derived["USER_NAME"]
        panel = "#282828"   # gruvbox, herdr's base theme here
        fg = "#ebdbb2"
        muted = "#928374"

        inner = max(width - 2, 44)
        side_w = min(24, max(16, inner // 4))
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
        row(side(" SPACES", Style(color=muted, bgcolor=panel, bold=True)),
            body("  ~/dotfiles", Style(color=fg, bgcolor=panel, bold=True)))
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
        return _overlay_title(out, title, 2)

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
SWATCH_W = 4
SWATCH_GAP = 1


class PaletteRow(Static):
    """The palette as a grid of swatches: arrows, digits or a click pick one,
    and picking applies it immediately -- there is nothing to confirm, the
    previews are the confirmation. Sixteen colours do not fit on one line of a
    46-column panel, hence the wrap into rows of PALETTE_COLUMNS."""

    can_focus = True
    BINDINGS = [
        Binding("left", "step(-1)", "prev colour", show=False),
        Binding("right", "step(1)", "next colour", show=False),
        Binding("up", "step_row(-1)", "row up", show=False),
        Binding("down", "step_row(1)", "row down", show=False),
    ]

    class Picked(Message):
        def __init__(self, field: str, hex_: str) -> None:
            super().__init__()
            self.field = field
            self.hex = hex_

    def __init__(self, field: str, palette: list[tuple[str, str]], value: str,
                 columns: int = 8, **kwargs) -> None:
        super().__init__(**kwargs)
        self.field = field
        self.palette = palette
        self.columns = max(1, columns)
        self.value = value.lower()

    @property
    def rows(self) -> int:
        return (len(self.palette) + self.columns - 1) // self.columns

    def set_value(self, value: str) -> None:
        self.value = value.lower()
        self.refresh_row()

    def on_mount(self) -> None:
        # Two lines per swatch row: the swatches, then the selection pointer.
        self.styles.height = self.rows * 2
        self.refresh_row()

    def _index(self) -> int:
        for i, (_, hex_) in enumerate(self.palette):
            if hex_ == self.value:
                return i
        return -1

    @property
    def name_of_value(self) -> str:
        idx = self._index()
        return self.palette[idx][0] if idx >= 0 else "custom"

    def refresh_row(self) -> None:
        idx = self._index()
        out = Text()
        for row in range(self.rows):
            entries = self.palette[row * self.columns:(row + 1) * self.columns]
            for _, hex_ in entries:
                out.append(" " * SWATCH_W, Style(bgcolor=hex_))
                out.append(" " * SWATCH_GAP)
            out.append("\n")
            # An underline pointer rather than more of the swatch colour, so it
            # reads as "this one" against any entry, dark or light.
            if idx >= 0 and idx // self.columns == row:
                out.append(" " * ((idx % self.columns) * (SWATCH_W + SWATCH_GAP)))
                out.append("▔" * SWATCH_W, Style(color="#d6deeb"))
            if row < self.rows - 1:
                out.append("\n")
        self.update(out)

    def action_step(self, delta: int) -> None:
        idx = self._index()
        if idx < 0:
            idx = 0 if delta > 0 else len(self.palette) - 1
        else:
            idx = (idx + delta) % len(self.palette)
        self._pick(idx)

    def action_step_row(self, delta: int) -> None:
        idx = self._index()
        if idx < 0:
            idx = 0
        else:
            idx = (idx + delta * self.columns) % len(self.palette)
        self._pick(idx)

    def _pick(self, idx: int) -> None:
        if 0 <= idx < len(self.palette):
            self.set_value(self.palette[idx][1])
            self.post_message(self.Picked(self.field, self.value))

    def on_click(self, event: events.Click) -> None:
        self.focus()
        if int(event.y) % 2 == 0:  # a swatch line, not a pointer line
            row = int(event.y) // 2
            self._pick(row * self.columns + int(event.x) // (SWATCH_W + SWATCH_GAP))

    def on_key(self, event: events.Key) -> None:
        # Digits pick within the row the selection is already on, so 1-8 stays
        # meaningful however many rows the palette wraps to.
        if event.character and event.character.isdigit():
            n = int(event.character)
            if 1 <= n <= self.columns:
                event.stop()
                row = max(self._index(), 0) // self.columns
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
    #previews { width: 1fr; padding: 0 1; }
    .section { color: $accent; text-style: bold; padding: 1 0 0 0; }
    .field { height: 1; }
    .field Label { width: 10; content-align: left middle; }
    .field Input { width: 1fr; height: 1; border: none; background: $boost; padding: 0 1; }
    .field Input:focus { background: $panel; }
    .field Input.-invalid { color: $error; }
    /* Three rows of eight swatches, two lines each (swatches + the selection
       pointer under them). PaletteRow.on_mount() sets the real height from the
       palette length, which wins over this; the value here just keeps the CSS
       from claiming something visibly different before it does. */
    PaletteRow { height: 6; padding: 0; }
    PaletteRow:focus { background: $boost; }
    ChoiceRow { height: 1; padding: 0; }
    ChoiceRow:focus { background: $boost; }
    Checkbox { height: 1; border: none; padding: 0; background: transparent; }
    Checkbox:focus { text-style: bold; }
    .preview { border: round white; padding: 0 1; height: auto; margin-bottom: 1; }
    .preview.wide { padding: 0; }
    #buttons { height: 3; align: center middle; padding: 0 1; }
    #buttons Button { margin: 0 1; }
    #status { height: 1; padding: 0 1; color: $error; }
    .hint { height: auto; color: $text-muted; }
    """
    BINDINGS = [
        Binding("ctrl+s", "install", "Install"),
        Binding("escape", "cancel", "Quit"),
        Binding("ctrl+q", "cancel", "Quit", show=False),
    ]

    def __init__(self, answers: Answers, palette: list[tuple[str, str]], out: Path | None,
                 columns: int = 8, catalogue: list[Tool] | None = None,
                 priv: str = ""):
        super().__init__()
        self.answers = answers
        self.palette = palette
        self.columns = columns
        self.catalogue = catalogue or []
        self.priv = priv
        self.out = out
        self.confirmed = False
        self.previewer = Previewer()
        self._debounce = None
        self._syncing = False

    # -- layout -------------------------------------------------------------
    def compose(self) -> ComposeResult:
        yield Header()
        with Horizontal(id="body"):
            with VerticalScroll(id="controls"):
                yield Static("Primary colour", classes="section", id="primary-title")
                with Horizontal(classes="field"):
                    yield Label("hex")
                    yield Input(value=self.answers.primary, id="primary-hex", max_length=7)
                yield PaletteRow("primary", self.palette, self.answers.primary,
                                 columns=self.columns, id="primary-row")

                yield Static("Secondary colour", classes="section", id="secondary-title")
                with Horizontal(classes="field"):
                    yield Label("hex")
                    yield Input(value=self.answers.secondary, id="secondary-hex", max_length=7)
                yield PaletteRow("secondary", self.palette, self.answers.secondary,
                                 columns=self.columns, id="secondary-row")

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

                yield Static("oh-my-posh accents", classes="section")
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
                    bar_box.border_title = "herdr-statusline"
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
        self.refresh_previews()
        # Keeps the clock in the bar ticking and the GPU reading fresh while the
        # UI sits open, without which the pane looks frozen.
        self.set_interval(10.0, self.refresh_previews)

    # -- input --------------------------------------------------------------
    @on(Input.Changed, "#primary-hex")
    def _primary_typed(self, event: Input.Changed) -> None:
        self._hex_typed(event, "primary", "#primary-row")

    @on(Input.Changed, "#secondary-hex")
    def _secondary_typed(self, event: Input.Changed) -> None:
        self._hex_typed(event, "secondary", "#secondary-row")

    def _hex_typed(self, event: Input.Changed, field: str, row: str) -> None:
        if self._syncing:
            return
        value = event.value.strip()
        if BARE_HEX_RE.match(value):  # a "#" is easy to leave off
            value = f"#{value}"
        if HEX_RE.match(value):
            event.input.remove_class("-invalid")
            self.answers = replace(self.answers, **{field: value.lower()})
            self.query_one(row, PaletteRow).set_value(value)
            self._sync_titles()
            self._sync_choices()
            self._sync_chrome()
            self._clear_error()
            self.schedule_preview()
        else:
            event.input.add_class("-invalid")

    @on(PaletteRow.Picked)
    def _swatch_picked(self, event: PaletteRow.Picked) -> None:
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
            row.set_colours(colours if row.choices is ACCENT_CHOICES else {})
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
        """The palette name goes in the section heading -- next to the swatches
        there is no room for it in a 46-column panel."""
        for field in ("primary", "secondary"):
            row = self.query_one(f"#{field}-row", PaletteRow)
            title = Text(f"{field.capitalize()} colour  ", style="bold")
            title.append(row.name_of_value, Style(dim=True, bold=False))
            self.query_one(f"#{field}-title", Static).update(title)

    @on(Button.Pressed, "#install")
    def _install_pressed(self) -> None:
        self.action_install()

    @on(Button.Pressed, "#quit")
    def _quit_pressed(self) -> None:
        self.action_cancel()

    def on_resize(self, event: events.Resize) -> None:
        self.schedule_preview()

    # -- previews -----------------------------------------------------------
    def schedule_preview(self, delay: float = 0.12) -> None:
        """Coalesce keystrokes: one render per pause, not one per character."""
        if self._debounce is not None:
            self._debounce.stop()
        self._debounce = self.set_timer(delay, self.refresh_previews)

    def refresh_previews(self) -> None:
        try:
            width = max(self.query_one("#previews").content_size.width - 4, 30)
        except Exception:
            width = 76
        self._render(self.answers, width)

    @work(thread=True, exclusive=True, group="preview")
    def _render(self, answers: Answers, width: int) -> None:
        try:
            derived = derive(answers)
            panes = {
                "posh": self.previewer.posh(derived, answers, width),
                "hsl-bar": self.previewer.statusline(derived, answers, width),
                "claude": self.previewer.claude(derived, answers, width),
                "herdr": self.previewer.herdr(derived, width),
            }
            if self.catalogue:
                panes["plan"] = self.previewer.plan(derived, answers, width)
        except Exception as exc:  # a broken preview must not take the UI down
            panes = {"posh": Text(f"preview failed: {exc}", style="red")}
        self.call_from_thread(self._apply, panes)

    def _apply(self, panes: dict[str, Text]) -> None:
        for widget_id, text in panes.items():
            try:
                self.query_one(f"#{widget_id}", Static).update(text)
            except Exception:
                pass

    # -- finishing ----------------------------------------------------------
    def _clear_error(self) -> None:
        self.query_one("#status", Static).update("")

    def _error(self, message: str) -> None:
        self.query_one("#status", Static).update(message)

    def action_install(self) -> None:
        for selector, ok, message in (
            ("#primary-hex", HEX_RE.match(self.answers.primary), "Primary colour is not a #rrggbb value."),
            ("#secondary-hex", HEX_RE.match(self.answers.secondary), "Secondary colour is not a #rrggbb value."),
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
            ("herdr-statusline", previewer.statusline(derived, answers, width)),
            ("claude code status line", previewer.claude(derived, answers, width)),
            ("herdr", previewer.herdr(derived, width)),
            (f"install plan  ({privilege_summary()})",
             previewer.plan(derived, answers, width)),
        ):
            console.print(f"[bold]{title}[/bold]")
            console.print(pane)
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
        columns = palette_columns(derived)
    except Exception as exc:
        print(f"cannot run {DERIVE}: {exc}", file=sys.stderr)
        return 1

    if args.dump:
        dump(answers, args.width)
        return 0

    app = SetupApp(answers, palette, args.out, columns=columns,
                   catalogue=catalogue, priv=privilege_summary())
    try:
        app.run()
    finally:
        app.previewer.cleanup()
    return 0 if app.confirmed else 10


if __name__ == "__main__":
    sys.exit(main())
