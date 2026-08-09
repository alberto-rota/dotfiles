#!/bin/bash
# What install.sh can PUT ON a machine, as opposed to what it configures.
#
# Same two-consumer shape as lib/derive.sh, and for the same reason:
#   * install.sh sources this file and calls install_tools().
#   * tui/configure.py EXECUTES it (`bash lib/tools.sh --list` for the checkbox
#     list, `--plan` for the install-plan preview) and parses the lines it
#     prints -- so the plan the UI shows is resolved by the very same code that
#     does the installing, not by a Python guess at it.
#
# Reads (all optional):
#   TOOL_<ID>=0|1        one per id in TOOL_IDS; unset means "yes, install it"
#   TOOLS_CAN_PROMPT     1 if there is a terminal to ask for a sudo password on
#   TOOLS_ASSUME_YES     1 to never prompt (implies no password-sudo route)
#
# --- how a route is chosen ------------------------------------------------
# Every tool has an ordered list of routes and takes the first one this machine
# can actually use. The system route (apt, or Homebrew on macOS) is only ever
# reachable with root or sudo; every other route (rustup/cargo, uv, a release
# tarball, a git clone) lands entirely inside $HOME and needs no privilege at
# all. That is the whole of the sudo/no-sudo split -- there is no second,
# parallel "unprivileged installer", just a route list whose first entry drops
# out.
#
# apt is the only system package manager wired up on Linux. On a dnf/pacman box
# the system route is simply unavailable and everything falls through to the
# userland routes, which are OS-independent -- which is also exactly what
# happens on an HPC login node, the case that actually matters here.
#
# --- macOS -----------------------------------------------------------------
# The second platform, and it differs in more than a package manager:
#
#   * /bin/bash is 3.2, so nothing in this file (or lib/derive.sh, or
#     install.sh) may use bash 4 syntax -- no `declare -A`, no ${var^^}, no
#     named file descriptors. That is why the catalogue below is a flat table
#     rather than three associative arrays;
#   * there is no apt, so Homebrew IS the system route rather than a last
#     resort, and `brew` is the only way to get git or Tailscale;
#   * Homebrew lives at /opt/homebrew (Apple silicon) or /usr/local (Intel),
#     never at the ~/.linuxbrew this file used to be the only spelling of;
#   * release assets are named darwin/macos rather than linux, and pair with a
#     different architecture tag depending on the project;
#   * /usr/bin/git EXISTS on a machine with no developer tools, as a stub that
#     pops a GUI installer the moment it is run -- see have_git().

# --- which platform ---------------------------------------------------------
OS_KERNEL="$(uname -s 2>/dev/null || echo unknown)"
is_mac() { [ "$OS_KERNEL" = Darwin ]; }

# Release assets spell this platform two different ways and both are in use
# here: oh-my-posh and glow say "darwin", jq and Neovim say "macos".
os_darwin() { if is_mac; then printf 'darwin'; else printf 'linux'; fi; }
os_macos()  { if is_mac; then printf 'macos';  else printf 'linux'; fi; }

# --- privilege ------------------------------------------------------------
# PRIV_MODE is one of:
#   root         running as uid 0; no sudo needed for anything
#   passwordless sudo works without a password (NOPASSWD, or a live timestamp)
#   password     this user may sudo, but has to type a password for it
#   none         no sudo, or not a sudoer -- userland routes only
PRIV_MODE=""
SUDO=""                  # prefix for a privileged command; empty when root
SUDO_UNLOCKED=0
SUDO_KEEPALIVE_PID=""

detect_privilege() {
  if [ "$(id -u)" -eq 0 ]; then
    PRIV_MODE=root; SUDO=""; return
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    PRIV_MODE=none; SUDO=""; return
  fi
  if sudo -n true 2>/dev/null; then
    PRIV_MODE=passwordless; SUDO="sudo -n"; SUDO_UNLOCKED=1; return
  fi
  # sudo exists and wants a password -- which is only worth anything if this
  # user is allowed to run it at all. `sudo -nv` tells the two apart: a sudoer
  # gets "a password is required", everyone else "may not run sudo" / "is not
  # in the sudoers file". LC_ALL=C pins those strings, which are localised.
  #
  # Precedence matters here: an explicit refusal has to beat the group-
  # membership guess below it. Being in group sudo does not make you a sudoer
  # (sudoers can exclude a group member, and plenty of hardened boxes do), so
  # reading "not in the sudoers file" and then claiming sudo anyway would send
  # every apt route into a wall of failed installs.
  local probe
  probe="$(LC_ALL=C sudo -nv 2>&1 || true)"
  if printf '%s' "$probe" | grep -qiE 'password is required|password for'; then
    PRIV_MODE=password; SUDO="sudo"; return
  fi
  if printf '%s' "$probe" | grep -qiE 'not in the sudoers|may not run sudo|not allowed to (run|execute)'; then
    PRIV_MODE=none; SUDO=""; return
  fi
  # Message unrecognised -- a locale we do not have a string for, or a sudo
  # that says something else entirely. Group names are never translated, so
  # they are the tiebreaker; being wrong here costs one failed apt call, which
  # apt_install() already survives.
  if id -nG 2>/dev/null | tr ' ' '\n' | grep -qxE 'sudo|wheel|admin'; then
    PRIV_MODE=password; SUDO="sudo"; return
  fi
  PRIV_MODE=none; SUDO=""
}

# detect_privilege() plus the one adjustment both the plan and the install have
# to make: a machine where sudo needs a password but there is nothing to type
# it on (`curl | bash`, CI, -y) is, for route-choosing purposes, a machine with
# no sudo. Resolving to apt and only finding out at install time that nothing
# can authenticate would fail every one of those tools instead of taking the
# userland route that would have worked.
priv_resolve() {
  detect_privilege
  if [ "$PRIV_MODE" = password ] && [ "${TOOLS_CAN_PROMPT:-0}" != 1 ]; then
    PRIV_MODE=none
    SUDO=""
  fi
}

priv_summary() {
  # Whether privilege is any USE here, which is not the same as having it. On a
  # Fedora, Arch or openSUSE box -- or an HPC node with sudo and no apt -- this
  # said "passwordless sudo -- apt available" while every route below it said
  # "needs apt". apt is the only system package manager wired up on Linux (see
  # the header), so no apt means sudo buys nothing and the userland routes are
  # what will run. macOS is the exception: its system route is Homebrew, which
  # admin can install rather than having to already have.
  local sys=""
  if is_mac; then sys=Homebrew
  elif have apt-get; then sys=apt; fi
  if [ -z "$sys" ] && [ "$PRIV_MODE" != none ]; then
    echo "sudo, but no apt -- \$HOME routes"
    return
  fi
  case "$PRIV_MODE" in
    # Kept under 40 cells: both front-ends show this as a hint, the UI's in a
    # 41-cell panel and the wizard's on whatever terminal you have. "Homebrew"
    # is three cells longer than "apt" and still fits.
    root)         echo "root -- $sys available" ;;
    passwordless) echo "passwordless sudo -- $sys available" ;;
    password)     echo "sudo ok (asks once for a password)" ;;
    *)            echo "no sudo -- installs under \$HOME" ;;
  esac
}

# True when a privileged command could run without stopping to ask anything.
# Used by --plan, which must not prompt: a plan that says "apt" is honest even
# in password mode, because install_tools() asks once up front before using it.
priv_available() { [ "$PRIV_MODE" != none ]; }

# Ask for the password once, then keep the timestamp warm for the rest of the
# run so no later apt call can stop halfway through and prompt again. Declining
# is not fatal: PRIV_MODE drops to none and every route resolves to its
# userland alternative from there on.
sudo_unlock() {
  [ "$PRIV_MODE" != none ] || return 1
  [ "$SUDO_UNLOCKED" -eq 1 ] && return 0
  if [ "${TOOLS_CAN_PROMPT:-0}" != 1 ]; then
    echo "  NOTE: sudo needs a password and there is no terminal to ask on;"
    echo "        falling back to the userland routes."
    PRIV_MODE=none; SUDO=""; return 1
  fi
  echo ""
  echo "  Some packages install fastest through apt, which needs sudo."
  echo "  Asked once now; everything else in this run reuses it."
  if ! sudo -v; then
    echo "  NOTE: no sudo then -- falling back to the userland routes."
    PRIV_MODE=none; SUDO=""; return 1
  fi
  SUDO_UNLOCKED=1
  # `sudo -v` expires (5 min by default) and a long apt run plus a rustup build
  # can outlast it. The refresher dies with this script -- it polls for the
  # parent rather than trusting a trap, so a kill -9 of install.sh cannot leave
  # it behind.
  ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null || exit 0; sleep 45; done ) &
  SUDO_KEEPALIVE_PID=$!
  trap 'sudo_keepalive_stop' EXIT
  return 0
}

sudo_keepalive_stop() {
  [ -n "$SUDO_KEEPALIVE_PID" ] || return 0
  kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  SUDO_KEEPALIVE_PID=""
}

# Run one command with privilege. $SUDO is deliberately unquoted -- it is either
# empty, "sudo" or "sudo -n", and the word split is the point.
run_priv() {
  if [ -n "$SUDO" ]; then $SUDO "$@"; else "$@"; fi
}

# --- the catalogue --------------------------------------------------------
# id|label|group, one row per tool, and the row ORDER is the install order: a
# tool may only depend on one listed above it. brew and rust come first because
# they are providers as well as tools; the herdr plugins come last because they
# need herdr, and the file viewer wants bat/delta/glow to render with.
#
# brew is listed ahead of git, which is the one ordering that is not obvious.
# On macOS git has no route EXCEPT Homebrew (its installer pulls in the Xcode
# Command Line Tools, git included), so git has to come after it. On Linux the
# dependency runs the other way -- brew bootstraps by cloning its own repo with
# git -- but that costs nothing here: the only machine where brew is wanted and
# git is missing is one with no apt either, and there git is unobtainable
# whichever order they are tried in.
#
# One flat table rather than the three `declare -A` arrays this used to be:
# associative arrays are bash 4, and on macOS this file is read by bash 3.2 --
# which does not merely lack them, it parses `[git]=...` as an arithmetic
# subscript and dies on `set -u` with "git: unbound variable" before the script
# has done anything at all.
TOOL_META=(
  "brew|Homebrew (if needed)|providers"
  "micromamba|conda-forge (if needed)|providers"
  "git|git|providers"
  "buildtools|C toolchain (if needed)|providers"
  "rust|Rust toolchain (cargo)|providers"
  "tmux|tmux|shell"
  "ohmyposh|oh-my-posh|shell"
  "jq|jq (JSON)|shell"
  "zoxide|zoxide (smarter cd)|shell"
  "eza|eza (ls)|shell"
  "fzf|fzf (fuzzy finder)|shell"
  "fd|fd (find)|shell"
  "bat|bat (cat)|shell"
  "delta|delta (git pager)|shell"
  "lazygit|lazygit (git TUI)|shell"
  "glow|glow (markdown)|shell"
  "dua|dua-cli (disk usage)|shell"
  "neovim|Neovim|editor"
  "lazyvim|LazyVim starter|editor"
  "claude|Claude Code|editor"
  "gdown|gdown|python"
  "groundcontrol|ground-control-tui|python"
  "nvitop|nvitop (GPU monitor)|gpu"
  "tailscale|Tailscale (needs 'up')|net"
  "herdr|herdr|herdr"
  "herdr_statusline|herdr-statusline plugin|herdr"
  "herdr_file_viewer|herdr-file-viewer plugin|herdr"
)

