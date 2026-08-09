#!/bin/bash
# Interactive dotfiles installer. Safe to re-run.
#
# Themed files are kept as *.in templates carrying @PRIMARY@ / @SECONDARY@ /
# @MACHINE@ placeholders, because none of tmux.conf, JSON or TOML can indirect
# through a variable. This script asks for those three values, renders every
# template into dotfiles/.generated/, and symlinks the real config path at the
# rendered copy -- so ~ still shows what is dotfiles-managed, the tracked files
# stay free of machine-specific values, and re-rendering updates live config.
#
# The answers are saved to ~/.config/dotfiles/theme.env and reused, so later runs
# (e.g. after editing a template) need no input. Use --reconfigure to change them.
#
# Asking is done by tui/configure.py, a Textual app run through `uv run` -- which
# is why the very first thing this script does is put uv on the machine. The old
# text wizard is still here as a fallback for when uv (or the network it needs on
# a first run) is unavailable, so an offline machine can still be set up.
#
# Everything that is not themed is symlinked straight out of the repo as before.
#
# Two entry points, and the first one is why the bootstrap block below exists:
#
#     curl -fsSL albertorota.dev/setmeup.sh | bash     # bare machine, no checkout
#     ./install.sh                                     # from a clone
#
set -euo pipefail

# --- bootstrap: fetch the repo when there isn't one -----------------------------
# Piped into bash, this script arrives on stdin: BASH_SOURCE is unset, $0 is
# "bash", and there is no repo on disk -- so lib/derive.sh and lib/tools.sh,
# which everything below sources, do not exist yet, and neither do the templates
# that get rendered. The fix is for this file to be self-bootstrapping: work out
# that it is running detached, clone the repo, and hand over to the copy inside
# it. From a normal checkout none of this runs.
DOTFILES_SLUG="${DOTFILES_SLUG:-alberto-rota/dotfiles}"
DOTFILES_REPO="${DOTFILES_REPO:-https://github.com/$DOTFILES_SLUG.git}"
DOTFILES_BRANCH="${DOTFILES_BRANCH:-main}"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
DOTFILES_TARBALL="${DOTFILES_TARBALL:-https://codeload.github.com/$DOTFILES_SLUG/tar.gz/refs/heads/$DOTFILES_BRANCH}"
# Dropped into a checkout that came from the tarball route rather than from git.
# It is what makes "refresh it" possible on a machine with no git: without a
# .git there is nothing to pull, and re-extracting over a directory is only safe
# when we know every file in it was put there by us. Absent = hands off.
TARBALL_STAMP=".dotfiles-tarball"

# The directory this script is in, or empty if it did not come from a file.
self_dir() {
  local self="${BASH_SOURCE[0]:-}"
  [ -n "$self" ] && [ -r "$self" ] || return 1
  cd "$(dirname "$self")" && pwd
}

# Does this look like a checkout of this repo, rather than just some directory?
is_checkout() { [ -r "$1/install.sh" ] && [ -r "$1/lib/derive.sh" ]; }

# Is there a git that will actually clone? On macOS /usr/bin/git EXISTS on a
# machine with no Xcode Command Line Tools, as a stub that pops a GUI installer
# and fails -- so `command -v git` says yes and the clone below then dies,
# instead of falling through to the tarball that would have worked.
# lib/tools.sh has the same check for the same reason; it cannot be shared,
# because at this point in the script there is no lib/ on disk to share it from.
bootstrap_have_git() {
  command -v git >/dev/null 2>&1 || return 1
  [ "$(uname -s 2>/dev/null)" = Darwin ] || return 0
  case "$(command -v git)" in
    /usr/bin/git) xcode-select -p >/dev/null 2>&1 ;;
    *) return 0 ;;
  esac
}

# Download the repo as a tarball and unpack it over $1, leaving the stamp that
# says the result is ours. Used both to create a checkout on a machine with no
# git and to refresh one later.
fetch_tarball() {
  local dir="$1"
  command -v curl >/dev/null 2>&1 || return 1
  mkdir -p "$dir"
  curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 "$DOTFILES_TARBALL" \
    | tar -xz -C "$dir" --strip-components 1 || return 1
  : > "$dir/$TARBALL_STAMP"
}

bootstrap() {
  echo "dotfiles: no checkout around this script, fetching one."
  echo "  repo   $DOTFILES_REPO ($DOTFILES_BRANCH)"
  echo "  into   $DOTFILES_DIR"
  echo ""

  if is_checkout "$DOTFILES_DIR"; then
    # There is already a checkout here -- the normal case on any machine this
    # has run on before. Bring it up to date and use it; never re-clone over it.
    echo "Already cloned; refreshing."
    # Non-fatal on purpose, every branch of it: local edits, a diverged branch
    # or no network are all reasons to carry on with the checkout that is
    # already there rather than to refuse to install.
    if [ -d "$DOTFILES_DIR/.git" ]; then
      if bootstrap_have_git; then
        git -C "$DOTFILES_DIR" pull --ff-only --quiet 2>/dev/null || {
          echo "  NOTE: couldn't fast-forward (local edits, a diverged branch or"
          echo "        no network); using the checkout as it is."
        }
      else
        echo "  NOTE: no usable git here, so a git checkout can't be pulled;"
        echo "        using it as it is."
      fi
    elif [ -f "$DOTFILES_DIR/$TARBALL_STAMP" ]; then
      # No .git to pull, but the stamp says this one came from the tarball route
      # below, so every file in it is ours and re-extracting is safe. It only
      # overwrites tracked files: .generated/ and the saved answers survive.
      echo "  (no .git -- refetching the tarball)"
      fetch_tarball "$DOTFILES_DIR" \
        || echo "  NOTE: couldn't refetch; using the checkout as it is."
    else
      echo "  NOTE: not a git checkout, and not one this script fetched --"
      echo "        leaving its contents alone and installing from them."
    fi
  elif [ -e "$DOTFILES_DIR" ] && [ -n "$(ls -A "$DOTFILES_DIR" 2>/dev/null)" ]; then
    echo "ERROR: $DOTFILES_DIR already exists, is not empty, and is not a" >&2
    echo "       checkout of this repo. Move it aside, or point somewhere else:" >&2
    echo "         curl -fsSL albertorota.dev/setmeup.sh | DOTFILES_DIR=~/other bash" >&2
    exit 1
  elif bootstrap_have_git; then
    # A full clone, not --depth 1: this is a repo you commit to, and starting
    # every machine off shallow just means unshallowing it later.
    git clone --branch "$DOTFILES_BRANCH" "$DOTFILES_REPO" "$DOTFILES_DIR" || {
      echo "ERROR: git clone failed." >&2; exit 1; }
  else
    # No usable git yet (the tools phase installs one later; on a fresh Mac that
    # means the Xcode Command Line Tools, which Homebrew's installer brings in).
    # A tarball is enough to get the installer running, and the result is still
    # a usable checkout -- just not a git one until you re-clone.
    echo "No git here; downloading a tarball instead."
    command -v curl >/dev/null 2>&1 || {
      echo "ERROR: neither git nor curl on this machine; cannot fetch the repo." >&2
      exit 1; }
    fetch_tarball "$DOTFILES_DIR" || {
      echo "ERROR: could not download or unpack $DOTFILES_TARBALL" >&2; exit 1; }
  fi

  is_checkout "$DOTFILES_DIR" || {
    echo "ERROR: $DOTFILES_DIR still doesn't look like a checkout." >&2; exit 1; }

  echo ""
  # Guards against an exec loop if the fetched copy somehow can't find its own
  # lib either -- better one clear error than a fork bomb.
  export DOTFILES_BOOTSTRAPPED=1
  # stdin is the exhausted curl pipe, so hand the real terminal over: with it,
  # the setup UI and the text wizard both take their normal path instead of
  # their "no tty" fallbacks. Without one (CI, cron) the run just stays
  # non-interactive, which is already handled everywhere below.
  if [ -r /dev/tty ] && (exec 3</dev/tty) 2>/dev/null; then
    exec bash "$DOTFILES_DIR/install.sh" "$@" </dev/tty
  fi
  exec bash "$DOTFILES_DIR/install.sh" "$@"
}

DOTFILES="$(self_dir || true)"
if [ -z "$DOTFILES" ] || ! is_checkout "$DOTFILES"; then
  if [ -n "${DOTFILES_BOOTSTRAPPED:-}" ]; then
    echo "ERROR: bootstrapped into $DOTFILES_DIR but lib/derive.sh is still missing." >&2
    exit 1
  fi
  bootstrap "$@"
fi

GENERATED="$DOTFILES/.generated"
XDG_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
ANSWERS="$XDG_CONFIG/dotfiles/theme.env"
# Every path install.sh takes over (symlink or plain copy) gets recorded here,
# one per run (not appended across runs), so ./reset.sh knows exactly what to
# undo without having to reverse-engineer it from the templates.
MANIFEST="$XDG_CONFIG/dotfiles/manifest.txt"
MANAGED=()
# Loaded before anything is touched, so copy_bin() below can tell "a plain
# copy we made on a previous run" (already in here) from "a real pre-existing
# file" (not in here) -- a distinction link()'s [ ! -L "$dst" ] check gets for
# free from symlinks, but a plain copy has no such marker of its own.
OLD_MANAGED=""
[ -r "$MANIFEST" ] && OLD_MANAGED="$(cat "$MANIFEST")"
HERDR_CONFIG="$XDG_CONFIG/herdr"
# Sourced, not duplicated: the palette, the validators, and everything derived
# from the answers (PRIMARY_DIM, the OMP_* colours, the four status-line strings)
# live in one file that tui/configure.py also runs, so the live preview and the
# rendered config are assembled by the same code. See lib/derive.sh.
# shellcheck source=lib/derive.sh
. "$DOTFILES/lib/derive.sh"
# The other half of the same split: what this script PUTS ON the machine, as
# opposed to what it configures. The catalogue, the sudo detection and every
# install route live there, and tui/configure.py runs the same file to build
# its checkbox list and its install-plan preview. See lib/tools.sh.
# shellcheck source=lib/tools.sh
. "$DOTFILES/lib/tools.sh"

# --- defaults -----------------------------------------------------------------
# The colour defaults reproduce the look this repo was committed with; the machine
# name defaults to this host's short name, which is usually what you want on a
# machine you are setting up for the first time.
PRIMARY="#00ff00"
SECONDARY="#ff7803"

