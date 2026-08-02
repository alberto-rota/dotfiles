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
  local sys=apt; is_mac && sys=Homebrew
  case "$PRIV_MODE" in
    # Kept under 40 cells: both front-ends show this as a hint, the UI's in a
    # 41-cell panel and the wizard's on whatever terminal you have. "Homebrew"
    # is three cells longer than "apt" and still fits.
    root)         echo "root -- system packages available" ;;
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
  "git|git|providers"
  "rust|Rust toolchain (cargo)|providers"
  "ohmyposh|oh-my-posh|shell"
  "jq|jq (JSON)|shell"
  "zoxide|zoxide (smarter cd)|shell"
  "eza|eza (ls)|shell"
  "fzf|fzf (fuzzy finder)|shell"
  "fd|fd (find)|shell"
  "bat|bat (cat)|shell"
  "delta|delta (git pager)|shell"
  "glow|glow (markdown)|shell"
  "nvtop|nvtop (GPU monitor)|gpu"
  "neovim|Neovim|editor"
  "lazyvim|LazyVim starter|editor"
  "gdown|gdown|python"
  "groundcontrol|ground-control-tui|python"
  "nvitop|nvitop|gpu"
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
tool_deps() {
  case "$1" in
    lazyvim) echo "neovim git" ;;
    herdr_statusline|herdr_file_viewer) echo "herdr" ;;
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

# Where Homebrew lives, per platform. Checked as a path rather than with
# `have brew` because a machine very often HAS brew and has simply never put it
# on PATH -- nothing does that until a shell sources its shellenv, which on this
# setup is bashrc_additions.sh, i.e. later than any of this. Missing that would
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

herdr_has_plugin() {
  have herdr || return 1
  herdr plugin list 2>/dev/null | grep -q "^- $1 "
}

tool_present() {
  case "$1" in
    git)           have_git ;;
    tailscale)     have tailscale ;;
    rust)          have cargo ;;
    brew)          have brew || brew_prefix >/dev/null 2>&1 ;;
    ohmyposh)      have oh-my-posh ;;
    jq)            have jq ;;
    zoxide)        have zoxide ;;
    eza)           have eza ;;
    fzf)           have fzf ;;
    fd)            have fd || have fdfind ;;
    bat)           have bat || have batcat ;;
    delta)         have delta ;;
    glow)          have glow ;;
    nvtop)         have nvtop ;;
    neovim)        have nvim ;;
    # The starter drops an init.lua in; anything else already there is somebody
    # else's config and install_lazyvim() will refuse to touch it.
    lazyvim)       [ -e "$LAZYVIM_DIR/init.lua" ] ;;
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
AVAIL_APT=0 AVAIL_CARGO=0 AVAIL_UV=0 AVAIL_BREW=0 AVAIL_GIT=0

providers_init() {
  AVAIL_APT=0; priv_available && have apt-get && AVAIL_APT=1
  AVAIL_CARGO=0; have cargo && AVAIL_CARGO=1
  AVAIL_UV=0;    have uv    && AVAIL_UV=1
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
}

# "the walk has just got past a provider": everything after it may count on it.
# One place rather than three identical case statements, since forgetting one is
# how a plan starts disagreeing with the run it is supposed to be describing.
providers_seen() {
  case "$1" in
    rust) AVAIL_CARGO=1 ;;
    brew) AVAIL_BREW=1 ;;
    git)  AVAIL_GIT=1 ;;
  esac
}

# cargo either is here, or rust is selected and about to put it here.
cargo_coming() {
  [ "$AVAIL_CARGO" = 1 ] && return 0
  tool_selected rust
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
  if is_mac; then
    # There is no apt to fall back to here, so brew is the system route and
    # these two have no other one at all: git ships with the Xcode Command Line
    # Tools (which Homebrew's own installer pulls in) and Tailscale publishes no
    # darwin tarball.
    for id in git tailscale; do
      if tool_selected "$id" && ! tool_present "$id"; then return 0; fi
    done
  else
    # nvtop is the sharp case on Linux: no cargo crate, no useful release
    # tarball. On macOS it is not a case at all -- see tool_route.
    if tool_selected nvtop && ! tool_present nvtop; then return 0; fi
  fi
  if ! cargo_coming; then
    for id in eza fd bat delta; do
      if tool_selected "$id" && ! tool_present "$id"; then return 0; fi
    done
  fi
  return 1
}