# The ids alone, in the same order -- walked far more often than the metadata is
# looked up, and derived here so a new tool means adding exactly one row above.
TOOL_IDS=()
for _row in "${TOOL_META[@]}"; do TOOL_IDS+=("${_row%%|*}"); done
unset _row

_tool_meta() {
  local row rest
  for row in "${TOOL_META[@]}"; do
    [ "${row%%|*}" = "$1" ] || continue
    rest="${row#*|}"
    case "$2" in
      label) printf '%s' "${rest%%|*}" ;;
      group) printf '%s' "${rest#*|}" ;;
    esac
    return 0
  done
  printf '%s' "$1"
}
tool_label() { _tool_meta "$1" label; }
tool_group() { _tool_meta "$1" group; }

# Only the hard ones: a dependency here means "cannot be installed before".
# bat/delta/glow are deliberately not listed under herdr_file_viewer because the
# plugin installs and runs fine without them -- it just falls back to plain text.
#
# herdr_statusline needs rust as well as herdr, and that one is not guesswork:
# its herdr-plugin.toml declares a build step (`sh scripts/build.sh`) which
# compiles hsl-config with `cargo build --release --locked` and only then
# installs the ~/.local/bin/hsl launcher. Without cargo the build exits 1, the
# plugin is not installed at all, and -- since install_tools() swallows each
# installer's output -- the whole explanation was one unattributed "FAILED".
tool_deps() {
  case "$1" in
    lazyvim) echo "neovim git" ;;
    # buildtools as well as rust, and for the same reason: cargo is half a
    # cargo build. tool_present buildtools is have_cc, so a machine that already
    # links satisfies it without installing anything, and one that does not gets
    # "SKIPPED (buildtools is not installed)" instead of a swallowed rustc error.
    herdr_statusline) echo "herdr rust buildtools" ;;
    herdr_file_viewer) echo "herdr" ;;
  esac
}

# --- is it already here? --------------------------------------------------
LAZYVIM_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"

have() { command -v "$1" >/dev/null 2>&1; }

# `have git` is not good enough on macOS. /usr/bin/git is a SHIM that exists on
# every Mac, developer tools or not: run it without them and it prints
# "xcode-select: note: No developer tools were found", pops a GUI installer
# dialog, and fails. So it passes `command -v` and then breaks every clone.
# `xcode-select -p` answers "are the tools actually installed" without
# triggering that dialog. A git from anywhere else (Homebrew, /usr/local) is
# taken at face value, since only the shim needs the question asked.
have_git() {
  have git || return 1
  is_mac || return 0
  case "$(command -v git)" in
    /usr/bin/git) xcode-select -p >/dev/null 2>&1 ;;
    *) return 0 ;;
  esac
}

# The C linker every cargo build needs, and the reason `have cargo` was never
# enough to know one would succeed: rustup ships a compiler for Rust and NOTHING
# to link its objects with. On a brand-new machine -- a slim container, an HPC
# login node, a fresh VM -- cargo therefore gets a long way through the crate
# graph and then dies on `error: linker "cc" not found` for every build script
# at once. rustc invokes the linker as `cc` by name, so a machine with gcc or
# clang but no `cc` in front of it fails identically; cc_linker() is what turns
# that from a dead end into a `-C linker=` flag.
#
# /usr/bin/cc on macOS is the same shim /usr/bin/git is, and answers the same
# way -- so is the whole toolchain there, not just a name on PATH.
cc_probe() {
  local c
  for c in cc gcc clang; do
    have "$c" || continue
    if is_mac; then
      case "$(command -v "$c")" in
        /usr/bin/*) xcode-select -p >/dev/null 2>&1 || continue ;;
      esac
    fi
    printf '%s' "$c"; return 0
  done
  return 1
}
have_cc() { cc_probe >/dev/null; }

# Empty when the linker is already spelled `cc` (rustc's default, nothing to
# say); otherwise the compiler to point rustc at instead.
cc_linker() {
  local c; c="$(cc_probe)" || return 1
  [ "$c" = cc ] && return 0
  printf '%s' "$c"
}

# Run a cargo build with whatever linker this machine actually has. RUSTFLAGS is
# only set when it would say something, and only for the child -- an existing
# RUSTFLAGS in the environment is somebody's deliberate choice and replacing it
# silently is worse than not helping.
cargo_with_linker() {
  local linker
  if [ -z "${RUSTFLAGS:-}" ] && linker="$(cc_linker)" && [ -n "$linker" ]; then
    RUSTFLAGS="-C linker=$linker" "$@"
  else
    "$@"
  fi
}

# Where Homebrew lives, per platform. Checked as a path rather than with
# `have brew` because a machine very often HAS brew and has simply never put it
# on PATH -- nothing does that until a shell sources its shellenv, which on this
# setup is shellrc_additions.sh, i.e. later than any of this. Missing that would
# make us install a second copy over the top of a perfectly good one.
# Most-official first. On macOS that is Apple silicon's /opt/homebrew, then
# Intel's /usr/local, then the unprivileged clone install_brew() falls back to;
# on Linux, the two linuxbrew spellings. The lists are spelled out in the loops
# rather than returned from a helper, so $HOME stays quoted the whole way.
brew_prefix() {
  local dir
  if is_mac; then
    for dir in /opt/homebrew /usr/local "$HOME/homebrew"; do
      if [ -x "$dir/bin/brew" ]; then printf '%s' "$dir"; return 0; fi
    done
  else
    for dir in "$HOME/.linuxbrew" /home/linuxbrew/.linuxbrew; do
      if [ -x "$dir/bin/brew" ]; then printf '%s' "$dir"; return 0; fi
    done
  fi
  return 1
}

# Put an already-installed Homebrew on PATH for the rest of this run.
brew_activate() {
  local prefix
  prefix="$(brew_prefix)" || return 1
  eval "$("$prefix/bin/brew" shellenv)" || return 1
  have brew
}

# --- conda-forge, via micromamba ------------------------------------------
# The answer to "how do you install git with no sudo", and the reason this
# section exists at all. Until it did, a machine with no apt, no Homebrew and no
# git had NO route to git, tmux, eza, fd, bat or delta -- which is to say
# an HPC login node, the exact machine this repo is most often set up on, was
# told "needs apt" about half the catalogue.
#
# micromamba is the bootstrap because it is a single statically-useful binary at
# a permanent-redirect URL: no privilege, no Python, no tarball, no unzip, and
# nothing to build. Exactly the shape fetch_bin() already handles for jq and
# oh-my-posh. conda-forge then has current builds of all six tools above for
# every platform this repo targets (linux-64/aarch64, osx-64/arm64).
#
# Two deliberate limits:
#
#   * it is a LAST resort, ordered behind apt, cargo and Homebrew everywhere.
#     A ~300MB environment is worth it to unblock a tool, not to replace a route
#     that already works;
#   * `buildtools` is NOT routed through it, even though conda-forge has gcc.
#     A conda compiler links against conda's own libgcc and sysroot, so the
#     cargo binaries it produced would depend on this environment continuing to
#     exist -- a `cargo build` that works today and breaks when the env is
#     pruned is worse than an honest "needs apt". herdr_statusline therefore
#     still wants a real compiler, and still says so.
#
# The env lives in its own prefix and only the binaries actually asked for are
# symlinked into ~/.local/bin. Putting $CONDA_ENV/bin on PATH would be less
# code and much worse: a conda env's bin holds its own python, curl, openssl and
# ncurses, and shadowing the system's with them is the classic way conda breaks
# a shell it was only supposed to add one command to.
CONDA_ROOT="$HOME/.local/share/dotfiles-conda"
CONDA_ENV="$CONDA_ROOT/envs/tools"

# conda-forge's spelling of this platform, which is its own again -- neither
# arch_deb()'s amd64/arm64 nor arch_tag()'s x86_64/arm64, and "osx" rather than
# either darwin or macos. Empty for an architecture conda-forge does not build.
conda_platform() {
  case "$OS_KERNEL/$(uname -m)" in
    Darwin/arm64)       printf 'osx-arm64' ;;
    Darwin/x86_64)      printf 'osx-64' ;;
    */x86_64|*/amd64)   printf 'linux-64' ;;
    */aarch64|*/arm64)  printf 'linux-aarch64' ;;
    */ppc64le)          printf 'linux-ppc64le' ;;
    *) return 1 ;;
  esac
}

# By path, not by PATH, for the same reason brew_prefix() is: an earlier run
# put it in ~/.local/bin, which a non-login shell has very likely never had.
micromamba_bin() {
  if have micromamba; then command -v micromamba; return 0; fi
  [ -x "$HOME/.local/bin/micromamba" ] || return 1
  printf '%s' "$HOME/.local/bin/micromamba"
}
have_micromamba() { micromamba_bin >/dev/null 2>&1; }

herdr_has_plugin() {
  have herdr || return 1
  herdr plugin list 2>/dev/null | grep -q "^- $1 "
}

tool_present() {
  case "$1" in
    git)           have_git ;;
    tailscale)     have tailscale ;;
    rust)          have cargo ;;
    # "is there a linker", not "did we install a package": a machine that came
    # with gcc, or with clang and no cc, already satisfies this and must not be
    # sent to apt for build-essential it does not need.
    buildtools)    have_cc ;;
    tmux)          have tmux ;;
    brew)          have brew || brew_prefix >/dev/null 2>&1 ;;
    micromamba)    have_micromamba ;;
    ohmyposh)      have oh-my-posh ;;
    jq)            have jq ;;
    zoxide)        have zoxide ;;
    eza)           have eza ;;
    fzf)           have fzf ;;
    fd)            have fd || have fdfind ;;
    bat)           have bat || have batcat ;;
    delta)         have delta ;;
    lazygit)       have lazygit ;;
    glow)          have glow ;;
    # The package is dua-cli, the binary is dua -- same split as git-delta/delta
    # and fd-find/fd, and the id follows the binary like those two do.
    dua)           have dua ;;
    neovim)        have nvim ;;
    # The starter drops an init.lua in; anything else already there is somebody
    # else's config and install_lazyvim() will refuse to touch it.
    lazyvim)       [ -e "$LAZYVIM_DIR/init.lua" ] ;;
    # The native build symlinks ~/.local/bin/claude at the versioned binary
    # under ~/.local/share/claude/versions, so the launcher is the thing to
    # look for -- an update swaps what it points at, not where it lives.
    claude)        have claude || [ -x "$HOME/.local/bin/claude" ] ;;
    gdown)         have gdown ;;
    groundcontrol) have groundcontrol || have gc ;;
    nvitop)        have nvitop ;;
    herdr)         have herdr ;;
    herdr_statusline)  herdr_has_plugin herdr-statusline ;;
    herdr_file_viewer) herdr_has_plugin herdr-file-viewer ;;
    *) return 1 ;;
  esac
}