# The default machine name is taken from the host, so it has to be MADE valid
# rather than validated: valid_machine() wants 1-24 of [A-Za-z0-9._-], and macOS
# hands out names like "Alberto's MacBook Pro" (spaces, an apostrophe) or a
# 30-character Bonjour name. Rejecting those aborts the install over a default
# nobody typed, which is not a useful answer to "set this machine up".
# A value given with --machine, or typed at either wizard, is still validated
# and still rejected -- that one someone chose.
default_machine() {
  local n
  n="$(hostname -s 2>/dev/null || uname -n 2>/dev/null || echo machine)"
  n="${n%%.*}"                                                 # strip a domain
  n="$(printf '%s' "$n" | tr -cs 'A-Za-z0-9._-' '-')"          # and anything else
  n="${n%-}"                                                   # no trailing filler
  n="${n:0:24}"
  n="${n%-}"                                                   # nor after truncating
  [ -n "$n" ] || n=machine
  printf '%s' "$n"
}
MACHINE="$(default_machine)"

# Status line components, shared by tmux's status bar and herdr-statusline (the
# two are meant to stay visually identical -- see CLAUDE.md). TEMP is a sub-toggle
# of GPU: it only has an effect when the GPU pill itself is shown.
SHOW_HOST=1
SHOW_GPU=1
SHOW_TEMP=1
SHOW_SLURM=1
SHOW_DATETIME=1

# Launch hsl (herdr + the status line) from the shell rc at login. OFF by default,
# and deliberately so: it is the one answer here that changes what happens when
# you open a terminal, and getting it wrong on a machine you reach only over ssh
# is the difference between "wrong colours" and "cannot get a shell". Turn it on
# per machine once you want it. shell/hsl-login.sh.in holds the guards.
HSL_LOGIN=0

# oh-my-posh accent placement: every accented part of the prompt names its own
# colour -- primary, secondary or neutral (#d6deeb, the theme's own text colour,
# so an unaccented element is still visible). The leading glyph additionally has
# a mode: "fixed" keeps OMP_ICON everywhere, "slurm" makes the glyph report the
# job -- primary on a normal shell, secondary inside an allocation.
# Deliberately EMPTY rather than pre-filled: lib/derive.sh both supplies the
# defaults for these and migrates the older OMP_COLOR_* answers into them, and
# it can only tell "not answered yet" from "answered" by them being unset.
# Defaulting them here would make that migration a silent no-op and quietly
# change the prompt on every machine set up before per-component colours.
OMP_ICON_MODE=""
OMP_ICON=""
OMP_TEXT=""
OMP_CHEVRON_OK=""
OMP_CHEVRON_ERROR=""
# NEUTRAL_FG, the palette, valid_hex/valid_machine, darken() and the defaults
# and migration for the five answers above all come from lib/derive.sh.

# Tools. Every TOOL_<ID> defaults to 1 -- the rule is "install the lot, deselect
# what you don't want" -- and tools_defaults() (lib/tools.sh) fills in the ones
# theme.env has never heard of, which is also what makes adding a tool to the
# catalogue turn it on automatically for machines set up before it existed.
INSTALL_TOOLS=1

RECONFIGURE=0
ASSUME_YES=0
SKIP_UV=0
NO_TUI=0
TOOLS_ONLY=0
# Which shells get wired up to shell/shellrc_additions.sh. "auto" works it out
# from this machine (see "which shells this machine logs into" below);
# bash/zsh/both force it.
SHELL_TARGET=auto

usage() {
  cat <<EOF
Usage: ./install.sh [options]
       curl -fsSL albertorota.dev/setmeup.sh | bash
       curl -fsSL albertorota.dev/setmeup.sh | bash -s -- [options]

  -r, --reconfigure     Re-ask for colours and machine name even if answers are saved.
      --primary HEX     Set the primary colour non-interactively (e.g. --primary '#78dce8').
      --secondary HEX   Set the secondary colour non-interactively.
      --machine NAME    Set the machine name non-interactively.
  -y, --non-interactive Never prompt; use saved answers, or the defaults if none.
      --skip-uv         Don't install/update uv (offline machines, CI).
      --shell WHICH     Which shells to wire up: auto (default), bash, zsh, both.
      --no-tui          Use the plain text wizard instead of the Textual UI.
      --no-tools        Only render and link config; install no tools.
      --tools-only      Only install tools; render and link nothing.
  -h, --help            Show this message.

With no options: installs uv if missing, then prompts (in the Textual UI) on the
first run, then reuses the saved answers from
$ANSWERS

A run also puts a 'dotfiles' CLI on PATH (~/.local/bin/dotfiles) that wraps this
script, reset.sh and lib/tools.sh from anywhere: 'dotfiles reconfigure',
'dotfiles update', 'dotfiles backups', 'dotfiles uninstall', and 'dotfiles purge'
(uninstall, then delete the checkout itself). 'dotfiles help' lists them all.

Tools are installed by whichever route this machine can actually use: apt when
you have root or sudo, and rustup/cargo, uv, release tarballs, git clones or
Homebrew when you don't. './install.sh --tools-only -y' shows the plan and runs
it without touching any config; 'bash lib/tools.sh --plan' just shows it.

Piped from curl there is no checkout to run from, so this script clones one
first and hands over to the copy inside it. That is controlled by:

  DOTFILES_DIR      where to clone       (default \$HOME/dotfiles)
  DOTFILES_SLUG     owner/repo on GitHub (default alberto-rota/dotfiles)
  DOTFILES_BRANCH   branch to check out  (default main)
  DOTFILES_REPO     full clone URL, if it isn't GitHub
EOF
}

# Only wizard concerns, so they stay here rather than in lib/derive.sh.

# How wide the terminal is, for laying the prompts out. stty on the real
# terminal first (most accurate), then tput, then 80 -- and never below 20,
# since a nonsense answer here would produce a nonsense layout rather than a
# narrow one. Everything drawn by the wizard is sized from this, because a
# wrapped row of swatches or a wrapped status bar preview is not a preview.
term_cols() {
  local c=""
  if [ -n "${TTY_FD:-}" ]; then
    c="$(stty size <&"$TTY_FD" 2>/dev/null | awk '{print $2}')"
  fi
  [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 20 ] || c="$(tput cols 2>/dev/null || true)"
  [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 20 ] || c=80
  printf '%s' "$c"
}

# A heading, and an optional hint on its OWN line. The hints used to be
# parenthetical tails ("Machine name  (shown in the tmux bar and the shell
# prompt)" is 60 cells) which wrapped on anything narrow; split in two, each
# line fits a 44-cell terminal.
section() {
  printf '\n  \033[1m%s\033[0m\n' "$1"
  [ -n "${2:-}" ] && printf '  \033[2m%s\033[0m\n' "$2"
  printf '\n'
}

# $HOME spelled as ~, for the messages that name a path in it. Nothing here can
# run a path through a shell, so this is purely cosmetic -- but "~/.bashrc" is
# 10 cells where "/home/somebody/.bashrc" is 23, and these lines are laid out to
# fit a narrow terminal. Guarded against an unset or "/" HOME, which would
# otherwise turn every absolute path into a tilde.
tilde() {
  case "${HOME:-}" in
    ''|/) printf '%s' "$1"; return ;;
  esac
  case "$1" in
    "$HOME") printf '~' ;;
    "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# swatch HEX [width] -- a block of colour, 4 cells unless told otherwise.
swatch() {
  local w="${2:-4}"
  printf '\033[48;2;%sm%*s\033[0m' "$(hex_rgb "$1")" "$w" ""
}

# --- arg parsing --------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -r|--reconfigure) RECONFIGURE=1 ;;
    -y|--non-interactive) ASSUME_YES=1 ;;
    --skip-uv)   SKIP_UV=1 ;;
    --shell)     SHELL_TARGET="${2:?--shell needs a value}"; shift ;;
    --no-tui)    NO_TUI=1 ;;
    --no-tools)  INSTALL_TOOLS=0 ;;
    --tools-only) TOOLS_ONLY=1 ;;
    --primary)   PRIMARY_ARG="${2:?--primary needs a value}"; shift ;;
    --secondary) SECONDARY_ARG="${2:?--secondary needs a value}"; shift ;;
    --machine)   MACHINE_ARG="${2:?--machine needs a value}"; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# --- which shells this machine logs into ----------------------------------------
# The prompt, the aliases and every PATH addition arrive through one line
# appended to a shell's rc file, so this has to know WHICH rc. macOS has logged
# people into zsh since Catalina and most Linux boxes into bash, and plenty of
# machines see both -- so it is detected rather than assumed, and --shell forces
# it either way.
#
# The LOGIN shell is not the shell running this script: under `curl | bash` that
# is bash even on a Mac whose login shell is zsh. $SHELL is the answer every
# terminal emulator honours; the passwd database is the fallback for a cron/CI
# environment that never set it (macOS has no getent, hence dscl).
# The `|| true` on both lookups is not optional: this script runs under
# `set -o pipefail`, so a machine with no dscl/getent (or a user missing from
# the local database, which is every LDAP-backed HPC login node) would fail the
# assignment and take the whole install down with it.
login_shell_name() {
  local s="${SHELL:-}"
  if [ -z "$s" ]; then
    if is_mac; then
      s="$(dscl . -read "/Users/$(id -un)" UserShell 2>/dev/null | awk '{print $NF}' || true)"
    else
      s="$(getent passwd "$(id -un)" 2>/dev/null | awk -F: '{print $7}' || true)"
    fi
  fi
  printf '%s' "${s##*/}"
}

LOGIN_SHELL="$(login_shell_name)"
# Nothing to go on at all -- no $SHELL, no passwd entry. bash is the assumption,
# which is also what gets wired in that case, so the two agree.
[ -n "$LOGIN_SHELL" ] || LOGIN_SHELL=bash
WIRE_BASH=0
WIRE_ZSH=0
case "$SHELL_TARGET" in
  bash) WIRE_BASH=1 ;;
  zsh)  WIRE_ZSH=1 ;;
  both) WIRE_BASH=1; WIRE_ZSH=1 ;;
  auto)
    # bash always: it is on every machine this repo targets, and `bash` typed
    # inside a zsh session should still come up with the prompt and the aliases.
    # zsh when there is evidence somebody uses it here -- it is the login shell,
    # or a ~/.zshrc already exists. A zsh merely INSTALLED is not evidence: it
    # sits unused on most Linux boxes, and creating a ~/.zshrc nobody asked for
    # changes what their next login does.
    WIRE_BASH=1
    if [ "$LOGIN_SHELL" = zsh ] || [ -f "$HOME/.zshrc" ]; then WIRE_ZSH=1; fi
    ;;
  *) echo "Unknown --shell '$SHELL_TARGET' -- want auto, bash, zsh or both." >&2; exit 2 ;;
esac