# --- route resolution -----------------------------------------------------
# One decision point, used by both --plan and install_tools(). Prints
# "method|detail". An empty method means there is no route on this machine; the
# method "na" means there is nothing to do here and never was (nvtop on a Mac,
# Homebrew on a machine that needs nothing from it), which both callers report
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
              elif is_mac; then echo "|needs Homebrew, or: xcode-select --install"
              else echo "|needs apt or an existing Homebrew"; fi ;;
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
    ohmyposh) echo "binary|oh-my-posh release -> ~/.local/bin" ;;
    jq)       if [ "$AVAIL_APT" = 1 ]; then echo "apt|jq"
              else echo "binary|jqlang/jq -> ~/.local/bin"; fi ;;
    herdr)    echo "script|herdr.dev -> ~/.local/bin" ;;
    zoxide)   if [ "$AVAIL_APT" = 1 ]; then echo "apt|zoxide"
              else echo "script|zoxide install.sh -> ~/.local/bin"; fi ;;
    fzf)      if [ "$AVAIL_GIT" = 1 ]; then echo "git|~/.fzf (--no-update-rc)"
              elif [ "$AVAIL_APT" = 1 ]; then echo "apt|fzf"
              else echo "|needs git or apt"; fi ;;
    eza)      _route_system_or_cargo eza eza ;;
    fd)       _route_system_or_cargo fd-find fd-find ;;
    bat)      _route_system_or_cargo bat bat ;;
    delta)    _route_system_or_cargo git-delta git-delta ;;
    glow)     echo "tarball|charmbracelet/glow -> ~/.local/bin" ;;
    # No NVIDIA GPU has ever been attached to a Mac that runs this, there is no
    # nvtop formula for darwin, and nvidia-smi is what the tool wraps.
    nvtop)    if is_mac; then echo "na|no NVIDIA GPUs on macOS"
              elif [ "$AVAIL_APT" = 1 ]; then echo "apt|nvtop"
              elif [ "$AVAIL_BREW" = 1 ] || brew_needed; then echo "brew|nvtop"
              else echo "|needs apt or Homebrew"; fi ;;
    # apt's neovim is 0.9.5 on 24.04, which LazyVim will start on and then warn
    # about forever. The official tarball is current, needs no privilege, and
    # lands where bashrc_additions.sh already puts ~/.local/nvim/bin on PATH.
    neovim)   echo "tarball|neovim stable -> ~/.local/nvim" ;;
    lazyvim)  if [ "$AVAIL_GIT" = 1 ]; then echo "git|LazyVim/starter -> $LAZYVIM_DIR"
              else echo "|needs git"; fi ;;
    gdown|groundcontrol|nvitop)
              if [ "$AVAIL_UV" = 1 ]; then echo "uv|uv tool install $(_pypi_name "$1")"
              else echo "|needs uv"; fi ;;
    herdr_statusline)  echo "plugin|iiii1224/herdr-statusline" ;;
    herdr_file_viewer) echo "plugin|smarzban/herdr-file-viewer" ;;
    *) echo "|unknown tool" ;;
  esac
}

