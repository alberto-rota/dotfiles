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
# can actually use. The system route (apt) is only ever reachable with root or
# sudo; every other route (rustup/cargo, uv, a release tarball, a git clone,
# Homebrew) lands entirely inside $HOME and needs no privilege at all. That is
# the whole of the sudo/no-sudo split -- there is no second, parallel
# "unprivileged installer", just a route list whose first entry drops out.
#
# apt is the only system package manager wired up. On a dnf/pacman box the
# system route is simply unavailable and everything falls through to the
# userland routes, which are OS-independent -- which is also exactly what
# happens on an HPC login node, the case that actually matters here.

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
  case "$PRIV_MODE" in
    # Kept under 40 cells: both front-ends show this as a hint, the UI's in a
    # 41-cell panel and the wizard's on whatever terminal you have.
    root)         echo "root -- system packages available" ;;
    passwordless) echo "passwordless sudo -- apt available" ;;
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
# Order IS the install order: a tool may only depend on one listed above it.
# rust and brew come first because they are providers as well as tools; the
# herdr plugins come last because they need herdr, and the file viewer wants
# bat/delta/glow to render with.
TOOL_IDS=(
  rust brew
  ohmyposh zoxide eza fzf fd bat delta glow nvtop
  neovim lazyvim
  gdown groundcontrol nvitop
  herdr herdr_statusline herdr_file_viewer
)

declare -A TOOL_LABEL=(
  [rust]="Rust toolchain (cargo)"   [brew]="Homebrew (if needed)"
  [ohmyposh]="oh-my-posh"           [zoxide]="zoxide (smarter cd)"
  [eza]="eza (ls)"                  [fzf]="fzf (fuzzy finder)"
  [fd]="fd (find)"                  [bat]="bat (cat)"
  [delta]="delta (git pager)"       [glow]="glow (markdown)"
  [nvtop]="nvtop (GPU monitor)"     [neovim]="Neovim"
  [lazyvim]="LazyVim starter"       [gdown]="gdown"
  [groundcontrol]="ground-control-tui" [nvitop]="nvitop"
  [herdr]="herdr"                   [herdr_statusline]="herdr-statusline plugin"
  [herdr_file_viewer]="herdr-file-viewer plugin"
)

declare -A TOOL_GROUP=(
  [rust]=providers [brew]=providers
  [ohmyposh]=shell [zoxide]=shell [eza]=shell [fzf]=shell
  [fd]=shell [bat]=shell [delta]=shell [glow]=shell
  [nvtop]=gpu [nvitop]=gpu
  [neovim]=editor [lazyvim]=editor
  [gdown]=python [groundcontrol]=python
  [herdr]=herdr [herdr_statusline]=herdr [herdr_file_viewer]=herdr
)

# Only the hard ones: a dependency here means "cannot be installed before".
# bat/delta/glow are not listed under herdr_file_viewer because the plugin
# installs and runs fine without them -- it just falls back to plain text.
declare -A TOOL_DEPS=(
  [lazyvim]="neovim"
  [herdr_statusline]="herdr"
  [herdr_file_viewer]="herdr"
)

# --- is it already here? --------------------------------------------------
LAZYVIM_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"

have() { command -v "$1" >/dev/null 2>&1; }

# Homebrew's two Linux prefixes. Checked as a path rather than with `have brew`
# because a machine very often HAS brew and has simply never put it on PATH --
# nothing does that until a shell sources its shellenv, which on this setup is
# bashrc_additions.sh, i.e. later than any of this. Missing that would make us
# clone a second copy over the top of a perfectly good one.
brew_prefix() {
  local dir
  for dir in "$HOME/.linuxbrew" "/home/linuxbrew/.linuxbrew"; do
    if [ -x "$dir/bin/brew" ]; then printf '%s' "$dir"; return 0; fi
  done
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
    rust)          have cargo ;;
    brew)          have brew || brew_prefix >/dev/null 2>&1 ;;
    ohmyposh)      have oh-my-posh ;;
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

# TOOL_<ID>, defaulting to on. This is the "all on by default, deselect what you
# don't want" rule, in one place.
tool_selected() {
  local var="TOOL_${1^^}"
  [ "${!var:-1}" = 1 ]
}

# Give every unset answer its default, so install.sh has real values to export
# to the setup UI and to write into theme.env rather than blanks. Unlike the
# OMP_* answers in lib/derive.sh there is nothing to migrate here, so "unset"
# can just mean "on" with no ambiguity to preserve.
tools_defaults() {
  local id var
  for id in "${TOOL_IDS[@]}"; do
    var="TOOL_${id^^}"
    [ -n "${!var:-}" ] || printf -v "$var" '%s' 1
  done
}

# Every TOOL_<ID>=value line, for install.sh's theme.env writer.
tools_answers() {
  local id var
  for id in "${TOOL_IDS[@]}"; do
    var="TOOL_${id^^}"
    printf '%s=%s\n' "$var" "${!var:-1}"
  done
}