# The rc that the shell you are actually dropped into at login will read: what
# the "source this to finish" line at the end names, and where the hsl autostart
# would run from. Falls back to whichever rc IS being wired when the login shell
# is something else (or was excluded with --shell).
# SHELL_FOR_RC goes with it: which of the two shells actually READS that file.
# Needed because the "source this to finish" step is only a valid instruction in
# a shell that can parse it -- see print_next_steps().
if [ "$LOGIN_SHELL" = zsh ] && [ "$WIRE_ZSH" -eq 1 ]; then
  LOGIN_RC="$HOME/.zshrc"; SHELL_FOR_RC=zsh
elif [ "$WIRE_BASH" -eq 1 ]; then
  LOGIN_RC="$HOME/.bashrc"; SHELL_FOR_RC=bash
else
  LOGIN_RC="$HOME/.zshrc"; SHELL_FOR_RC=zsh
fi
# Which shell to name in the "how do I get a plain login shell" escape hatch the
# hsl notes print. Only the two this repo wires; anything else gets bash, which
# is the one guaranteed to be there.
case "$LOGIN_SHELL" in
  zsh) HSL_ESCAPE_SHELL=zsh ;;
  *)   HSL_ESCAPE_SHELL=bash ;;
esac

# --- uv --------------------------------------------------------------------
# First thing this script does on a machine, before anything is asked or
# rendered: uv is what runs the setup UI (tui/configure.py, a PEP 723 script, so
# `uv run --script` fetches its own Python and Textual), and it is wanted on
# every machine anyway. A failure here is never fatal -- an offline machine just
# falls back to the text wizard further down.
UV_ENV_FILE="$XDG_CONFIG/dotfiles/uv-env.sh"

# Where the astral installer will put (or has already put) uv. Mirrors the
# installer's own precedence, so we can find it afterwards without re-parsing
# its output.
uv_install_dir() {
  if [ -n "${UV_INSTALL_DIR:-}" ]; then printf '%s' "$UV_INSTALL_DIR"
  elif [ -n "${XDG_BIN_HOME:-}" ]; then printf '%s' "$XDG_BIN_HOME"
  elif [ -n "${XDG_DATA_HOME:-}" ]; then printf '%s' "$XDG_DATA_HOME/../bin"
  else printf '%s' "$HOME/.local/bin"; fi
}

# The permanent half of "put uv on PATH": a tiny file that shellrc_additions.sh
# sources on every shell, bash and zsh alike. It is written even when uv was
# already installed, so a machine where uv landed somewhere unusual
# (UV_INSTALL_DIR/XDG_BIN_HOME) still gets that directory on PATH for good.
persist_uv_path() {
  local dir="$1"
  mkdir -p "$(dirname "$UV_ENV_FILE")"
  cat > "$UV_ENV_FILE" <<EOF
# GENERATED by dotfiles/install.sh -- puts uv's install directory on PATH.
# Sourced from shell/shellrc_additions.sh (and so from ~/.bashrc and ~/.zshrc).
# Edit install.sh, not this file; it is rewritten on every run.
case ":\$PATH:" in
  *":$dir:"*) ;;
  *) export PATH="$dir:\$PATH" ;;
esac
# The installer's own env file, if it wrote one (it may add more than PATH).
[ -f "$dir/env" ] && . "$dir/env"
EOF
  echo "uv on PATH permanently via $UV_ENV_FILE (sourced from shellrc_additions.sh)"
}

ensure_uv() {
  local dir; dir="$(uv_install_dir)"

  # Installed by an earlier run but not on this shell's PATH yet.
  if ! command -v uv >/dev/null 2>&1 && [ -x "$dir/uv" ]; then
    PATH="$dir:$PATH"
  fi

  if command -v uv >/dev/null 2>&1; then
    dir="$(dirname "$(command -v uv)")"
    echo "uv $(uv --version 2>/dev/null | awk '{print $2}') already installed ($dir/uv)"
  else
    if ! command -v curl >/dev/null 2>&1; then
      echo "NOTE: no curl on this machine, so uv can't be installed automatically."
      return 1
    fi
    echo "Installing uv into $dir ..."
    # UV_NO_MODIFY_PATH (INSTALLER_NO_MODIFY_PATH is its older name, still
    # honoured -- both are set so this keeps working either way): left to
    # itself the installer appends its own PATH line to ~/.bashrc, ~/.profile
    # and friends -- and on a machine this repo has already installed,
    # ~/.profile is a SYMLINK INTO THIS REPO, so that edit would land in
    # tracked dotfiles. persist_uv_path() below does the same job the dotfiles
    # way instead. It also suppresses the installer's own env file, which is
    # why uv-env.sh exports PATH itself and only sources that file if present.
    if ! curl -LsSf https://astral.sh/uv/install.sh \
         | env UV_INSTALL_DIR="$dir" UV_NO_MODIFY_PATH=1 INSTALLER_NO_MODIFY_PATH=1 sh; then
      echo "NOTE: uv install failed (offline?); continuing without it."
      return 1
    fi
    PATH="$dir:$PATH"
    command -v uv >/dev/null 2>&1 || { echo "NOTE: uv still not on PATH after install."; return 1; }
  fi

  export PATH
  persist_uv_path "$dir"
}

HAVE_UV=0
if [ "$SKIP_UV" -eq 1 ]; then
  echo "Skipping the uv step (--skip-uv)."
  command -v uv >/dev/null 2>&1 && HAVE_UV=1
elif ensure_uv; then
  HAVE_UV=1
fi
echo ""

# --- load saved answers -------------------------------------------------------
if [ -r "$ANSWERS" ]; then
  # shellcheck disable=SC1090
  . "$ANSWERS"
  HAD_ANSWERS=1
else
  HAD_ANSWERS=0
fi

# Explicit flags win over both saved answers and defaults.
PRIMARY="${PRIMARY_ARG:-$PRIMARY}"
SECONDARY="${SECONDARY_ARG:-$SECONDARY}"
MACHINE="${MACHINE_ARG:-$MACHINE}"

for v in PRIMARY SECONDARY; do
  valid_hex "${!v}" || { echo "Invalid $v colour '${!v}' -- want #rrggbb." >&2; exit 2; }
done
valid_machine "$MACHINE" || {
  echo "Invalid machine name '$MACHINE' -- want 1-24 of [A-Za-z0-9._-]." >&2; exit 2; }

# Normalise the answers before anything asks about them: this is what turns a
# theme.env written before per-component colours existed into the equivalent
# OMP_ICON/OMP_TEXT/OMP_CHEVRON_* answers, and fills in defaults on a machine
# with no saved answers at all. Both front-ends therefore start from real
# values rather than from blanks, and derive() runs again after they are done.
derive
# Same idea for the tool answers: a theme.env written before a tool joined the
# catalogue simply has no line for it, and "no line" has to mean "on" or a new
# tool would never install itself on an existing machine.
tools_defaults

# --- decide whether to prompt -------------------------------------------------
# Read from the terminal explicitly so the wizard still works under `curl | bash`.
# /dev/tty can be present but unopenable (cron, CI, a container without a
# controlling terminal), so the open has to be allowed to fail rather than
# aborting under `set -e`.
# The descriptor number is hardcoded rather than allocated with `exec {TTY_FD}<&0`,
# which is bash 4.1 and so not available on macOS. 3 is free: nothing else in
# this script holds one open, and the /dev/tty probes only ever open it inside a
# subshell.
TTY_FD=""
if [ -t 0 ]; then
  exec 3<&0
  TTY_FD=3
elif [ -r /dev/tty ] && (exec 3</dev/tty) 2>/dev/null; then
  # Probed in a subshell above, so bash never prints its own redirection error.
  exec 3</dev/tty
  TTY_FD=3
fi

INTERACTIVE=0
if [ -n "$TTY_FD" ] && [ "$ASSUME_YES" -eq 0 ] \
   && { [ "$HAD_ANSWERS" -eq 0 ] || [ "$RECONFIGURE" -eq 1 ]; }; then
  INTERACTIVE=1
fi

# --- what the tools phase may do about sudo -------------------------------------
# Settled here, well before the phase itself, for two reasons: both wizards
# print the result ("sudo available (will ask for your password once)") next to
# the tool list, and the setup UI -- which runs next -- inherits TOOLS_CAN_PROMPT
# and resolves its install-plan pane against it, so the plan it shows is the
# plan that will run. Costs a couple of `sudo -n` calls, neither of which can
# prompt. Note this is NOT the same test as INTERACTIVE: there is a terminal to
# ask a password on even when the wizard is being skipped because answers are
# already saved.
TOOLS_CAN_PROMPT=0
if [ -n "$TTY_FD" ] && [ "$ASSUME_YES" -eq 0 ]; then TOOLS_CAN_PROMPT=1; fi
export TOOLS_CAN_PROMPT
priv_resolve

# --- what the previews need -----------------------------------------------------
# Before the wizard, deliberately. Its preview panes are the real prompt and the
# real Claude status line, which need oh-my-posh and jq to exist; without them a
# first-time user gets a hand-drawn approximation and a "needs jq" apology --
# precisely what the previews exist to avoid. Cheap (two small downloads), never
# prompts, and always optional: a failure here just restores the old fallbacks.
if [ "$INSTALL_TOOLS" = 1 ] && [ "$INTERACTIVE" -eq 1 ]; then
  install_preview_prereqs
fi

