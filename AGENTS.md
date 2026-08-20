# AGENTS.md

Dotfiles repo — tmux, Claude Code, OpenCode, oh-my-posh, herdr, shell additions. No build/test/lint tooling. The "runtime" is `./install.sh` and the Textual setup UI it launches.

## Verify changes

| What you changed | Command |
|---|---|
| Any template, `lib/derive.sh`, shell config | `./install.sh -y` — idempotent, check `.generated/` and `$HOME` symlinks |
| Tool routes, catalogue, install logic | `bash lib/tools.sh --plan` — same route resolution, no installs |
| TUI layout, new pane, sizing | `tui/measure.py` — every pane at widths 120→20 |
| TUI at real terminal sizes | `tui/test_narrow.py` — the real app at 10 widths |
| Pane fits its bordered box | `tui/test_panes.py` — catches wrapping inside containers |
| Answers round-trip | `tui/test_answers.py` — env ↔ shell ↔ settings consistency |
| TUI preview only (no install) | `uv run --script tui/configure.py --dump` — renders every pane to stdout |
| Shell 3.2 compat | `bash-3.2 -n <file>` for syntax, but runtime failures (`${var,,}`, `mapfile`) need real execution |

## Architecture

`.in` templates with `@PRIMARY@`/`@SECONDARY@`/`@MACHINE@` placeholders → rendered into `.generated/` (gitignored) → symlinked to `~/.config/...`, `~/.tmux.conf`, etc.

```
tmux/.tmux.conf.in                 tracked
  → .generated/tmux/.tmux.conf    rendered, gitignored
       ← ~/.tmux.conf             symlink
```

**Always edit the `.in` file.** `.generated/` is overwritten every run.

## Key source-of-truth splits

- **`lib/derive.sh`** — every value derived from answers (palette, validators, status-line strings, accent ramps). `install.sh` sources it; `tui/configure.py` executes it. There is one assembly; previews and installs cannot disagree.
- **`lib/tools.sh`** — what gets installed: catalogue, sudo detection, every route. `install.sh` sources it; `tui/configure.py` runs `--list` / `--plan` / `--priv`. Adding a tool = editing this one file.
- **`tui/configure.py`** — the setup UI. Its `placeholders()` and `render_template()` mirror `render()` in `install.sh` (same `#>>` stripping, same longest-name-first substitution order).

## Critical constraints

- **bash 3.2** — macOS ships 3.2 and Apple won't ship newer. No `declare -A`, `${var^^}`, `mapfile`, `&>>`. Use `to_lower()` in `lib/derive.sh` and `tool_var()` in `lib/tools.sh` for case folding.
- **`set -e` sourced vs. executed** — `lib/tools.sh` sourced from `install.sh` runs under `set -euo pipefail`; `bash lib/tools.sh --plan` does not. A fallible `&&`/`||` list as the last statement of a function returns that status, which kills `install.sh`. The fix is `if ...; then ...; fi` (always returns 0). `providers_init()`'s last line is the trap.
- **`pipefail` + `grep -q`** — `herdr plugin list | grep -q foo` fails under `pipefail` because `grep -q` closes stdout while herdr is still writing (broken-pipe panic, exit 101). Capture first, match second.
- **No wrapping in panes** — a wrapped line is a lie about what the bar looks like. `fit_block()` clips every line; CSS enforces `text-wrap: nowrap` on previews. A new pane must not overflow.
- **`bin/hsl` must use `-f` on `new-session`** — `tmux -f conf start-server` silently ignores the file.

## Adding a tool

1. Add `id|label|group` row to `TOOL_META` in `lib/tools.sh` (topological order — dependents below)
2. Add `tool_present`, `tool_route`, `install_<id>()`
3. If it has hard dependencies, add a `tool_deps()` case
4. Run `bash lib/tools.sh --plan` to verify the route resolves correctly
5. Run `tui/test_answers.py` to confirm theme.env round-trips

Answers (`TOOL_<ID>=0|1`) are auto-generated from the catalogue — no manual `theme.env` edit needed. Unset = on (new tools install by default).

## Adding a derived value

Add it in `lib/derive.sh`'s `derive()` — not in `install.sh`. If the UI needs it, add a `run_tui()` export line and wire it through `configure.py`.

## Adding an answer

Needs: a default + `theme.env` write in `install.sh`, a field on `Answers` in `configure.py`, a control in `compose()`, a prompt in the text fallback's `ask_components()`. If used verbatim (not derived), also needs `run_tui()`'s `export` line and `placeholders()` to read it from `as_env()`.

## Adding a template placeholder

Add in two places: `render()` sed in `install.sh`, and `placeholders()` in `tui/configure.py`. Longest names first in substitution order (`@PRIMARY_DIM@` before `@PRIMARY@`).

## Claude Code theme keys

Key names are not guessable — wrong keys silently fail. Recover the real list from the binary:

```bash
strings ~/.local/share/claude/versions/<v> | grep -o "autoAccept:.\{0,2600\}" | grep 'text:"rgb(2'
```

Accepted values: `rgb(r,g,b)`, `#rrggbb`, `#rgb`, `ansi256(n)`, `ansi:<name>`.

## OpenCode theme

Custom themes live in `~/.config/opencode/themes/` and are selected by name in `tui.json` (`"theme": "dotfiles"`). The template is `opencode/themes/dotfiles.json.in`.

OpenCode's theme schema uses `defs` (named colour references) and a `theme` map of UI roles to colour names. Accepted values: `#rrggbb` hex, a `defs` reference name, `{"dark": "...", "light": "..."}`, or `"none"`.

The `OPENCODE_SWAP` answer reverses which accent is `primary` vs `secondary` in the theme, the same way `CLAUDE_SWAP` does for Claude Code. The shimmer values (`OPENCODE_PRIMARY_SHIMMER`, `OPENCODE_SECONDARY_SHIMMER`) are lighter variants derived from the accent ramp, used for `borderActive` and syntax highlights.

## Testing the TUI without installing

`uv run --script tui/configure.py --dump` renders every pane to stdout (no terminal needed). `--dump --width N` at a narrow width.

`App.run_test()` (Textual's headless pilot) can drive widgets programmatically.

## Don'ts

- Never edit `.generated/` files
- Don't create `~/.bash_profile` (it shadows `~/.profile` which is a symlink of ours)
- Don't run `sed -i` with a bare suffix (BSD `-i` takes a mandatory suffix arg)
- Don't use `date -d` (GNU-only; use `date -r N` or `date -j -f`)
- Don't use `find ... -print -quit` (BSD find may lack it; use `| head -n 1 || true`)
- Don't add comments with apostrophes in `accent_ramps()` awk (single-quoted program)
