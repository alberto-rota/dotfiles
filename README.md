# dotfiles

Personal machine config, synced across machines. Run `./install.sh` on a
new machine: it asks for the two accent colours, the machine name, which
status line components to show, and how oh-my-posh applies its accent
colours, shows a preview, then installs everything (idempotent, backs up
any real file it would overwrite as `<file>.bak`).

```
./install.sh                 # prompts on the first run, reuses the answers after
./install.sh --reconfigure   # change the colours / machine name
./install.sh --primary '#78dce8' --secondary '#ffd866' --machine proxima -y
./install.sh --help
./reset.sh                   # undo: remove everything install.sh put in place
```

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

## Layout

- `tmux/` — `.tmux.conf.in` (mouse mode on by default, accent-coloured
  borders/status bar, popups) plus the two scripts it shells out to for
  the status bar: `other-sessions.sh` (session list), `slurm-status.sh`
  (Slurm job status — degrades to "no jobs" if `squeue` isn't available),
  and the shared `gpu-status.sh` (see herdr-statusline below). Which of the
  host/GPU/temperature/Slurm/date-time pills actually show is chosen in the
  install.sh wizard, not hardcoded here.
- `claude/` — Claude Code global `settings.json`, `keybindings.json`,
  `statusline-command.sh`, and custom themes (`themes/*.json`). Per-project
  Claude settings (`settings.local.json`, project `.claude/` dirs) are
  **not** synced here — those stay per-project.
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
- `oh-my-posh/` — the active prompt theme, `albe-monokai2.omp.json`. The
  install.sh wizard also chooses whether the leading glyph, the machine
  text, and the bottom exit-status chevrons pick up the accent colours or
  fall back to a neutral foreground.
- `shell/` — portable additions layered on top of each machine's own
  `.bashrc`/`.profile`:
  - `bashrc_additions.sh` — aliases, PATH additions, oh-my-posh/zoxide/fzf
    init, tmux auto-attach, env vars. Sourced from the tail of `~/.bashrc`
    (install.sh appends one `source` line, guarded by a marker comment).
  - `bashrc_functions` — shell functions (currently just `syncop`, a
    generic rsync-between-machines helper).
  - `profile` — symlinked directly to `~/.profile`.
- `bin/` — binaries/scripts to drop on every machine. install.sh copies
  everything here into `~/.local/bin` (plain copies, not symlinks, and not
  templated — this is for prebuilt tools, not machine-specific config).
  Currently empty; add files here to have them installed.

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
  strings, built by install.sh from the `SHOW_HOST` / `SHOW_GPU` /
  `SHOW_TEMP` / `SHOW_SLURM` / `SHOW_DATETIME` wizard answers. tmux.conf and
  herdr's TOML have no conditional syntax to gate a segment on, so the
  conditional logic lives in install.sh and each template just holds one
  placeholder for the whole bar half.
- `@OMP_ICON_COLOR@` / `@OMP_TEXT_COLOR@` / `@OMP_CHEVRON_FG@` /
  `@OMP_CHEVRON_ERR@` — the oh-my-posh machine segment's glyph and text
  colour, and the bottom chevron line's success/error colour, each either
  the accent colour or the neutral fallback `#d6deeb` depending on the
  `OMP_COLOR_ICON` / `OMP_COLOR_TEXT` / `OMP_COLOR_CHEVRON` wizard answers.
- `@SHOW_TEMP@` — passed straight through into `gpu-status.sh.in` so the GPU
  pill can omit just the temperature reading, independent of the pill itself.

Note that `claude/statusline-command.sh` is deliberately **not** themed — its
bubbles use a distinct per-field palette (blue model, purple effort, pink
usage, orange weekly, teal context), not the accent pair.