# --- the wizard ---------------------------------------------------------------
# PALETTE_NAMES / PALETTE_HEX / PALETTE_COLUMNS come from lib/derive.sh, sourced
# above. They are deliberately NOT redeclared here: this file used to carry its
# own copy of the first eight, which meant the text wizard silently offered a
# different (and shorter) set of swatches than the Textual UI did.
# Forty-eight numbered lines is not a menu, it is a wall, so the picker is two
# steps: choose a scheme (six lines, each showing its whole ramp as one ribbon of
# swatches), then a colour inside it. A #rrggbb typed at either prompt is taken
# as-is, and empty keeps what is already set -- so the fast paths stay one
# keystroke, and nothing has to be counted.
ask_color() {
  local var="$1" label="$2" choice row col i idx
  local nrows="${#PALETTE_ROWS[@]}" ncols="$PALETTE_COLUMNS"
  # Split from the declaration above: inside a single `local`, the indirection
  # ${!var} is evaluated before `var` itself is usable as a name.
  local cur="${!var}"
  # Laid out to fit: "    N) " + a 10-cell scheme name + the ribbon + " *".
  # The scheme names are never abbreviated (a cut "catppucc" is worse than a
  # thinner swatch), so it is the swatches that give up cells on a narrow
  # terminal -- 4 down to 1.
  local cols cell per
  cols="$(term_cols)"
  cell=$(( (cols - 20) / ncols ))
  [ "$cell" -gt 4 ] && cell=4
  [ "$cell" -lt 1 ] && cell=1

  while true; do
    local keep lbl
    keep="  keep $cur"
    lbl="$(palette_label "$cur")"
    # The scheme name is dropped rather than wrapped when it will not fit --
    # "catppuccin / rosewater" is 22 cells on its own.
    [ $(( ${#keep} + ${#lbl} )) -le "$cols" ] && keep="$keep$lbl"
    printf '\n  \033[1m%s colour\033[0m\n%s\n\n' "$label" "$keep"
    for i in "${!PALETTE_ROWS[@]}"; do
      printf '    %d) %-10s ' "$((i + 1))" "${PALETTE_ROWS[$i]}"
      for (( col = 0; col < ncols; col++ )); do
        idx=$(( i * ncols + col ))
        swatch "${PALETTE_HEX[$idx]}" "$cell"
      done
      # A marker on the row the current colour lives in, so "where am I" needs
      # no counting either.
      [ "$(palette_group_of "$(palette_index "$cur")" 2>/dev/null)" = "${PALETTE_ROWS[$i]}" ] \
        && printf ' *'
      echo
    done

    printf '\n  scheme 1-%d, hex, or enter: ' "$nrows"
    read -r -u "$TTY_FD" choice || choice=""
    [ -z "$choice" ] && { printf -v "$var" '%s' "$cur"; return; }

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$nrows" ]; then
      row=$(( choice - 1 ))
      # Second step: the eight colours of that scheme, four to a line.
      printf '\n    \033[1m%s\033[0m\n' "${PALETTE_ROWS[$row]}"
      # Each cell is "N) " + the swatch + " " + a 10-cell name; fit as many
      # across as the terminal takes, at least one.
      per=$(( (cols - 4) / (cell + 14) ))
      [ "$per" -lt 1 ] && per=1
      [ "$per" -gt "$ncols" ] && per="$ncols"
      for (( col = 0; col < ncols; col++ )); do
        idx=$(( row * ncols + col ))
        [ $(( col % per )) -eq 0 ] && printf '    '
        printf '%d) ' "$((col + 1))"
        swatch "${PALETTE_HEX[$idx]}" "$cell"
        printf ' %-10s' "${PALETTE_NAMES[$idx]}"
        [ $(( (col + 1) % per )) -eq 0 ] && echo
      done
      [ $(( ncols % per )) -eq 0 ] || echo
      printf '\n    colour 1-%d, enter=back: ' "$ncols"
      read -r -u "$TTY_FD" choice || choice=""
      [ -z "$choice" ] && continue
      if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$ncols" ]; then
        printf -v "$var" '%s' "${PALETTE_HEX[$(( row * ncols + choice - 1 ))]}"
        return
      fi
    fi

    # A hex typed at either prompt, with a bare "abc123" treated as "#abc123"
    # since the # is easy to leave off.
    [[ "$choice" =~ ^[0-9a-fA-F]{6}$ ]] && choice="#$choice"
    if valid_hex "$choice"; then
      printf -v "$var" '%s' "$choice"; return
    fi
    printf '  \033[31mNot a scheme number or a #rrggbb value.\033[0m\n'
  done
}

ask_machine() {
  local answer
  while true; do
    section "Machine name" "shown in the bar and the prompt"
    printf '  name [%s]: ' "$MACHINE"
    read -r -u "$TTY_FD" answer || answer=""
    [ -z "$answer" ] && return
    if valid_machine "$answer"; then MACHINE="$answer"; return; fi
    printf '  \033[31mUse 1-24 characters from [A-Za-z0-9._-].\033[0m\n'
  done
}

ask_bool() {
  local var="$1" label="$2" hint answer
  # Split from the declaration above, same reason as ask_color(): inside a
  # single `local`, ${!var} is evaluated before `var` itself is usable as a
  # name for the indirection.
  local cur="${!var}"
  hint="y/N"; [ "$cur" = 1 ] && hint="Y/n"
  while true; do
    printf '  %s [%s]: ' "$label" "$hint"
    read -r -u "$TTY_FD" answer || answer=""
    # to_lower() from lib/derive.sh -- ${answer,,} is bash 4 and this script has
    # to parse under macOS's 3.2. Same everywhere a reply is folded below.
    case "$(to_lower "$answer")" in
      '') printf -v "$var" '%s' "$cur"; return ;;
      y|yes) printf -v "$var" '%s' 1; return ;;
      n|no)  printf -v "$var" '%s' 0; return ;;
      *) printf '  \033[31mAnswer y or n.\033[0m\n' ;;
    esac
  done
}

# ask_choice VAR "label" opt1 opt2 ...  -- pick one of a fixed set by number or
# by (unique) prefix, empty keeps the current value. The wizard's counterpart to
# the UI's cycling choice rows.
ask_choice() {
  local var="$1" label="$2"; shift 2
  local opts=("$@") cur="${!var}" answer answer_lc i
  while true; do
    printf '  %s [%s]:\n' "$label" "$cur"
    for i in "${!opts[@]}"; do
      printf '      %d) %-10s' "$((i + 1))" "${opts[$i]}"
      [ "${opts[$i]}" = "$cur" ] && printf ' <- current'
      echo
    done
    printf '    choice: '
    read -r -u "$TTY_FD" answer || answer=""
    [ -z "$answer" ] && { printf -v "$var" '%s' "$cur"; return; }
    if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le "${#opts[@]}" ]; then
      printf -v "$var" '%s' "${opts[$((answer - 1))]}"; return
    fi
    answer_lc="$(to_lower "$answer")"
    for i in "${!opts[@]}"; do
      if [ "${opts[$i]#"$answer_lc"}" != "${opts[$i]}" ]; then
        printf -v "$var" '%s' "${opts[$i]}"; return
      fi
    done
    printf '  \033[31mPick one of: %s\033[0m\n' "${opts[*]}"
  done
}

ask_components() {
  section "Status line" "tmux bar + herdr-statusline"
  ask_bool SHOW_HOST     "  hostname pill"
  ask_bool SHOW_GPU      "  GPU usage pill"
  if [ "$SHOW_GPU" = 1 ]; then
    ask_bool SHOW_TEMP   "    also GPU temperature"
  else
    SHOW_TEMP=0
  fi
  ask_bool SHOW_SLURM    "  Slurm job pill"
  ask_bool SHOW_DATETIME "  date / time pill"

  section "Shell login"
  ask_bool HSL_LOGIN "  start herdr at login"

  section "oh-my-posh accents" "machine segment + status chevrons"
  ask_choice OMP_ICON_MODE "  leading glyph" fixed slurm
  if [ "$OMP_ICON_MODE" = fixed ]; then
    ask_choice OMP_ICON "  glyph colour" "${OMP_CHOICES[@]}"
  else
    printf '    (slurm: primary normally, secondary inside a job shell)\n'
  fi
  ask_choice OMP_TEXT         "  machine text" "${OMP_CHOICES[@]}"
  ask_choice OMP_CHEVRON_OK   "  chevrons, exit 0" "${OMP_CHOICES[@]}"
  ask_choice OMP_CHEVRON_ERROR "  chevrons, error" "${OMP_CHOICES[@]}"
}

# The text fallback's counterpart to the UI's Tools checkboxes. Nineteen y/n
# prompts would be miserable, so it prints the list with everything already on
# and takes numbers to switch off -- which also matches how the answer defaults
# actually work.
ask_tools() {
  local i id var picked line
  while true; do
    section "Tools to install" "$(priv_summary)"
    for i in "${!TOOL_IDS[@]}"; do
      id="${TOOL_IDS[$i]}"; var="$(tool_var "$id")"
      if [ "${!var}" = 1 ]; then
        printf '    %2d) \033[1m[x]\033[0m %s\n' "$((i + 1))" "$(tool_label "$id")"
      else
        printf '    %2d) [ ] \033[2m%s\033[0m\n' "$((i + 1))" "$(tool_label "$id")"
      fi
    done
    printf '\n  numbers to toggle, enter=ok: '
    read -r -u "$TTY_FD" line || line=""
    [ -z "$line" ] && return
    for picked in $line; do
      [[ "$picked" =~ ^[0-9]+$ ]] || continue
      [ "$picked" -ge 1 ] && [ "$picked" -le "${#TOOL_IDS[@]}" ] || continue
      id="${TOOL_IDS[$((picked - 1))]}"; var="$(tool_var "$id")"
      if [ "${!var}" = 1 ]; then printf -v "$var" '%s' 0; else printf -v "$var" '%s' 1; fi
    done
  done
}

# Renders the REAL prompt via `oh-my-posh print`, not an approximation: builds
# a throwaway rendered copy of the template with the wizard's current answers
# (same placeholders as render(), computed inline since the OMP_* colour
# derivation normally happens once after the wizard, but the preview needs it
# on every iteration) and asks oh-my-posh itself to render it, in this actual
# shell/cwd/git-state -- so what you see is what you'll get, not a guess at it.
# Falls back to a hand-drawn approximation if oh-my-posh isn't on PATH yet
# (e.g. a machine being set up for the first time, before this same install.sh
# run has had a chance to put it there).
omp_live_preview() {
  # A directory with a known filename inside it, rather than `mktemp
  # ....XXXXXX.json`: BSD mktemp only substitutes Xs at the very END of the
  # template, so on macOS that spelling produces a file literally called
  # "XXXXXX.json" (or an error). The .json matters -- oh-my-posh picks its
  # config parser from the extension.
  local dir tmp
  dir="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-omp.XXXXXX")"
  tmp="$dir/preview.omp.json"
  sed -e '/^#>>/d' \
      -e "s|@PRIMARY@|$PRIMARY|g" \
      -e "s|@SECONDARY@|$SECONDARY|g" \
      -e "s|@MACHINE_LOWER@|$MACHINE_LOWER|g" \
      -e "s|@OMP_ICON_COLOR_JOB@|$OMP_ICON_COLOR_JOB|g" \
      -e "s|@OMP_ICON_COLOR@|$OMP_ICON_COLOR|g" \
      -e "s|@OMP_TEXT_COLOR@|$OMP_TEXT_COLOR|g" \
      -e "s|@OMP_CHEVRON_FG@|$OMP_CHEVRON_FG|g" \
      -e "s|@OMP_CHEVRON_ERR@|$OMP_CHEVRON_ERR|g" \
      "$DOTFILES/oh-my-posh/albe-monokai2.omp.json.in" > "$tmp"

  # --terminal-width so oh-my-posh lays its right-hand block out for the space
  # that actually exists; left to its own guess the prompt is padded wider than
  # the terminal and wraps. There is deliberately no `cut` as a backstop: cut
  # counts characters, not display cells, and this stream is mostly colour
  # escapes, so it would hack the prompt to pieces long before its visible end.
  #
  # Both OSC terminators are stripped. oh-my-posh emits the console title as
  # ESC ] ... BEL *and* its git links as ESC ] 8 ; ; URL ESC \ -- handling only
  # the BEL form left the link markers to print as literal "]8;;https://..."
  # text in the middle of the preview.
  #
  # The escapes are spliced in with $'...' and the pattern is an EXTENDED one,
  # because both halves of the obvious spelling are GNU-only: BSD sed reads
  # \x1b as a literal "x1b", and BRE alternation \| is not in POSIX at all. Two
  # GNU-isms in one expression that would each have failed silently -- the
  # preview would simply have grown a line of escape-code litter.
  local w esc bel
  w=$(( $(term_cols) - 4 ))
  [ "$w" -lt 20 ] && w=20
  esc=$'\033'; bel=$'\007'
  oh-my-posh print primary --config "$tmp" --shell universal \
      --terminal-width "$w" 2>/dev/null \
    | sed -E -e "s/${esc}\][^${bel}${esc}]*(${bel}|${esc}\\\\)//g" \
    | awk '{ print "    " $0 }'
  rm -rf "$dir"
}