# The answer variable for a tool id. ${1^^} would be the obvious spelling and is
# bash 4; the ids are plain ASCII so tr is exact, at the cost of a fork on a
# list of twenty-odd. Both front-ends and theme.env agree on this name.
tool_var() { printf 'TOOL_%s' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"; }

# TOOL_<ID>, defaulting to on. This is the "all on by default, deselect what you
# don't want" rule, in one place.
tool_selected() {
  local var; var="$(tool_var "$1")"
  [ "${!var:-1}" = 1 ]
}

# Give every unset answer its default, so install.sh has real values to export
# to the setup UI and to write into theme.env rather than blanks. Unlike the
# OMP_* answers in lib/derive.sh there is nothing to migrate here, so "unset"
# can just mean "on" with no ambiguity to preserve.
tools_defaults() {
  local id var
  for id in "${TOOL_IDS[@]}"; do
    var="$(tool_var "$id")"
    [ -n "${!var:-}" ] || printf -v "$var" '%s' 1
  done
}

# Every TOOL_<ID>=value line, for install.sh's theme.env writer.
tools_answers() {
  local id var
  for id in "${TOOL_IDS[@]}"; do
    var="$(tool_var "$id")"
    printf '%s=%s\n' "$var" "${!var:-1}"
  done
}

# Export them all, for handing the current answers to tui/configure.py.
tools_export() {
  local id
  for id in "${TOOL_IDS[@]}"; do export "$(tool_var "$id")"; done
}

# --- providers ------------------------------------------------------------
# Availability during a plan walk or an install run. These start from what is
# on the machine now and are flipped on as the walk passes a provider it is
# going to install, so a tool listed after rust can count on cargo.
AVAIL_APT=0 AVAIL_CARGO=0 AVAIL_UV=0 AVAIL_BREW=0 AVAIL_GIT=0 AVAIL_CC=0
AVAIL_CONDA=0

providers_init() {
  AVAIL_APT=0; priv_available && have apt-get && AVAIL_APT=1
  AVAIL_CARGO=0; have cargo && AVAIL_CARGO=1
  AVAIL_UV=0;    have uv    && AVAIL_UV=1
  # A linker is a provider in its own right, separate from cargo: rustup brings
  # cargo and no `cc`, so the two are genuinely independent facts about a
  # machine and every cargo route has to check both. See have_cc().
  AVAIL_CC=0;    have_cc   && AVAIL_CC=1
  # git is a provider as much as a tool -- fzf, LazyVim and Homebrew's own
  # bootstrap all clone with it -- so it gets the same treatment as cargo: what
  # is here now, flipped on as the walk passes it. Without that, a Mac with no
  # developer tools reports fzf and LazyVim as blocked in the plan and then
  # installs both, because git arrived in between.
  AVAIL_GIT=0;   have_git  && AVAIL_GIT=1
  # Detected by path, not by PATH -- see brew_prefix(). install_tools() calls
  # brew_activate() to make an adopted one actually usable; the plan only needs
  # to know it is there, and must stay free of side effects.
  AVAIL_BREW=0
  if have brew || brew_prefix >/dev/null 2>&1; then AVAIL_BREW=1; fi
  # Same reasoning again: an earlier run's micromamba sits in ~/.local/bin, which
  # this process may not have on PATH yet.
  #
  # An `if` rather than the `have_micromamba && AVAIL_CONDA=1` the lines above
  # use, and that is load-bearing: this is the LAST statement of the function, so
  # its exit status is the function's. install.sh sources this file under
  # `set -euo pipefail` and calls providers_init bare, so on any machine without
  # micromamba -- i.e. almost all of them -- a failing AND-list here took the
  # whole install down silently, right after "Saved answers to ...". The earlier
  # lines get away with it only by not being last. An `if` with no else always
  # returns 0, which is also why the brew line above is written this way.
  AVAIL_CONDA=0
  if have_micromamba; then AVAIL_CONDA=1; fi
}

# "the walk has just got past a provider": everything after it may count on it.
# One place rather than three identical case statements, since forgetting one is
# how a plan starts disagreeing with the run it is supposed to be describing.
providers_seen() {
  case "$1" in
    rust) AVAIL_CARGO=1 ;;
    brew) AVAIL_BREW=1 ;;
    git)  AVAIL_GIT=1 ;;
    buildtools) AVAIL_CC=1 ;;
    micromamba) AVAIL_CONDA=1 ;;
  esac
}

# ...and the other half of that, which was missing. A provider whose install was
# ATTEMPTED AND FAILED must stop being offered as a route, or every tool behind
# it fails in turn for a reason that is not its own: kill the network and
# `micromamba` failing was followed by git and tmux each reporting a bare
# FAILED, two more round-trips spent, and nothing saying why.
#
# Only the two providers whose "is it coming" answer is PREDICTIVE need this.
# AVAIL_CARGO/AVAIL_CC/AVAIL_GIT are only ever flipped on by providers_seen, so a
# failed rust already stops cargo_usable() dead and the routes behind it fall
# through on their own. brew_coming() and conda_coming(), by contrast, answer
# from brew_needed()/conda_needed() -- which say what SHOULD happen, and go on
# saying it after it has already not happened.
BREW_FAILED=0
CONDA_FAILED=0
providers_failed() {
  case "$1" in
    brew)       BREW_FAILED=1 ;;
    micromamba) CONDA_FAILED=1 ;;
  esac
}

# cargo either is here, or rust is selected and about to put it here.
cargo_coming() {
  [ "$AVAIL_CARGO" = 1 ] && return 0
  tool_selected rust
}

# A cargo route is only real when BOTH halves are: a cargo to run and a linker
# for it to finish with. Everything that used to test AVAIL_CARGO alone now asks
# this instead, which is the whole bug -- `have cargo` on a machine with no
# compiler resolved to a route that could not possibly work, and reported it as
# a plan the run would follow.
cargo_usable() {
  [ "$AVAIL_CARGO" = 1 ] && [ "$AVAIL_CC" = 1 ]
}

# Which release tarball eza/fd/bat/delta each publish FOR THIS MACHINE, printed
# as the triple in the asset name, or nothing at all. Named for the tool id, not
# the crate, since that is what every caller iterates over.
#
# This is the one thing that decides whether these four are a download or a
# no -- **none of them is ever compiled** (see _route_prebuilt() below for why),
# so an arch or an OS this returns nothing for is an arch they do not get
# installed on. It is therefore a table of what upstream actually ships rather
# than one shared triple function, because the four disagree in both directions:
#
#   eza    linux gnu only          -- no musl for aarch64, and no darwin at all
#   delta  linux gnu, darwin arm64 -- no x86_64-apple-darwin is published
#   fd     linux musl, darwin arm64 -- ditto; x86_64-apple-darwin was dropped
#   bat    linux musl, both darwins
#
# Getting one of these wrong is not fatal but it is a wasted round trip: the
# asset lookup simply matches nothing and the install fails where the plan said
# it would work. On macOS it costs nothing in practice -- Homebrew is ahead of
# this on every Mac that has it, and this is what a Mac without one falls to.
# It is a table rather than a call into rust_triple()/rust_triple_gnu() because
# those name a triple for every arch dua-cli covers, including riscv64 and armv7
# -- and none of these four publishes a riscv64 build at all, so borrowing that
# answer would advertise a download that matches no asset. Anything not listed
# is a `return 1`, which the route reads as "no prebuilt route here".
tarball_triple() {
  local id="$1" m libc
  case "$(uname -m)" in
    x86_64|amd64)  m=x86_64 ;;
    aarch64|arm64) m=aarch64 ;;
    armv7l|armv7)  m=arm ;;
    *)             return 1 ;;
  esac
  if is_mac; then
    case "$id/$m" in
      delta/aarch64|fd/aarch64|bat/aarch64) printf 'aarch64-apple-darwin' ;;
      bat/x86_64)                           printf 'x86_64-apple-darwin' ;;
      *) return 1 ;;
    esac
    return 0
  fi
  # eza and delta publish no aarch64 musl build (only x86_64's), so both take
  # gnu on every arch rather than trying musl and falling back for just those
  # two. fd and bat ship musl everywhere, and a static binary is the better
  # answer on a machine whose glibc vintage is not ours to assume.
  case "$id" in
    eza|delta) libc=gnu ;;
    fd|bat)    libc=musl ;;
    *)         return 1 ;;
  esac
  # armv7 spells both of those with an eabihf tail; nothing else does.
  case "$m" in
    arm) printf 'arm-unknown-linux-%seabihf' "$libc" ;;
    *)   printf '%s-unknown-linux-%s' "$m" "$libc" ;;
  esac
}

# Whether a compiler is worth installing here: only when something selected has
# no route EXCEPT a cargo build. Deliberately shaped like brew_needed() and
# deliberately NOT asking tool_route() -- the cargo routes consult AVAIL_CC, so
# asking them what they would do would be circular. Kept explicit instead.
cc_needed() {
  tool_selected buildtools || return 1
  [ "$AVAIL_CC" = 1 ] && return 1
  cargo_coming || return 1          # nothing will be building with cargo at all
  # herdr-statusline compiles hsl-config; there is no prebuilt route to it, and
  # deliberately no conda one either (see the conda-forge section above), so this
  # is the one clause a conda environment cannot answer.
  if ! is_mac && tool_selected herdr_statusline && ! tool_present herdr_statusline; then
    return 0
  fi
  # ...and it is now the ONLY clause. eza/fd/bat/delta used to be counted here
  # too, because cargo was their last-resort route; it no longer is (see
  # _route_prebuilt()), so nothing they need can be bought with a compiler.
  return 1
}