# Export them all, for handing the current answers to tui/configure.py.
tools_export() {
  local id
  for id in "${TOOL_IDS[@]}"; do export "TOOL_${id^^}"; done
}

# --- providers ------------------------------------------------------------
# Availability during a plan walk or an install run. These start from what is
# on the machine now and are flipped on as the walk passes a provider it is
# going to install, so a tool listed after rust can count on cargo.
AVAIL_APT=0 AVAIL_CARGO=0 AVAIL_UV=0 AVAIL_BREW=0

providers_init() {
  AVAIL_APT=0; priv_available && have apt-get && AVAIL_APT=1
  AVAIL_CARGO=0; have cargo && AVAIL_CARGO=1
  AVAIL_UV=0;    have uv    && AVAIL_UV=1
  # Detected by path, not by PATH -- see brew_prefix(). install_tools() calls
  # brew_activate() to make an adopted one actually usable; the plan only needs
  # to know it is there, and must stay free of side effects.
  AVAIL_BREW=0
  if have brew || brew_prefix >/dev/null 2>&1; then AVAIL_BREW=1; fi
}

# cargo either is here, or rust is selected and about to put it here.
cargo_coming() {
  [ "$AVAIL_CARGO" = 1 ] && return 0
  tool_selected rust
}

# Homebrew is bootstrapped only when it is the *sole* remaining route to
# something that was actually asked for -- a ~1GB clone is not something to do
# on spec. glow and neovim never count towards that: their release tarballs
# work on every machine, privileged or not.
brew_needed() {
  tool_selected brew || return 1
  [ "$AVAIL_BREW" = 1 ] && return 1
  [ "$AVAIL_APT" = 1 ] && return 1     # apt covers everything brew would
  local id
  # nvtop is the sharp case: no cargo crate, no useful release tarball.
  if tool_selected nvtop && ! tool_present nvtop; then return 0; fi
  if ! cargo_coming; then
    for id in eza fd bat delta; do
      if tool_selected "$id" && ! tool_present "$id"; then return 0; fi
    done
  fi
  return 1
}

# --- route resolution -----------------------------------------------------
# One decision point, used by both --plan and install_tools(). Prints
# "method|detail"; an empty method means there is no route on this machine.
tool_route() {
  case "$1" in
    rust)     echo "script|rustup.rs -> ~/.cargo" ;;
    brew)     if brew_needed; then echo "git|~/.linuxbrew (sole route to something selected)"
              else echo "|not needed on this machine"; fi ;;
    ohmyposh) echo "script|ohmyposh.dev -> ~/.local/bin" ;;
    herdr)    echo "script|herdr.dev -> ~/.local/bin" ;;
    zoxide)   if [ "$AVAIL_APT" = 1 ]; then echo "apt|zoxide"
              else echo "script|zoxide install.sh -> ~/.local/bin"; fi ;;
    fzf)      if have git; then echo "git|~/.fzf (--no-update-rc)"
              elif [ "$AVAIL_APT" = 1 ]; then echo "apt|fzf"
              else echo "|needs git or apt"; fi ;;
    eza)      _route_cargo_or_apt eza eza ;;
    fd)       _route_cargo_or_apt fd-find fd-find ;;
    bat)      _route_cargo_or_apt bat bat ;;
    delta)    _route_cargo_or_apt git-delta git-delta ;;
    glow)     echo "tarball|charmbracelet/glow -> ~/.local/bin" ;;
    nvtop)    if [ "$AVAIL_APT" = 1 ]; then echo "apt|nvtop"
              elif [ "$AVAIL_BREW" = 1 ] || brew_needed; then echo "brew|nvtop"
              else echo "|needs apt or Homebrew"; fi ;;
    # apt's neovim is 0.9.5 on 24.04, which LazyVim will start on and then warn
    # about forever. The official tarball is current, needs no privilege, and
    # lands where bashrc_additions.sh already puts ~/.local/nvim/bin on PATH.
    neovim)   echo "tarball|neovim stable -> ~/.local/nvim" ;;
    lazyvim)  if have git; then echo "git|LazyVim/starter -> $LAZYVIM_DIR"
              else echo "|needs git"; fi ;;
    gdown|groundcontrol|nvitop)
              if [ "$AVAIL_UV" = 1 ]; then echo "uv|uv tool install $(_pypi_name "$1")"
              else echo "|needs uv"; fi ;;
    herdr_statusline)  echo "plugin|iiii1224/herdr-statusline" ;;
    herdr_file_viewer) echo "plugin|smarzban/herdr-file-viewer" ;;
    *) echo "|unknown tool" ;;
  esac
}