# bar_seg WIDTH FORMAT [ARGS...] -- print one status-bar pill, but only if its
# visible width still fits BAR_LEFT. Dropping from the right is what tmux itself
# does with a bar too wide for the window, so a trimmed preview is still an
# honest one; BAR_DROPPED records that something went, for the ellipsis.
BAR_LEFT=0
BAR_DROPPED=0
bar_seg() {
  local w="$1"; shift
  if [ "$w" -gt "$BAR_LEFT" ]; then BAR_DROPPED=1; return 0; fi
  BAR_LEFT=$(( BAR_LEFT - w ))
  # shellcheck disable=SC2059  -- the format is ours, from the caller below
  printf "$@"
}

show_preview() {
  local p s icon_c text_c chev_c cols rule
  # Everything the preview needs is a derived value, so derive them exactly the
  # way the install will -- no second, drifting copy of the colour logic here.
  derive
  # Sized to the terminal. The rule was a flat 48 cells and the sample bar below
  # it is wider still (~57 with every pill on), so on anything narrow they
  # wrapped -- and a wrapped preview of a status bar is not a preview of it.
  cols="$(term_cols)"
  rule=$(( cols - 4 ))
  [ "$rule" -gt 48 ] && rule=48
  [ "$rule" -lt 8 ] && rule=8
  p="$(hex_rgb "$PRIMARY")"
  s="$(hex_rgb "$SECONDARY")"
  icon_c="$(hex_rgb "$OMP_ICON_COLOR")"
  text_c="$(hex_rgb "$OMP_TEXT_COLOR")"
  chev_c="$(hex_rgb "$OMP_CHEVRON_FG")"
  section "Preview"
  # pane border
  printf '    \033[38;2;%sm' "$p"
  printf '─%.0s' $(seq "$rule")
  printf '\033[0m\n'
  if command -v oh-my-posh >/dev/null 2>&1; then
    omp_live_preview
  else
    # oh-my-posh not installed yet -- hand-drawn approximation of just the
    # machine segment and the bottom chevron line, on the theme's #212224 panel.
    printf '    \033[48;2;33;34;36m\033[38;2;%sm  \033[38;2;%sm%s \033[0m' \
      "$icon_c" "$text_c" "$MACHINE_LOWER"
    printf '\033[38;2;33;34;36m\033[0m\n'
    printf '    \033[38;2;33;34;36m╰─\033[38;2;%sm \033[0m\n' "$chev_c"
  fi

  # tmux / herdr-statusline: host, gpu, slurm, clock -- only the enabled pills,
  # and only as many of those as the terminal has room for. The widths are the
  # VISIBLE cell counts of each pill, counted from the literals below (the
  # escapes around them take no cells).
  BAR_LEFT=$rule
  BAR_DROPPED=0
  printf '    '
  [ "$SHOW_HOST" = 1 ] && bar_seg $(( ${#MACHINE} + 2 )) \
    '\033[48;2;0;0;0m\033[1m\033[38;2;255;255;255m %s \033[0m' "$MACHINE"
  if [ "$SHOW_GPU" = 1 ]; then
    if [ "$SHOW_TEMP" = 1 ]; then
      bar_seg 18 '\033[48;2;0;0;0m\033[38;2;%sm GPU ▰▰▱▱ 45%% 62° \033[0m' "$p"
    else
      bar_seg 14 '\033[48;2;0;0;0m\033[38;2;%sm GPU ▰▰▱▱ 45%% \033[0m' "$p"
    fi
  fi
  [ "$SHOW_SLURM" = 1 ] && bar_seg 9 \
    '\033[48;2;0;0;0m\033[38;2;%sm  1 job \033[0m' "$p"
  if [ "$SHOW_DATETIME" = 1 ]; then
    bar_seg 22 '\033[48;2;%sm\033[38;2;0;0;0m\033[0m\033[48;2;%sm\033[1m\033[38;2;0;0;0m  12:34  2026-07-31 \033[0m' \
      "$s" "$p"
  fi
  [ "$BAR_DROPPED" = 1 ] && printf '\033[2m…\033[0m'
  printf '\n'

  # Claude Code's five bubbles, in the ramp derive() just computed. Six cells
  # each (four of pill, the cap glyph, a space), so they get the same budget.
  BAR_LEFT=$rule
  BAR_DROPPED=0
  printf '    '
  local rgb
  for rgb in "$CLAUDE_MODEL_RGB" "$CLAUDE_EFFORT_RGB" "$CLAUDE_USAGE_RGB" \
             "$CLAUDE_WEEK_RGB" "$CLAUDE_CTX_RGB"; do
    bar_seg 6 '\033[38;2;%sm\033[48;2;%sm\033[38;2;0;0;0m    \033[0m\033[38;2;%sm\033[0m ' \
      "$rgb" "$rgb" "$rgb"
  done
  [ "$BAR_DROPPED" = 1 ] && printf '\033[2m…\033[0m'
  printf '\n\n'
}

text_wizard() {
  printf '\n\033[1mdotfiles setup\033[0m\n'
  printf 'Pick the two accent colours and this machine'\''s name, then everything installs.\n'
  while true; do
    ask_color PRIMARY   "Primary"
    ask_color SECONDARY "Secondary"
    ask_machine
    ask_components
    [ "$INSTALL_TOOLS" = 1 ] && ask_tools
    show_preview
    printf '  Install with these? [\033[1mY\033[0m]es / [r]edo / [q]uit: '
    read -r -u "$TTY_FD" reply || reply=""
    case "$(to_lower "$reply")" in
      ''|y|yes)    return 0 ;;
      r|redo)      continue ;;
      q|quit|n|no) echo "Aborted; nothing was changed."; exit 1 ;;
      *) printf '  \033[31mAnswer y, r or q.\033[0m\n' ;;
    esac
  done
}

# --- the Textual UI -------------------------------------------------------------
# tui/configure.py carries its own dependencies in a PEP 723 header, so `uv run
# --script` fetches Python and Textual itself -- nothing to install by hand and
# nothing left behind on the machine. The answers come back as a shell fragment
# (the theme.env format) that this script sources, so the UI decides nothing
# about how anything is rendered; it only chooses values.
#
# Exit codes: 0 = confirmed and $1 written, 10 = the user quit, anything else =
# the UI could not run and the caller should fall back to text_wizard.
TUI_CANCELLED=10
run_tui() {
  local out="$1" rc=0
  command -v uv >/dev/null 2>&1 || return 1
  [ -r "$DOTFILES/tui/configure.py" ] || return 1

  # The UI reads the current answers from the environment, exactly as
  # lib/derive.sh does when the UI shells out to it for its live preview.
  export DOTFILES PRIMARY SECONDARY MACHINE USER_NAME NEUTRAL_FG
  export SHOW_HOST SHOW_GPU SHOW_TEMP SHOW_SLURM SHOW_DATETIME
  export OMP_ICON_MODE OMP_ICON OMP_TEXT OMP_CHEVRON_OK OMP_CHEVRON_ERROR
  export HSL_LOGIN
  # Every TOOL_<ID>, so the UI's checkboxes open on this machine's saved answers
  # and its install-plan pane resolves against them.
  tools_export

  echo "Starting the setup UI (uv run tui/configure.py) ..."
  # Textual needs the terminal on both stdin and stdout. Under `curl | bash`
  # neither is one, hence the /dev/tty fallback -- the same reasoning as TTY_FD
  # above, but the child process needs real fd 0/1, not a spare descriptor.
  if [ -t 0 ] && [ -t 1 ]; then
    uv run --quiet --script "$DOTFILES/tui/configure.py" --out "$out" || rc=$?
  elif [ -r /dev/tty ] && [ -w /dev/tty ]; then
    uv run --quiet --script "$DOTFILES/tui/configure.py" --out "$out" </dev/tty >/dev/tty || rc=$?
  else
    return 1
  fi
  return "$rc"
}

if [ "$INTERACTIVE" -eq 1 ]; then
  WIZARD_RC=0
  if [ "$NO_TUI" -eq 1 ] || [ "$HAVE_UV" -eq 0 ]; then
    WIZARD_RC=1
  else
    # A directory, not `mktemp ...XXXXXX.env` -- BSD mktemp only substitutes a
    # RUN OF Xs at the end of the template, so that spelling does not produce a
    # unique name on macOS. Same reasoning as omp_live_preview().
    TUI_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-setup.XXXXXX")"
    TUI_OUT="$TUI_DIR/answers.env"
    run_tui "$TUI_OUT" || WIZARD_RC=$?
    if [ "$WIZARD_RC" -eq 0 ] && [ -r "$TUI_OUT" ]; then
      # shellcheck disable=SC1090
      . "$TUI_OUT"
    fi
    rm -rf "$TUI_DIR"
  fi

  if [ "$WIZARD_RC" -eq "$TUI_CANCELLED" ]; then
    echo "Aborted; nothing was changed."
    exit 1
  elif [ "$WIZARD_RC" -ne 0 ]; then
    [ "$NO_TUI" -eq 1 ] || echo "NOTE: the Textual UI is unavailable here; using the text wizard."
    text_wizard
  fi
elif [ -n "${PRIMARY_ARG:-}${SECONDARY_ARG:-}${MACHINE_ARG:-}" ]; then
  echo "Using the values given on the command line."
elif [ "$HAD_ANSWERS" -eq 1 ]; then
  echo "Using saved theme from $ANSWERS (--reconfigure to change)."
elif [ -z "$TTY_FD" ]; then
  echo "No saved theme and no terminal to prompt on; using defaults."
else
  echo "Using saved theme (--reconfigure to change)."
fi