# Whether a conda-forge environment is worth putting on this machine: only when
# it is the LAST route left to something actually selected. Shaped like
# brew_needed() and cc_needed(), and like them it deliberately does not ask
# tool_route() -- those routes consult AVAIL_CONDA, so that would be circular.
#
# It never asks brew_needed()/brew_coming() either, which is what keeps the two
# from calling each other in a loop. Instead the precedence between them is
# FIXED here and mirrored there: an already-present Homebrew wins (a bottle is
# seconds), but one that would have to be bootstrapped loses -- ~1GB and a
# source build on a no-admin Mac, against a 20MB binary and a 300MB env.
conda_needed() {
  tool_selected micromamba || return 1
  [ "$AVAIL_CONDA" = 1 ] && return 1
  conda_platform >/dev/null 2>&1 || return 1   # no conda-forge build for this arch
  [ "$AVAIL_APT" = 1 ] && return 1             # apt covers every candidate below
  [ "$AVAIL_BREW" = 1 ] && return 1            # so does a Homebrew already here
  local id
  # git first, because it is the one that unblocks others (fzf, LazyVim, and
  # Homebrew's own Linux bootstrap all clone with it). On macOS with admin,
  # Homebrew's installer brings the Xcode CLT and therefore git AND a compiler,
  # which is a better answer than a conda git -- so that case is left to it.
  if tool_selected git && ! tool_present git && ! { is_mac && priv_available; }; then
    return 0
  fi
  # tmux is the other one that matters: upstream ships source only, so before
  # this it was apt, Homebrew, or nothing at all -- and "nothing at all" on the
  # login nodes whose tmux config is the main thing this repo syncs.
  if tool_selected tmux && ! tool_present tmux; then return 0; fi
  # And the four rust tools, whenever upstream publishes no release build for
  # this machine. There used to be a `cargo_coming && AVAIL_CC` guard in front
  # of this loop -- a compiler was the other way out, so conda was not needed
  # when one was coming. Compiling these is no longer a route at all (see
  # _route_prebuilt()), so conda-forge is now the ONLY thing behind the tarball
  # and the guard would just have blocked the tool for no gain.
  for id in eza fd bat delta; do
    if tool_selected "$id" && ! tool_present "$id" && ! tarball_triple "$id" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

# ...and whether it can be, the brew_obtainable() counterpart. Far simpler,
# which is the point of choosing micromamba as the bootstrap: one curl of one
# binary, no privilege, no git, no compiler, nothing to unpack.
conda_obtainable() { have curl && conda_platform >/dev/null 2>&1; }

# What every route that falls back to conda-forge asks, rather than AVAIL_CONDA
# -- micromamba is resolved early in the walk, but install_git()/install_tmux()
# and friends re-resolve their own route outside that order.
conda_coming() {
  [ "$AVAIL_CONDA" = 1 ] && return 0
  [ "$CONDA_FAILED" = 1 ] && return 1  # already tried this run; it did not work
  conda_needed && conda_obtainable
}

# Homebrew is bootstrapped only when it is the *sole* remaining route to
# something that was actually asked for -- a ~1GB install is not something to do
# on spec. glow and neovim never count towards that: their release tarballs
# work on every machine, privileged or not.
brew_needed() {
  tool_selected brew || return 1
  [ "$AVAIL_BREW" = 1 ] && return 1
  [ "$AVAIL_APT" = 1 ] && return 1     # apt covers everything brew would
  local id
  # Everything below is also served by conda-forge except macOS's git and
  # Tailscale, so a conda environment that is coming anyway settles those cases
  # far more cheaply than bootstrapping Homebrew for them would. See
  # conda_needed() for the fixed precedence this mirrors; asking conda_coming()
  # here is safe only because conda_needed() never asks back.
  local conda_will=0
  conda_coming && conda_will=1
  # tmux used to be the one entry that counted on BOTH platforms, since upstream
  # ships source only and macOS ships screen rather than tmux. conda-forge now
  # has a current tmux for all four platforms, so Homebrew is only wanted for it
  # when there is no conda route either. tool_selected/tool_present rather than
  # tool_route, which would recurse straight back into here.
  if [ "$conda_will" = 0 ] && tool_selected tmux && ! tool_present tmux; then return 0; fi
  # macOS only. There is no apt to fall back to there, so brew is the system
  # route and these two have no other one at all: git ships with the Xcode
  # Command Line Tools (which Homebrew's own installer pulls in) and Tailscale
  # publishes no darwin tarball. Linux has no such case left -- nvtop was the
  # sharp one (no cargo crate, no useful release tarball) and it is gone from
  # the catalogue; nvitop, which replaced it, is a uv tool install.
  if is_mac; then
    for id in git tailscale; do
      if tool_selected "$id" && ! tool_present "$id"; then return 0; fi
    done
  fi
  if [ "$conda_will" = 0 ] && ! cargo_coming; then
    for id in eza fd bat delta; do
      if tool_selected "$id" && ! tool_present "$id"; then return 0; fi
    done
  fi
  return 1
}

# ...and whether it CAN be. brew_needed() answers "is Homebrew wanted", which is
# a different question from "will it be here", and the brew row resolves the
# second one two branches further down: the installer needs admin on macOS, and
# every other route is a git clone of Homebrew's own repo. On a bare Mac -- no
# admin, and a /usr/bin/git that is only a shim -- "wanted" was yes while the
# brew row itself was blocked, so six routes advertised a Homebrew install the
# run could never perform. Mirrors those branches deliberately; if one moves,
# this moves with it.
brew_obtainable() {
  is_mac && priv_available && return 0   # the official installer brings the CLT
  have_git                               # otherwise: something to clone with
}

# The question every route that falls back to Homebrew actually wants answered.
# AVAIL_BREW alone is not it either: brew is the FIRST catalogue entry, so a walk
# that is going to install it has already flipped the flag by the time anything
# else is resolved -- but a route asked outside that order (install_tmux() and
# install_git() re-resolve their own) still needs the honest answer.
brew_coming() {
  [ "$AVAIL_BREW" = 1 ] && return 0
  [ "$BREW_FAILED" = 1 ] && return 1   # already tried this run; it did not work
  brew_needed && brew_obtainable
}

# --- route resolution -----------------------------------------------------
# One decision point, used by both --plan and install_tools(). Prints
# "method|detail". An empty method means there is no route on this machine; the
# method "na" means there is nothing to do here and never was (herdr-statusline
# on a Mac, Homebrew on a machine that needs nothing from it), which both report
# as a skip rather than as a machine that fell short.
tool_route() {
  case "$1" in
    # AVAIL_BREW rather than brew_needed(): the flag is already "brew is here,
    # or the walk has just installed it", and brew is ordered ahead of git
    # precisely so that answer is settled by the time this is asked. Calling
    # brew_needed() from here would be the circular version, since on Linux
    # Homebrew bootstraps itself by cloning its own repo WITH git.
    git)      if [ "$AVAIL_APT" = 1 ]; then echo "apt|git"
              elif [ "$AVAIL_BREW" = 1 ]; then echo "brew|git"
              # The no-privilege route, and the reason the conda section exists:
              # before it, this line was the flat "needs apt" that a no-sudo box
              # got about the one tool half the catalogue clones with.
              elif conda_coming; then echo "conda|git (conda-forge)"
              elif is_mac; then echo "|needs Homebrew, or: xcode-select --install"
              else echo "|needs apt, Homebrew or conda-forge"; fi ;;
    # On Linux with privilege the official script is right: it picks the distro
    # package and sets up the systemd unit, which is what makes a real node.
    # Without, the static tarball still gives a working CLI and daemon, but the
    # daemon has to be started by hand in userspace-networking mode.
    # There is no darwin tarball and the install script refuses to run on macOS,
    # so there the brew formula is the whole story (the App Store build is a GUI
    # app with a sandboxed CLI). print_next_steps() spells out what is left in
    # each of the three cases rather than leaving it to be discovered.
    tailscale) if is_mac; then
                 if [ "$AVAIL_BREW" = 1 ]; then echo "brew|tailscale (then: brew services start)"
                 else echo "|needs Homebrew (or the App Store app)"; fi
               elif priv_available; then echo "script|tailscale.com/install.sh + systemd"
               else echo "tarball|static binaries -> ~/.local/bin (userspace)"; fi ;;
    rust)     echo "script|rustup.rs -> ~/.cargo" ;;
    # Nothing to install when the machine already links, and nothing worth
    # installing when nothing selected would build -- both are "na", not a
    # shortfall. Otherwise apt is the only route: there is no userland way to
    # put a working C toolchain on a Linux box, and a Homebrew gcc is a
    # multi-hundred-megabyte detour that still leaves rustc looking for `cc`.
    # Blocked here is honest, and says which tools it costs.
    buildtools) if [ "$AVAIL_CC" = 1 ]; then echo "na|already present"
              elif ! cc_needed; then echo "na|not needed on this machine"
              elif [ "$AVAIL_APT" = 1 ]; then echo "apt|build-essential"
              elif is_mac; then echo "|needs: xcode-select --install"
              else echo "|needs apt, or a cc/gcc/clang on PATH"; fi ;;
    # have_git, not AVAIL_GIT: brew is the FIRST entry in the catalogue, so
    # nothing has had a chance to install git yet and the live answer is the
    # only true one. On macOS that is also why the admin route matters so much
    # -- the official installer brings the Xcode CLT (and therefore git) with
    # it, where the clone needs a git that a bare Mac does not have.
    brew)     if ! brew_needed; then echo "na|not needed on this machine"
              elif is_mac && priv_available; then echo "script|brew.sh installer (+ Xcode CLT)"
              elif ! have_git && is_mac; then echo "|needs admin, or a git to clone with"
              elif ! have_git; then echo "|needs git to clone Homebrew with"
              elif is_mac; then echo "git|~/homebrew (no admin: builds from source)"
              else echo "git|~/.linuxbrew (sole route to something selected)"; fi ;;
    # The unprivileged system route. Gated exactly like brew: only when it is
    # the last one left to something selected, so a machine with apt (or a
    # Homebrew already on it) never grows a conda environment it has no use for.
    # "na" rather than blocked in that case -- there was never anything to do.
    micromamba) if [ "$AVAIL_CONDA" = 1 ]; then echo "na|already present"
              elif ! conda_platform >/dev/null 2>&1; then echo "na|no conda-forge build for $(uname -m)"
              elif ! conda_needed; then echo "na|not needed on this machine"
              elif ! have curl; then echo "|needs curl"
              else echo "binary|micromamba -> ~/.local/bin (conda-forge)"; fi ;;
    # The one tool here whose config this repo cares about most and which has no
    # userland route at all: upstream ships source only (a build wants libevent
    # and ncurses headers, i.e. the whole problem buildtools exists to dodge),
    # and the static builds floating around GitHub are third-party and version-
    # lagging -- not something to put on every machine on this repo's authority.
    # So apt, Homebrew, or a clear no. macOS does NOT ship tmux (it ships
    # screen), which is why brew is the mac answer rather than "already there".
    # In practice the machines that hit the blocked case -- HPC login nodes --
    # are also the ones that came with tmux.
    tmux)     if [ "$AVAIL_APT" = 1 ]; then echo "apt|tmux"
              elif [ "$AVAIL_BREW" = 1 ]; then echo "brew|tmux"
              # conda-forge ahead of a Homebrew that is not here yet: both are
              # prebuilt binaries, and one of them is not a 1GB bootstrap.
              elif conda_coming; then echo "conda|tmux (conda-forge)"
              elif brew_coming; then echo "brew|tmux"
              elif is_mac; then echo "|needs Homebrew or conda-forge"
              else echo "|needs apt, Homebrew or conda-forge"; fi ;;
    ohmyposh) echo "binary|oh-my-posh release -> ~/.local/bin" ;;
    jq)       if [ "$AVAIL_APT" = 1 ]; then echo "apt|jq"
              else echo "binary|jqlang/jq -> ~/.local/bin"; fi ;;
    herdr)    echo "script|herdr.dev -> ~/.local/bin" ;;
    zoxide)   if [ "$AVAIL_APT" = 1 ]; then echo "apt|zoxide"
              else echo "script|zoxide install.sh -> ~/.local/bin"; fi ;;
    fzf)      if [ "$AVAIL_GIT" = 1 ]; then echo "git|~/.fzf (--no-update-rc)"
              elif [ "$AVAIL_APT" = 1 ]; then echo "apt|fzf"
              else echo "|needs git or apt"; fi ;;
    # Prebuilt or not at all -- see _route_prebuilt(). Which release build each
    # of them publishes for this machine is tarball_triple()'s table, not an
    # argument here; the arguments are only the three names that differ per
    # package manager, plus the repo the tarball comes from.
    eza)      _route_prebuilt eza   eza      eza      eza-community/eza ;;
    fd)       _route_prebuilt fd    fd-find  fd-find  sharkdp/fd ;;
    bat)      _route_prebuilt bat   bat      bat      sharkdp/bat ;;
    delta)    _route_prebuilt delta git-delta git-delta dandavison/delta ;;
    # Not in apt (nor Debian) -- there is a golang-github-jesseduffield-lazycore
    # package but no lazygit itself -- and it is Go, not Rust, so there is no
    # cargo fallback the way dua-cli has one. Upstream ships a release tarball
    # for every arch this repo targets, which needs no privilege and is
    # therefore the first choice; Homebrew and conda-forge both carry it too
    # (conda-forge on all four subdirs, kept current), so an architecture the
    # tarball has no asset for still has two working fallbacks.
    lazygit)  case "$(uname -m)" in
                x86_64|amd64|aarch64|arm64)
                  echo "tarball|jesseduffield/lazygit -> ~/.local/bin" ;;
                *)
                  if [ "$AVAIL_BREW" = 1 ]; then echo "brew|lazygit"
                  elif conda_coming; then echo "conda|lazygit (conda-forge)"
                  elif brew_coming; then echo "brew|lazygit"
                  else echo "|no release for $(uname -m), and no Homebrew or conda-forge"; fi ;;
              esac ;;
    glow)     echo "tarball|charmbracelet/glow -> ~/.local/bin" ;;
    # dua-cli is in NO system package manager here -- not apt on 24.04, not
    # Debian -- so the usual apt-first shape does not apply. What it does ship is
    # a static musl binary per platform (plus riscv64 and armv7), which needs no
    # privilege, no compiler and no matching glibc: strictly the best route on
    # every machine, so there is nothing for privilege to change. conda-forge has
    # it too but two versions behind, and pulling a ~300MB environment for a tool
    # whose own binary is a 2MB download would be the wrong trade -- so dua is
    # deliberately NOT in conda_needed().
    #
    # cargo only as the answer for an architecture rust_triple() cannot name;
    # install_dua() also falls back to it if the asset lookup fails, for the
    # reason spelled out there.
    dua)      if rust_triple >/dev/null 2>&1; then echo "tarball|Byron/dua-cli -> ~/.local/bin"
              elif cargo_usable; then echo "cargo|dua-cli"
              else echo "|no release for $(uname -m), and no usable cargo"; fi ;;
    # apt's neovim is 0.9.5 on 24.04, which LazyVim will start on and then warn
    # about forever. The official tarball is current, needs no privilege, and
    # lands where shellrc_additions.sh already puts ~/.local/nvim/bin on PATH.
    neovim)   echo "tarball|neovim stable -> ~/.local/nvim" ;;
    lazyvim)  if [ "$AVAIL_GIT" = 1 ]; then echo "git|LazyVim/starter -> $LAZYVIM_DIR"
              else echo "|needs git"; fi ;;
    # One route on both platforms: the native installer detects darwin/linux and
    # arm64/x64 itself, lands everything under $HOME (a versioned binary in
    # ~/.local/share/claude plus the ~/.local/bin/claude symlink), and needs no
    # privilege and no node. Unlike rustup, fzf and uv it writes to no shell rc,
    # so there is no --no-modify-path to pass: nothing here can land in the
    # tracked ~/.profile symlink.
    claude)   echo "script|claude.ai/install.sh -> ~/.local/bin" ;;
    gdown|groundcontrol|nvitop)
              if [ "$AVAIL_UV" = 1 ]; then echo "uv|uv tool install $(_pypi_name "$1")"
              else echo "|needs uv"; fi ;;
    # The plugin's own herdr-plugin.toml is `platforms = ["linux"]`, so on macOS
    # there is nothing to install rather than something that failed -- and it
    # wraps tmux around a herdr session to draw a status line, which is a Linux
    # box's idea of a login shell anyway. na, not an empty method.
    #
    # Unlike every other cargo consumer this one has no second route: the plugin
    # BUILDS hsl-config, there is no release binary, so both halves of
    # cargo_usable are hard requirements and a machine short of either is
    # blocked rather than attempted. Saying which half is missing is the point --
    # the failure this replaces was 30 lines of rustc output ending in
    # `linker "cc" not found`, printed nowhere because install_tools() sends each
    # installer's output to /dev/null.
    herdr_statusline)  if is_mac; then echo "na|linux only (plugin manifest)"
                       elif ! cargo_coming; then echo "|needs rust (builds hsl-config)"
                       elif [ "$AVAIL_CC" = 0 ]; then echo "|needs a C compiler (cargo build)"
                       else echo "plugin|iiii1224/herdr-statusline"; fi ;;
    herdr_file_viewer) echo "plugin|smarzban/herdr-file-viewer" ;;
    *) echo "|unknown tool" ;;
  esac
}

