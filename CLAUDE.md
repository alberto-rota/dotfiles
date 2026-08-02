# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Personal dotfiles synced across machines: tmux, Claude Code global config, oh-my-posh prompt, herdr (terminal workspace manager) config + plugins, and portable shell additions. There is no build/test/lint tooling — this repo *is* the config; the only "runtime" is `./install.sh` plus the Textual setup UI it launches.

## Commands

```
curl -fsSL albertorota.dev/setmeup.sh | bash          # bare machine, no checkout
curl -fsSL albertorota.dev/setmeup.sh | bash -s -- --no-tools   # ...with options

./install.sh                 # installs uv, then prompts (setup UI) on first run
./install.sh --reconfigure   # change the colours / machine name / tool selection
./install.sh --primary '#78dce8' --secondary '#ffd866' --machine proxima -y
./install.sh --skip-uv       # don't install/update uv (offline, CI)
./install.sh --no-tui        # plain text wizard instead of the setup UI
./install.sh --no-tools      # render and link config only, install nothing
./install.sh --tools-only    # install tools only, render and link nothing
./install.sh --help
./reset.sh                   # undo everything install.sh put in place

uv run --script tui/configure.py --dump            # previews to stdout, no UI
uv run --script tui/configure.py --dump --width 40 # ...at a narrow width
bash lib/derive.sh                           # the derived values, KEY=value
bash lib/tools.sh --plan                     # what a tools run would do here
bash lib/tools.sh --list                     # the catalogue, id|label|group|on
bash lib/tools.sh --priv                     # what sudo looks like on this box

uv run --script tui/measure.py               # every pane at widths 120..20
uv run --script tui/test_narrow.py           # the real app at 10 terminal sizes
uv run --script tui/test_panes.py            # panes vs the boxes that hold them
uv run --script tui/test_answers.py          # answers round-trip, grid, catalogue
```