# --- derive everything that follows from the answers ---------------------------
# PRIMARY_DIM, MACHINE_LOWER, USER_NAME, the OMP_* colours and the four status
# line strings, all from lib/derive.sh -- the same function tui/configure.py
# runs for its preview, so the preview cannot disagree with what gets rendered.
derive

echo "  primary   $PRIMARY  (herdr sidebar rail $PRIMARY_DIM)"
echo "  secondary $SECONDARY"
echo "  machine   $MACHINE"
echo "  status    host=$SHOW_HOST gpu=$SHOW_GPU temp=$SHOW_TEMP slurm=$SHOW_SLURM datetime=$SHOW_DATETIME"
echo "  omp       glyph=$OMP_ICON_MODE/$OMP_ICON text=$OMP_TEXT chevrons=$OMP_CHEVRON_OK,$OMP_CHEVRON_ERROR"
SHELLS_DESC=""
[ "$WIRE_BASH" -eq 1 ] && SHELLS_DESC="~/.bashrc"
[ "$WIRE_ZSH" -eq 1 ] && SHELLS_DESC="${SHELLS_DESC:+$SHELLS_DESC + }~/.zshrc"
echo "  shells    $SHELLS_DESC  (login shell: $LOGIN_SHELL)"
case "$LOGIN_SHELL" in
  bash|zsh|sh) ;;
  *) echo "            NOTE: your login shell is $LOGIN_SHELL, and this repo configures only"
     echo "            bash and zsh -- so $LOGIN_SHELL gets no prompt, aliases or PATH."
     echo "            Nothing is skipped otherwise: the tools still install and"
     echo "            $(tilde "$LOGIN_RC") is still written, so '$SHELL_FOR_RC -l' has the lot."
     echo "            To switch for good:  chsh -s \$(command -v $SHELL_FOR_RC)" ;;
esac
if [ "$HSL_LOGIN" = 1 ]; then
  # hsl where it exists, plain herdr where it does not (every Mac -- the
  # herdr-statusline plugin that ships hsl is Linux-only).
  if is_mac; then
    echo "  login     herdr starts at every interactive login (hsl is Linux-only)"
  else
    echo "  login     hsl (herdr + status line) starts at every interactive login"
  fi
else
  echo "  login     plain shell (herdr autostart off)"
fi
if [ "$INSTALL_TOOLS" = 1 ]; then
  TOOLS_ON=0
  for id in "${TOOL_IDS[@]}"; do tool_selected "$id" && TOOLS_ON=$((TOOLS_ON + 1)); done
  echo "  tools     $TOOLS_ON of ${#TOOL_IDS[@]} selected"
else
  echo "  tools     disabled (--no-tools)"
fi
echo ""

# --- save the answers ---------------------------------------------------------
mkdir -p "$(dirname "$ANSWERS")"
cat > "$ANSWERS" <<EOF
# GENERATED by dotfiles/install.sh -- this machine's theme answers.
# Re-run './install.sh --reconfigure' to change them, or edit and re-run install.sh.
PRIMARY="$PRIMARY"
SECONDARY="$SECONDARY"
MACHINE="$MACHINE"
SHOW_HOST=$SHOW_HOST
SHOW_GPU=$SHOW_GPU
SHOW_TEMP=$SHOW_TEMP
SHOW_SLURM=$SHOW_SLURM
SHOW_DATETIME=$SHOW_DATETIME
OMP_ICON_MODE=$OMP_ICON_MODE
OMP_ICON=$OMP_ICON
OMP_TEXT=$OMP_TEXT
OMP_CHEVRON_OK=$OMP_CHEVRON_OK
OMP_CHEVRON_ERROR=$OMP_CHEVRON_ERROR
HSL_LOGIN=$HSL_LOGIN
EOF
# One TOOL_<ID>=0|1 per catalogue entry, appended rather than spelled out in the
# heredoc above so adding a tool needs no edit here. A tool that is not in the
# catalogue any more drops out of the file on the next run, same as a stale
# render gets pruned from .generated/.
tools_answers >> "$ANSWERS"
echo "Saved answers to $ANSWERS"

# --- tools --------------------------------------------------------------------
# Defined before the phase runs, because --tools-only exits straight after it.
#
# A NEW shell needs nothing: shellrc_additions.sh sources the tools-env.sh that
# install_tools() just wrote, and already exports ~/.local/bin, ~/.cargo/bin and
# ~/.local/nvim/bin itself. This is purely for the terminal the install ran in,
# which will otherwise keep saying "command not found" for something that is
# very much installed -- the one thing that reliably makes a fresh setup look
# broken when it is not.
# Does this machine still need `tailscale up`? That step cannot be automated --
# it opens a browser to authenticate the node against your tailnet -- so the
# most this script can do is notice and say so.
needs_tailscale_up() {
  command -v tailscale >/dev/null 2>&1 || return 1
  local out
  out="$(tailscale status 2>&1 || true)"
  # A connected node lists its peers, one IP per line. Anything else -- "Logged
  # out.", the daemon not running, a permission error -- means there is still an
  # `up` to run.
  printf '%s' "$out" | grep -qE '^[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' && return 1
  return 0
}

# One block to copy and paste when the run is done: everything left that needs a
# human. A NEW shell needs none of it (shellrc_additions.sh sources the
# tools-env.sh install_tools() wrote), but the terminal the install ran in will
# otherwise keep saying "command not found" for something very much installed --
# the one thing that reliably makes a finished setup look broken.
print_next_steps() {
  local missing steps=() line
  missing="$(tools_missing_path)"
  [ -n "$missing" ] && \
    # The trailing "-" is not decoration: GNU paste defaults to stdin, BSD paste
    # requires a file operand and prints its usage without one.
    steps+=("export PATH=\"$(printf '%s' "$missing" | paste -sd: -):\$PATH\"")

  if [ "$INSTALL_TOOLS" = 1 ] && needs_tailscale_up; then
    if is_mac; then
      # The brew formula ships a launchd service rather than a systemd unit, and
      # it is not started for you -- `tailscale up` against a daemon that was
      # never launched just times out.
      steps+=("sudo brew services start tailscale")
      steps+=("tailscale up")
    elif [ "$PRIV_MODE" = none ]; then
      # No root, so no systemd unit: the daemon has to be run by hand, in
      # userspace-networking mode and against a socket under $HOME.
      steps+=("mkdir -p ~/.tailscale")
      steps+=("tailscaled --tun=userspace-networking --socket=~/.tailscale/tailscaled.sock --statedir=~/.tailscale &")
      steps+=("tailscale --socket=~/.tailscale/tailscaled.sock up")
    else
      steps+=("sudo tailscale up")
    fi
  fi

  # Last, because it is what makes the shell you are in match the one every new
  # shell will be: PATH, aliases, the prompt. Named for the shell this machine
  # actually logs into -- on a Mac that is ~/.zshrc, and "source ~/.bashrc"
  # there does precisely nothing.
  #
  # ...unless the login shell is neither of the two, in which case `source` is
  # the wrong instruction entirely: fish, csh and ksh all have their own syntax
  # and none of them can read a bash rc -- pasted into fish, "source ~/.bashrc"
  # is a screenful of parse errors. The install is fine and the NOTE further up
  # already says so; what is needed here is a shell that CAN read what was
  # written, so the step is to start one.
  case "$LOGIN_SHELL" in
    bash|zsh|sh) steps+=("source $LOGIN_RC") ;;
    *)           steps+=("$SHELL_FOR_RC -l   # $LOGIN_SHELL cannot read $(tilde "$LOGIN_RC")") ;;
  esac

  echo ""
  echo "Copy and paste this to finish:"
  echo ""
  for line in "${steps[@]}"; do printf '    %s\n' "$line"; done
  echo ""
  if [ "$HSL_LOGIN" = 1 ]; then
    echo "  (that last line will start herdr, since hsl-at-login is on --"
    echo "   'NO_HSL=1 source $LOGIN_RC' if you would rather it did not)"
    echo ""
  fi
}

# Before the rendering below, not after: `herdr plugin install` creates each
# plugin's config directory and drops the plugin's own defaults in it, and the
# link() calls further down are supposed to take those paths over (backing the
# defaults up as .bak). Installing second would mean the plugin unpacked its
# config on top of our symlink.
echo ""
if [ "$INSTALL_TOOLS" = 1 ]; then
  # TOOLS_CAN_PROMPT was settled up by the wizard, so sudo_unlock() already
  # knows whether there is a terminal to ask a password on.
  install_tools
else
  echo "Skipping the tools phase (--no-tools)."
fi

if [ "$TOOLS_ONLY" -eq 1 ]; then
  echo ""
  echo "--tools-only: no config was rendered or linked."
  print_next_steps
  exit 0
fi
echo ""

# --- plumbing -----------------------------------------------------------------
# Where to put the real file currently sitting at $1, WITHOUT ever writing over
# a backup that is already there. The first .bak is the important one -- it is
# this machine's own original file, from before any of this ran, and it is the
# one reset.sh puts back -- so it is never reused. Anything found at the same
# path later (somebody replaced our symlink with a file of their own, then
# re-ran install.sh) gets a numbered name of its own instead of taking its
# place. Backups are only ever created here, never overwritten and never
# removed; reset.sh is the only thing that consumes one.
backup_name() {
  local dst="$1" n=2
  if [ ! -e "$dst.bak" ] && [ ! -L "$dst.bak" ]; then printf '%s' "$dst.bak"; return 0; fi
  while [ -e "$dst.bak.$n" ] || [ -L "$dst.bak.$n" ]; do n=$((n + 1)); done
  printf '%s' "$dst.bak.$n"
}

link() {
  local src="$1" dst="$2" bak
  mkdir -p "$(dirname "$dst")"
  # Only a real (non-symlink) file gets backed up: on a second run dst is
  # already our own symlink, so our rendered output is never mistaken for
  # something worth keeping.
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    bak="$(backup_name "$dst")"
    mv "$dst" "$bak"
    echo "Backed up existing $dst -> $bak"
  fi
  ln -sfn "$src" "$dst"
  echo "Linked $dst -> $src"
  MANAGED+=("$dst")
}

is_already_managed() {
  printf '%s\n' "$OLD_MANAGED" | grep -qxF "$1"
}