# eza / fd / bat / delta: four prebuilt routes and no fifth. **cargo is not one
# of them, deliberately**, and that is the whole point of this function.
#
# It used to be the last resort, on the reasoning that a slow install beats no
# install. It does not. `cargo install git-delta` is five to ten minutes of
# compiling on a decent machine and considerably worse on a login node, it is
# reached exactly on the machines least able to afford it (no apt, no Homebrew),
# and it was silently reached in a second way too: the tarball route below can
# only test whether this arch HAS an asset name, not whether the lookup will
# succeed, so one rate-limited GitHub API call on a shared IP turned a download
# into a compile with nothing said about it. Every one of these four is a
# convenience -- a nicer ls, a nicer find, a nicer cat, a nicer diff -- and none
# is a dependency of anything else here (herdr-file-viewer wants bat/delta/glow
# and falls back to plain text without them). A tool of that weight does not get
# to cost ten minutes. So the honest answer on a machine with no prebuilt route
# is `blocked`, which the plan and the run both report, and the install moves on.
#
# rust/cargo stays in the catalogue and stays useful: herdr-statusline genuinely
# has no prebuilt route (it compiles hsl-config), and that is now the only thing
# in here that ever invokes a compiler.
#
# Order, fastest first:
#   apt          -- Linux with privilege; seconds, and the machine's own package
#   brew         -- macOS with Homebrew ALREADY here; a bottle, also seconds
#   tarball      -- upstream's own static build, if it publishes one for this
#                   machine (tarball_triple() above is the table of that)
#   conda-forge  -- a ~20MB micromamba plus a ~300MB env, but prebuilt
#   brew         -- one that would have to be bootstrapped: ~1GB, so it is last
#
# Package names are a third spelling again -- apt's fd-find, Homebrew's fd,
# conda-forge's fd-find -- so the conda one is passed in rather than derived.
_route_prebuilt() {
  local id="$1" apt_pkg="$2" conda_pkg="$3" repo="$4"
  local formula="${apt_pkg%-find}"
  if is_mac; then
    if [ "$AVAIL_BREW" = 1 ]; then echo "brew|$formula"
    elif tarball_triple "$id" >/dev/null 2>&1; then echo "tarball|$repo -> ~/.local/bin"
    elif conda_coming; then echo "conda|$conda_pkg (conda-forge)"
    elif brew_coming; then echo "brew|$formula"
    else echo "|needs Homebrew or conda-forge"; fi
    return
  fi
  if [ "$AVAIL_APT" = 1 ]; then echo "apt|$apt_pkg"
  elif tarball_triple "$id" >/dev/null 2>&1; then echo "tarball|$repo -> ~/.local/bin"
  elif conda_coming; then echo "conda|$conda_pkg (conda-forge)"
  elif brew_coming; then echo "brew|$formula"
  else echo "|needs apt, Homebrew or conda-forge"; fi
}

_pypi_name() {
  case "$1" in
    groundcontrol) echo "ground-control-tui" ;;
    *) echo "$1" ;;
  esac
}

# --- plumbing -------------------------------------------------------------
TOOLS_PATH_HINTS=()          # dirs a tool landed in that a new shell will need
TOOLS_INSTALLED=()
TOOLS_FAILED=()
TOOLS_SKIPPED=()

note_path() {
  local dir="$1" d
  [ -d "$dir" ] || return 0
  for d in "${TOOLS_PATH_HINTS[@]+"${TOOLS_PATH_HINTS[@]}"}"; do
    [ "$d" = "$dir" ] && return 0
  done
  TOOLS_PATH_HINTS+=("$dir")
}

APT_UPDATED=0
apt_install() {
  sudo_unlock || return 1
  if [ "$APT_UPDATED" -eq 0 ]; then
    APT_UPDATED=1
    run_priv apt-get update -qq || true
  fi
  run_priv env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
}

cargo_install() { cargo_with_linker cargo install --locked --quiet "$@"; }

# uv drops the tool's executables in ~/.local/bin (shellrc_additions.sh already
# exports it, but the current-shell hint should still mention it).
uv_install() { uv tool install --quiet "$@" && note_path "$HOME/.local/bin"; }

brew_install() { brew install --quiet "$@"; }

# Download a single executable straight into ~/.local/bin. Some projects ship a
# bare binary rather than an archive -- jq is one -- so there is nothing to
# unpack, but it still has to land somewhere on PATH and be marked executable.
fetch_bin() {
  local url="$1" name="$2" tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-bin.XXXXXX")"
  if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 "$url" -o "$tmp/$name"; then
    rm -rf "$tmp"; return 1
  fi
  mkdir -p "$HOME/.local/bin"
  install -m 0755 "$tmp/$name" "$HOME/.local/bin/$name"
  rm -rf "$tmp"
  note_path "$HOME/.local/bin"
}

# Debian's spelling of the architecture, which is what several projects name
# their release assets with (jq: jq-linux-amd64). arch_tag() has the other one.
arch_deb() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) echo "$(uname -m)" ;;
  esac
}

# Pull one binary out of a release tarball and drop it in ~/.local/bin. The
# layouts differ between projects (top level, or one directory down), so the
# binary is found by name rather than by a hardcoded --strip-components.
fetch_bin_from_tarball() {
  local url="$1"; shift
  local tmp found name got=0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-tool.XXXXXX")"
  if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 180 "$url" -o "$tmp/archive.tar.gz"; then
    rm -rf "$tmp"; return 1
  fi
  if ! tar -xzf "$tmp/archive.tar.gz" -C "$tmp"; then rm -rf "$tmp"; return 1; fi
  mkdir -p "$HOME/.local/bin"
  # Several names, one download: Tailscale ships the CLI and the daemon in the
  # same archive and the CLI is useless without the daemon. Succeeds if any one
  # of them was found.
  #
  # `| head -1` rather than find's own -print -quit, which is not in every BSD
  # find; the `|| true` is because head closing the pipe early can hand find a
  # SIGPIPE, and this file is sourced into a `set -o pipefail` script.
  for name in "$@"; do
    found="$(find "$tmp" -type f -name "$name" -perm -u+x 2>/dev/null | head -n 1 || true)"
    [ -n "$found" ] || continue
    install -m 0755 "$found" "$HOME/.local/bin/$name"
    got=1
  done
  rm -rf "$tmp"
  [ "$got" -eq 1 ] || return 1
  note_path "$HOME/.local/bin"
}

