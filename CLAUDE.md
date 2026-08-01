# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Personal dotfiles synced across machines: tmux, Claude Code global config, oh-my-posh prompt, herdr (terminal workspace manager) config + plugins, and portable shell additions. There is no build/test/lint tooling — this repo *is* the config; the only "runtime" is `./install.sh`.

## Commands

```
./install.sh                 # prompts on first run, reuses saved answers after
./install.sh --reconfigure   # change the colours / machine name
./install.sh --primary '#78dce8' --secondary '#ffd866' --machine proxima -y
./install.sh --help
./reset.sh                   # undo everything install.sh put in place
```

There's no test suite. To validate a change, run `./install.sh` (it's idempotent and safe to re-run) and check the rendered output under `.generated/` and the symlinks it creates in `$HOME`.

## Backup + reset

`link()` and `copy()` (install.sh's plumbing helpers) back up any real, non-symlink file already at a destination as `<file>.bak` before taking it over — but only the first time: on a later run the destination is already a symlink (or, for `copy()`, already listed in the *previous* run's manifest), so the `.bak` is never overwritten by our own output. Every destination either helper touches is recorded in `MANAGED` and written out fresh each run to `~/.config/dotfiles/manifest.txt`.

`reset.sh` reads that manifest and undoes it: removes every path on it, restores `<file>.bak` wherever one exists, strips the `bashrc_additions` block from `~/.bashrc`, and best-effort unlinks the `herdr-workspace-prefix` plugin. Paths with no `.bak` (there was nothing there before install.sh) are just removed. `theme.env` and `.generated/` are deliberately left alone — reset undoes *installation*, not the saved colour/machine/toggle answers.

## Architecture: templates + `.generated/`

This is the one thing that has to click before editing anything here. Any file whose content depends on the accent colours or machine name is tracked as a `*.in` template with `@PRIMARY@` / `@SECONDARY@` / `@MACHINE@` (and a few derived: `@PRIMARY_DIM@`, `@MACHINE_LOWER@`, `@HERDR_CONFIG@`, `@SHOW_TEMP@`, `@OMP_ICON_COLOR@`/`@OMP_TEXT_COLOR@`/`@OMP_CHEVRON_FG@`/`@OMP_CHEVRON_ERR@`, `@TMUX_STATUS_LEFT@`/`@TMUX_STATUS_RIGHT@`/`@HSL_STATUS_LEFT@`/`@HSL_STATUS_RIGHT@`) placeholders — because none of tmux.conf, JSON, or TOML can indirect through a shell variable. `install.sh`'s `render()`/`render_script()` helpers substitute these into `.generated/` (gitignored), and `link()` symlinks the real config path (`~/.tmux.conf`, `~/.config/herdr/config.toml`, etc.) at the rendered copy:

```
tmux/.tmux.conf.in                 tracked, has @PRIMARY@
  -> .generated/tmux/.tmux.conf    rendered, gitignored
       <- ~/.tmux.conf             symlink
```

**Always edit the `.in` file, never the file under `.generated/`** — it's overwritten on every `install.sh` run and stamped with a "GENERATED, do not edit" header (except JSON, which has no comment syntax to carry one). Templated files: `tmux/.tmux.conf`, `tmux/other-sessions.sh`, `tmux/slurm-status.sh`, `oh-my-posh/albe-monokai2.omp.json`, `herdr/config.toml`, `claude/themes/*.json`, `herdr/plugins/herdr-file-viewer/config.toml` (that last one only for `@HERDR_CONFIG@`, not colours), and `herdr/plugins/herdr-statusline/{config.toml,gpu-status.sh}`. Everything else not carrying a placeholder is symlinked straight out of the repo, unrendered.

In `render()`, `sed` substitution order matters: longer placeholder names (`@PRIMARY_DIM@`, `@MACHINE_LOWER@`) are substituted before their shorter prefixes (`@PRIMARY@`, `@MACHINE@`) so a future placeholder without a trailing-`@` guard can't be half-substituted.

Answers (colours, machine name, status-line component toggles, oh-my-posh accent placement) persist to `~/.config/dotfiles/theme.env` and are reused on later runs — that's what makes re-rendering after editing a template a no-prompt no-op (`./install.sh -y`).

### Status line components and oh-my-posh accent placement

tmux's status bar and herdr-statusline are meant to look identical, and both are driven by the same five wizard toggles: `SHOW_HOST`, `SHOW_GPU`, `SHOW_TEMP` (sub-toggle of `SHOW_GPU` — only matters when the GPU pill itself is shown), `SHOW_SLURM`, `SHOW_DATETIME`. Since tmux.conf and herdr's TOML have no conditional syntax, the conditional assembly happens in bash in install.sh's "status line assembly" section — it builds `TMUX_STATUS_LEFT`/`TMUX_STATUS_RIGHT`/`HSL_STATUS_LEFT`/`HSL_STATUS_RIGHT` as complete literal strings (colours and powerline glyphs baked in, not left as `@PRIMARY@` for a second substitution pass), and each `.in` template just holds one placeholder for the whole bar half. `gpu-status.sh.in` is rendered once and linked into both `~/.tmux/gpu-status.sh` and herdr-statusline's config dir, same as `slurm-status.sh`, so the two bars can't drift apart even when a toggle changes which pills are called.

