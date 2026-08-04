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
./install.sh --shell zsh     # wire up only zsh (auto | bash | zsh | both)
./install.sh --no-tui        # plain text wizard instead of the setup UI
./install.sh --no-tools      # render and link config only, install nothing
./install.sh --tools-only    # install tools only, render and link nothing
./install.sh --help
./reset.sh                   # undo everything install.sh put in place

dotfiles reconfigure         # the CLI: any of the above, from any directory
dotfiles update              # git pull --ff-only, then install -y
dotfiles backups             # every .bak on the manifest, and its fate
dotfiles uninstall           # reset.sh (removes the CLI itself too)
dotfiles purge               # uninstall, THEN delete the checkout + answers
dotfiles path                # where the checkout is
dotfiles help

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

- **already a checkout at `$DOTFILES_DIR`** — refresh it in place and install from it; never re-clone over it. With a `.git` and a usable git that is `git pull --ff-only`; with the `.dotfiles-tarball` stamp (below) it is a refetch of the tarball; with neither it is a NOTE and the checkout is used exactly as it stands. Every branch is non-fatal — local edits, a diverged branch or no network are all reasons to use what's there, not to refuse to install;
- **absent or empty** — full `git clone` (not `--depth 1`: this is a repo you commit to, and every machine starting shallow just means unshallowing later);
- **no git** — codeload tarball, `--strip-components 1`, plus a `.dotfiles-tarball` stamp in the result. Still a usable checkout, just not a git one. git is itself in the tools catalogue;
- **non-empty and not ours** — refuse, exit 1, touch nothing.

The stamp is the whole reason a non-git checkout can be refreshed at all: re-extracting an archive over a directory is only safe when every file in it is known to be ours, and a `.git`-less directory somebody assembled by hand is not that. It is written by `fetch_tarball()`, which is also the create path, so the two can't disagree.

Overridable by env: `DOTFILES_DIR`, `DOTFILES_SLUG`, `DOTFILES_BRANCH`, `DOTFILES_REPO`, `DOTFILES_TARBALL`.

Two details worth keeping. `DOTFILES_BOOTSTRAPPED=1` is exported before the `exec` so a fetched copy that still can't find its own lib gives one clear error instead of forking forever. And the `exec` redirects stdin from `/dev/tty` when there is one — stdin is the exhausted curl pipe, and handing over the real terminal is what lets the setup UI and the text wizard take their normal paths instead of their no-tty fallbacks. The `(exec 3</dev/tty)` probe is the same subshell trick used further down for `TTY_FD`: `/dev/tty` can exist but be unopenable (cron, CI, a container with no controlling terminal).

The clone is over HTTPS, since a fresh machine has no SSH key. That's fine for pulling; to push, `git -C ~/dotfiles remote set-url origin git@github.com:alberto-rota/dotfiles.git`.

**A change to install.sh only reaches new machines once it is pushed** — the one-liner fetches whatever `main` currently serves, not what is in your working tree.

## uv, and the setup UI

`install.sh` installs uv (`curl -LsSf https://astral.sh/uv/install.sh | sh`) before it asks anything, because the wizard *is* a uv script: `tui/configure.py` declares `textual` in a PEP 723 header, so `uv run --script` fetches both Python and Textual — nothing to preinstall, nothing left behind.

Two things about that install are deliberate:

- **`INSTALLER_NO_MODIFY_PATH=1`.** Left alone, the astral installer appends its PATH line to `~/.bashrc` *and* `~/.profile` — and on a machine this repo has already installed, `~/.profile` is a symlink into the repo, so that edit would land in tracked dotfiles. install.sh persists the PATH itself instead, writing `~/.config/dotfiles/uv-env.sh` (which `shell/shellrc_additions.sh` sources) with uv's actual install dir. With `NO_MODIFY_PATH` the installer also skips writing its own `~/.local/bin/env`, which is why `uv-env.sh` does the `case`-guarded export itself and only sources that file `[ -f ]`.
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

**`priv_summary()` reports whether privilege is any USE here, not whether you have it.** Both front-ends print it beside the tool list, and it used to say `passwordless sudo -- apt available` on any box with sudo and no apt — Fedora, Arch, openSUSE, or an HPC node — while every route underneath it said `needs apt`. apt is the only system package manager wired up on Linux, so no apt means sudo buys nothing and the userland routes are what will run; that case now reads `sudo, but no apt -- $HOME routes`. macOS is the exception and stays as it was, because there the system route is Homebrew, which admin can *install* rather than having to already have.

**`install_preview_prereqs()` puts `PRIV_MODE` back when it is done.** It deliberately treats a password-sudo machine as unprivileged for its own duration (being asked for a password before the first question is a poor greeting, and both preview tools have userland routes) — but it used to leave that pessimism behind in install.sh's process. install.sh has *already* resolved and printed the real answer by then, so the text wizard went on to head its tool list `no sudo -- installs under $HOME` on a machine that has sudo, and `install_tools()` then re-resolved and used apt anyway. The plan disagreeing with the run is the one thing this file exists to prevent, so the downgrade is saved and restored around the pre-pass.

