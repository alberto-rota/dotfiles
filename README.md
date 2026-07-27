# dotfiles

Personal machine config, synced across machines. Run `./install.sh` on a
new machine to symlink everything into place (idempotent, backs up any
real file it would overwrite as `<file>.bak`).

## Layout

- `tmux/` — `.tmux.conf` (mouse mode on by default, yellow/blue theme,
  popups) plus the two scripts it shells out to for the status bar:
  `other-sessions.sh` (session list) and `slurm-status.sh` (Slurm job
  status — degrades to "no jobs" if `squeue` isn't available).
- `claude/` — Claude Code global `settings.json`, `keybindings.json`,
  `statusline-command.sh`, and custom themes (`themes/*.json`). Per-project
  Claude settings (`settings.local.json`, project `.claude/` dirs) are
  **not** synced here — those stay per-project.
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
- `jn_tunnel` alias (assumes an SSH host alias `alex` is configured
  locally — set that up per-machine in `~/.ssh/config` if you want it).
- The `fusermount3` -> `fusermount` symlink shim (workaround specific to
  one cluster's FUSE setup).

## Colors

Primary `#ffea02` (yellow) / secondary `#03a1fc` (blue) — defined directly
in `tmux/.tmux.conf` (borders, status bar, popups, message line) and
mirrored in the two status-bar scripts and the oh-my-posh theme.