# copy() is for plain files (bin/) rather than rendered/symlinked config: same
# backup-before-overwrite courtesy as link(), but since a copy leaves no marker
# of its own (unlike a symlink), "already ours" is decided from last run's
# manifest instead of [ ! -L "$dst" ]. `cmp` is the fallback for a missing or
# stale manifest: a destination that is byte-for-byte the file we are about to
# write is our own previous copy, and backing that up would be filing away a
# copy of ourselves.
copy() {
  local src="$1" dst="$2" bak
  mkdir -p "$(dirname "$dst")"
  if [ -e "$dst" ] && ! is_already_managed "$dst" && ! cmp -s "$src" "$dst"; then
    bak="$(backup_name "$dst")"
    cp -f "$dst" "$bak"
    echo "Backed up existing $dst -> $bak"
  fi
  cp -f "$src" "$dst"
  chmod +x "$dst"
  echo "Copied $dst -> $src"
  MANAGED+=("$dst")
}

# render <template> <path-under-.generated> [comment-prefix]
# Strips #>> template-only lines, substitutes the placeholders, and stamps a
# "generated" header when the file's format has line comments (JSON has none).
RENDERED=()
render() {
  local src="$DOTFILES/$1" rel="$2" cmt="${3-}" out="$GENERATED/$2"
  mkdir -p "$(dirname "$out")"
  RENDERED+=("$rel")
  {
    if [ -n "$cmt" ]; then
      echo "$cmt GENERATED by dotfiles/install.sh from $1 -- do not edit."
      echo "$cmt Edit the template in the dotfiles repo, then re-run ./install.sh."
    fi
    # Delimiter is | , not the usual / or # : the colour values themselves start
    # with # and HERDR_CONFIG is a path full of /. None of the six values can
    # contain a pipe (colours are validated hex, the machine name is validated
    # against [A-Za-z0-9._-], and a path with a pipe would break far more than
    # this). The longer _DIM / _LOWER names are substituted first: the trailing @
    # already stops @PRIMARY@ from matching inside @PRIMARY_DIM@, but keeping the
    # specific-before-general order means a future placeholder without that guard
    # cannot be quietly half-substituted.
    sed -e '/^#>>/d' \
        -e "s|@PRIMARY_DIM@|$PRIMARY_DIM|g" \
        -e "s|@PRIMARY@|$PRIMARY|g" \
        -e "s|@SECONDARY@|$SECONDARY|g" \
        -e "s|@MACHINE_LOWER@|$MACHINE_LOWER|g" \
        -e "s|@USER@|$USER_NAME|g" \
        -e "s|@MACHINE@|$MACHINE|g" \
        -e "s|@HERDR_CONFIG@|$HERDR_CONFIG|g" \
        -e "s|@SHOW_TEMP@|$SHOW_TEMP|g" \
        -e "s|@HSL_LOGIN@|$HSL_LOGIN|g" \
        -e "s|@OMP_ICON_COLOR_JOB@|$OMP_ICON_COLOR_JOB|g" \
        -e "s|@OMP_ICON_COLOR@|$OMP_ICON_COLOR|g" \
        -e "s|@OMP_TEXT_COLOR@|$OMP_TEXT_COLOR|g" \
        -e "s|@OMP_CHEVRON_FG@|$OMP_CHEVRON_FG|g" \
        -e "s|@OMP_CHEVRON_ERR@|$OMP_CHEVRON_ERR|g" \
        -e "s|@CLAUDE_MODEL_RGB@|$CLAUDE_MODEL_RGB|g" \
        -e "s|@CLAUDE_EFFORT_RGB@|$CLAUDE_EFFORT_RGB|g" \
        -e "s|@CLAUDE_USAGE_RGB@|$CLAUDE_USAGE_RGB|g" \
        -e "s|@CLAUDE_WEEK_RGB@|$CLAUDE_WEEK_RGB|g" \
        -e "s|@CLAUDE_CTX_RGB@|$CLAUDE_CTX_RGB|g" \
        -e "s|@TMUX_STATUS_LEFT@|$TMUX_STATUS_LEFT|g" \
        -e "s|@TMUX_STATUS_RIGHT@|$TMUX_STATUS_RIGHT|g" \
        -e "s|@HSL_STATUS_LEFT@|$HSL_STATUS_LEFT|g" \
        -e "s|@HSL_STATUS_RIGHT@|$HSL_STATUS_RIGHT|g" \
        "$src"
  } > "$out"
  echo "Rendered $out"
}

# A shebang must stay on line 1, so scripts get their header after it instead.
#
# Spliced with head/tail rather than `sed -i "1a ..."`, which is GNU twice over:
# BSD sed's -i takes a mandatory backup suffix (so -i "1a..." would treat the
# script as the suffix and the filename as the program), and its `a` command
# wants a backslash and a real newline before the text.
render_script() {
  render "$1" "$2"
  local out="$GENERATED/$2" tmp="$GENERATED/$2.tmp"
  {
    head -n 1 "$out"
    echo "# GENERATED by dotfiles/install.sh from $1 -- do not edit; edit the template."
    tail -n +2 "$out"
  } > "$tmp"
  mv "$tmp" "$out"
  chmod +x "$out"
}

# Renders overwrite in place rather than wiping .generated/ first, so a failure
# part-way through can never leave the live symlinks dangling. Anything stale (a
# template that got renamed) is pruned at the very end, once every link is set.

# --- tmux ---
render        tmux/.tmux.conf.in        tmux/.tmux.conf '#'
render_script tmux/other-sessions.sh.in tmux/other-sessions.sh
render_script tmux/slurm-status.sh.in   tmux/slurm-status.sh
link "$GENERATED/tmux/.tmux.conf"        "$HOME/.tmux.conf"
link "$GENERATED/tmux/other-sessions.sh" "$HOME/.tmux/other-sessions.sh"
link "$GENERATED/tmux/slurm-status.sh"   "$HOME/.tmux/slurm-status.sh"