# The newest release's asset whose name matches, skipping the SBOM/checksum
# files that sit next to it. Two API calls per run at most, well inside the
# unauthenticated rate limit.
github_latest_asset() {
  local repo="$1" pattern="$2"
  curl -fsSL --retry 2 --connect-timeout 10 --max-time 30 \
       "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null \
    | grep -oE '"browser_download_url":[[:space:]]*"[^"]+"' \
    | sed -E 's/.*"(https[^"]*)".*/\1/' \
    | grep -E "$pattern" \
    | grep -vE '\.(sbom\.json|sha256|sig|pem)$' \
    | head -1
}

arch_tag() {
  case "$(uname -m)" in
    x86_64|amd64) echo x86_64 ;;
    aarch64|arm64) echo arm64 ;;
    *) echo "$(uname -m)" ;;
  esac
}

# The Rust target triple, which is how a project releasing through cargo-dist or
# cross names its assets -- and a FOURTH spelling of this platform after
# arch_deb()'s amd64, arch_tag()'s x86_64/arm64 and conda_platform()'s osx-arm64.
# The trap is `aarch64`: Rust uses it on macOS as well as Linux, where arch_tag()
# says arm64, so reusing that helper matches no asset at all on Apple silicon.
#
# musl rather than gnu on Linux, deliberately: the result is a STATIC binary, so
# it does not care what vintage of glibc the machine has -- which is exactly the
# property wanted on an old cluster login node. A project that publishes only
# gnu builds needs its own pattern rather than this helper; what actually selects
# the asset is the regex passed to github_latest_asset(), and this only supplies
# the platform half of it.
#
# Empty for an architecture with no mapping, which callers report as blocked.
rust_triple() {
  case "$OS_KERNEL/$(uname -m)" in
    Darwin/arm64)        printf 'aarch64-apple-darwin' ;;
    Darwin/x86_64)       printf 'x86_64-apple-darwin' ;;
    */x86_64|*/amd64)    printf 'x86_64-unknown-linux-musl' ;;
    */aarch64|*/arm64)   printf 'aarch64-unknown-linux-musl' ;;
    # Both published by dua-cli, and neither has a musl build -- so they are gnu
    # here, and a tool that does not ship them simply fails the asset match.
    */riscv64)           printf 'riscv64gc-unknown-linux-gnu' ;;
    */armv7l|*/armv7)    printf 'arm-unknown-linux-gnueabihf' ;;
    *) return 1 ;;
  esac
}

# (There was a rust_triple_gnu() beside this, the same switch with gnu in place
# of musl, for eza and git-delta. tarball_triple() above spells their triples out
# itself now -- it has to, since the two of them ship a narrower set of arches
# than dua-cli does -- and nothing else ever wanted the gnu spelling.)

# eza/fd/bat/delta each publish a static release tarball per platform, the same
# shape dua-cli's is, so a machine with no system package manager downloads one.
#
# There is no cargo fallback here any more, and that is the point (see
# _route_prebuilt()): it used to catch both "this arch has no asset" and "the
# GitHub API said 403", and in the second case it silently turned a download
# into a ten-minute compile. A failure here is now just a failure, reported as
# one -- and the first case cannot arise at all, since the route only says
# `tarball` when tarball_triple() named a triple in the first place.
_install_tarball() {
  local repo="$1" prefix="$2" id="$3" bin="$4" triple url
  triple="$(tarball_triple "$id" 2>/dev/null)" || return 1
  [ -n "$triple" ] || return 1
  url="$(github_latest_asset "$repo" "${prefix}.*${triple}\.tar\.gz$")"
  [ -n "$url" ] || return 1
  fetch_bin_from_tarball "$url" "$bin"
}

# --- the installers -------------------------------------------------------
# One per tool, each free to do whatever that tool needs. They return non-zero
# on failure and the orchestrator records it; nothing here is ever fatal.

# micromamba is a bare static binary at a permanent-redirect URL, so this is
# fetch_bin() and nothing else -- no API call to be rate limited, no archive, no
# unzip, no privilege. The same shape jq and oh-my-posh take, and the reason it
# was chosen as the conda bootstrap over anaconda/miniforge installers.
install_micromamba() {
  local plat; plat="$(conda_platform)" || return 1
  fetch_bin \
    "https://github.com/mamba-org/micromamba-releases/releases/latest/download/micromamba-$plat" \
    micromamba || return 1
  have_micromamba
}

# _install_conda_pkg <conda-package> <binary> [binary...]
# One shared environment for every conda-routed tool, and only the binaries
# named here are exposed -- as symlinks into ~/.local/bin rather than by putting
# $CONDA_ENV/bin on PATH, which would shadow the system python, curl, openssl
# and ncurses with conda's own. See the conda-forge section above.
#
# --no-rc so a ~/.mambarc or ~/.condarc on the machine (very common on a cluster,
# and often pointing at an internal mirror) cannot change which channel this
# resolves against; -c conda-forge is then the only one in play.
_install_conda_pkg() {
  local pkg="$1"; shift
  local mm name
  mm="$(micromamba_bin)" || return 1
  mkdir -p "$CONDA_ROOT" "$HOME/.local/bin"
  # `install` into an existing prefix, `create` to make it: micromamba's install
  # refuses a prefix that has no conda-meta, and create refuses one that has.
  if [ -d "$CONDA_ENV/conda-meta" ]; then
    "$mm" install -y -q --no-rc -r "$CONDA_ROOT" -p "$CONDA_ENV" -c conda-forge "$pkg" \
      >/dev/null 2>&1 || return 1
  else
    "$mm" create -y -q --no-rc -r "$CONDA_ROOT" -p "$CONDA_ENV" -c conda-forge "$pkg" \
      >/dev/null 2>&1 || return 1
  fi
  for name in "$@"; do
    [ -x "$CONDA_ENV/bin/$name" ] || return 1
    ln -sfn "$CONDA_ENV/bin/$name" "$HOME/.local/bin/$name"
  done
  # The downloaded archives, once they have been extracted, are dead weight --
  # 62MB of the 444MB a git+tmux environment costs. Only --tarballs: the
  # EXTRACTED packages under pkgs/ are what the env's files are hardlinked to,
  # so cleaning those would either break the env or silently double its size.
  # Non-fatal; a tool that installed is installed whatever the cleanup does.
  "$mm" clean -y -q --tarballs -r "$CONDA_ROOT" >/dev/null 2>&1 || true
  note_path "$HOME/.local/bin"
}

install_git() {
  local route; route="$(tool_route git)"
  case "${route%%|*}" in
    apt)  apt_install git ;;
    brew) brew_install git ;;
    # git finds its own libexec/git-core from the path it was invoked through, so
    # the symlink in ~/.local/bin resolves subcommands correctly -- `git clone`
    # and `git log` work through it, which is the whole point of preferring a
    # symlink to putting the env's bin on PATH.
    conda) _install_conda_pkg git git ;;
    *)    return 1 ;;
  esac
}

install_tailscale() {
  # macOS: no static tarball is published and the install script bails out
  # there, so the brew formula (tailscaled + CLI, started with `brew services`)
  # is the only route. tool_route has already established brew is usable.
  if is_mac; then
    brew_install tailscale || return 1
    have tailscale
    return
  fi
  if priv_available; then
    sudo_unlock || return 1
    # The installer calls sudo itself; the unlock above has already primed the
    # timestamp so it does not stop to ask again halfway through.
    curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1 || return 1
    have tailscale
    return
  fi
  local ver url
  ver="$(curl -fsSL --retry 2 --max-time 20 'https://pkgs.tailscale.com/stable/?mode=json' 2>/dev/null \
         | grep -oE '"TarballsVersion"[[:space:]]*:[[:space:]]*"[^"]+"' \
         | sed -E 's/.*"([^"]+)"$/\1/')"
  [ -n "$ver" ] || return 1
  url="https://pkgs.tailscale.com/stable/tailscale_${ver}_$(arch_deb).tgz"
  # Both halves: the CLI is useless without a daemon to talk to.
  fetch_bin_from_tarball "$url" tailscale tailscaled
}

# build-essential (gcc, the linker, libc headers) is the only route, and it is
# gated by cc_needed() in tool_route so a machine that already links, or that
# has nothing to build, never comes here at all. Nothing else is added: this
# exists to make `cargo build` work, not to turn every box into a dev machine.
install_buildtools() {
  apt_install build-essential || return 1
  have_cc
}

install_rust() {
  have rustup && { rustup update --no-self-update >/dev/null 2>&1 || true; }
  if ! have rustup; then
    # --no-modify-path for the same reason uv gets it in install.sh: left alone
    # rustup appends to ~/.profile, which on an already-installed machine is a
    # SYMLINK INTO THIS REPO. shellrc_additions.sh already exports ~/.cargo/bin.
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal >/dev/null || return 1
  fi
  # shellcheck disable=SC1091
  [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
  PATH="$HOME/.cargo/bin:$PATH"; export PATH
  note_path "$HOME/.cargo/bin"
  have cargo
}

install_brew() {
  local prefix
  # Adopt an existing prefix rather than installing a second one next to it.
  if prefix="$(brew_prefix)"; then
    :
  elif is_mac && priv_available; then
    # The official installer is the only route to a *bottled* Homebrew: a prefix
    # anywhere other than /opt/homebrew (or /usr/local on Intel) makes brew
    # build every formula from source. It needs admin to create that directory,
    # and it installs the Xcode Command Line Tools on the way -- which is what
    # makes it git's route on this platform too. NONINTERACTIVE=1 stops it
    # waiting on a RETURN nobody is there to press.
    sudo_unlock || return 1
    NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
      >/dev/null 2>&1 || return 1
    prefix="$(brew_prefix)" || return 1
  else
    # The "clone anywhere" install, which is the only one that needs no root --
    # and on macOS the one that means source builds, hence its place last.
    prefix="$HOME/.linuxbrew"; is_mac && prefix="$HOME/homebrew"
    have_git || return 1
    git clone --depth 1 https://github.com/Homebrew/brew "$prefix" >/dev/null 2>&1 || return 1
  fi
  eval "$("$prefix/bin/brew" shellenv)" || return 1
  brew update --force --quiet >/dev/null 2>&1 || true
  note_path "$prefix/bin"
  have brew
}

install_ohmyposh() {
  # The bare release binary first, not the official install.sh. That script
  # needs `unzip` (it fetches the themes archive as well), which a slim
  # container or a login node may simply not have -- and the themes are not
  # wanted here anyway, since the one theme this repo uses is rendered from its
  # own template. The script stays as a fallback for an architecture with no
  # published binary.
  if fetch_bin \
      "https://github.com/JanDeDobbeleer/oh-my-posh/releases/latest/download/posh-$(os_darwin)-$(arch_deb)" \
      oh-my-posh; then
    return 0
  fi
  have unzip || return 1
  mkdir -p "$HOME/.local/bin"
  curl -s https://ohmyposh.dev/install.sh | bash -s -- -d "$HOME/.local/bin" >/dev/null || return 1
  note_path "$HOME/.local/bin"
}

install_herdr() {
  mkdir -p "$HOME/.local/bin"
  HERDR_INSTALL_DIR="$HOME/.local/bin" \
    sh -c "$(curl -fsSL https://herdr.dev/install.sh)" >/dev/null || return 1
  note_path "$HOME/.local/bin"
  have herdr
}

install_jq() {
  local route; route="$(tool_route jq)"
  if [ "${route%%|*}" = apt ]; then
    apt_install jq && return 0
  fi
  # /releases/latest/download/ is a permanent redirect to the newest tag, so
  # this needs no API call and cannot be rate limited.
  fetch_bin "https://github.com/jqlang/jq/releases/latest/download/jq-$(os_macos)-$(arch_deb)" jq
}

install_zoxide() {
  local route; route="$(tool_route zoxide)"
  if [ "${route%%|*}" = apt ]; then
    apt_install zoxide && return 0
  fi
  mkdir -p "$HOME/.local/bin"
  curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh \
    | sh -s -- --bin-dir "$HOME/.local/bin" >/dev/null || return 1
  note_path "$HOME/.local/bin"
  have zoxide
}

install_fzf() {
  if have git; then
    [ -d "$HOME/.fzf" ] || git clone --depth 1 https://github.com/junegunn/fzf.git "$HOME/.fzf" >/dev/null 2>&1 || return 1
    # --no-update-rc: same ~/.profile-is-a-symlink-into-the-repo hazard as uv
    # and rustup. It still writes ~/.fzf.bash and ~/.fzf.zsh -- one per shell it
    # finds on the machine -- and shellrc_additions.sh sources whichever matches
    # the shell reading it. That file is also what puts ~/.fzf/bin on PATH.
    "$HOME/.fzf/install" --all --no-update-rc >/dev/null 2>&1 || return 1
    note_path "$HOME/.fzf/bin"
    return 0
  fi
  apt_install fzf
}

# eza / fd / bat / delta all share the apt-or-tarball-or-conda-or-brew shape --
# every one of them a prebuilt binary, none of them a compile. The binary a
# package installs is not always its own name (git-delta ships `delta`, fd-find
# ships `fd`), so the conda branch is told both; the tarball branch additionally
# needs the repo and the asset's name prefix, the triple being tarball_triple()'s
# to decide from the id.
_install_via_route() {
  local id="$1" bin="$2" repo="$3" prefix="$4"
  local route method detail pkg
  route="$(tool_route "$id")"; method="${route%%|*}"; detail="${route#*|}"
  case "$method" in
    apt)     apt_install "$detail" ;;
    tarball) _install_tarball "$repo" "$prefix" "$id" "$bin" ;;
    brew)    brew_install "$detail" ;;
    # The detail carries a " (conda-forge)" tail for the plan's benefit; the
    # package name is the first word of it.
    conda)   pkg="${detail%% *}"; _install_conda_pkg "$pkg" "$bin" ;;
    *)       return 1 ;;
  esac
}