**`tools_plan()` prepends `~/.local/bin` exactly as `install_tools()` does**, and for the same reason spelled out under `install_tools()` below: without it the plan and the run disagree about every tool a *previous* run installed there. On a machine whose login shell never added that directory (it did not exist at login, so Debian's `~/.profile` skipped it), `have git` answers "no" about the git sitting in it — so the plan said `install` where the run then said `already installed`. Only the plan process's own PATH is touched, which is not a side effect on the machine.

**One route list, not two installers.** Each tool has an ordered list of routes and takes the first this machine can use. The system route (apt, or Homebrew on macOS) needs privilege; every other one — rustup/cargo, `uv tool install`, a release tarball, a git clone — lands entirely in `$HOME`. The sudo/no-sudo split is just that first entry dropping out. apt is the only system package manager wired up on Linux: on dnf/pacman the system route is simply unavailable and everything falls through to the userland routes, which is also what happens on an HPC login node.

`tool_route()` is the single decision point, used by both `--plan` and `install_tools()`. It reads the `AVAIL_APT` / `AVAIL_CARGO` / `AVAIL_UV` / `AVAIL_BREW` / `AVAIL_GIT` flags, which start from what is on the machine now and are **flipped on as the walk passes a provider it is going to install** (`providers_seen()`, called from all four places that advance the walk) — that is what lets `eza: cargo` be true on a box with no cargo yet, because `rust` is listed above it, and `fzf: git` be true on a Mac whose git arrives with Homebrew two lines earlier.

A route may also come back with the method `na`, which means *there was never anything to do here* — Homebrew on a machine that needs nothing from it, `herdr-statusline` on a Mac. Both the plan and the run report that as a skip rather than as a machine that fell short, which is the distinction an empty method (genuinely blocked) carries.

**Homebrew is bootstrapped only when it is the sole remaining route** to something actually selected (`brew_needed()`) — a ~1GB install is not worth doing on spec. On Linux that means eza/fd/bat/delta with no apt *and* no cargo coming — there is no Linux-only case left since `nvtop` was dropped for `nvitop`, which is a `uv tool install`. On macOS it means git or Tailscale, neither of which has any other route at all. **`tmux` is the one entry that counts on both**, for the reason in its route below. glow and neovim never count towards it on either: their release tarballs work everywhere. The tests there are `tool_selected`/`tool_present`, never `tool_route` — the routes ask `brew_needed()` themselves, so that would recurse.

**`brew_needed()` is "is Homebrew wanted", which is not "will it be here"** — and every route that falls back to Homebrew wants the second question. The brew row resolves it two branches further down: the official installer needs admin on macOS, and every other route is a git clone of Homebrew's own repo. So on a **bare Mac** — no admin, and a `/usr/bin/git` that is only a shim — "wanted" was yes while the brew row itself was `blocked`, and five routes (`tmux`, eza/fd/bat/delta) advertised a Homebrew install the run could never perform. That is the plan disagreeing with the run, the one thing this file keeps insisting on. `brew_obtainable()` mirrors those branches and `brew_coming()` is what the fallbacks now ask; `AVAIL_BREW` alone would not do either, since `install_tmux()`/`install_git()` re-resolve their own route outside the ordered walk. A no-admin Mac now reports `tmux|blocked|needs Homebrew` and still installs everything with a `$HOME` route (rust, claude, herdr, neovim, glow, jq, oh-my-posh, zoxide).

**`tmux` is apt, an existing Homebrew, conda-forge, a bootstrapped Homebrew, or a clear no** — the one tool whose config this repo cares about most, and for a long time the one with no userland route at all. Upstream ships source only, and building it wants libevent and ncurses headers, which is the whole problem `buildtools` exists to sidestep; the static builds on GitHub are third-party and version-lagging, not something to put on every machine on this repo's authority. macOS is not exempt — it ships `screen`, not tmux. conda-forge is what closed that gap (see below): it has a current tmux for all four platforms, so the blocked case is now genuinely rare rather than "every HPC login node, which happens to have come with tmux anyway".

### conda-forge via micromamba — the answer to "no sudo, no apt, no brew"

The newest provider, and the one that exists because of a specific embarrassment: on a bare machine with no apt, no Homebrew and no git — an HPC login node, a slim container, a Mac with no admin — **13 of the 25 catalogue entries resolved to `blocked`**. git was the worst of them, because half the catalogue clones with it: no git means no fzf, no LazyVim, and no way to bootstrap Homebrew on Linux either, so the one missing tool took four more down with it.

conda-forge fixes it, and micromamba is how it is reached: a **single static binary at a permanent-redirect URL** (`micromamba-releases/releases/latest/download/micromamba-<platform>`), so it is `fetch_bin()` and nothing else — no privilege, no Python, no archive, no `unzip`, no API call to be rate-limited. Exactly the shape jq and oh-my-posh already take, which is why it was chosen over the anaconda/miniforge installers. conda-forge then has current builds of **git, tmux, eza, fd-find, bat and git-delta** for every platform this repo targets. Bare no-sudo Linux goes from 13 blocked to 2.

Four things about it are deliberate and worth not undoing:

- **It is a last resort, everywhere.** Ordered behind apt, behind a usable cargo, and behind an *already-installed* Homebrew — but *ahead* of a Homebrew that would have to be bootstrapped, since both are prebuilt binaries and only one of them is a ~1GB detour. `conda_needed()` fires only when something selected has no other route at all, so a machine with apt never grows an environment and the plan reads `micromamba|na|not needed on this machine`.
- **The precedence with Homebrew is fixed by hand, not negotiated.** `brew_coming()` asks `conda_coming()`, so `conda_needed()` must never ask back — it reads `AVAIL_BREW` and `is_mac && priv_available` directly instead. That asymmetry is the whole reason there is no infinite recursion between the two. macOS-with-admin is the one case where Homebrew wins for git: its installer brings the Xcode CLT, and therefore a real compiler, which conda cannot.
- **`buildtools` is NOT routed through it**, even though conda-forge has gcc. A conda compiler links against conda's own libgcc and sysroot, so a `cargo build` it drove would produce a binary that depends on the environment continuing to exist — something that works today and breaks when the env is pruned is worse than an honest `needs apt`. So `buildtools` still says apt-or-nothing, and `herdr_statusline` (which genuinely compiles `hsl-config`) still says `needs a C compiler`. Those two are the only `blocked` rows left on a bare box, and both are telling the truth.
- **Only the requested binaries are exposed**, as symlinks from `~/.local/bin` into `$CONDA_ENV/bin` — never by putting that `bin` on PATH. A conda env's `bin` holds its own python, curl, openssl and ncurses, and shadowing the system's with them is the classic way conda breaks a shell it was only supposed to add one command to. git is fine through a symlink: it resolves `libexec/git-core` from the path it was invoked through, so subcommands work.

The env lives at `~/.local/share/dotfiles-conda` (root prefix) with the single shared environment under `envs/tools`. `_install_conda_pkg()` uses `create` for a prefix with no `conda-meta` and `install` for one that has it, since micromamba refuses the wrong one either way; it passes `--no-rc` so a `~/.condarc` pointing at an internal mirror (very common on a cluster) cannot change what it resolves against. It ends with `clean --tarballs`, which reclaims ~62MB of the ~444MB a git+tmux env costs — **`--tarballs` only**, because the *extracted* packages under `pkgs/` are what the env's files are hardlinked to, so cleaning those would either break the env or silently double its size. `reset.sh` names the directory and its live size on the way out, being the largest thing the tools phase can leave behind.

**Package names are a third spelling again.** apt's `fd-find`, cargo's `fd-find`, Homebrew's `fd`, conda-forge's `fd-find` — and the *binary* is `fd` in all of them, just as `git-delta` ships `delta`. `_route_system_or_cargo()` therefore takes the conda package as its own argument, and `_install_via_route()` takes the binary name separately, rather than deriving either from the others.

**A failed provider has to stop being a route.** `providers_seen()` had no counterpart, and `brew_coming()`/`conda_coming()` answer from `brew_needed()`/`conda_needed()` — which say what *should* happen and go on saying it after it has already not happened. So killing the network made `micromamba` fail and then git and tmux each report a bare `FAILED`, two more round-trips spent, nothing saying why. `providers_failed()` (called from `install_tools()`'s failure branch) latches `BREW_FAILED`/`CONDA_FAILED`, both `*_coming()` consult it, and those are now reported as `SKIPPED (needs apt, Homebrew or conda-forge)` instead. Only those two providers need it: `AVAIL_CARGO`/`AVAIL_CC`/`AVAIL_GIT` are *only* ever set by `providers_seen()`, so a failed `rust` already stops `cargo_usable()` dead and the routes behind it fall through on their own.

Ordering is the array order of `TOOL_META`, which is topological — a tool may only depend on one listed above it. `tool_deps()` holds only the hard ones (LazyVim needs neovim; both herdr plugins need herdr). bat/delta/glow are deliberately *not* dependencies of `herdr-file-viewer`: it installs and runs fine without them and just falls back to plain text.

**`herdr-statusline` needs `rust` and `buildtools` as well as `herdr`**, which is not a guess about it: its `herdr-plugin.toml` declares a build step, and that step (`sh scripts/build.sh`) is a `cargo build --release --locked` of `hsl-config` which only then installs the `~/.local/bin/hsl` launcher. With no cargo the build exits 1, the plugin is not installed *at all*, and because `install_tools()` swallows each installer's output the entire diagnosis was one unattributed `FAILED`. The same manifest is `platforms = ["linux"]`, so the macOS route is `na|linux only` rather than something that fails. Unlike every other cargo consumer this one has **no second route** — there is no released `hsl-config` binary — so a machine short of either half is blocked with a reason rather than attempted.

### This file is sourced under `set -euo pipefail`, and that has teeth

`lib/tools.sh` sets no shell options of its own, so **executing** it (`bash lib/tools.sh --plan`, which is what `tui/configure.py` does) runs without `set -e`, while **sourcing** it from `install.sh` runs every function under `set -euo pipefail`. The two paths therefore do not fail in the same places, and the sourced one is the one that can take an install down.

The trap is specific: **a procedure whose last statement is a fallible `&&`/`||` list returns that status**, and procedures here are called bare. `providers_init()` ends in the `AVAIL_*` detection, and adding `AVAIL_CONDA=0; have_micromamba && AVAIL_CONDA=1` as the final line meant that on any machine *without* micromamba — i.e. almost all of them — the function returned 1, `install_tools()` aborted, and install.sh died silently right after `Saved answers to ...` with exit 1. The earlier lines in that same function use the identical `have x && AVAIL_X=1` spelling and are fine, purely by not being last. So the last statement is written `if have_micromamba; then AVAIL_CONDA=1; fi` — an `if` with no `else` always returns 0, which is also why the `brew` line above it was already written that way.

The predicates (`tool_selected`, `cargo_usable`, `cargo_coming`, `brew_coming`, `conda_coming`) *do* end in fallible lists, and must: they exist to return a truth value and are only ever called inside a condition, where `set -e` is suspended. The distinction to keep is procedure-vs-predicate, not the syntax.

Worth knowing because **no test harness that runs `bash lib/tools.sh` will ever catch it** — only one that sources the file under the real options, the way install.sh does.

### `have cargo` was never enough: the linker is its own provider

**rustup ships a compiler for Rust and nothing to link its objects with.** So on a brand-new machine — a slim container, an HPC login node, a fresh VM — `AVAIL_CARGO=1` was a promise the machine could not keep: cargo got a long way through the crate graph and then died on `error: linker "cc" not found`, once per build script, for **every** cargo route (`eza`, `fd`, `bat`, `delta` and the hsl plugin alike). And because rustc invokes the linker as `cc` *by name*, a box with `gcc` or `clang` but no `cc` in front of it failed in exactly the same way.

So a linker is a detected provider in its own right, `AVAIL_CC`, and:

- `cc_probe()` finds the first of `cc` / `gcc` / `clang` that is real — and on macOS `/usr/bin/cc` is the **same shim `/usr/bin/git` is**, so it gets the same `xcode-select -p` question rather than being taken at its word;
- **`cargo_usable()` — both halves — replaces every `AVAIL_CARGO` test in a route.** That is the actual bug: a cargo with no compiler behind it is not a route to anything, and offering it as one sent four tools into minutes of compiling before the link step failed, *on machines where the Homebrew route below would have worked*;
- `cc_linker()` / `cargo_with_linker()` turn "gcc but no `cc`" from a dead end into `RUSTFLAGS="-C linker=gcc"` — set only when it would say something, and never over an existing `RUSTFLAGS`, which is somebody's deliberate choice;
- `buildtools` is a catalogue entry in `providers`, ordered **ahead of `rust`** so `providers_seen` has flipped `AVAIL_CC` before any cargo consumer is resolved (that ordering is what keeps the plan agreeing with the run: on an apt machine with no compiler the plan says `buildtools|install|apt|build-essential` and then `herdr_statusline|install|plugin|…`, which is what the run does). `tool_present buildtools` is `have_cc` — "is there a linker", not "did we install a package" — so a machine that came with gcc is never sent to apt for build-essential it does not need;
- it is gated by **`cc_needed()`**, shaped like `brew_needed()`: install a compiler only when something selected has no route *except* a cargo build. Deliberately does not ask `tool_route()` — the cargo routes consult `AVAIL_CC`, so that would be circular. apt (`build-essential`) is the only route offered; there is no userland way to put a working C toolchain on a Linux box, and a Homebrew gcc is a multi-hundred-megabyte detour that still leaves rustc looking for `cc`.

`_install_herdr_plugin()` then assembles the environment the build actually runs in, because **herdr runs plugin build commands as a child of this process**: `~/.cargo/bin` prepended (a rust from an *earlier* run of this script is invisible to a non-login shell — `install_rust()` prepends it only when it is the one installing), the standard system directories **appended** so nothing of the user's own is shadowed, Homebrew's prefix if there is one, and the `cargo_with_linker` flag. The appended system dirs are not paranoia about a normal login shell: this phase can be reached with almost no PATH at all (`curl | bash` under cron or CI, a `sudo -i` that reset it, a herdr pane spawned from a stripped environment), and a build whose PATH has `~/.cargo/bin` but not `/usr/bin` finds cargo, compiles most of the crate graph, and only then reports a missing compiler **on a machine that has one**.

**Claude Code is in the catalogue** (`claude`, in the `editor` group) — this repo syncs its settings, keybindings, themes and status line, so a machine that has the config and not the binary is half set up. One route on both platforms: the native installer (`claude.ai/install.sh`) detects darwin/linux and arm64/x64 itself, needs no privilege and no node, and lands a versioned binary under `~/.local/share/claude` with a `~/.local/bin/claude` symlink at it. It is the one installer here that needs **no** `--no-modify-path` equivalent: it writes to no shell rc, so nothing of it can land in the tracked `~/.profile` symlink. `tool_present claude` checks `have claude` **or** that launcher directly, because an update swaps what the symlink points at rather than where it lives.

**`install_tools()` puts `~/.local/bin` on its own PATH**, immediately *after* capturing `TOOLS_ORIG_PATH` (before it, and `print_path_hint()` would stop reporting the directory to the calling shell). Most userland routes land there, and several installers end by checking that what they just installed can be found — `install_herdr()` in `have herdr`, `install_claude()` in `tool_present claude`. On a bare machine that directory did not exist at login so Debian's `~/.profile` never added it, and every one of those checks answered "no" about a tool that had installed perfectly: herdr was reported `FAILED` and **both herdr plugins then SKIPPED on the dependency check behind it**. `install_preview_prereqs()` already did this, but only on an interactive run — `-y`, `--tools-only` and the tty-less `curl | bash` never went through it.

**`brew` is listed ahead of `git`**, which is the one ordering that does not read as obvious. On macOS git has no route *except* Homebrew — its installer pulls in the Xcode Command Line Tools, git included — so git has to come after it. On Linux the dependency runs the other way (brew bootstraps by cloning its own repo with git), but that costs nothing: the only Linux machine where brew is wanted *and* git is missing is one with no apt either, and there git is unobtainable in either order.

Answers are one `TOOL_<ID>=0|1` per catalogue entry in theme.env, appended by `tools_answers()` rather than spelled out in install.sh's heredoc — so adding a tool needs no edit there. **Unset means on**, which is what makes a newly-added tool install itself on a machine whose theme.env predates it (`tools_defaults()`).

Three things each installer is careful about, all the same hazard: `rustup` gets `--no-modify-path`, `fzf` gets `--no-update-rc`, and uv gets `UV_NO_MODIFY_PATH` — left alone all three append to `~/.profile`, which **on an already-installed machine is a symlink into this repo**, so the edit would land in tracked dotfiles. `install_lazyvim()` refuses to touch a `~/.config/nvim` that already has files in it and returns 2, which the orchestrator prints as "left alone" rather than counting as a failure. Nothing in the phase is ever fatal: a failed tool is recorded and the run continues.

PATH goes out two ways. Permanently through `~/.config/dotfiles/tools-env.sh` (written by `tools_write_env()`, sourced by `shellrc_additions.sh` — same shape as `uv-env.sh`, and the reason Homebrew gets a full `brew shellenv` rather than just its bin dir). And for the terminal the install ran in, `print_path_hint()` prints a copy-paste `export PATH=...`, compared against `TOOLS_ORIG_PATH` — the PATH as it was when the phase *started*, because `install_rust()` and `install_neovim()` prepend to install.sh's own PATH so later steps can use what they just installed, and checking the live one would report every such directory as already handled.

**`PREVIEW_TOOLS` (`ohmyposh`, `jq`) are installed *before* the wizard opens**, by `install_preview_prereqs()`. The preview panes are the real prompt and the real Claude status line; without oh-my-posh the prompt pane is a hand-drawn approximation and without jq the Claude pane is the string "needs jq on PATH", which is exactly what the whole previews-are-real design exists to avoid. Two rules make that pre-pass safe: it **never prompts** (a machine needing a sudo password is treated as unprivileged for the duration, since both tools have userland routes — being asked for a password before the first question is a poor greeting), and a failure is silent and harmless, just restoring the old fallbacks. It also puts `~/.local/bin` on PATH, since the UI is a child process that inherits it.

**`dua-cli` is the one entry with no system route on any platform, and does not want one.** It is in neither apt (not on 24.04, not Debian) nor Homebrew's list of things worth preferring here, but upstream publishes a **statically linked musl** binary per platform — plus riscv64 and armv7 — so the release tarball needs no privilege, no compiler and no particular glibc vintage. That makes it strictly the best route on every machine, privileged or not, which is why `tool_route dua` does not branch on `AVAIL_APT` at all. conda-forge has it two versions behind; it is deliberately **not** in `conda_needed()`, since pulling a ~300MB environment for a tool whose own binary is a 2MB download is the wrong trade.

Its asset names embed the **version** (`dua-v2.41.0-aarch64-unknown-linux-musl.tar.gz`), so unlike jq and oh-my-posh it cannot use the `/releases/latest/download/<name>` permanent redirect — the name is unknowable without the tag. That means a GitHub API call, and the unauthenticated limit is 60/hour **per IP**, which a shared login node or CI can genuinely be on the wrong side of. Hence the cargo fallback inside `install_dua()`, the same belt-and-braces shape `install_ohmyposh()` has: the *route* still advertises the tarball, because that is what gets tried first and no plan can know a rate limit is waiting. `cargo` is also the honest route on an architecture `rust_triple()` cannot name (s390x, say), and blocked when there is no usable cargo either.

`rust_triple()` is a **fourth** spelling of the platform, after `arch_deb()`'s amd64, `arch_tag()`'s x86_64/arm64 and `conda_platform()`'s osx-arm64. The trap in it is `aarch64`: Rust uses that on macOS as well as Linux, where `arch_tag()` says `arm64` — so reusing `arch_tag()` here matches no asset at all on Apple silicon. musl over gnu is deliberate (static binary, no glibc dependency); a project publishing only gnu builds needs its own pattern, since what actually selects an asset is the regex handed to `github_latest_asset()` and this helper only supplies the platform half.

Two installers deliberately avoid the "official" route. **oh-my-posh** takes its bare release binary rather than `ohmyposh.dev/install.sh`, because that script requires `unzip` (it also fetches the themes archive) and a slim container or login node may not have it — and the themes are unwanted here anyway, since the one theme this repo uses is rendered from its own template. The script stays as a fallback. **jq** likewise takes `releases/latest/download/jq-<os>-<arch>`, a permanent redirect that needs no API call and cannot be rate-limited; `fetch_bin()` handles projects shipping a bare binary, `fetch_bin_from_tarball()` those shipping an archive, and `arch_deb()` gives the amd64/arm64 spelling those assets use (`arch_tag()` gives the x86_64/arm64 one). The OS half needs two helpers, not one, because the projects disagree: `os_darwin()` gives oh-my-posh's and glow's `darwin`, `os_macos()` gives jq's and Neovim's `macos`.

**git and Tailscale** are the two entries whose routes are shaped by something other than convenience. git is a *provider* as much as a tool — fzf, LazyVim and Homebrew's own Linux bootstrap all clone with it — hence `AVAIL_GIT`. Its own route is apt, then an available Homebrew, then blocked; on macOS "blocked" carries the `xcode-select --install` hint, because that is the other way out. Tailscale takes the official installer when there is privilege on Linux (it picks the distro package and sets up the systemd unit, which is what makes a real node) and the static tarball when there is not — that still gives a working CLI and daemon, but the daemon must be started by hand in userspace-networking mode. On macOS neither exists: there is no darwin tarball and the install script refuses to run, so it is the brew formula plus a `brew services start` (the App Store build is a GUI app with a sandboxed CLI). `print_next_steps()` spells out whichever of the three applies rather than leaving it to be discovered. `tailscale up` is never run for you: it opens a browser to authenticate the node.

`print_next_steps()` is the single copy-and-paste block at the end of a run — the PATH export for *this* shell, any Tailscale step, and `source ~/.bashrc` last, since that is what makes the current shell match every future one. It warns when that last line will start herdr (hsl-at-login on). `needs_tailscale_up()` decides the Tailscale step by looking for peer IPs in `tailscale status`; anything else — "Logged out.", no daemon, a permission error — means there is still an `up` to run.

Tools are **not** recorded in the manifest: `reset.sh` undoes this repo's config, not the software on the machine. The one thing it names explicitly on the way out is `~/.local/share/dotfiles-conda`, with its live `du -sh` — it is by far the largest thing the phase can leave behind, it only exists on a machine that had no privileged route, and its path is not one anybody would guess.

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

**Which login shell**, separately from which bash. macOS has logged people into **zsh** since Catalina, so on a Mac none of `~/.bashrc`, `~/.bash_profile` or `~/.profile` is read at all — see "Two shells" below, which is the other half of this section.

To check a change here, there is no macOS in CI, so build the shell instead — `bash-3.2.57` from ftp.gnu.org compiles in about a minute (`./configure --without-bash-malloc CFLAGS="-Wno-implicit-function-declaration -std=gnu89"`). Its bundled `support/config.sub` is too old to recognise **aarch64** and configure dies on `checking build system type`; copy `/usr/share/misc/config.sub` (and `config.guess`) over the bundled pair first, which is quicker than fetching them from savannah. `bash -n` is *not* enough: `${1,,}` and `mapfile` are runtime failures, not parse errors. Run the real entry points, and diff a `--plan` between 3.2 and 5 — they must be byte-identical.

### Probing a machine you do not have

Almost everything in `lib/tools.sh` is a decision about a machine's *shape*, so the way to test it is to fake the shape rather than to find the machine. Three ingredients, all of which have caught real bugs:

- **A minimal PATH.** A directory of symlinks to only the utilities the script itself needs (`bash sh uname id tr grep sed awk printf head tail cat mktemp ln find install curl tar chmod cmp paste seq env kill sleep`), run under `env -i HOME=<throwaway> PATH=<that dir>`. Everything the catalogue probes for is then genuinely absent. Resolve those symlinks with `type -P`, **not** `command -v` — an interactive shell may have a *function* shadowing `grep`, in which case `command -v grep` prints `grep` and you get a self-referential symlink that silently breaks every `grep` in the script.
- **Stub `uname` / `sudo` / `apt-get`.** `OS_KERNEL` is read once from `uname -s`, so a stub is all it takes for the Darwin routes; `uname -m` drives `conda_platform()`, `arch_deb()` and `arch_tag()`. For privilege, a `sudo` stub that fails `-n` and prints `sudo: a password is required` to stderr for `-nv` is a password-sudo machine; one that prints `is not allowed to execute` is a non-sudoer; one that prints something unrecognised exercises the group-membership fallback. Delete the stub for "no sudo at all".
- **`brew_prefix()` probes absolute paths**, so a box that really has `/home/linuxbrew/.linuxbrew` leaks into every "bare machine" test and reports `brew|present`. Rewrite those two path lists in a *copy* of the file for probing.

And the mistake to avoid: **run the copy the way install.sh does it** — sourced under `set -euo pipefail`, functions called bare — not as `bash lib/tools.sh --plan`. The `providers_init()` bug in the section below survived a full matrix of `--plan`/`--priv`/`--list` probes across seven machine shapes, because executing the file does not set `-e` and only the sourced path does.

## Two shells: bash and zsh

The other thing a brand-new machine varies in, and the one that used to make an
install on a Mac look like it had done nothing at all: **zsh reads none of the
files this repo wires**. Not `~/.bashrc`, not `~/.profile`, not
`~/.bash_profile`. Everything installed correctly and no shell ever loaded it.

**One file, not two.** `shell/shellrc_additions.sh` is sourced from `~/.bashrc`
*and* `~/.zshrc`, and works out which shell is reading it from `$ZSH_VERSION` /
`$BASH_VERSION` (not `$SHELL`, which is the *login* shell and says nothing about
the shell you are in; not `$0`, which is `-zsh`/`zsh`/`bash`/`-bash` depending
on how it was started). A second copy for zsh would drift within a month. Only
these genuinely differ, and each branches:

| | bash | zsh |
| --- | --- | --- |
| prompt | `oh-my-posh init bash` | `oh-my-posh init zsh` |
| `cd` | `zoxide init bash` | `zoxide init zsh` |
| history on ↑ | `bind '"\e[A": history-search-backward'` | `bindkey '^[[A' history-beginning-search-backward` |
| fzf | `~/.fzf.bash` | `~/.fzf.zsh` |
| completion | the distro's | `compinit`, or there is none at all |
| nvm | `$NVM_DIR/bash_completion` | skipped — it calls `complete` |

Two of those have a detail worth keeping. zsh's `history-search-*` widgets are
**not** the counterpart of bash's — `history-beginning-search-*` are; and both
`^[[A` *and* `^[OA` are bound, because a terminal left in application cursor
mode (which is what tmux and every full-screen TUI leave behind) sends the
latter. `compinit` runs with `-u` and its own dump under `$XDG_CACHE_HOME`, and
only when `compdef` is undefined: with a framework already loaded it would be a
second run, and without `-u` a group-writable completion dir — the norm on any
shared machine — makes zsh ask a question at every single login.

**Which rc files get the line** is decided by `login_shell_name()` and the
`case "$SHELL_TARGET"` beside it in install.sh: bash always (it is everywhere, and `bash` typed inside
zsh should still get the prompt), zsh when it is the login shell or a
`~/.zshrc` already exists. A zsh merely *installed* does not count — it sits
unused on most Linux boxes. `--shell bash|zsh|both` forces it. `login_shell_name()`
reads `$SHELL` first and falls back to the passwd database (`dscl` on macOS,
`getent` elsewhere) — both lookups need `|| true`, or a machine without them
fails the assignment under `set -o pipefail` and takes the install down.

Creating a missing `~/.zshrc` is safe, unlike creating a `~/.bash_profile`:
zsh reads `~/.zshenv`, `~/.zprofile`, `~/.zshrc` and `~/.zlogin` in turn and
none shadows another, so there is no chain to break. `~/.zshrc` alone is also
enough — zsh reads it for every *interactive* shell, login or not, where bash
splits that job between `~/.bashrc` and `~/.profile`.

**A login shell that is neither** (fish, csh, ksh) must degrade loudly, and the
thing that was wrong here was not the detection but the *instruction*. Nothing
is skipped: `WIRE_BASH=1` regardless, every tool still installs, `~/.bashrc` is
still written, and the summary block already said so. But the closing
copy-and-paste step was `source $LOGIN_RC` — pasted at a fish prompt that is a
screenful of parse errors, because fish cannot read a bash rc and does not
spell `source` the same way either. `SHELL_FOR_RC` (set beside `LOGIN_RC`,
naming whichever of the two shells actually *reads* that file) is what fixes
it: `print_next_steps()` offers `bash -l` instead for those shells, and the
NOTE names `chsh -s $(command -v bash)` for making it permanent. The `sh` case
stays with `source`, since `~/.profile` is genuinely readable there.

`tilde()` exists for those messages — `~/.bashrc` is 10 cells where
`/home/somebody/.bashrc` is 23, and these lines are laid out to fit a narrow
terminal. It is guarded against an unset or `/` `$HOME`, which would otherwise
turn every absolute path on the machine into a tilde.

**The block is refreshed, not just appended.** `rc_wire()` strips a block whose
`source` line points somewhere else (the checkout moved) and, before that, any
block under the older `# >>> dotfiles bashrc_additions >>>` marker, which is
what a machine set up before the rename has. `shell/bashrc_additions.sh` still
exists as a four-line redirect for exactly the window between "this is pushed"
and "install.sh has been re-run there" — without it, every new shell on those
machines opens with a `No such file or directory` and no PATH.

To check a change here without a Mac: `apt-get download zsh zsh-common`
(no root needed), `dpkg-deb -x` both somewhere, and run
`<there>/bin/zsh -i -c '...'` with `HOME` pointed at a throwaway directory that
install.sh has been run against. The extracted zsh needs `module_path` and
`fpath` set in that `HOME`'s `.zshenv` to find its own modules, or every
`bindkey` fails for a reason that has nothing to do with this repo.

## The hsl login autostart

`HSL_LOGIN` is the one answer that changes what opening a terminal does, so it is the one that can lock you out of a machine you only reach over ssh. It is therefore **off by default**, and `shell/hsl-login.sh.in` is deliberately paranoid about it:

- it is **sourced**, never executed, so every exit path is `return` — an `exit` would close the login shell;
- `hsl` is **run, not `exec`ed**, so quitting herdr drops you into a normal shell rather than ending the session;
- `NO_HSL=1` is the escape hatch (`NO_HSL=1 bash -l`, or `zsh -l`), checked before anything else;
- `DOTFILES_HSL_STARTED` (exported) makes it once-per-login — the shell rc gets re-sourced constantly, not least by this repo's own `rebash` alias, and each of those would otherwise stack another herdr;
- it bails on: a non-interactive shell (`case $- in *i*`), `SSH_ORIGINAL_COMMAND` (scp/rsync break outright if a login shell writes to stdout), **being inside herdr already** (`HERDR_ENV`/`HERDR_PANE_ID`/`HERDR_SOCKET_PATH`/`HERDR_WORKSPACE_ID` — every pane herdr spawns runs the shell rc, so without this the first thing a new pane does is start a second herdr inside itself), `TMUX`, an agent shell (`CLAUDECODE`/`AI_AGENT`), no tty on both ends, `TERM=dumb`, and `hsl` not being on PATH at all.

The answer is baked in at render time rather than re-read per shell, so "off" is a file that returns on its second line. It is sourced from the **very end** of `shellrc_additions.sh`: when it does start herdr it blocks until you quit, so anything after that line would not run until then.

`hsl` itself ships with the herdr-statusline plugin (it is a generated launcher — do **not** put it in `bin/`; the plugin's build step is what writes it, and that build needs cargo — see `tool_deps()` above), which is a separate answer, so it can legitimately be absent; install.sh prints a NOTE for that combination rather than failing.

## Backup + reset

`link()` and `copy()` (install.sh's plumbing helpers) back up any real, non-symlink file already at a destination as `<file>.bak` before taking it over — but only the first time: on a later run the destination is already a symlink (or, for `copy()`, byte-identical to what we are about to write, or already listed in the *previous* run's manifest), so the `.bak` is never overwritten by our own output. Every destination either helper touches is recorded in `MANAGED` and written out fresh each run to `~/.config/dotfiles/manifest.txt`.

**A backup is only ever created, never written over.** `backup_name()` is the single place that decides where one goes: `<file>.bak` when that name is free, otherwise `<file>.bak.2`, `.bak.3`, … The case that makes this necessary is a real file turning up at a path we already took over once — somebody deleted our symlink and wrote their own `~/.tmux.conf` — where the old `mv "$dst" "$dst.bak"` would have destroyed the machine's *original* file, the one thing reset.sh needs. reset.sh restores the plain `.bak` (the original, by construction) and reports the numbered ones without touching them: choosing between several saved files is a human's job.

`reset.sh` reads that manifest and undoes it: removes every path on it, restores `<file>.bak` wherever one exists, strips the additions block from `~/.bashrc` and `~/.zshrc` (both the current marker and the older `bashrc_additions` spelling), and best-effort unlinks the `herdr-workspace-prefix` plugin. Paths with no `.bak` (there was nothing there before install.sh) are just removed. `theme.env` and `.generated/` are deliberately left alone — reset undoes *installation*, not the saved colour/machine/toggle answers. The `checkout` pointer (below) *is* removed: it describes an installation, the way the manifest does.

## `bin/dotfiles` — the CLI, and the two things it can't delegate

`install.sh`, `reset.sh` and `lib/tools.sh --plan` all want to be run from the checkout, which means `cd ~/dotfiles` before every reconfigure. `bin/dotfiles` is one command on PATH that wraps them — `reconfigure`, `install`, `update`, `tools`, `plan`, `backups`, `uninstall`, `purge`, `path` — and, being in `bin/`, arrives on every machine by the existing plain-copy route with no new plumbing in install.sh beyond the pointer below.

**It is a wrapper, not a second implementation.** Every subcommand `exec`s into the checkout, so there is still one installer and one uninstaller, and `dotfiles install --no-tools` works because options are passed straight through. Only two things genuinely live here, and they are the two that cannot:

- **Finding the checkout from outside it.** `install.sh` writes `~/.config/dotfiles/checkout` (one line, the absolute path) next to the copy of the CLI it just made, and `find_checkout()` reads `$DOTFILES_DIR`, then that, then `~/dotfiles`. A `@DOTFILES@` placeholder would have been the obvious alternative and is *wrong*: `bin/` is plain-copied precisely so a copy survives the checkout moving or being deleted, and rendering it would make it one more file that has to be regenerated. The pointer is rewritten every run, so moving the checkout and re-installing re-points it. `is_checkout()` is install.sh's own two-file test (`install.sh` + `lib/derive.sh` both readable), so a stale pointer falls through to the next candidate rather than resolving to a directory that no longer holds an installer.
- **The ordering and the guards on `purge`.** This is the only new destructive operation in the repo, and its shape is dictated by one fact: **`reset.sh`, the thing that restores this machine's original files, lives inside the directory being deleted.** So purge runs `reset.sh -y` to completion first and only then `rm -rf`s the checkout — and if reset fails, the checkout is deliberately **not** deleted, because a second attempt is otherwise impossible. It `cd`s to `$HOME` first (launched from inside the checkout, `rm -rf` would be pulling its own cwd out), and it removes `~/.config/dotfiles` as well, since "delete the dotfiles completely" includes the saved answers that reset keeps.

`repo_has_unsaved_work()` is the refusal: uncommitted changes, or commits not on the upstream, or **a branch with no upstream at all** (those commits have no other home by definition) mean purge exits rather than deleting. Everything else purge destroys can be reinstalled from GitHub; unpushed work cannot, which is the whole reason this repo is cloned rather than tarballed by default. `--force` overrides it; `-y` only skips the typed-`purge` confirmation. A checkout with no `.git` (the tarball route) cannot be checked at all — an edited file there is indistinguishable from a pristine one — so purge says so instead of implying it looked.

Two smaller consequences worth not rediscovering. **`dotfiles uninstall` deletes the `dotfiles` command**, because `~/.local/bin/dotfiles` is on the manifest like everything else; both the CLI and reset.sh say so up front rather than leaving it to be noticed. And reset.sh's closing notes — "the answers were left alone", "re-run install.sh from the checkout" — are all statements about what *survived*, two of which purge is about to delete, so purge exports `DOTFILES_PURGING=1` and reset.sh prints one line instead. Deleting the CLI's own file mid-run is safe: it is unlinked, not truncated, and bash holds the fd open.

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

**Job state is the one thing in either bar that is deliberately not accent-coloured.** `slurm-status.sh.in` draws running jobs neon green (`#00ff00`) and queued ones neon yellow (`#fff700`) — fixed, because "which of my jobs are actually running" has to read the same on every machine whatever primary is set, the way a traffic light does. They are palette hexes (the same row, so they read as a pair) so they still sit with everything else, and they are drawn as *foreground* on black, so the "light enough to take black text" rule that governs the accents does not apply.

**Each pill leads with the same `U+E0BA U+E0BC` cap oh-my-posh's machine segment carries** and `derive.sh` spells as `CAP`, in the state colour, foreground-on-black like the name beside it. There was already a slot for it: every pill opened with an *empty* `#[fg=#000000,bg=$RUN_FG]` directive — a style with no text after it, so tmux applied it to nothing and it drew zero cells. That dead directive is what the glyph replaced. It is written as **UTF-8 bytes** (`$'\xee\x82\xba\xee\x82\xbc'`) for the reason `derive.sh` gives for wrapping its own copy in `$'…'` — a PUA codepoint pasted raw into a shell script is what an editor or a terminal in the middle silently eats — except that `derive.sh`'s copy *is* pasted raw and so does not in fact survive that; this one does. `\x` and not `\u`, since `\u` in `$'…'` is bash 4.2 and up and this script runs under whatever `/bin/bash` is, which on macOS is 3.2. Both branches used to be byte-identical `@PRIMARY@`, so a queued job and a running one looked exactly the same and the pills answered the one question they exist to answer with "some jobs". Anything that is neither `R` nor `PD` (`CG`, `F`, `CA`, `TO`, `S`) still prints nothing at all and silently leaves the bar — pre-existing, and worth a third colour if it ever matters.

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

- `tmux/` — `.tmux.conf.in` plus the two scripts its status bar shells out to: `other-sessions.sh` (session list), `slurm-status.sh` (Slurm job status, degrades gracefully without `squeue`). tmux itself is in the tools catalogue (`shell` group); the config is rendered and linked either way, since a machine can be set up before the binary arrives.
- `claude/` — Claude Code **global** `settings.json`, `keybindings.json`, `statusline-command.sh.in`, and custom themes (`themes/*.json(.in)`). Per-project Claude settings (`settings.local.json`, project `.claude/` dirs) are intentionally not synced here. The status line's five bubbles used to be a fixed palette of their own; they are now the primary→secondary ramp (`claude_ramp()` in `lib/derive.sh`), so it is templated like everything else.
- `herdr/` — `config.toml.in` (keybindings, sidebar rows, theme overrides) plus plugin configs under `herdr/plugins/*`. Plugin *code* is not synced/tracked as an installed plugin — see below.
  - **`prefix+j` is the Slurm popup, in both tmux and herdr**, and it is worth knowing what that cost. herdr's own default binds `prefix+j` to `focus_pane_down`, so `[keys] focus_pane_down = "prefix+shift+j"` moves it out of the way explicitly rather than trusting whichever binding wins — nothing documents that precedence, and a popup that silently does not open is worse than a nav key that moved (pane-down is untouched in navigate mode, which has its own prefix-less `j`). `[keys]` is written **before** the `[[keys.command]]` blocks, since those implicitly create the `keys` table and declaring a super-table after its own array-of-tables is the one TOML ordering that is not clearly legal. The command is `jwatch` from `bin/` rather than the pipeline spelled out inline: it is then the same script tmux's popup can run, and herdr spawns `keys.command` popups through `portable_pty` while documenting only that *Windows* runs the string through `cmd.exe /d /c` — nothing promises a POSIX host gets a shell, so a compound `a; b` string is not safe to hand it while a single executable always is. `herdr config check` validates a candidate config, and pointing `XDG_CONFIG_HOME` at a scratch dir is how to run it against one without touching the live config.
- `oh-my-posh/` — `albe-monokai2.omp.json.in`, the active prompt theme.
- `lib/` — `derive.sh` and `tools.sh`, both described above. Sourced by install.sh, executed by the setup UI.
- `tui/` — `configure.py`, the Textual setup UI. A PEP 723 uv script: dependencies live in its header, capped at the tested Textual major so a breaking release cannot break setting up a machine.
- `shell/` — layered on top of each machine's own `.bashrc`/`.profile`, not a replacement for them:
  - `shellrc_additions.sh` — aliases, PATH, oh-my-posh/zoxide/fzf init, key bindings, env vars. **One file for bash and zsh** (see "Two shells" above). Sourced from the tail of `~/.bashrc` and `~/.zshrc` via one `source` line that `install.sh` appends to each, guarded by a marker comment (idempotent).
  - `bashrc_additions.sh` — a redirect to the above, nothing else. Only there so a machine whose `~/.bashrc` still names the old path keeps working until install.sh is re-run on it; deletable once every machine has had a run.
  - `bashrc_functions` — shell functions (currently `syncop`, a generic rsync-between-machines helper).
  - `profile` — symlinked directly to `~/.profile`.
- `bin/` — binaries/scripts install.sh plain-copies (not symlinks, not templated) into `~/.local/bin`; drop files in to have them installed. Currently `dotfiles` (the CLI — see below) and `jwatch`, the body of the `prefix+j` Slurm popup that **both** tmux and herdr bind (see below). Note `~/.local/bin/hsl` is *not* a candidate: herdr-statusline generates that launcher itself.

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
- A new **tool**, by contrast, needs editing exactly one file: add one `id|label|group` row to `TOOL_META` (in dependency order — `TOOL_IDS` is derived from it), then a `tool_present` probe, a `tool_route` case and an `install_<id>()`. Both front-ends pick it up from the catalogue, theme.env gains its line automatically, and it defaults to on. Add a `tool_deps()` case only if it genuinely cannot be installed before something else. Give the route a macOS answer as well as a Linux one, even if that answer is `na|…`. If it could plausibly be wanted on a box with no privilege, check conda-forge (`https://api.anaconda.org/package/conda-forge/<pkg>`) for a build on all four subdirs before declaring it blocked — and if you add it to `conda_needed()`, remember the matching `! conda_coming` guard in `brew_needed()`/`cc_needed()`, or the plan starts promising a Homebrew or a compiler that nothing will use.
- A new **provider** (something other tools route *through*) is the one case that touches more: a `providers_init()` detection, a `providers_seen()` line, a `providers_failed()` line if its "is it coming" answer is predictive rather than a flag, and a `*_needed()`/`*_obtainable()`/`*_coming()` trio shaped like brew's and conda's. Keep `providers_init()`'s last statement an `if`, not an `&&` list — see the `set -e` section above for what that costs.
- The palette is 48 colours as **six rows of eight, each row one real scheme** (`PALETTE_ROWS`: monokai, catppuccin, dracula, nord, tokyonight, neon), and it lives **only** in `lib/derive.sh`. install.sh used to carry its own copy of the first eight, which meant the text wizard silently offered a different set from the UI — don't reintroduce that. Only each scheme's *accent* ramp is included, never its backgrounds or greys: the primary is used as a **background with black text on it** (both status bars, the Claude Code bubbles), so a dark entry would be unreadable there. Hexes are unique across all six rows — the UI marks "your primary is here" by hex lookup, so a duplicate would show two markers. `PALETTE=name:hex:scheme` is the emit format; `palette_index()`/`palette_group_of()`/`palette_label()` turn a hex back into "monokai / pink".
- Both front-ends dropped the 48-numbered-lines menu. The text wizard picks in **two steps** (scheme, then colour within it — six ribbon rows, with `<-` on the row holding the current colour); the UI has **one** `PaletteGrid` for both accents instead of two `PaletteRow`s, marking primary `P` / secondary `S` / `PS` inside the swatch itself, which removes the pointer line *and* the duplicate grid. `p`/`s`, the "editing" ChoiceRow, or clicking a swatch chooses which accent the arrows move.
- `SetupApp._inputs_live` is **not** called `_ready` — `App` already has a `_ready()` method, and shadowing it crashes the app on start. It exists because Textual posts `Input.Changed` for an Input's *initial* value as it mounts, and `_hex_typed()` treats a change as "the user is working on this accent"; without the flag the secondary hex box, purely by mounting last, left the grid editing secondary before the user touched anything.
- `#>>` -prefixed lines in a `.in` template are template-only comments and get stripped by `render()` — use them for notes that shouldn't appear in the rendered/live config.
- `render_script()` inserts the GENERATED header as line 2 (after the shebang, which must stay on line 1) and `chmod +x`s the output.
- `link()`/`copy()` back up any real file at the destination as `<file>.bak` before taking it over — safe to re-run against a machine with pre-existing dotfiles. See "Backup + reset" above.
