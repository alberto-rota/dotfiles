# dotfiles

Personal machine config, synced across machines. Run `./install.sh` on a
new machine: it asks for the two accent colours and the machine name, shows
a preview, then installs everything (idempotent, backs up any real file it
would overwrite as `<file>.bak`).

```
./install.sh                 # prompts on the first run, reuses the answers after
./install.sh --reconfigure   # change the colours / machine name
./install.sh --primary '#78dce8' --secondary '#ffd866' --machine proxima -y
./install.sh --help
```

Answers are saved to `~/.config/dotfiles/theme.env`, so later runs re-render
without prompting — which is what you want after editing a template. Add `-y`
to guarantee no prompt (for a scripted or headless run).

## Layout

- `tmux/` — `.tmux.conf.in` (mouse mode on by default, accent-coloured
  borders/status bar, popups) plus the two scripts it shells out to for
  the status bar:
  `other-sessions.sh` (session list) and `slurm-status.sh` (Slurm job
  status — degrades to "no jobs" if `squeue` isn't available).
- `claude/` — Claude Code global `settings.json`, `keybindings.json`,
  `statusline-command.sh`, and custom themes (`themes/*.json`). Per-project
  Claude settings (`settings.local.json`, project `.claude/` dirs) are
  **not** synced here — those stay per-project.
- `herdr/` — the terminal workspace manager's `config.toml.in` (keybindings,
  sidebar rows, theme overrides) plus the `herdr-file-viewer` plugin's own
  config: `plugins/herdr-file-viewer/config.toml.in` (a **template** —
  install.sh renders it with the machine's config dir, because the glow
  style argument has to be an absolute path) and the Monokai glow palette
  it points at, `markdown-monokai.json`. The plugin itself is **not**
  synced — install it per machine with
  `herdr plugin install smarzban/herdr-file-viewer`. Its content pane wants
  `bat`, `delta` and `glow` on PATH, all three themed Monokai; without them
  the viewer degrades to plain text.
- `oh-my-posh/` — the active prompt theme, `albe-monokai2.omp.json`.
- `shell/` — portable additions layered on top of each machine's own
  `.bashrc`/`.profile`:
  - `bashrc_additions.sh` — aliases, PATH additions, oh-my-posh/zoxide/fzf
    init, tmux auto-attach, env vars. Sourced from the tail of `~/.bashrc`
    (install.sh appends one `source` line, guarded by a marker comment).
  - `bashrc_functions` — shell functions (currently just `syncop`, a
    generic rsync-between-machines helper).
  - `profile` — symlinked directly to `~/.profile`.

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
`claude/themes/*.json`, and `herdr/plugins/herdr-file-viewer/config.toml`
(that last one for `@HERDR_CONFIG@`, not colours). Everything else is
symlinked straight out of the repo.

Two derived values the installer computes rather than asks for:

- `@MACHINE_LOWER@` — lowercased, for the oh-my-posh prompt and the Claude
  theme name, where the display casing would look wrong.
- `@SECONDARY_DIM@` — the secondary scaled toward black. herdr has no separate
  selection colour, so one token (`surface_dim`) paints the selection
  background *and* the sidebar rail; the raw secondary is bright enough that
  primary-coloured workspace names on top fall to ~2:1 contrast, while the
  darkened version holds around 4:1 and still reads as a border.

Note that `claude/statusline-command.sh` is deliberately **not** themed — its
bubbles use a distinct per-field palette (blue model, purple effort, pink
usage, orange weekly, teal context), not the accent pair.