# The system package manager when we may use it, else cargo (which rust puts
# there), else Homebrew. On macOS the first and last of those are the same
# thing, so brew simply moves to the front: a bottle is seconds where the same
# crate is minutes of compiling.
_route_system_or_cargo() {
  local apt_pkg="$1" crate="$2" formula="${1%-find}"
  if is_mac; then
    if [ "$AVAIL_BREW" = 1 ]; then echo "brew|$formula"
    elif [ "$AVAIL_CARGO" = 1 ]; then echo "cargo|$crate"
    elif brew_needed; then echo "brew|$formula"
    else echo "|needs cargo or Homebrew"; fi
    return
  fi
  if [ "$AVAIL_APT" = 1 ]; then echo "apt|$apt_pkg"
  elif [ "$AVAIL_CARGO" = 1 ]; then echo "cargo|$crate"
  elif [ "$AVAIL_BREW" = 1 ] || brew_needed; then echo "brew|$formula"
  else echo "|needs apt, cargo or Homebrew"; fi
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

cargo_install() { cargo install --locked --quiet "$@"; }

# uv drops the tool's executables in ~/.local/bin (bashrc_additions.sh already
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

# --- the installers -------------------------------------------------------
# One per tool, each free to do whatever that tool needs. They return non-zero
# on failure and the orchestrator records it; nothing here is ever fatal.

install_git() {
  local route; route="$(tool_route git)"
  case "${route%%|*}" in
    apt)  apt_install git ;;
    brew) brew_install git ;;
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

install_rust() {
  have rustup && { rustup update --no-self-update >/dev/null 2>&1 || true; }
  if ! have rustup; then
    # --no-modify-path for the same reason uv gets it in install.sh: left alone
    # rustup appends to ~/.profile, which on an already-installed machine is a
    # SYMLINK INTO THIS REPO. bashrc_additions.sh already exports ~/.cargo/bin.
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
    # and rustup. It still writes ~/.fzf.bash, which bashrc_additions.sh
    # already sources, and that file is what puts ~/.fzf/bin on PATH.
    "$HOME/.fzf/install" --all --no-update-rc >/dev/null 2>&1 || return 1
    note_path "$HOME/.fzf/bin"
    return 0
  fi
  apt_install fzf
}

# eza / fd / bat / delta all share the apt-or-cargo-or-brew shape.
_install_via_route() {
  local id="$1" route method detail
  route="$(tool_route "$id")"; method="${route%%|*}"; detail="${route#*|}"
  case "$method" in
    apt)   apt_install "$detail" ;;
    cargo) cargo_install "$detail" && note_path "$HOME/.cargo/bin" ;;
    brew)  brew_install "$detail" ;;
    *)     return 1 ;;
  esac
}

install_eza()   { _install_via_route eza; }
install_fd()    { _install_via_route fd; }
install_bat()   { _install_via_route bat; }
install_delta() { _install_via_route delta; }

install_glow() {
  local url os="[Ll]inux"
  is_mac && os="[Dd]arwin"
  url="$(github_latest_asset charmbracelet/glow "$os.*$(arch_tag).*\.tar\.gz")"
  [ -n "$url" ] || return 1
  fetch_bin_from_tarball "$url" glow
}

install_nvtop() {
  local route; route="$(tool_route nvtop)"
  case "${route%%|*}" in
    apt)  apt_install nvtop ;;
    brew) brew_install nvtop ;;
    *)    return 1 ;;
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

install_gdown()         { uv_install gdown; }
install_groundcontrol() { uv_install ground-control-tui; }
install_nvitop()        { uv_install nvitop; }

_install_herdr_plugin() {
  have herdr || return 1
  herdr plugin install "$1" -y >/dev/null 2>&1
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
    # needs it, nvtop on a Mac) rather than a machine that fell short.
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
# generated fragment that bashrc_additions.sh sources on every shell. Most of
# these dirs are already exported there; this is what covers the ones that are
# not (Homebrew's prefix above all, which moves per machine).
tools_write_env() {
  local file="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/tools-env.sh" dir
  mkdir -p "$(dirname "$file")"
  {
    echo "# GENERATED by dotfiles/install.sh -- PATH for the tools it installed."
    echo "# Sourced from shell/bashrc_additions.sh. Rewritten on every run."
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