# apt when we may use it, else cargo (which rust puts there), else brew.
_route_cargo_or_apt() {
  local apt_pkg="$1" crate="$2"
  if [ "$AVAIL_APT" = 1 ]; then echo "apt|$apt_pkg"
  elif [ "$AVAIL_CARGO" = 1 ]; then echo "cargo|$crate"
  elif [ "$AVAIL_BREW" = 1 ] || brew_needed; then echo "brew|${apt_pkg%-find}"
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

# Pull one binary out of a release tarball and drop it in ~/.local/bin. The
# layouts differ between projects (top level, or one directory down), so the
# binary is found by name rather than by a hardcoded --strip-components.
fetch_bin_from_tarball() {
  local url="$1" binary="$2" tmp found
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-tool.XXXXXX")"
  if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 180 "$url" -o "$tmp/archive.tar.gz"; then
    rm -rf "$tmp"; return 1
  fi
  if ! tar -xzf "$tmp/archive.tar.gz" -C "$tmp"; then rm -rf "$tmp"; return 1; fi
  found="$(find "$tmp" -type f -name "$binary" -perm -u+x -print -quit)"
  if [ -z "$found" ]; then rm -rf "$tmp"; return 1; fi
  mkdir -p "$HOME/.local/bin"
  install -m 0755 "$found" "$HOME/.local/bin/$binary"
  rm -rf "$tmp"
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
  # Adopt an existing prefix rather than cloning a second one next to it.
  if ! prefix="$(brew_prefix)"; then
    prefix="$HOME/.linuxbrew"
    have git || return 1
    # The "clone anywhere" install, which is the only one that needs no root.
    git clone --depth 1 https://github.com/Homebrew/brew "$prefix" >/dev/null 2>&1 || return 1
  fi
  eval "$("$prefix/bin/brew" shellenv)" || return 1
  brew update --force --quiet >/dev/null 2>&1 || true
  note_path "$prefix/bin"
  have brew
}

install_ohmyposh() {
  mkdir -p "$HOME/.local/bin"
  curl -s https://ohmyposh.dev/install.sh | bash -s -- -d "$HOME/.local/bin" >/dev/null || return 1
  note_path "$HOME/.local/bin"
  have oh-my-posh
}

install_herdr() {
  mkdir -p "$HOME/.local/bin"
  HERDR_INSTALL_DIR="$HOME/.local/bin" \
    sh -c "$(curl -fsSL https://herdr.dev/install.sh)" >/dev/null || return 1
  note_path "$HOME/.local/bin"
  have herdr
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
  local url
  url="$(github_latest_asset charmbracelet/glow "[Ll]inux.*$(arch_tag).*\.tar\.gz")"
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
  case "$(uname -m)" in
    x86_64|amd64)  arch="linux-x86_64" ;;
    aarch64|arm64) arch="linux-arm64" ;;
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
      case "$id" in
        rust) AVAIL_CARGO=1 ;; brew) AVAIL_BREW=1 ;;
      esac
      continue
    fi
    # A dependency that is neither present nor going to be installed blocks it.
    missing=""
    for dep in ${TOOL_DEPS[$id]:-}; do
      if ! tool_present "$dep" && ! tool_selected "$dep"; then missing="$dep"; break; fi
    done
    if [ -n "$missing" ]; then
      printf '%s|blocked|-|needs %s\n' "$id" "$missing"; continue
    fi
    route="$(tool_route "$id")"; method="${route%%|*}"; detail="${route#*|}"
    # Before the no-route check below: brew having no route is the normal,
    # intended outcome ("nothing here needs it"), not a machine that fell short.
    if [ "$id" = brew ] && ! brew_needed; then
      printf '%s|skip|-|%s\n' "$id" "$detail"; continue
    fi
    if [ -z "$method" ]; then
      printf '%s|blocked|-|%s\n' "$id" "$detail"; continue
    fi
    printf '%s|install|%s|%s\n' "$id" "$method" "$detail"
    case "$id" in
      rust) AVAIL_CARGO=1 ;; brew) AVAIL_BREW=1 ;;
    esac
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
  if ! have git && priv_available; then
    echo "  git is needed by fzf and LazyVim; installing it first."
    apt_install git || echo "  NOTE: could not install git."
  fi

  local id route method detail rc dep blocked
  for id in "${TOOL_IDS[@]}"; do
    if ! tool_selected "$id"; then
      TOOLS_SKIPPED+=("$id"); continue
    fi
    if tool_present "$id"; then
      printf '  %-22s already installed\n' "$id"
      case "$id" in rust) AVAIL_CARGO=1 ;; brew) AVAIL_BREW=1 ;; esac
      continue
    fi
    blocked=""
    for dep in ${TOOL_DEPS[$id]:-}; do
      tool_present "$dep" || { blocked="$dep"; break; }
    done
    if [ -n "$blocked" ]; then
      printf '  %-22s SKIPPED (%s is not installed)\n' "$id" "$blocked"
      TOOLS_SKIPPED+=("$id"); continue
    fi
    if [ "$id" = brew ] && ! brew_needed; then
      printf '  %-22s not needed on this machine\n' "$id"
      TOOLS_SKIPPED+=("$id"); continue
    fi
    route="$(tool_route "$id")"; method="${route%%|*}"; detail="${route#*|}"
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
      case "$id" in rust) AVAIL_CARGO=1 ;; brew) AVAIL_BREW=1 ;; esac
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
        printf '%s|%s|%s|%s\n' "$id" "${TOOL_LABEL[$id]}" "${TOOL_GROUP[$id]}" \
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
