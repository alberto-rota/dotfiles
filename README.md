# dotfiles

Personal machine config, synced across machines. On a brand new machine, one
line is the whole thing:

```
curl -fsSL albertorota.dev/setmeup.sh | bash
```

There is no checkout to run from at that point, so the script clones this
repo to `~/dotfiles` and hands over to the copy inside it — then carries on
exactly as a local run would. (No git on the machine yet? It falls back to a
release tarball; git itself is one of the tools it installs.) Pass options
through with `bash -s --`, and override where it lands with `DOTFILES_DIR`:

```
curl -fsSL albertorota.dev/setmeup.sh | bash -s -- --no-tools
curl -fsSL albertorota.dev/setmeup.sh | DOTFILES_DIR=~/cfg bash
```

From a clone it's just `./install.sh`. Either way it installs
[uv](https://astral.sh/uv) first, opens a small setup UI to pick the two
accent colours, the machine name, which status line components to show, how
oh-my-posh applies its accents and which tools to put on the machine — with
live previews of the prompt, the status bars, herdr and the install plan —
then installs the lot (idempotent, backs up any real file it would overwrite
as `<file>.bak`).

```
./install.sh                 # prompts on the first run, reuses the answers after
./install.sh --reconfigure   # change the colours / machine name / tool selection
./install.sh --primary '#78dce8' --secondary '#ffd866' --machine proxima -y
./install.sh --skip-uv       # don't install/update uv (offline machines, CI)
./install.sh --no-tui        # plain text wizard instead of the setup UI
./install.sh --no-tools      # render and link config only, install nothing
./install.sh --tools-only    # install tools only, render and link nothing
./install.sh --help
./reset.sh                   # undo: remove everything install.sh put in place

bash lib/tools.sh --plan     # what a tools run would do here, without doing it
```

### The setup UI

`tui/configure.py` is a [Textual](https://textual.textualize.io) app with
its dependencies declared in a PEP 723 header, so `uv run --script` fetches
Python and Textual itself — that is the whole reason install.sh puts uv on
the machine before anything else. uv lands in `~/.local/bin` (or
`$UV_INSTALL_DIR`/`$XDG_BIN_HOME` if set) and is put on PATH permanently
through `~/.config/dotfiles/uv-env.sh`, which `shell/bashrc_additions.sh`
sources. The installer is run with `INSTALLER_NO_MODIFY_PATH=1` on purpose:
left to itself it appends a PATH line to `~/.profile`, which on an
already-installed machine is a symlink into *this repo*.

The previews are the real thing, not drawings of it:

- **oh-my-posh** — `oh-my-posh print` on a rendered copy of the real
  template, in the current directory and git state.
- **herdr-statusline** — the status string `lib/derive.sh` assembles (the
  same one rendered into the real config), interpreted by a small
  tmux-format renderer, with the `#(...)` segments actually executed: the
  GPU pill really is this machine's `nvidia-smi`. tmux's bar is built from
  the same toggles by the same code, so it isn't previewed separately.
- **claude code status line** — the rendered status line script itself, run
  against a sample statusLine payload.
- **herdr** — the one drawing, since herdr cannot render a frame into a
  string; the accent and the darkened `surface_dim` in it are the real
  derived values.
- **install plan** — `lib/tools.sh --plan`, the same route resolution the
  installer performs, so the pane cannot promise a route it would not take.
  It updates as you deselect tools: turn off Rust and watch eza/fd/bat/delta
  fall from `cargo` to `brew` (or to blocked, if you turn that off too).

Everything is keyboard-driven: `tab` between fields, `←`/`→`/`↑`/`↓` or
`1`-`8` in the palette, `p`/`s` to switch which accent the palette moves,
`←`/`→`/`enter` to cycle a choice row, `space` to toggle a checkbox, `ctrl+s`
to install, `esc` to quit. Machines without uv (or without the network to
fetch it) fall back to the original text wizard, so an offline machine can
still be set up.

### The palette

48 colours, as six rows of eight — and each row is one real scheme, so
"which row" is itself the choice:

| | |
|---|---|
| monokai | this repo's own identity |
| catppuccin | mocha accents |
| dracula | |
| nord | frost, then the warmer aurora half |
| tokyonight | |
| neon | where the defaults come from |

Only each scheme's *accent* ramp is included, never its backgrounds or
greys: the primary gets used as a **background with black text on it** (both
status bars, the Claude Code bubbles), so a dark entry would be illegible
there. The near-whites (`dracula/snow`, `nord/snow`) are the deliberate
low-saturation option — saturation is passed through untouched, so those
give grey pills rather than invented colour. Any `#rrggbb` still works if
none of the 48 suit.

Rather than a 48-line menu, the setup UI shows one grid for **both** accents
at once, marked `P` and `S` in place (`PS` if you set them the same), with
`p`/`s` choosing which one the arrows move. The text wizard asks in two
steps: scheme first (six rows of swatches, `<-` on the one you are on), then
the colour inside it.

### hsl at login

Optionally, `hsl` — herdr with the status line — starts at every interactive
login. **Off by default**, because it is the one setting that changes what
opening a terminal does, and getting it wrong on a machine you only reach
over ssh is worse than any wrong colour.

It is run rather than `exec`ed, so quitting herdr leaves you in a normal
shell, and `NO_HSL=1 bash -l` skips it outright. It also declines to start
when it would be wrong or recursive: inside herdr already (every pane herdr
spawns re-runs `~/.bashrc`), inside tmux, inside an AI agent's shell, on a
non-interactive shell, under an ssh forced command, with `TERM=dumb`, or
when `hsl` isn't installed — it ships with the herdr-statusline plugin.

Both front-ends are built to fit the terminal rather than wrap in it: a
wrapped status bar is a lie about what the bar looks like. Content is clipped
to the width instead, panes size themselves from the space they have, the
palette narrows its swatches (keeping the scheme names in full) and the
sample bar drops pills from the right the way tmux does. Below 88 columns the
setup UI stacks its two panels instead of squeezing them. It stays readable
down to about 60 columns, and usable well below that — the one thing that can
still outgrow a very narrow terminal is oh-my-posh's own prompt, which would
do that on its own account anyway.

Answers are saved to `~/.config/dotfiles/theme.env`, so later runs re-render
without prompting — which is what you want after editing a template. Add `-y`
to guarantee no prompt (for a scripted or headless run).

Before install.sh symlinks or copies over a path, if a real (non-symlink) file
is already there it gets moved aside to `<file>.bak` first — so nothing you had
before is ever lost, and only the very first run backs it up (a second run
sees its own symlink/copy there instead and leaves the `.bak` alone). Every
path it manages is recorded in `~/.config/dotfiles/manifest.txt`.
`./reset.sh` reads that manifest, removes everything on it, restores each
path's `.bak` if one exists, and strips the block it added to `~/.bashrc` —
bringing the machine back to how it looked before `./install.sh` ever ran.
Reset undoes *config*, not the software: tools stay installed, and each has
its own uninstall.

### The tools

Everything in the catalogue is **on by default** — deselect what you don't
want, in the setup UI's checkbox list or by typing numbers in the text
wizard. The answers persist per machine like the colours do, and a tool
added to the catalogue later switches itself on (an absent answer means yes).

| | |
|---|---|
| shell | oh-my-posh, jq, zoxide, eza, fzf, fd, bat, delta, glow |
| network | Tailscale |
| gpu | nvtop, nvitop |
| editor | Neovim + the LazyVim starter |
| python (uv tools) | gdown, ground-control-tui |
| herdr | herdr, herdr-statusline, herdr-file-viewer |
| toolchains | git, Rust (rustup/cargo), Homebrew — only if something needs it |

Tailscale is installed but **not** connected: `tailscale up` opens a browser to
authenticate the machine, so it is left to you. The run ends with a single
copy-and-paste block containing everything still outstanding — the `PATH`
export for the shell you are in, the Tailscale step if one is needed, and
`source ~/.bashrc` — so finishing is one paste rather than a hunt through the
output:

```
Copy and paste this to finish:

    export PATH="/home/you/.local/bin:$PATH"
    sudo tailscale up
    source ~/.bashrc
```

Without root, Tailscale still installs (static binaries) and the block gives
the userspace-networking commands to run the daemon under `$HOME` instead.

oh-my-posh and jq are fetched *before* the setup UI opens, because its
preview panes are the real prompt and the real Claude status line — without
those two they degrade to a hand-drawing and a "needs jq" apology. That
pre-pass never asks for a password (both have routes that need no sudo) and
is harmless if it fails.

**Sudo is detected, not assumed.** install.sh works out whether you are root,
have passwordless sudo, are a sudoer who has to type a password, or have no
sudo at all — and picks routes accordingly. With privilege it uses apt;
without, everything lands in `$HOME` via rustup/cargo, `uv tool install`,
release tarballs, git clones or Homebrew. There is no separate unprivileged
installer, just a route list whose first entry drops out. On an HPC login
node that means it all still works, unattended.

If a password is needed you are asked **once**, up front, before anything
runs — not repeatedly in the middle of the install. Say no and it falls back
to the userland routes rather than failing. With no terminal to ask on
(`curl | bash`, CI, `-y`) it doesn't try.

A few deliberate choices: Neovim comes from the official tarball rather than
apt, because apt's 0.9.5 is old enough that LazyVim complains about it;
LazyVim refuses to touch a `~/.config/nvim` that already has files in it;
Homebrew is only bootstrapped when it is the *sole* route to something you
actually selected (in practice `nvtop` on a box with no apt); and on Debian
and Ubuntu, where the packages are called `batcat` and `fdfind`,
`bashrc_additions.sh` aliases them back to `bat` and `fd` — but only when the
real binaries aren't there, so a cargo or brew install isn't shadowed.

Nothing in the phase is fatal. A tool that fails is reported and the run
carries on; re-run `./install.sh` to retry it. Anything with no route on this
machine is listed as blocked rather than silently skipped.

New tools land on PATH permanently through
`~/.config/dotfiles/tools-env.sh` (sourced by `bashrc_additions.sh`, same
shape as `uv-env.sh`). For the terminal you ran the install in, install.sh
prints a copy-paste `export PATH=...` at the end.

## Layout

- `tmux/` — `.tmux.conf.in` (mouse mode on by default, accent-coloured
  borders/status bar, popups) plus the two scripts it shells out to for
  the status bar: `other-sessions.sh` (session list), `slurm-status.sh`
  (Slurm job status — degrades to "no jobs" if `squeue` isn't available),
  and the shared `gpu-status.sh` (see herdr-statusline below). Which of the
  host/GPU/temperature/Slurm/date-time pills actually show is chosen in the
  install.sh wizard, not hardcoded here.
- `claude/` — Claude Code global `settings.json`, `keybindings.json`,
  `statusline-command.sh.in`, and custom themes (`themes/*.json`).
  Per-project Claude settings (`settings.local.json`, project `.claude/`
  dirs) are **not** synced here — those stay per-project. The status line's
  five bubbles are a primary→secondary ramp (HSL, shorter hue arc,
  lightness floored so the black bubble text stays readable).
- `herdr/` — the terminal workspace manager's `config.toml.in` (keybindings,
  sidebar rows, theme overrides) plus its plugin configs under `plugins/`:
  - `herdr-file-viewer` — third-party plugin; only its config
    (`config.toml.in`, a **template** for `@HERDR_CONFIG@`, because the
    glow style argument has to be an absolute path) and its Monokai glow
    palette (`markdown-monokai.json`) are synced. The plugin itself is
    installed per machine with `herdr plugin install
    smarzban/herdr-file-viewer`. Its content pane wants `bat`, `delta` and
    `glow` on PATH, all three themed Monokai; without them the viewer
    degrades to plain text.
  - `herdr-statusline` — config + `gpu-status.sh.in`, reproducing the tmux
    status bar (same components, same SHOW_* toggles) inside a herdr
    session. Its Slurm and GPU scripts are the very same rendered files
    tmux uses, symlinked a second time, so the two bars can't drift apart.
  - `herdr-workspace-prefix` — a herdr plugin whose code *is* tracked here
    (`herdr-plugin.toml` + `tag-workspaces.py`); linked into herdr with
    `herdr plugin link` rather than installed from GitHub.
- `oh-my-posh/` — the active prompt theme, `albe-monokai2.omp.json`. Each
  accented part of it — the leading glyph, the machine text, and the bottom
  chevrons for exit 0 and for errors — separately picks the primary, the
  secondary or a neutral foreground. The glyph can instead be set to
  *slurm* mode, where it reports the allocation: primary on a normal shell,
  secondary inside a job.
- `shell/` — portable additions layered on top of each machine's own
  `.bashrc`/`.profile`:
  - `bashrc_additions.sh` — aliases, PATH additions, oh-my-posh/zoxide/fzf
    init, tmux auto-attach, env vars. Sourced from the tail of `~/.bashrc`
    (install.sh appends one `source` line, guarded by a marker comment).
  - `bashrc_functions` — shell functions (currently just `syncop`, a
    generic rsync-between-machines helper).
  - `profile` — symlinked directly to `~/.profile`.
- `lib/derive.sh` — everything computed *from* the answers: the palette, the
  validators, `PRIMARY_DIM`, the `OMP_*` colours and the four assembled status
  line strings. install.sh sources it; the setup UI executes it and parses its
  output, so the preview and the rendered config can never disagree.
- `lib/tools.sh` — the other half of the same split: what gets **installed**
  rather than configured. The catalogue, the sudo detection and every install
  route live here, and the setup UI runs it (`--list`, `--plan`, `--priv`) for
  its checkbox list and its install-plan pane — so, again, the preview and the
  real thing are one piece of code. Adding a tool means editing this file only.
- `tui/configure.py` — the setup UI (see above).
- `bin/` — scripts to drop on every machine. install.sh copies everything here
  into `~/.local/bin` (plain copies, not symlinks, and not templated — this is
  for your own scripts, not machine-specific config, and not for the tools in
  the catalogue above, which have real installers). Currently empty; add files
  here to have them installed.

## Intentionally excluded (machine/cluster-specific)

- Conda `init` block (install path differs per machine — run
  `conda init bash` fresh instead).
- Google Cloud SDK sourcing (path was specific to one cluster workspace mount).
- Workspace aliases like `twist`, `unref`, `gate`, etc. (point at
  `/anvme/workspace/...` paths that only exist on that HPC cluster).
- `jn_tunnel` alias (assumes an SSH host alias `elcap` is configured
  locally — set that up per-machine in `~/.ssh/config` if you want it).
- herdr's machine-local state: `plugins.json` (the install registry, with
  absolute paths and a resolved commit), `plugins/github/` (the plugin
  clone and its `target/` build output), `session.json`, the sockets and
  the logs. herdr rewrites all of these itself.
- The `fusermount3` -> `fusermount` symlink shim (workaround specific to
  one cluster's FUSE setup).

## Templates and `.generated/`

Anything carrying a colour or the machine name is a `*.in` **template** with
`@PRIMARY@` / `@SECONDARY@` / `@MACHINE@` placeholders, because none of
tmux.conf, JSON or TOML can indirect through a variable. `install.sh` renders
every template into `.generated/` (gitignored) and points the real config path
at the rendered copy:

```
tmux/.tmux.conf.in                 tracked, has @PRIMARY@
  -> .generated/tmux/.tmux.conf    rendered, gitignored
       <- ~/.tmux.conf             symlink
```

So `~` still shows what is dotfiles-managed, tracked files stay free of
machine-specific values, and re-running `install.sh` updates live config.
**Edit the `.in` file, never the rendered one** — renders are overwritten and
carry a "GENERATED" header (except JSON, which has no comment syntax).

Templated: `tmux/.tmux.conf`, `tmux/other-sessions.sh`, `tmux/slurm-status.sh`,
`oh-my-posh/albe-monokai2.omp.json`, `herdr/config.toml`,
`claude/themes/*.json`, `herdr/plugins/herdr-file-viewer/config.toml`
(that last one for `@HERDR_CONFIG@`, not colours), and
`herdr/plugins/herdr-statusline/{config.toml,gpu-status.sh}`. Everything
else is symlinked straight out of the repo.

Values the installer computes rather than asks for directly:

- `@MACHINE_LOWER@` — lowercased, for the oh-my-posh prompt and the Claude
  theme name, where the display casing would look wrong.
- `@PRIMARY_DIM@` — the primary scaled 50% toward black, for herdr's sidebar
  rail. herdr has no dedicated border colour (the whole `[theme.custom]` set is
  `surface_dim`, `text`, `accent`, `green`, `yellow`, `red`, `peach`, `mauve`,
  `blue`, `teal`), and that one `surface_dim` token paints the rail *and* the
  selected row's background. Since the workspace names are primary-coloured they
  sit on it when selected, so the rail cannot be the raw primary — that would be
  green-on-green. At 50% it measures ~3.8:1 for the bold row text and ~2.8:1 for
  the rail against the gruvbox panel.
- `@TMUX_STATUS_LEFT@` / `@TMUX_STATUS_RIGHT@` / `@HSL_STATUS_LEFT@` /
  `@HSL_STATUS_RIGHT@` — the fully assembled tmux and herdr-statusline bar
  strings, built by `lib/derive.sh` from the `SHOW_HOST` / `SHOW_GPU` /
  `SHOW_TEMP` / `SHOW_SLURM` / `SHOW_DATETIME` answers. tmux.conf and
  herdr's TOML have no conditional syntax to gate a segment on, so the
  conditional logic lives in `derive.sh` and each template just holds one
  placeholder for the whole bar half.
- `@OMP_ICON_COLOR@` / `@OMP_ICON_COLOR_JOB@` / `@OMP_TEXT_COLOR@` /
  `@OMP_CHEVRON_FG@` / `@OMP_CHEVRON_ERR@` — the oh-my-posh machine segment's
  glyph (outside and inside a Slurm job shell) and text colour, and the bottom
  chevrons for exit 0 and for errors. Each resolves the `OMP_ICON` / `OMP_TEXT`
  / `OMP_CHEVRON_OK` / `OMP_CHEVRON_ERROR` answer — `primary`, `secondary` or
  `neutral` (`#d6deeb`) — to a hex value. Answers saved as the older
  `OMP_COLOR_*` booleans are migrated to their equivalent.
- `@SHOW_TEMP@` — passed straight through into `gpu-status.sh.in` so the GPU
  pill can omit just the temperature reading, independent of the pill itself.

- `@CLAUDE_MODEL_RGB@` / `@CLAUDE_EFFORT_RGB@` / `@CLAUDE_USAGE_RGB@` /
  `@CLAUDE_WEEK_RGB@` / `@CLAUDE_CTX_RGB@` — the Claude Code status line's five
  bubbles, ramped from the primary to the secondary by `claude_ramp()`. They
  used to be a fixed palette of their own (blue/purple/pink/orange/teal); the
  bar now belongs to the same two accents as everything else.