# --- claude ---
link "$DOTFILES/claude/settings.json"        "$HOME/.claude/settings.json"
link "$DOTFILES/claude/keybindings.json"     "$HOME/.claude/keybindings.json"
# The status line is templated now: its five bubbles are the primary->secondary
# ramp, so it is themed like everything else rather than carrying a palette of
# its own.
render_script claude/statusline-command.sh.in claude/statusline-command.sh
link "$GENERATED/claude/statusline-command.sh" "$HOME/.claude/statusline-command.sh"
# Themes are templated (JSON, so no generated-header comment is possible).
for f in "$DOTFILES"/claude/themes/*.json.in; do
  b="$(basename "$f" .in)"
  render "claude/themes/$(basename "$f")" "claude/themes/$b"
  link "$GENERATED/claude/themes/$b" "$HOME/.claude/themes/$b"
done
# Any theme that is not templated is still symlinked straight from the repo.
for f in "$DOTFILES"/claude/themes/*.json; do
  [ -e "$f" ] || continue
  link "$f" "$HOME/.claude/themes/$(basename "$f")"
done

# --- herdr ---
# Only hand-written config is synced. plugins.json, plugins/github/ (the plugin
# clone + its build output), session.json, the sockets and the logs are all
# machine-local state that herdr regenerates, so they stay out of the repo.
render herdr/config.toml.in herdr/config.toml '#'
link "$GENERATED/herdr/config.toml" "$HERDR_CONFIG/config.toml"

FV_REL="herdr/plugins/herdr-file-viewer"
FV_CONFIG="$HERDR_CONFIG/plugins/config/herdr-file-viewer"
link "$DOTFILES/$FV_REL/markdown-monokai.json" "$FV_CONFIG/markdown-monokai.json"
# The glow style path inside this one has to be absolute -- the plugin runs
# renderer commands without a shell, so neither ~ nor $HOME ever expands.
render "$FV_REL/config.toml.in" "$FV_REL/config.toml" '#'
link "$GENERATED/$FV_REL/config.toml" "$FV_CONFIG/config.toml"

# herdr-statusline reproduces the tmux status line around a herdr session, so it
# is themed from the same two colours and the same machine name.
HSL_REL="herdr/plugins/herdr-statusline"
HSL_CONFIG="$HERDR_CONFIG/plugins/config/herdr-statusline"
render "$HSL_REL/config.toml.in" "$HSL_REL/config.toml" '#'
link "$GENERATED/$HSL_REL/config.toml" "$HSL_CONFIG/config.toml"
# The bar's right half IS the tmux bar's right half: the same rendered script,
# linked a second time, so the two can never drift. The plugin only exports
# $HERDR_PLUGIN_CONFIG_DIR to its `#(...)` commands, hence the link lives here
# rather than the config pointing at ~/.tmux/.
link "$GENERATED/tmux/slurm-status.sh" "$HSL_CONFIG/slurm-status.sh"
# The GPU pill lives under the plugin's own template dir (it needs @SHOW_TEMP@,
# which no tmux template needs), then gets linked a second time into ~/.tmux/ --
# same reasoning as slurm-status.sh above, so tmux and herdr-statusline can never
# show a different GPU reading. It no-ops on a machine with no nvidia-smi (e.g.
# a login node), so linking it unconditionally is harmless even with SHOW_GPU=0
# in the tmux/herdr status strings, which just never invoke it.
render_script "$HSL_REL/gpu-status.sh.in" "$HSL_REL/gpu-status.sh"
link "$GENERATED/$HSL_REL/gpu-status.sh" "$HSL_CONFIG/gpu-status.sh"
link "$GENERATED/$HSL_REL/gpu-status.sh" "$HOME/.tmux/gpu-status.sh"

# herdr-workspace-prefix is OURS (it lives in this repo, unlike the third-party
# plugins), so it is linked here rather than left to a per-machine step. `plugin
# link` is idempotent, and a missing herdr just means this machine has none yet.
if command -v herdr >/dev/null 2>&1; then
  if herdr plugin link "$DOTFILES/herdr/plugins/herdr-workspace-prefix" >/dev/null 2>&1; then
    echo "Linked herdr plugin herdr-workspace-prefix"
  else
    echo "NOTE: could not link herdr-workspace-prefix (is the herdr server running?)"
  fi
fi

# --- oh-my-posh ---
render oh-my-posh/albe-monokai2.omp.json.in oh-my-posh/albe-monokai2.omp.json
link "$GENERATED/oh-my-posh/albe-monokai2.omp.json" \
     "$HOME/.cache/oh-my-posh/themes/albe-monokai2.omp.json"

# --- local bin ---
# Plain copies, not symlinks/renders: these are prebuilt binaries/scripts, not
# something a template could parameterise, and a copy still works if the repo
# checkout later moves or is removed.
mkdir -p "$HOME/.local/bin"
if [ -d "$DOTFILES/bin" ]; then
  for f in "$DOTFILES"/bin/*; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    [ "$b" = ".gitkeep" ] && continue
    copy "$f" "$HOME/.local/bin/$b"
  done
fi

# Which checkout the copies above came from. bin/dotfiles is the CLI wrapper
# around this script, reset.sh and lib/tools.sh, and being a plain copy is what
# lets it outlive the checkout (that is the whole point for `dotfiles purge`) --
# but it also means it carries no @PLACEHOLDER@ it could have been told the path
# through. So the path is written beside it instead, and find_checkout() there
# reads it. Written here rather than with the manifest so the pointer and the CLI
# always land together; refreshed every run, so moving the checkout and re-running
# is all it takes to re-point it. State, like the manifest, so it is not in
# MANAGED -- reset.sh removes it explicitly.
CHECKOUT_POINTER="$XDG_CONFIG/dotfiles/checkout"
mkdir -p "$(dirname "$CHECKOUT_POINTER")"
printf '%s\n' "$DOTFILES" > "$CHECKOUT_POINTER"

# --- shell ---
# Sourced by shellrc_additions.sh at the very end. Rendered rather than
# symlinked straight out of the repo because it carries the answer (@HSL_LOGIN@)
# -- with it baked in, an "off" answer is a file that returns immediately
# instead of one that re-decides on every single shell start.
render_script shell/hsl-login.sh.in shell/hsl-login.sh
link "$GENERATED/shell/hsl-login.sh" "$XDG_CONFIG/dotfiles/hsl-login.sh"
link "$DOTFILES/shell/bashrc_functions" "$HOME/.bashrc_functions"
link "$DOTFILES/shell/profile"          "$HOME/.profile"

# One line in one rc file is the whole hook: everything else hangs off
# shell/shellrc_additions.sh, which bash and zsh both read (it branches on which
# of the two is running it). The block is marked at both ends so it can be found
# again -- to refresh it, and for reset.sh to take it back out.
RC_MARKER="# >>> dotfiles shell additions >>>"
RC_MARKER_END="# <<< dotfiles shell additions <<<"
# What those markers said while this was bash-only, and while the file was
# called bashrc_additions.sh. A machine set up before then has that block in its
# ~/.bashrc pointing at a path that no longer exists, so it is replaced rather
# than left to break every new shell there.
RC_MARKER_OLD="# >>> dotfiles bashrc_additions >>>"
RC_MARKER_OLD_END="# <<< dotfiles bashrc_additions <<<"

# Delete a marked block from a file, in place. Filtered to a temp file and
# copied back rather than `sed -i`, which is GNU-only -- BSD sed takes a
# MANDATORY backup suffix after -i and would read the range as that suffix.
# Copying the CONTENT back (rather than mv) also keeps the original inode, which
# matters because ~/.bashrc may be a symlink or have permissions somebody chose.
rc_strip_block() {
  local file="$1" start="$2" end="$3" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/dotfiles-rc.XXXXXX")"
  if sed "/^${start}\$/,/^${end}\$/d" "$file" > "$tmp"; then
    cat "$tmp" > "$file"
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# rc_wire FILE -- make FILE source the additions, exactly once.
rc_wire() {
  local file="$1" want="source \"$DOTFILES/shell/shellrc_additions.sh\""
  if [ ! -e "$file" ]; then
    echo "Creating $file (this machine had none)"
  elif grep -qF "$RC_MARKER_OLD" "$file" 2>/dev/null; then
    rc_strip_block "$file" "$RC_MARKER_OLD" "$RC_MARKER_OLD_END" \
      && echo "Replaced the old bashrc_additions block in $file"
  fi
  if grep -qF "$RC_MARKER" "$file" 2>/dev/null; then
    if grep -qF "$want" "$file" 2>/dev/null; then
      echo "$file already sources the dotfiles additions, skipping"
      return 0
    fi
    # Our block, pointing somewhere else: the checkout moved. Rewritten rather
    # than appended to, or the shell would end up sourcing two of them (one of
    # which is gone).
    rc_strip_block "$file" "$RC_MARKER" "$RC_MARKER_END" \
      && echo "The dotfiles block in $file pointed elsewhere; rewriting it"
  fi
  {
    echo ""
    echo "$RC_MARKER"
    echo "$want"
    echo "$RC_MARKER_END"
  } >> "$file"
  echo "Appended the dotfiles source line to $file"
}

[ "$WIRE_BASH" -eq 1 ] && rc_wire "$HOME/.bashrc"
# zsh never reads ~/.bashrc or ~/.profile, so it needs its own line. ~/.zshrc is
# enough on its own: zsh reads it for every INTERACTIVE shell, login or not
# (unlike bash, which splits that between ~/.bashrc and ~/.profile), and a
# non-interactive zsh has no use for a prompt or key bindings anyway. Creating
# the file when it is absent is safe here, unlike ~/.bash_profile below --
# there is no other zsh startup file it could shadow.
[ "$WIRE_ZSH" -eq 1 ] && rc_wire "$HOME/.zshrc"

# A bash LOGIN shell reads the FIRST of ~/.bash_profile, ~/.bash_login,
# ~/.profile that exists and stops there. This repo symlinks ~/.profile (which
# sources ~/.bashrc), so on a machine that already has a ~/.bash_profile none of
# the above is ever read and the whole install looks like it did nothing.
#
# That is mostly a macOS problem, because Terminal.app opens a LOGIN shell for
# every window -- on Linux the terminal usually starts an interactive non-login
# shell, which reads ~/.bashrc directly -- but the trap is the same on both, so
# the fix is not conditioned on the platform.
#
# Only ever appended to a ~/.bash_profile that ALREADY EXISTS: creating one
# would take the symlinked ~/.profile out of the chain rather than put it in.
#
# zsh needs no equivalent: it reads ~/.zshenv, ~/.zprofile, ~/.zshrc and
# ~/.zlogin in turn and none of them shadows another, so wiring ~/.zshrc above
# is the whole job there.
PROFILE_MARKER="# >>> dotfiles bash_profile >>>"
if [ "$WIRE_BASH" -eq 1 ] && [ -f "$HOME/.bash_profile" ]; then
  if grep -qF "$PROFILE_MARKER" "$HOME/.bash_profile" 2>/dev/null; then
    echo "~/.bash_profile already chains to ~/.bashrc, skipping"
  elif grep -qE '(^|[^-[:alnum:]_])~?/?\.?bashrc' "$HOME/.bash_profile" 2>/dev/null; then
    echo "~/.bash_profile already mentions .bashrc, leaving it alone"
  else
    {
      echo ""
      echo "$PROFILE_MARKER"
      echo "# bash reads this file INSTEAD of ~/.profile for a login shell, so the"
      echo "# dotfiles additions have to be picked up from here as well."
      echo '[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"'
      echo "# <<< dotfiles bash_profile <<<"
    } >> "$HOME/.bash_profile"
    echo "Appended a ~/.bashrc source line to ~/.bash_profile (it shadows ~/.profile)"
  fi
fi

# --- prune ---
# Drop anything left in .generated/ by a template that has since been renamed or
# removed. Done last, so every live symlink already points at a fresh render.
if [ -d "$GENERATED" ]; then
  while IFS= read -r -d '' f; do
    rel="${f#"$GENERATED"/}"
    keep=0
    for r in "${RENDERED[@]}"; do [ "$r" = "$rel" ] && { keep=1; break; }; done
    [ "$keep" -eq 1 ] || { rm -f "$f"; echo "Pruned stale $rel"; }
  done < <(find "$GENERATED" -type f -print0)
  find "$GENERATED" -mindepth 1 -type d -empty -delete 2>/dev/null || true
fi

# --- manifest -------------------------------------------------------------
# Every dst that link()/copy() touched this run, so ./reset.sh knows exactly
# what to undo. Written fresh each run rather than appended, since MANAGED
# already reflects the complete current set of managed paths -- a stale entry
# left over from a removed template would otherwise linger forever.
mkdir -p "$(dirname "$MANIFEST")"
printf '%s\n' "${MANAGED[@]}" | sort -u > "$MANIFEST"

echo ""
echo "Done. Notes:"
echo "  - 'dotfiles' is now on PATH (~/.local/bin/dotfiles) and wraps all of this from"
echo "    anywhere: 'dotfiles reconfigure', 'dotfiles update', 'dotfiles backups',"
echo "    'dotfiles uninstall', 'dotfiles purge' (that last one deletes the checkout"
echo "    too, after restoring the backups). 'dotfiles help' lists the lot."
echo "  - Re-run './install.sh' any time after editing a *.in template; it reuses the"
echo "    saved answers, so it re-renders without prompting. './install.sh --reconfigure'"
echo "    changes the colours or machine name."
echo "  - './reset.sh' undoes this: removes every symlink/copy install.sh made and"
echo "    restores whatever real file was there before (from the .bak it saved)."
echo "  - conda init and any gcloud SDK sourcing are NOT included (machine-specific paths) — re-run"
echo "    'conda init bash' / the gcloud installer on this machine if needed."
echo "  - Workspace aliases (cluster-specific /anvme paths etc.) are intentionally excluded;"
echo "    keep those per-machine or in a separate per-project config."
echo "  - herdr: 'herdr server reload-config' picks up a config change without restarting."
echo "    The file viewer's Monokai content pane needs bat, delta and glow on PATH; the"
echo "    tools phase installs all three, and without them the viewer falls back to plain text."
echo "  - Tools are installed by whichever route this machine can use (apt with sudo;"
echo "    rustup/cargo, uv, release tarballs, git or Homebrew without). './install.sh"
echo "    --reconfigure' lets you deselect any of them; 'bash lib/tools.sh --plan' shows"
echo "    what a run would do without doing it."
if [ "$HSL_LOGIN" = 1 ]; then
  if command -v hsl >/dev/null 2>&1; then
    echo "  - hsl (herdr + the status line) will start at every interactive login."
    echo "    'NO_HSL=1 $HSL_ESCAPE_SHELL -l' gets you a plain shell; quitting herdr drops you"
    echo "    into one too (it is run, not exec'd, so a login can't be lost to it)."
  elif command -v herdr >/dev/null 2>&1; then
    # hsl ships with herdr-statusline, whose manifest is platforms = ["linux"],
    # so on a Mac it is never there. The autostart falls back to plain herdr
    # rather than doing nothing -- see shell/hsl-login.sh.in.
    echo "  - herdr will start at every interactive login. ('hsl' -- herdr plus the"
    if is_mac; then
      echo "    status line -- is Linux-only, so this machine gets herdr on its own.)"
    else
      echo "    status line -- is not on PATH here, so it is plain herdr for now.)"
    fi
    echo "    'NO_HSL=1 $HSL_ESCAPE_SHELL -l' gets you a plain shell; quitting herdr drops you"
    echo "    into one too (it is run, not exec'd, so a login can't be lost to it)."
  else
    echo "  - NOTE: the login autostart is on, but neither 'hsl' nor 'herdr' is on"
    echo "    PATH. Until one of them is installed the autostart just no-ops, so"
    echo "    your logins are unaffected either way."
  fi
fi
print_next_steps
