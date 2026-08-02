# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Personal dotfiles synced across machines: tmux, Claude Code global config, oh-my-posh prompt, herdr (terminal workspace manager) config + plugins, and portable shell additions. There is no build/test/lint tooling — this repo *is* the config; the only "runtime" is `./install.sh` plus the Textual setup UI it launches.

## Commands

```
curl -fsSL albertorota.dev/install.sh | bash          # bare machine, no checkout
curl -fsSL albertorota.dev/install.sh | bash -s -- --no-tools   # ...with options

./install.sh                 # installs uv, then prompts (setup UI) on first run
./install.sh --reconfigure   # change the colours / machine name / tool selection
./install.sh --primary '#78dce8' --secondary '#ffd866' --machine proxima -y
./install.sh --skip-uv       # don't install/update uv (offline, CI)
./install.sh --no-tui        # plain text wizard instead of the setup UI
./install.sh --no-tools      # render and link config only, install nothing
./install.sh --tools-only    # install tools only, render and link nothing
./install.sh --help
./reset.sh                   # undo everything install.sh put in place

uv run --script tui/configure.py --dump      # previews to stdout, no UI
bash lib/derive.sh                           # the derived values, KEY=value
bash lib/tools.sh --plan                     # what a tools run would do here
bash lib/tools.sh --list                     # the catalogue, id|label|group|on
bash lib/tools.sh --priv                     # what sudo looks like on this box
```