install_eza()   { _install_via_route eza   eza   eza-community/eza eza_ ; }
install_fd()    { _install_via_route fd    fd    sharkdp/fd        fd- ; }
install_bat()   { _install_via_route bat   bat   sharkdp/bat       bat- ; }
install_delta() { _install_via_route delta delta dandavison/delta  delta- ; }

# Asset names embed the version (lazygit_0.64.0_linux_x86_64.tar.gz), so -- like
# dua -- the /releases/latest/download/<name> permanent redirect jq and
# oh-my-posh use cannot work here and this costs one GitHub API call. The
# package name is the same as the binary in both Homebrew and conda-forge, so
# unlike _install_via_route() no separate bin argument is needed there.
install_lazygit() {
  local route; route="$(tool_route lazygit)"
  case "${route%%|*}" in
    brew)    brew_install lazygit ;;
    conda)   _install_conda_pkg lazygit lazygit ;;
    tarball)
      local os="linux" url
      is_mac && os="darwin"
      url="$(github_latest_asset jesseduffield/lazygit "lazygit_[0-9.]+_${os}_$(arch_tag)\.tar\.gz")"
      [ -n "$url" ] || return 1
      fetch_bin_from_tarball "$url" lazygit
      ;;
    *) return 1 ;;
  esac
}

install_glow() {
  local url os="[Ll]inux"
  is_mac && os="[Dd]arwin"
  url="$(github_latest_asset charmbracelet/glow "$os.*$(arch_tag).*\.tar\.gz")"
  [ -n "$url" ] || return 1
  fetch_bin_from_tarball "$url" glow
}

# Unlike jq and oh-my-posh, dua's assets embed the VERSION in their filenames
# (dua-v2.41.0-aarch64-unknown-linux-musl.tar.gz), so the
# /releases/latest/download/<name> permanent redirect those two use cannot work
# here -- the name is not predictable without knowing the tag. That means an API
# call, and the unauthenticated GitHub limit is 60/hour PER IP: on a shared login
# node or in CI that is a real thing to be on the wrong side of. Hence the cargo
# fallback, the same belt-and-braces shape install_ohmyposh() has. The route
# still advertises the tarball, because that is what will be tried first and a
# plan cannot know in advance that a rate limit is waiting.
install_dua() {
  local triple url
  triple="$(rust_triple)" || return 1
  url="$(github_latest_asset Byron/dua-cli "$triple\.tar\.gz")"
  # The archive is one directory deep; fetch_bin_from_tarball finds the binary by
  # name, so that needs no --strip-components guess.
  if [ -n "$url" ] && fetch_bin_from_tarball "$url" dua; then
    return 0
  fi
  cargo_usable || return 1
  cargo_install dua-cli && note_path "$HOME/.cargo/bin"
}

install_tmux() {
  local route; route="$(tool_route tmux)"
  case "${route%%|*}" in
    apt)   apt_install tmux ;;
    brew)  brew_install tmux ;;
    conda) _install_conda_pkg tmux tmux ;;
    *)     return 1 ;;
  esac
}

install_neovim() {
  local arch url tmp dest="$HOME/.local/nvim"
  # Neovim's asset names pair "macos" with the x86_64/arm64 arch spelling.
  case "$OS_KERNEL/$(uname -m)" in
    Darwin/arm64)         arch="macos-arm64" ;;
    Darwin/x86_64)        arch="macos-x86_64" ;;
    */x86_64|*/amd64)     arch="linux-x86_64" ;;
    */aarch64|*/arm64)    arch="linux-arm64" ;;
    *) return 1 ;;
  esac
  url="https://github.com/neovim/neovim/releases/download/stable/nvim-$arch.tar.gz"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-nvim.XXXXXX")"
  if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 300 "$url" -o "$tmp/nvim.tar.gz"; then
    rm -rf "$tmp"; return 1
  fi
  mkdir -p "$dest"
  # --strip-components 1: the tarball is one nvim-linux-*/ directory holding
  # bin/ lib/ share/, and ~/.local/nvim/bin is what is already on PATH.
  if ! tar -xzf "$tmp/nvim.tar.gz" -C "$dest" --strip-components 1; then
    rm -rf "$tmp"; return 1
  fi
  rm -rf "$tmp"
  # macOS: Neovim's own instructions say to clear the quarantine attribute
  # before running these. curl does not set one (only browsers do), so this is
  # belt and braces -- but a Gatekeeper refusal at first launch is an obscure
  # enough failure to be worth two harmless lines.
  is_mac && xattr -cr "$dest" >/dev/null 2>&1
  PATH="$dest/bin:$PATH"; export PATH
  note_path "$dest/bin"
  have nvim
}

install_lazyvim() {
  have git || return 1
  # Never clobber somebody else's nvim config. An empty directory is fine to
  # clone into; anything with files in it is left exactly as it is, and rc 2
  # tells the orchestrator that is a deliberate outcome rather than a failure.
  if [ -e "$LAZYVIM_DIR" ] && [ -n "$(ls -A "$LAZYVIM_DIR" 2>/dev/null)" ]; then
    return 2
  fi
  mkdir -p "$(dirname "$LAZYVIM_DIR")"
  git clone --depth 1 https://github.com/LazyVim/starter "$LAZYVIM_DIR" >/dev/null 2>&1 || return 1
  # The starter is a template, not a checkout to keep tracking upstream.
  rm -rf "$LAZYVIM_DIR/.git"
}

install_claude() {
  mkdir -p "$HOME/.local/bin"
  # `| bash`, not `sh`: the installer's shebang is bash and it uses [[ ]].
  curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1 || return 1
  note_path "$HOME/.local/bin"
  tool_present claude
}

install_gdown()         { uv_install gdown; }
install_groundcontrol() { uv_install ground-control-tui; }
install_nvitop()        { uv_install nvitop; }

_path_prepend() {
  [ -d "$1" ] || return 0
  case ":$PATH:" in
    *":$1:"*) ;;
    *) PATH="$1:$PATH"; export PATH ;;
  esac
}
_path_append() {
  [ -d "$1" ] || return 0
  case ":$PATH:" in
    *":$1:"*) ;;
    *) PATH="$PATH:$1"; export PATH ;;
  esac
}

_install_herdr_plugin() {
  have herdr || return 1
  # herdr runs each plugin's build commands as a child of this process, so the
  # environment assembled here IS the environment the build gets -- and
  # herdr-statusline's build.sh is a `cargo build`, which needs both cargo and a
  # linker to be reachable from it.
  #
  # ~/.cargo/bin first: install_rust() prepends it only when it is the one doing
  # the installing, so a rust from an EARLIER run of this script is invisible to
  # a non-login shell.
  _path_prepend "$HOME/.cargo/bin"
  # Then the standard system directories, APPENDED so nothing of the user's own
  # is shadowed. This is not paranoia about a normal login shell -- it is that
  # this phase can be reached with almost no PATH at all (`curl | bash` from
  # cron or CI, a sudo -i that reset it, a herdr pane spawned from a stripped
  # environment), and a cargo build whose PATH has ~/.cargo/bin but not /usr/bin
  # finds cargo, compiles most of the crate graph, and only then dies on
  # `linker "cc" not found` -- on a machine where /usr/bin/cc exists. Cheap
  # insurance against a failure that looks exactly like a missing compiler.
  local d
  for d in /usr/local/bin /usr/bin /bin /usr/sbin /sbin; do _path_append "$d"; done
  if d="$(brew_prefix 2>/dev/null)"; then _path_append "$d/bin"; fi
  # And if this machine links with something other than `cc`, say so -- rustc
  # asks for `cc` by name and would not find gcc or clang on its own.
  cargo_with_linker herdr plugin install "$1" -y >/dev/null 2>&1
}
install_herdr_statusline()  { _install_herdr_plugin iiii1224/herdr-statusline; }
install_herdr_file_viewer() { _install_herdr_plugin smarzban/herdr-file-viewer; }

# --- what the setup UI's previews need ------------------------------------
# The whole point of the preview panes is that they are the real thing rather
# than a drawing of it -- but oh-my-posh renders the prompt pane and jq parses
# the sample payload for the Claude status line pane, so on a machine that has
# neither, the first thing a new user sees is a hand-drawn approximation and an
# apology. These two therefore go on BEFORE the wizard opens, not with the rest.
PREVIEW_TOOLS=(ohmyposh jq)