Similarly, `OMP_COLOR_ICON`/`OMP_COLOR_TEXT`/`OMP_COLOR_CHEVRON` pick whether the oh-my-posh machine segment's glyph, its text, and the bottom exit-status chevron line use the accent colours or fall back to the neutral `NEUTRAL_FG` (`#d6deeb`) — computed into `OMP_ICON_COLOR`/`OMP_TEXT_COLOR`/`OMP_CHEVRON_FG`/`OMP_CHEVRON_ERR` before rendering, for the same "bake it in, don't double-substitute" reason.

`ask_components()` runs inside the same wizard loop as the colour/machine prompts, so `show_preview()` reflects all of it before the user confirms.

`install.sh` never wipes `.generated/` up front; it overwrites in place render-by-render so a failure mid-run can't leave a live symlink dangling, then prunes anything stale (a renamed template) only at the very end once every link is set.

## Layout

- `tmux/` — `.tmux.conf.in` plus the two scripts its status bar shells out to: `other-sessions.sh` (session list), `slurm-status.sh` (Slurm job status, degrades gracefully without `squeue`).
- `claude/` — Claude Code **global** `settings.json`, `keybindings.json`, `statusline-command.sh`, and custom themes (`themes/*.json(.in)`). Per-project Claude settings (`settings.local.json`, project `.claude/` dirs) are intentionally not synced here. `statusline-command.sh` uses its own fixed per-field palette (blue model, purple effort, pink usage, orange weekly, teal context) — it is deliberately *not* themed with the accent colours.
- `herdr/` — `config.toml.in` (keybindings, sidebar rows, theme overrides) plus plugin configs under `herdr/plugins/*`. Plugin *code* is not synced/tracked as an installed plugin — see below.
- `oh-my-posh/` — `albe-monokai2.omp.json.in`, the active prompt theme.
- `shell/` — layered on top of each machine's own `.bashrc`/`.profile`, not a replacement for them:
  - `bashrc_additions.sh` — aliases, PATH, oh-my-posh/zoxide/fzf init, tmux auto-attach, env vars. Sourced from the tail of `~/.bashrc` via one `source` line that `install.sh` appends, guarded by a marker comment (idempotent).
  - `bashrc_functions` — shell functions (currently `syncop`, a generic rsync-between-machines helper).
  - `profile` — symlinked directly to `~/.profile`.
- `bin/` — binaries/scripts install.sh plain-copies (not symlinks, not templated) into `~/.local/bin`. Currently a scaffold (just `.gitkeep`); drop files in to have them installed.

## herdr plugins

- `herdr-file-viewer` — third-party plugin; only its config (`config.toml.in`, a template for `@HERDR_CONFIG@` because the glow style arg must be an absolute path) and its Monokai glow palette (`markdown-monokai.json`) live here. The plugin code itself is installed per machine via `herdr plugin install smarzban/herdr-file-viewer`, not synced from this repo. Its content pane needs `bat`, `delta`, and `glow` on PATH (themed Monokai); missing any degrades to plain text.
- `herdr-statusline` — config + `gpu-status.sh.in` script, reproducing the tmux status bar's components inside a herdr session; see "Status line components" above for how the two stay in sync.
- `herdr-workspace-prefix` — a real herdr plugin whose code *is* tracked here (`herdr-plugin.toml` + `tag-workspaces.py`). Workaround for herdr's sidebar only accepting known `$token` names in `rows` (a literal string is rejected): it reports a fixed prefix as workspace *metadata* and swaps which token (`$aa`/`$name` vs `$bb`/`$name_active`) a workspace holds depending on focus, so exactly one renders. Metadata lives only in the running herdr server (absent from `session.json`), so it must be re-seeded on every start via `[[startup]]` running `tag-workspaces.py watch`, plus a manual `retag` action for `tag-workspaces.py once`.

## Intentionally excluded (machine/cluster-specific)

Not oversights — don't try to "restore" these:
- Conda `init` block (path differs per machine — run `conda init bash` fresh).
- Google Cloud SDK sourcing (was specific to one cluster's workspace mount).
- HPC workspace aliases (`twist`, `unref`, `gate`, etc. — point at one cluster's `/anvme/workspace/...` paths).
- `jn_tunnel` alias (assumes an SSH host alias `elcap` configured locally per-machine).
- herdr's machine-local state (`plugins.json`, `plugins/github/`, `session.json`, sockets, logs) — herdr rewrites these itself.
- The `fusermount3` -> `fusermount` symlink shim (one cluster's FUSE workaround).

## Conventions when editing

- Colour values are validated as 6-hex (`^#[0-9a-fA-F]{6}$`); machine name as `^[A-Za-z0-9._-]{1,24}$` (it gets substituted into sed replacements and JSON/tmux strings, so keep it conservative if extending validation).
- `#>>` -prefixed lines in a `.in` template are template-only comments and get stripped by `render()` — use them for notes that shouldn't appear in the rendered/live config.
- `render_script()` inserts the GENERATED header as line 2 (after the shebang, which must stay on line 1) and `chmod +x`s the output.
- `link()`/`copy()` back up any real file at the destination as `<file>.bak` before taking it over — safe to re-run against a machine with pre-existing dotfiles. See "Backup + reset" above.