There's no test suite. To validate a change, run `./install.sh` (it's idempotent and safe to re-run) and check the rendered output under `.generated/` and the symlinks it creates in `$HOME`. For a change to the setup UI, `--dump` renders every preview to stdout without needing a terminal to drive, and `App.run_test()` (Textual's headless pilot) can drive the widgets.

## The bootstrap — `curl | bash` with no repo on disk

`albertorota.dev/install.sh` serves this repo's `install.sh`, so the one-liner runs it with **no checkout around it**: bash reads the script from stdin, `BASH_SOURCE` is unset and `$0` is `bash`, so the old `DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` died on `set -u` before doing anything. Worse, `lib/derive.sh`, `lib/tools.sh` and every `*.in` template are simply absent.

So install.sh is self-bootstrapping. `self_dir()` returns empty when the script did not come from a readable file, and `is_checkout()` (`install.sh` **and** `lib/derive.sh` both readable) decides whether what we have is usable. If not, `bootstrap()` fetches the repo and `exec`s the copy inside it. Four cases, all tested:

- **already a checkout at `$DOTFILES_DIR`** — `git pull --ff-only`, non-fatal (local edits, a diverged branch or no network are all reasons to use what's there, not to refuse to install);
- **absent or empty** — full `git clone` (not `--depth 1`: this is a repo you commit to, and every machine starting shallow just means unshallowing later);
- **no git** — codeload tarball, `--strip-components 1`. Still a usable checkout, just not a git one. git is itself in the tools catalogue;
- **non-empty and not ours** — refuse, exit 1, touch nothing.

Overridable by env: `DOTFILES_DIR`, `DOTFILES_SLUG`, `DOTFILES_BRANCH`, `DOTFILES_REPO`, `DOTFILES_TARBALL`.

Two details worth keeping. `DOTFILES_BOOTSTRAPPED=1` is exported before the `exec` so a fetched copy that still can't find its own lib gives one clear error instead of forking forever. And the `exec` redirects stdin from `/dev/tty` when there is one — stdin is the exhausted curl pipe, and handing over the real terminal is what lets the setup UI and the text wizard take their normal paths instead of their no-tty fallbacks. The `(exec 3</dev/tty)` probe is the same subshell trick used further down for `TTY_FD`: `/dev/tty` can exist but be unopenable (cron, CI, a container with no controlling terminal).

The clone is over HTTPS, since a fresh machine has no SSH key. That's fine for pulling; to push, `git -C ~/dotfiles remote set-url origin git@github.com:alberto-rota/dotfiles.git`.

**A change to install.sh only reaches new machines once it is pushed** — the one-liner fetches whatever `main` currently serves, not what is in your working tree.

## uv, and the setup UI

`install.sh` installs uv (`curl -LsSf https://astral.sh/uv/install.sh | sh`) before it asks anything, because the wizard *is* a uv script: `tui/configure.py` declares `textual` in a PEP 723 header, so `uv run --script` fetches both Python and Textual — nothing to preinstall, nothing left behind.

Two things about that install are deliberate:

- **`INSTALLER_NO_MODIFY_PATH=1`.** Left alone, the astral installer appends its PATH line to `~/.bashrc` *and* `~/.profile` — and on a machine this repo has already installed, `~/.profile` is a symlink into the repo, so that edit would land in tracked dotfiles. install.sh persists the PATH itself instead, writing `~/.config/dotfiles/uv-env.sh` (which `shell/bashrc_additions.sh` sources) with uv's actual install dir. With `NO_MODIFY_PATH` the installer also skips writing its own `~/.local/bin/env`, which is why `uv-env.sh` does the `case`-guarded export itself and only sources that file `[ -f ]`.
- **Never fatal.** No curl, no network, install fails → a NOTE and the run continues; `HAVE_UV=0` then routes the wizard to the text fallback, so an offline machine can still be set up. Same for `--skip-uv`.

`run_tui()` passes the current answers in the environment and gets a theme.env-format fragment back on `--out`, which install.sh sources. Exit 0 = confirmed, 10 = the user quit (install aborts), anything else = the UI could not run (fall back to `text_wizard`, the original prompt loop, kept for exactly this). Textual needs a real terminal on fd 0 *and* 1, hence the `/dev/tty` redirect for the `curl | bash` case.

Pane borders and their titles are white, not Textual's default `$panel` -- that is a grey on a grey background, which left them all but invisible. The section headings do follow the chosen primary (`_sync_chrome()`, on every colour change), passed through `readable_on_dark()` so a very dark custom hex still reads against the app background. The previews themselves are never lifted that way: a dark accent is supposed to look dark there.

The previews are real rather than drawn, and that is the point of the split below: the status bar is the string `lib/derive.sh` assembles (herdr's only — tmux's comes out of the same toggles and the same code, so showing both said the same thing twice), interpreted by a small tmux-format renderer in `configure.py` (which reproduces tmux dropping a whole `#[...]` directive that contains an invalid colour — that is what makes the deliberate `bg=#00000t0` typo look right), with `#(...)` segments actually executed. Helper scripts are rendered with the colours left as `<<PRIMARY>>`/`<<SECONDARY>>` sentinels and substituted in their *output*, so changing a colour repaints instantly instead of re-running `nvidia-smi`. The prompt is `oh-my-posh print` on a rendered copy of the real template, and the Claude Code line is the rendered status line script run against a sample statusLine payload (its five bubble colours use the same sentinel trick, so recolouring does not re-run jq). Only the herdr pane is a drawing.

## lib/derive.sh — the one source of truth for computed values

Everything derived *from* the answers lives in `lib/derive.sh`: the palette, `valid_hex`/`valid_machine`, `darken()`, and `derive()`, which computes `PRIMARY_DIM`, `MACHINE_LOWER`, `USER_NAME`, the four `OMP_*` colours and the four assembled status-line strings. install.sh sources it and calls `derive`; `tui/configure.py` executes it (`bash lib/derive.sh`, emit mode prints `KEY=value` lines) and parses the result. That is why the preview cannot drift from what gets installed — there is only one assembly, and both front-ends run it. **Add a derived value there, not in install.sh.**

## lib/tools.sh — what gets INSTALLED, as opposed to configured

The other half of the derive.sh split, and the same two-consumer shape: install.sh sources it and calls `install_tools()`; `tui/configure.py` executes it (`--list` for its checkbox list, `--plan` for the install-plan preview pane, `--priv` for the sudo one-liner). The plan the UI shows is therefore resolved by the code that does the installing, not by a Python guess at it.

**Sudo is detected, not assumed.** `detect_privilege()` sets `PRIV_MODE` to one of `root` / `passwordless` / `password` / `none`. The interesting case is the last two being told apart: `sudo -nv` says *"a password is required"* for a real sudoer and *"is not in the sudoers file"* for everyone else, and **an explicit refusal beats the group-membership fallback below it** — being in group `sudo` does not make you a sudoer, and believing it would send every apt route into a wall of failures. The group check only runs when the message is unrecognised (a locale we have no string for).

In `password` mode nothing prompts until a privileged command is actually needed: `sudo_unlock()` asks **once**, up front, then keeps the timestamp warm with a background refresher that polls for its parent (so a `kill -9` of install.sh cannot orphan it). Declining is not fatal — `PRIV_MODE` drops to `none` and every later route resolves to its userland alternative. With no terminal to ask on (`curl | bash`, CI, `-y`) it doesn't try.

**One route list, not two installers.** Each tool has an ordered list of routes and takes the first this machine can use. The system route (apt) needs privilege; every other one — rustup/cargo, `uv tool install`, a release tarball, a git clone, Homebrew — lands entirely in `$HOME`. The sudo/no-sudo split is just that first entry dropping out. apt is the only system package manager wired up: on dnf/pacman the system route is simply unavailable and everything falls through to the userland routes, which is also what happens on an HPC login node.

`tool_route()` is the single decision point, used by both `--plan` and `install_tools()`. It reads the `AVAIL_APT` / `AVAIL_CARGO` / `AVAIL_UV` / `AVAIL_BREW` flags, which start from what is on the machine now and are **flipped on as the walk passes a provider it is going to install** — that is what lets `eza: cargo` be true on a box with no cargo yet, because `rust` is listed above it.

**Homebrew is bootstrapped only when it is the sole remaining route** to something actually selected (`brew_needed()`) — a ~1GB clone is not worth doing on spec. In practice that means `nvtop` on a machine with no apt, or eza/fd/bat/delta with no apt *and* no cargo coming. glow and neovim never count towards it: their release tarballs work everywhere.

Ordering is the array order of `TOOL_IDS`, which is topological — a tool may only depend on one listed above it. `TOOL_DEPS` holds only the hard ones (LazyVim needs neovim; both herdr plugins need herdr). bat/delta/glow are deliberately *not* dependencies of `herdr-file-viewer`: it installs and runs fine without them and just falls back to plain text.

Answers are one `TOOL_<ID>=0|1` per catalogue entry in theme.env, appended by `tools_answers()` rather than spelled out in install.sh's heredoc — so adding a tool needs no edit there. **Unset means on**, which is what makes a newly-added tool install itself on a machine whose theme.env predates it (`tools_defaults()`).

Three things each installer is careful about, all the same hazard: `rustup` gets `--no-modify-path`, `fzf` gets `--no-update-rc`, and uv gets `UV_NO_MODIFY_PATH` — left alone all three append to `~/.profile`, which **on an already-installed machine is a symlink into this repo**, so the edit would land in tracked dotfiles. `install_lazyvim()` refuses to touch a `~/.config/nvim` that already has files in it and returns 2, which the orchestrator prints as "left alone" rather than counting as a failure. Nothing in the phase is ever fatal: a failed tool is recorded and the run continues.

PATH goes out two ways. Permanently through `~/.config/dotfiles/tools-env.sh` (written by `tools_write_env()`, sourced by `bashrc_additions.sh` — same shape as `uv-env.sh`, and the reason Homebrew gets a full `brew shellenv` rather than just its bin dir). And for the terminal the install ran in, `print_path_hint()` prints a copy-paste `export PATH=...`, compared against `TOOLS_ORIG_PATH` — the PATH as it was when the phase *started*, because `install_rust()` and `install_neovim()` prepend to install.sh's own PATH so later steps can use what they just installed, and checking the live one would report every such directory as already handled.

Tools are **not** recorded in the manifest: `reset.sh` undoes this repo's config, not the software on the machine.

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

**Always edit the `.in` file, never the file under `.generated/`** — it's overwritten on every `install.sh` run and stamped with a "GENERATED, do not edit" header (except JSON, which has no comment syntax to carry one). Templated files: `tmux/.tmux.conf`, `tmux/other-sessions.sh`, `tmux/slurm-status.sh`, `oh-my-posh/albe-monokai2.omp.json`, `herdr/config.toml`, `claude/themes/*.json`, `claude/statusline-command.sh`, `herdr/plugins/herdr-file-viewer/config.toml` (that one only for `@HERDR_CONFIG@`, not colours), and `herdr/plugins/herdr-statusline/{config.toml,gpu-status.sh}`. Everything else not carrying a placeholder is symlinked straight out of the repo, unrendered.

In `render()`, `sed` substitution order matters: longer placeholder names (`@PRIMARY_DIM@`, `@MACHINE_LOWER@`) are substituted before their shorter prefixes (`@PRIMARY@`, `@MACHINE@`) so a future placeholder without a trailing-`@` guard can't be half-substituted.

Answers (colours, machine name, status-line component toggles, oh-my-posh accent placement) persist to `~/.config/dotfiles/theme.env` and are reused on later runs — that's what makes re-rendering after editing a template a no-prompt no-op (`./install.sh -y`).

### Status line components and oh-my-posh accent placement

tmux's status bar and herdr-statusline are meant to look identical, and both are driven by the same five wizard toggles: `SHOW_HOST`, `SHOW_GPU`, `SHOW_TEMP` (sub-toggle of `SHOW_GPU` — only matters when the GPU pill itself is shown), `SHOW_SLURM`, `SHOW_DATETIME`. Since tmux.conf and herdr's TOML have no conditional syntax, the conditional assembly happens in bash in `lib/derive.sh`'s "status line assembly" section — it builds `TMUX_STATUS_LEFT`/`TMUX_STATUS_RIGHT`/`HSL_STATUS_LEFT`/`HSL_STATUS_RIGHT` as complete literal strings (colours and powerline glyphs baked in, not left as `@PRIMARY@` for a second substitution pass), and each `.in` template just holds one placeholder for the whole bar half. `gpu-status.sh.in` is rendered once and linked into both `~/.tmux/gpu-status.sh` and herdr-statusline's config dir, same as `slurm-status.sh`, so the two bars can't drift apart even when a toggle changes which pills are called.

### oh-my-posh, per component

Each accented part of the prompt names its own colour — `OMP_ICON`, `OMP_TEXT`, `OMP_CHEVRON_OK`, `OMP_CHEVRON_ERROR`, each one of `primary` / `secondary` / `neutral` (`NEUTRAL_FG`, `#d6deeb`) — resolved to hex by `accent_hex()` into `OMP_ICON_COLOR` / `OMP_ICON_COLOR_JOB` / `OMP_TEXT_COLOR` / `OMP_CHEVRON_FG` / `OMP_CHEVRON_ERR` before rendering, for the same "bake it in, don't double-substitute" reason.

`OMP_ICON_MODE` is the odd one: the machine segment's template already branches on `$SLURM_JOB_NAME` (a different glyph inside a job shell), so the glyph has *two* colour placeholders. `fixed` puts `OMP_ICON`'s colour in both; `slurm` makes the glyph itself report the allocation — primary on a normal shell, secondary inside a job.

The chevron's error colour is guarded (`{{ if gt .Code 0 }}…{{ end }}`) — a bare literal in `foreground_templates` always renders non-empty, so oh-my-posh applied it unconditionally and the success colour never showed. Keep the guard, or `OMP_CHEVRON_OK` silently stops meaning anything.

These five answers replace the older `OMP_COLOR_ICON` / `OMP_COLOR_TEXT` / `OMP_COLOR_CHEVRON` booleans. `derive()` migrates a theme.env that still has those — but only when the new answers are *unset*, which is why install.sh initialises them empty and calls `derive` once up front to normalise, instead of defaulting them in its own defaults block.

### The Claude Code status line

`claude_ramp()` turns the two accents into the five bubble colours: HSL interpolation along the shorter hue arc (so green→orange goes through yellow, not through grey), with lightness floored at 0.50 because the bubbles carry black text. Saturation is untouched, so picking the silver swatch gives grey pills rather than invented colour. Emitted as `r;g;b`, which is the form the script's `bubble()` takes.

In the setup UI these are checkboxes with the GPU-temperature one disabled while the GPU pill is off; in the text fallback, `ask_components()` runs inside the same wizard loop as the colour/machine prompts, so `show_preview()` reflects all of it before the user confirms. Both front-ends force `SHOW_TEMP=0` when `SHOW_GPU=0`, so they save identical answers.

`install.sh` never wipes `.generated/` up front; it overwrites in place render-by-render so a failure mid-run can't leave a live symlink dangling, then prunes anything stale (a renamed template) only at the very end once every link is set.

## Layout

- `tmux/` — `.tmux.conf.in` plus the two scripts its status bar shells out to: `other-sessions.sh` (session list), `slurm-status.sh` (Slurm job status, degrades gracefully without `squeue`).
- `claude/` — Claude Code **global** `settings.json`, `keybindings.json`, `statusline-command.sh.in`, and custom themes (`themes/*.json(.in)`). Per-project Claude settings (`settings.local.json`, project `.claude/` dirs) are intentionally not synced here. The status line's five bubbles used to be a fixed palette of their own; they are now the primary→secondary ramp (`claude_ramp()` in `lib/derive.sh`), so it is templated like everything else.
- `herdr/` — `config.toml.in` (keybindings, sidebar rows, theme overrides) plus plugin configs under `herdr/plugins/*`. Plugin *code* is not synced/tracked as an installed plugin — see below.
- `oh-my-posh/` — `albe-monokai2.omp.json.in`, the active prompt theme.
- `lib/` — `derive.sh` and `tools.sh`, both described above. Sourced by install.sh, executed by the setup UI.
- `tui/` — `configure.py`, the Textual setup UI. A PEP 723 uv script: dependencies live in its header, capped at the tested Textual major so a breaking release cannot break setting up a machine.
- `shell/` — layered on top of each machine's own `.bashrc`/`.profile`, not a replacement for them:
  - `bashrc_additions.sh` — aliases, PATH, oh-my-posh/zoxide/fzf init, tmux auto-attach, env vars. Sourced from the tail of `~/.bashrc` via one `source` line that `install.sh` appends, guarded by a marker comment (idempotent).
  - `bashrc_functions` — shell functions (currently `syncop`, a generic rsync-between-machines helper).
  - `profile` — symlinked directly to `~/.profile`.
- `bin/` — binaries/scripts install.sh plain-copies (not symlinks, not templated) into `~/.local/bin`. Currently a scaffold (just `.gitkeep`); drop files in to have them installed. Note `~/.local/bin/hsl` is *not* a candidate: herdr-statusline generates that launcher itself.

## herdr plugins

- `herdr-file-viewer` — third-party plugin; only its config (`config.toml.in`, a template for `@HERDR_CONFIG@` because the glow style arg must be an absolute path) and its Monokai glow palette (`markdown-monokai.json`) live here. The plugin *code* is not tracked in this repo — the tools phase installs it with `herdr plugin install smarzban/herdr-file-viewer`, and the config linking that follows takes the config path over from whatever defaults the plugin shipped. Its content pane needs `bat`, `delta` and `glow` on PATH (themed Monokai); the tools phase installs all three, and missing any degrades to plain text.
- `herdr-statusline` — config + `gpu-status.sh.in` script, reproducing the tmux status bar's components inside a herdr session; see "Status line components" above for how the two stay in sync. Same deal as the file viewer: config here, code installed by the tools phase from `iiii1224/herdr-statusline`.
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

- Colour values are validated as 6-hex (`^#[0-9a-fA-F]{6}$`); machine name as `^[A-Za-z0-9._-]{1,24}$` (it gets substituted into sed replacements and JSON/tmux strings, so keep it conservative if extending validation). Both front-ends validate: `valid_hex`/`valid_machine` in `lib/derive.sh`, `HEX_RE`/`MACHINE_RE` in `tui/configure.py` — keep them in step.
- A new placeholder needs adding in *two* places: install.sh's `render()` sed, and `placeholders()` in `tui/configure.py`, whose `render_template()` mirrors `render()` (same `#>>` stripping, same longest-name-first substitution) so previews render the same file the installer will.
- A new answer needs: a default + the `theme.env` write in install.sh, a field on `Answers` in `tui/configure.py` (which round-trips it through `as_env()`/`as_shell()`), a control in `compose()`, and a prompt in the text fallback's `ask_components()`.
- A new **tool**, by contrast, needs editing exactly one file: add its id to `TOOL_IDS` (in dependency order), give it a `TOOL_LABEL`/`TOOL_GROUP` entry, a `tool_present` probe, a `tool_route` case and an `install_<id>()`. Both front-ends pick it up from the catalogue, theme.env gains its line automatically, and it defaults to on. Add a `TOOL_DEPS` entry only if it genuinely cannot be installed before something else.
- The palette is 24 colours in three rows of eight (vivid, gap-filling, pastel), and it lives **only** in `lib/derive.sh`. install.sh used to carry its own copy of the first eight, which meant the text wizard silently offered a different set from the UI — don't reintroduce that.
- `#>>` -prefixed lines in a `.in` template are template-only comments and get stripped by `render()` — use them for notes that shouldn't appear in the rendered/live config.
- `render_script()` inserts the GENERATED header as line 2 (after the shebang, which must stay on line 1) and `chmod +x`s the output.
- `link()`/`copy()` back up any real file at the destination as `<file>.bak` before taking it over — safe to re-run against a machine with pre-existing dotfiles. See "Backup + reset" above.