install_preview_prereqs() {
  local id route method rc any=0
  # Saved and put back at the end. The downgrade below is meant to last for this
  # pre-pass only, and install.sh has ALREADY resolved and printed the real
  # answer by the time this runs -- so leaving PRIV_MODE=none behind made the
  # text wizard head its tool list "no sudo -- installs under $HOME" on a
  # machine that has sudo, then install_tools() re-resolve and use apt anyway.
  # The plan disagreeing with the run is the one thing this file exists to stop.
  local was_mode="$PRIV_MODE" was_sudo="$SUDO"
  detect_privilege
  # This never prompts. It runs before the user has been asked anything, and
  # demanding a sudo password before the first question is a poor greeting --
  # so a password-sudo machine is treated as an unprivileged one here and takes
  # the userland route, which both of these have. The real tools phase later
  # asks once, properly, and by then the user has agreed to an install.
  if [ "$PRIV_MODE" = password ]; then PRIV_MODE=none; SUDO=""; fi
  providers_init

  for id in "${PREVIEW_TOOLS[@]}"; do
    tool_selected "$id" || continue
    tool_present "$id" && continue
    route="$(tool_route "$id")"; method="${route%%|*}"
    [ -n "$method" ] || continue
    if [ "$any" -eq 0 ]; then
      echo "Fetching what the setup UI needs to draw real previews:"
      any=1
    fi
    printf '  %-22s via %s ... ' "$id" "$method"
    rc=0
    "install_$id" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] && echo "ok" || echo "skipped (the preview falls back)"
  done

  # Whatever just landed has to be findable by the UI, which runs as a child of
  # this script and inherits its PATH.
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) PATH="$HOME/.local/bin:$PATH"; export PATH ;;
  esac
  # The privilege state as the caller had it, so nothing downstream reads this
  # pre-pass's deliberately pessimistic view as the machine's real one.
  PRIV_MODE="$was_mode"; SUDO="$was_sudo"
  [ "$any" -eq 1 ] && echo ""
  return 0
}

# --- the plan -------------------------------------------------------------
# Walk the catalogue in order and say what would happen to each tool, flipping
# provider availability on as the walk passes a provider it would install --
# which is what lets "eza: cargo" be true on a machine that has no cargo yet.
# Prints "id|status|method|detail"; status is present|install|skip|blocked.
tools_plan() {
  priv_resolve
  # The same ~/.local/bin that install_tools() prepends, and for the same reason
  # -- without it the plan and the run disagree about every tool a PREVIOUS run
  # installed there. On a machine whose login shell never added that directory
  # (it did not exist at login, so Debian's ~/.profile skipped it), `have git`
  # answers no about the git sitting in it, and the plan says "install" where the
  # run then says "already installed". Only this process's PATH is touched, so
  # the plan stays free of side effects on the machine itself.
  _path_prepend "$HOME/.local/bin"
  providers_init
  local id route method detail dep missing
  for id in "${TOOL_IDS[@]}"; do
    if ! tool_selected "$id"; then
      printf '%s|skip|-|deselected\n' "$id"; continue
    fi
    if tool_present "$id"; then
      printf '%s|present|-|already installed\n' "$id"
      providers_seen "$id"
      continue
    fi
    # A dependency that is neither present nor going to be installed blocks it.
    missing=""
    for dep in $(tool_deps "$id"); do
      if ! tool_present "$dep" && ! tool_selected "$dep"; then missing="$dep"; break; fi
    done
    if [ -n "$missing" ]; then
      printf '%s|blocked|-|needs %s\n' "$id" "$missing"; continue
    fi
    route="$(tool_route "$id")"; method="${route%%|*}"; detail="${route#*|}"
    # Before the no-route check below: "na" is the normal, intended outcome for
    # a tool this machine has no business installing (Homebrew when nothing
    # needs it, herdr-statusline on a Mac) than a machine that fell short.
    if [ "$method" = na ]; then
      printf '%s|skip|-|%s\n' "$id" "$detail"; continue
    fi
    if [ -z "$method" ]; then
      printf '%s|blocked|-|%s\n' "$id" "$detail"; continue
    fi
    printf '%s|install|%s|%s\n' "$id" "$method" "$detail"
    providers_seen "$id"
  done
}

# --- the orchestrator -----------------------------------------------------
install_tools() {
  priv_resolve
  providers_init
  TOOLS_ORIG_PATH="$PATH"
  # AFTER the line above, deliberately: TOOLS_ORIG_PATH is the PATH as the phase
  # found it, and print_path_hint() diffs against that precisely so a directory
  # this phase puts on its own PATH is still reported to the calling shell.
  #
  # ~/.local/bin is where most of the userland routes land, and half a dozen
  # installers finish by checking that what they just installed can be found --
  # install_herdr() ends in `have herdr`, install_claude() in `tool_present
  # claude`. On a bare machine that directory did not exist at login, so it is
  # not on PATH (Debian's ~/.profile adds it only `if [ -d ]`), and every one of
  # those checks says no about a tool that installed perfectly. herdr then
  # "FAILED" and both herdr plugins SKIPPED on the dependency check behind it.
  # install_preview_prereqs() already does this, but only on an interactive run;
  # `-y`, --tools-only and the tty-less `curl | bash` never went through it.
  mkdir -p "$HOME/.local/bin" 2>/dev/null || true
  _path_prepend "$HOME/.local/bin"
  # A Homebrew that is installed but was never put on PATH is common (see
  # brew_prefix). Wire it up now so brew_install() can actually use it, and so
  # "brew: already installed" is a true statement rather than a dead end.
  if [ "$AVAIL_BREW" = 1 ] && ! have brew && tool_selected brew; then
    brew_activate || true
  fi
  echo "Tools: $(priv_summary)"

  # curl is load-bearing for nearly every route and is not something to install
  # on a machine that has no way to download an installer in the first place.
  if ! have curl; then
    echo "  NOTE: no curl on this machine; skipping the tools phase entirely."
    return 0
  fi
  local id route method detail rc dep blocked
  for id in "${TOOL_IDS[@]}"; do
    if ! tool_selected "$id"; then
      TOOLS_SKIPPED+=("$id"); continue
    fi
    if tool_present "$id"; then
      printf '  %-22s already installed\n' "$id"
      providers_seen "$id"
      continue
    fi
    blocked=""
    for dep in $(tool_deps "$id"); do
      tool_present "$dep" || { blocked="$dep"; break; }
    done
    if [ -n "$blocked" ]; then
      printf '  %-22s SKIPPED (%s is not installed)\n' "$id" "$blocked"
      TOOLS_SKIPPED+=("$id"); continue
    fi
    route="$(tool_route "$id")"; method="${route%%|*}"; detail="${route#*|}"
    if [ "$method" = na ]; then
      printf '  %-22s %s\n' "$id" "$detail"
      TOOLS_SKIPPED+=("$id"); continue
    fi
    if [ -z "$method" ]; then
      printf '  %-22s SKIPPED (%s)\n' "$id" "$detail"
      TOOLS_SKIPPED+=("$id"); continue
    fi

    printf '  %-22s installing via %s (%s) ... ' "$id" "$method" "$detail"
    rc=0
    "install_$id" >/dev/null 2>&1 || rc=$?
    # 2 is "deliberately left alone", not a failure -- install_lazyvim() uses it
    # when there is already an nvim config it refuses to overwrite.
    if [ "$rc" -eq 0 ]; then
      echo "ok"
      TOOLS_INSTALLED+=("$id")
      providers_seen "$id"
    elif [ "$rc" -eq 2 ]; then
      echo "left alone"
      TOOLS_SKIPPED+=("$id")
    else
      echo "FAILED"
      TOOLS_FAILED+=("$id")
      # A provider that failed must stop being advertised as a route, so the
      # tools behind it are reported as skipped-with-a-reason rather than each
      # failing again for somebody else's reason. See providers_failed().
      providers_failed "$id"
    fi
  done

  sudo_keepalive_stop
  tools_write_env
  echo "  ${#TOOLS_INSTALLED[@]} installed, ${#TOOLS_SKIPPED[@]} skipped, ${#TOOLS_FAILED[@]} failed."
  if [ "${#TOOLS_FAILED[@]}" -gt 0 ]; then
    echo "  failed: ${TOOLS_FAILED[*]}  (re-run ./install.sh to retry)"
  fi
}

# The permanent half of "put these on PATH", the same shape uv-env.sh has: a
# generated fragment that shellrc_additions.sh sources on every shell. Most of
# these dirs are already exported there; this is what covers the ones that are
# not (Homebrew's prefix above all, which moves per machine).
tools_write_env() {
  local file="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/tools-env.sh" dir
  mkdir -p "$(dirname "$file")"
  {
    echo "# GENERATED by dotfiles/install.sh -- PATH for the tools it installed."
    echo "# Sourced from shell/shellrc_additions.sh (bash and zsh). Rewritten every run."
    for dir in "${TOOLS_PATH_HINTS[@]+"${TOOLS_PATH_HINTS[@]}"}"; do
      printf 'case ":$PATH:" in *":%s:"*) ;; *) export PATH="%s:$PATH" ;; esac\n' "$dir" "$dir"
    done
    # brew wants more than PATH (MANPATH, INFOPATH, HOMEBREW_PREFIX), so it gets
    # its own shellenv rather than just its bin directory. Only when it was not
    # deselected: a Homebrew sitting unused on the machine is not a reason to
    # start putting it on every shell's PATH against the answer given.
    if tool_selected brew && dir="$(brew_prefix)"; then
      printf 'eval "$(%s/bin/brew shellenv)"\n' "$dir"
    fi
  } > "$file"
}

# Directories a tool went into that the CALLING shell does not have on PATH --
# the copy-paste line install.sh prints at the end, for the terminal you are in
# right now (a new shell gets them from tools-env.sh above).
#
# Compared against the PATH as it was when the tools phase started, not the
# current one: install_rust() and install_neovim() prepend to install.sh's own
# PATH so that later steps can use what they just installed, and checking
# against that would report every one of those directories as already handled
# when the user's shell has never heard of them.
TOOLS_ORIG_PATH=""
tools_missing_path() {
  local dir out=() base="${TOOLS_ORIG_PATH:-$PATH}"
  for dir in "${TOOLS_PATH_HINTS[@]+"${TOOLS_PATH_HINTS[@]}"}"; do
    case ":$base:" in *":$dir:"*) ;; *) out+=("$dir") ;; esac
  done
  if [ "${#out[@]}" -gt 0 ]; then printf '%s\n' "${out[@]}"; fi
  return 0
}

# --- emit modes -----------------------------------------------------------
# Only when EXECUTED, not when sourced -- tui/configure.py's two entry points.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:---list}" in
    --list)
      # id|label|group|selected -- the checkbox list, in catalogue order.
      for id in "${TOOL_IDS[@]}"; do
        printf '%s|%s|%s|%s\n' "$id" "$(tool_label "$id")" "$(tool_group "$id")" \
          "$(tool_selected "$id" && echo 1 || echo 0)"
      done
      ;;
    --plan)
      tools_plan
      ;;
    --priv)
      priv_resolve
      printf 'PRIV_MODE=%s\nPRIV_SUMMARY=%s\n' "$PRIV_MODE" "$(priv_summary)"
      ;;
    *)
      echo "usage: tools.sh [--list|--plan|--priv]" >&2; exit 2 ;;
  esac
fi