There's no test suite. To validate a change, run `./install.sh` (it's idempotent and safe to re-run) and check the rendered output under `.generated/` and the symlinks it creates in `$HOME`. For a change to the setup UI, `--dump` renders every preview to stdout without needing a terminal to drive, and `App.run_test()` (Textual's headless pilot) can drive the widgets.

## The bootstrap — `curl | bash` with no repo on disk

`albertorota.dev/setmeup.sh` serves this repo's `install.sh`, so the one-liner runs it with **no checkout around it**: bash reads the script from stdin, `BASH_SOURCE` is unset and `$0` is `bash`, so the old `DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` died on `set -u` before doing anything. Worse, `lib/derive.sh`, `lib/tools.sh` and every `*.in` template are simply absent.

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

## Nothing wraps — and it has to keep not wrapping

A wrapped line is not a cosmetic problem here. A wrapped status bar is a *lie about what the bar looks like*, and a wrapped heading or palette row silently changes a widget's height, which shoves everything below it down and makes the panel jump as you type. So both front-ends clip rather than wrap, and both size their content from the width they actually have.

**The UI.** `fit_block()` is the backstop: it clips every line of a pane to the width and sets `no_wrap`/`overflow="ellipsis"`. Every pane also calls it on its own way out, so a pane measured alone reports what it will really occupy — that is what makes the measurement harness meaningful. CSS carries `text-wrap: nowrap` on `#previews Static`, `.section`, `ChoiceRow`, `PaletteGrid` and `Checkbox`, plus `overflow-x: hidden` on `#previews`. `.hint` is the **one deliberate exception** — those are prose and carry their own newlines.

Four places had to be fixed at the source, not just clipped:

- **oh-my-posh** right-aligns its second block to the `--terminal-width` it is told, so a stale `max(width, 40)` produced a 92-cell line in a 46-cell pane. It now gets the real width.
- **herdr** had `inner = max(width - 2, 44)`, which drew a 46-cell box into any pane it was handed and overflowed narrower ones by up to 26 cells. The floor is gone; under 26 cells it returns `(too narrow)` — itself kept short, because the original wording was 31 cells and overflowed the very panes it was apologising for.
- **the install plan** had a fixed 19-cell id column, which alone overflowed a pane under ~22 cells. Both columns are now sized from the width, and the route is dropped rather than wrapped when there is no room.
- **`compose_bar`** gets a final clip: both halves are already truncated, but an ellipsis substituted into a double-width cell can still land one cell over.

**Layout.** Below `SetupApp.NARROW_AT` (88 columns) the two-column split stops being useful — 46 for the controls leaves the previews a sliver — so `on_resize()` sets a `narrow` class and they stack. App CSS outranks `Horizontal`'s own `layout: horizontal`, which is what makes that work.

**The palette grid** sizes itself in `_metrics()`, and **the scheme names take priority over swatch width**: eight 4-cell swatches plus `" catppuccin"` wants 43 cells and the controls panel has 41, which was silently cutting the two longest names to `catppucc` and `tokyonig`. The swatches give up a cell instead (4 → 3 → 2 → 1), and names are shown in **full or not at all** — a half-name is worse than none, since the heading names the scheme you are on. For the same reason the heading shows only the accent being *edited*: both at once is 43 cells before the word "Colours".

**The text wizard** gets its width from `term_cols()` (stty on the real terminal, then `tput`, then 80; never below 20) and sizes the swatch ribbon from it the same way. `section()` exists because the headings used to be parenthetical tails — `"Machine name  (shown in the tmux bar and the shell prompt)"` is 60 cells — so the hint moved onto its own line. `bar_seg()` gives the sample status bar a cell budget and drops pills from the right, which is what tmux does to a bar too wide for its window; `BAR_DROPPED` adds the `…`. Every prompt string is kept short enough to fit ~38 columns.

Two things deliberately left alone: `omp_live_preview` has **no `cut` backstop**, because `cut -c` counts characters rather than display cells and this stream is mostly colour escapes — it would hack the prompt apart long before its visible end, and clipping ANSI-plus-nerd-font text by cell in portable awk risks mojibake instead. And oh-my-posh's own prompt can exceed a terminal under ~60 columns, which is exactly what the real prompt does there too. Its output is piped through `awk '{ print "    " $0 }'` rather than `sed 's/^/    /'` because oh-my-posh emits no trailing newline and `awk`'s `print` always adds one — without that the sample status bar printed onto the end of the prompt line.

**Each pane is sized by its own widget's `content_size`, never by one shared estimate.** That was `#previews`.content_size minus a hardcoded 4 — but `.preview.wide` carries no padding while `.preview` does, and the scrollbar takes two cells more, so the single figure was right for three panes and two cells too generous for the other two. The herdr box is drawn to fill its width *exactly*, so those two cells wrapped all eleven of its lines in half, at every terminal size. `#previews` is `overflow-y: scroll` rather than `auto` for the same reason: with `auto` the scrollbar appears *because* of what was just rendered, shrinking every pane after the fact. `_apply()` additionally re-renders if a width moved under it (a resize racing the worker), which converges on the next pass.

To check a change here, three harnesses, and they catch different things:

- `tui/measure.py` — every pane at widths 120 → 20, asserting the pane's own output fits the width it was given;
- `tui/test_narrow.py` — the real app at ten terminal sizes, asserting no rendered line exceeds the *terminal*;
- `tui/test_panes.py` — the real app again, asserting each pane fits **the box that holds it** and is not drawn taller than its own line count. This is the one that catches wrapping *inside* a bordered container, which the other two cannot: wrapping does not make the screen wider, it makes the box taller. Every pane failed it at every size until the sizing above was fixed.

## lib/derive.sh — the one source of truth for computed values

Everything derived *from* the answers lives in `lib/derive.sh`: the palette, `valid_hex`/`valid_machine`, `darken()`, and `derive()`, which computes `PRIMARY_DIM`, `MACHINE_LOWER`, `USER_NAME`, the four `OMP_*` colours and the four assembled status-line strings. install.sh sources it and calls `derive`; `tui/configure.py` executes it (`bash lib/derive.sh`, emit mode prints `KEY=value` lines) and parses the result. That is why the preview cannot drift from what gets installed — there is only one assembly, and both front-ends run it. **Add a derived value there, not in install.sh.**

## lib/tools.sh — what gets INSTALLED, as opposed to configured

The other half of the derive.sh split, and the same two-consumer shape: install.sh sources it and calls `install_tools()`; `tui/configure.py` executes it (`--list` for its checkbox list, `--plan` for the install-plan preview pane, `--priv` for the sudo one-liner). The plan the UI shows is therefore resolved by the code that does the installing, not by a Python guess at it.

**Sudo is detected, not assumed.** `detect_privilege()` sets `PRIV_MODE` to one of `root` / `passwordless` / `password` / `none`. The interesting case is the last two being told apart: `sudo -nv` says *"a password is required"* for a real sudoer and *"is not in the sudoers file"* for everyone else, and **an explicit refusal beats the group-membership fallback below it** — being in group `sudo` does not make you a sudoer, and believing it would send every apt route into a wall of failures. The group check only runs when the message is unrecognised (a locale we have no string for).

In `password` mode nothing prompts until a privileged command is actually needed: `sudo_unlock()` asks **once**, up front, then keeps the timestamp warm with a background refresher that polls for its parent (so a `kill -9` of install.sh cannot orphan it). Declining is not fatal — `PRIV_MODE` drops to `none` and every later route resolves to its userland alternative. With no terminal to ask on (`curl | bash`, CI, `-y`) it doesn't try.

**One route list, not two installers.** Each tool has an ordered list of routes and takes the first this machine can use. The system route (apt, or Homebrew on macOS) needs privilege; every other one — rustup/cargo, `uv tool install`, a release tarball, a git clone — lands entirely in `$HOME`. The sudo/no-sudo split is just that first entry dropping out. apt is the only system package manager wired up on Linux: on dnf/pacman the system route is simply unavailable and everything falls through to the userland routes, which is also what happens on an HPC login node.

`tool_route()` is the single decision point, used by both `--plan` and `install_tools()`. It reads the `AVAIL_APT` / `AVAIL_CARGO` / `AVAIL_UV` / `AVAIL_BREW` / `AVAIL_GIT` flags, which start from what is on the machine now and are **flipped on as the walk passes a provider it is going to install** (`providers_seen()`, called from all four places that advance the walk) — that is what lets `eza: cargo` be true on a box with no cargo yet, because `rust` is listed above it, and `fzf: git` be true on a Mac whose git arrives with Homebrew two lines earlier.

A route may also come back with the method `na`, which means *there was never anything to do here* — Homebrew on a machine that needs nothing from it, `nvtop` on a Mac. Both the plan and the run report that as a skip rather than as a machine that fell short, which is the distinction an empty method (genuinely blocked) carries.

**Homebrew is bootstrapped only when it is the sole remaining route** to something actually selected (`brew_needed()`) — a ~1GB install is not worth doing on spec. On Linux that means `nvtop` with no apt, or eza/fd/bat/delta with no apt *and* no cargo coming. On macOS it means git or Tailscale, neither of which has any other route at all. glow and neovim never count towards it on either: their release tarballs work everywhere.

Ordering is the array order of `TOOL_META`, which is topological — a tool may only depend on one listed above it. `tool_deps()` holds only the hard ones (LazyVim needs neovim; both herdr plugins need herdr). bat/delta/glow are deliberately *not* dependencies of `herdr-file-viewer`: it installs and runs fine without them and just falls back to plain text.

**`brew` is listed ahead of `git`**, which is the one ordering that does not read as obvious. On macOS git has no route *except* Homebrew — its installer pulls in the Xcode Command Line Tools, git included — so git has to come after it. On Linux the dependency runs the other way (brew bootstraps by cloning its own repo with git), but that costs nothing: the only Linux machine where brew is wanted *and* git is missing is one with no apt either, and there git is unobtainable in either order.

Answers are one `TOOL_<ID>=0|1` per catalogue entry in theme.env, appended by `tools_answers()` rather than spelled out in install.sh's heredoc — so adding a tool needs no edit there. **Unset means on**, which is what makes a newly-added tool install itself on a machine whose theme.env predates it (`tools_defaults()`).

Three things each installer is careful about, all the same hazard: `rustup` gets `--no-modify-path`, `fzf` gets `--no-update-rc`, and uv gets `UV_NO_MODIFY_PATH` — left alone all three append to `~/.profile`, which **on an already-installed machine is a symlink into this repo**, so the edit would land in tracked dotfiles. `install_lazyvim()` refuses to touch a `~/.config/nvim` that already has files in it and returns 2, which the orchestrator prints as "left alone" rather than counting as a failure. Nothing in the phase is ever fatal: a failed tool is recorded and the run continues.

PATH goes out two ways. Permanently through `~/.config/dotfiles/tools-env.sh` (written by `tools_write_env()`, sourced by `bashrc_additions.sh` — same shape as `uv-env.sh`, and the reason Homebrew gets a full `brew shellenv` rather than just its bin dir). And for the terminal the install ran in, `print_path_hint()` prints a copy-paste `export PATH=...`, compared against `TOOLS_ORIG_PATH` — the PATH as it was when the phase *started*, because `install_rust()` and `install_neovim()` prepend to install.sh's own PATH so later steps can use what they just installed, and checking the live one would report every such directory as already handled.

**`PREVIEW_TOOLS` (`ohmyposh`, `jq`) are installed *before* the wizard opens**, by `install_preview_prereqs()`. The preview panes are the real prompt and the real Claude status line; without oh-my-posh the prompt pane is a hand-drawn approximation and without jq the Claude pane is the string "needs jq on PATH", which is exactly what the whole previews-are-real design exists to avoid. Two rules make that pre-pass safe: it **never prompts** (a machine needing a sudo password is treated as unprivileged for the duration, since both tools have userland routes — being asked for a password before the first question is a poor greeting), and a failure is silent and harmless, just restoring the old fallbacks. It also puts `~/.local/bin` on PATH, since the UI is a child process that inherits it.

Two installers deliberately avoid the "official" route. **oh-my-posh** takes its bare release binary rather than `ohmyposh.dev/install.sh`, because that script requires `unzip` (it also fetches the themes archive) and a slim container or login node may not have it — and the themes are unwanted here anyway, since the one theme this repo uses is rendered from its own template. The script stays as a fallback. **jq** likewise takes `releases/latest/download/jq-<os>-<arch>`, a permanent redirect that needs no API call and cannot be rate-limited; `fetch_bin()` handles projects shipping a bare binary, `fetch_bin_from_tarball()` those shipping an archive, and `arch_deb()` gives the amd64/arm64 spelling those assets use (`arch_tag()` gives the x86_64/arm64 one). The OS half needs two helpers, not one, because the projects disagree: `os_darwin()` gives oh-my-posh's and glow's `darwin`, `os_macos()` gives jq's and Neovim's `macos`.

**git and Tailscale** are the two entries whose routes are shaped by something other than convenience. git is a *provider* as much as a tool — fzf, LazyVim and Homebrew's own Linux bootstrap all clone with it — hence `AVAIL_GIT`. Its own route is apt, then an available Homebrew, then blocked; on macOS "blocked" carries the `xcode-select --install` hint, because that is the other way out. Tailscale takes the official installer when there is privilege on Linux (it picks the distro package and sets up the systemd unit, which is what makes a real node) and the static tarball when there is not — that still gives a working CLI and daemon, but the daemon must be started by hand in userspace-networking mode. On macOS neither exists: there is no darwin tarball and the install script refuses to run, so it is the brew formula plus a `brew services start` (the App Store build is a GUI app with a sandboxed CLI). `print_next_steps()` spells out whichever of the three applies rather than leaving it to be discovered. `tailscale up` is never run for you: it opens a browser to authenticate the node.

`print_next_steps()` is the single copy-and-paste block at the end of a run — the PATH export for *this* shell, any Tailscale step, and `source ~/.bashrc` last, since that is what makes the current shell match every future one. It warns when that last line will start herdr (hsl-at-login on). `needs_tailscale_up()` decides the Tailscale step by looking for peer IPs in `tailscale status`; anything else — "Logged out.", no daemon, a permission error — means there is still an `up` to run.

Tools are **not** recorded in the manifest: `reset.sh` undoes this repo's config, not the software on the machine.

## macOS: bash 3.2, and a BSD userland

Linux and macOS are both supported, and the macOS half is the one that is easy to break without noticing, because **nothing here fails at parse time** — a GNU-only flag just silently does the wrong thing.

**Every shell file in this repo must run under bash 3.2.** That is what `/bin/bash` is on macOS, it is what `curl … | bash` therefore gets, and Apple will not be shipping a newer one (bash 4 went GPLv3). So: no `declare -A`, no `${var^^}` / `${var,,}`, no `mapfile`/`readarray`, no `exec {fd}<…`, no `&>>`. `to_lower()` in `lib/derive.sh` and `tool_var()` in `lib/tools.sh` exist for the two folding cases; `TTY_FD` is the literal `3`; the tool catalogue is a flat `TOOL_META` table.

That failure mode is worth remembering because it is not graceful. `declare -A TOOL_LABEL=([git]="git" …)` under 3.2 parses `[git]` as an *arithmetic subscript*, so with `set -u` the whole install died on line one of the catalogue with **`lib/tools.sh: line 164: git: unbound variable`** — a message that names git and has nothing to do with git.

The BSD-userland traps that were actually hit, all of which had a GNU-only spelling that worked fine on Linux:

| don't | do | because |
| --- | --- | --- |
| `sed -i 'PROG' f` | filter to a temp file, `cat` it back | BSD `-i` takes a **mandatory** backup suffix, so it reads the program as the suffix |
| `sed '1a text'` | `head -1` + `echo` + `tail -n +2` | BSD's `a` wants a backslash and a real newline |
| `sed 's/\x1b//'` | splice the byte in with `$'\033'` | BSD sed reads `\x1b` as the literal text `x1b` |
| `sed 's/\(a\|b\)//'` | `sed -E 's/(a\|b)//'` | BRE alternation `\|` is a GNU extension, not POSIX |
| `awk '… strtonum("0x" x)'` | decode hex with `index()` | `strtonum` is gawk-only; macOS has the one true awk |
| `date -d @N` / `date -d STR` | try GNU, then `date -r N` / `date -j -f FMT STR` | no shared syntax at all |
| `mktemp f.XXXXXX.json` | `mktemp -d` and name the file inside | BSD only substitutes a run of Xs at the **end** |
| `paste -sd:` | `paste -sd: -` | BSD paste requires a file operand |
| `find … -print -quit` | `… \| head -n 1 \|\| true` | `-quit` is not in every BSD find (`\|\| true` covers the SIGPIPE under `pipefail`) |

**`/usr/bin/git` exists on a Mac with no developer tools.** It is a stub that passes `command -v`, pops a GUI installer when run, and fails — so `have git` says yes and every clone then breaks. `have_git()` asks `xcode-select -p` instead, which answers without triggering the dialog, and only bothers for `/usr/bin/git` (a Homebrew git is taken at face value). install.sh's bootstrap carries its own copy as `bootstrap_have_git()` — it cannot share one, because at that point in the script there is no `lib/` on disk yet. Getting this wrong means refusing to install rather than falling through to the tarball that would have worked.

**The machine name is sanitised, not validated, when it comes from the host.** macOS hands out `Alberto's MacBook Pro` and 30-character Bonjour names, both of which `valid_machine()` rejects — and aborting the install over a default nobody typed is not a useful answer. `default_machine()` folds anything else to `-` and truncates to 24. A name given with `--machine` or typed at either wizard is still validated and still rejected; that one someone chose.

**Login shells.** bash reads the first of `~/.bash_profile`, `~/.bash_login`, `~/.profile` that exists and stops. This repo symlinks `~/.profile`, so a pre-existing `~/.bash_profile` shadows the entire install — and Terminal.app opens a *login* shell for every window, where a Linux terminal usually opens an interactive non-login one that reads `~/.bashrc` directly. install.sh appends a marked block sourcing `~/.bashrc` to `~/.bash_profile`, but **only when that file already exists**: creating one would take `~/.profile` out of the chain rather than put it in. `reset.sh` strips both blocks.

To check a change here, there is no macOS in CI, so build the shell instead — `bash-3.2.57` from ftp.gnu.org compiles in about a minute (`./configure --build=<host-triple> --without-bash-malloc CFLAGS="-Wno-implicit-function-declaration -std=gnu89"`; its `config.guess` is too old to recognise aarch64 unaided). `bash -n` is *not* enough: `${1,,}` and `mapfile` are runtime failures, not parse errors. Run the real entry points. `uname` is read once into `OS_KERNEL`, so a stub `uname` early on PATH is all it takes to exercise the Darwin routes on Linux.

## The hsl login autostart

`HSL_LOGIN` is the one answer that changes what opening a terminal does, so it is the one that can lock you out of a machine you only reach over ssh. It is therefore **off by default**, and `shell/hsl-login.sh.in` is deliberately paranoid about it:

- it is **sourced**, never executed, so every exit path is `return` — an `exit` would close the login shell;
- `hsl` is **run, not `exec`ed**, so quitting herdr drops you into a normal shell rather than ending the session;
- `NO_HSL=1` is the escape hatch (`NO_HSL=1 bash -l`), checked before anything else;
- `DOTFILES_HSL_STARTED` (exported) makes it once-per-login — `~/.bashrc` gets re-sourced constantly, not least by this repo's own `rebash` alias, and each of those would otherwise stack another herdr;
- it bails on: a non-interactive shell (`case $- in *i*`), `SSH_ORIGINAL_COMMAND` (scp/rsync break outright if a login shell writes to stdout), **being inside herdr already** (`HERDR_ENV`/`HERDR_PANE_ID`/`HERDR_SOCKET_PATH`/`HERDR_WORKSPACE_ID` — every pane herdr spawns runs `~/.bashrc`, so without this the first thing a new pane does is start a second herdr inside itself), `TMUX`, an agent shell (`CLAUDECODE`/`AI_AGENT`), no tty on both ends, `TERM=dumb`, and `hsl` not being on PATH at all.

The answer is baked in at render time rather than re-read per shell, so "off" is a file that returns on its second line. It is sourced from the **very end** of `bashrc_additions.sh`: when it does start herdr it blocks until you quit, so anything after that line would not run until then.

`hsl` itself ships with the herdr-statusline plugin (it is a generated launcher — do **not** put it in `bin/`), which is a separate answer, so it can legitimately be absent; install.sh prints a NOTE for that combination rather than failing.

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
- A new **tool**, by contrast, needs editing exactly one file: add one `id|label|group` row to `TOOL_META` (in dependency order — `TOOL_IDS` is derived from it), then a `tool_present` probe, a `tool_route` case and an `install_<id>()`. Both front-ends pick it up from the catalogue, theme.env gains its line automatically, and it defaults to on. Add a `tool_deps()` case only if it genuinely cannot be installed before something else. Give the route a macOS answer as well as a Linux one, even if that answer is `na|…`.
- The palette is 48 colours as **six rows of eight, each row one real scheme** (`PALETTE_ROWS`: monokai, catppuccin, dracula, nord, tokyonight, neon), and it lives **only** in `lib/derive.sh`. install.sh used to carry its own copy of the first eight, which meant the text wizard silently offered a different set from the UI — don't reintroduce that. Only each scheme's *accent* ramp is included, never its backgrounds or greys: the primary is used as a **background with black text on it** (both status bars, the Claude Code bubbles), so a dark entry would be unreadable there. Hexes are unique across all six rows — the UI marks "your primary is here" by hex lookup, so a duplicate would show two markers. `PALETTE=name:hex:scheme` is the emit format; `palette_index()`/`palette_group_of()`/`palette_label()` turn a hex back into "monokai / pink".
- Both front-ends dropped the 48-numbered-lines menu. The text wizard picks in **two steps** (scheme, then colour within it — six ribbon rows, with `<-` on the row holding the current colour); the UI has **one** `PaletteGrid` for both accents instead of two `PaletteRow`s, marking primary `P` / secondary `S` / `PS` inside the swatch itself, which removes the pointer line *and* the duplicate grid. `p`/`s`, the "editing" ChoiceRow, or clicking a swatch chooses which accent the arrows move.
- `SetupApp._inputs_live` is **not** called `_ready` — `App` already has a `_ready()` method, and shadowing it crashes the app on start. It exists because Textual posts `Input.Changed` for an Input's *initial* value as it mounts, and `_hex_typed()` treats a change as "the user is working on this accent"; without the flag the secondary hex box, purely by mounting last, left the grid editing secondary before the user touched anything.
- `#>>` -prefixed lines in a `.in` template are template-only comments and get stripped by `render()` — use them for notes that shouldn't appear in the rendered/live config.
- `render_script()` inserts the GENERATED header as line 2 (after the shebang, which must stay on line 1) and `chmod +x`s the output.
- `link()`/`copy()` back up any real file at the destination as `<file>.bak` before taking it over — safe to re-run against a machine with pre-existing dotfiles. See "Backup + reset" above.
