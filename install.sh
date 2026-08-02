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
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
MACHINE="$(hostname -s 2>/dev/null || uname -n 2>/dev/null || echo machine)"

# Status line components, shared by tmux's status bar and herdr-statusline (the
# two are meant to stay visually identical -- see CLAUDE.md). TEMP is a sub-toggle
# of GPU: it only has an effect when the GPU pill itself is shown.
SHOW_HOST=1
SHOW_GPU=1
SHOW_TEMP=1
SHOW_SLURM=1
SHOW_DATETIME=1

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

usage() {
  cat <<EOF
Usage: ./install.sh [options]

  -r, --reconfigure     Re-ask for colours and machine name even if answers are saved.
      --primary HEX     Set the primary colour non-interactively (e.g. --primary '#78dce8').
      --secondary HEX   Set the secondary colour non-interactively.
      --machine NAME    Set the machine name non-interactively.
  -y, --non-interactive Never prompt; use saved answers, or the defaults if none.
      --skip-uv         Don't install/update uv (offline machines, CI).
      --no-tui          Use the plain text wizard instead of the Textual UI.
      --no-tools        Only render and link config; install no tools.
      --tools-only      Only install tools; render and link nothing.
  -h, --help            Show this message.

With no options: installs uv if missing, then prompts (in the Textual UI) on the
first run, then reuses the saved answers from
$ANSWERS

Tools are installed by whichever route this machine can actually use: apt when
you have root or sudo, and rustup/cargo, uv, release tarballs, git clones or
Homebrew when you don't. './install.sh --tools-only -y' shows the plan and runs
it without touching any config; 'bash lib/tools.sh --plan' just shows it.
EOF
}

# Only a wizard concern, so it stays here rather than in lib/derive.sh.
swatch() { printf '\033[48;2;%sm    \033[0m' "$(hex_rgb "$1")"; }

# --- arg parsing --------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -r|--reconfigure) RECONFIGURE=1 ;;
    -y|--non-interactive) ASSUME_YES=1 ;;
    --skip-uv)   SKIP_UV=1 ;;
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

# The permanent half of "put uv on PATH": a tiny file that bashrc_additions.sh
# sources on every shell. It is written even when uv was already installed, so a
# machine where uv landed somewhere unusual (UV_INSTALL_DIR/XDG_BIN_HOME) still
# gets that directory on PATH for good.
persist_uv_path() {
  local dir="$1"
  mkdir -p "$(dirname "$UV_ENV_FILE")"
  cat > "$UV_ENV_FILE" <<EOF
# GENERATED by dotfiles/install.sh -- puts uv's install directory on PATH.
# Sourced from shell/bashrc_additions.sh (and therefore from ~/.bashrc).
# Edit install.sh, not this file; it is rewritten on every run.
case ":\$PATH:" in
  *":$dir:"*) ;;
  *) export PATH="$dir:\$PATH" ;;
esac
# The installer's own env file, if it wrote one (it may add more than PATH).
[ -f "$dir/env" ] && . "$dir/env"
EOF
  echo "uv on PATH permanently via $UV_ENV_FILE (sourced from bashrc_additions.sh)"
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
TTY_FD=""
if [ -t 0 ]; then
  exec {TTY_FD}<&0
elif [ -r /dev/tty ] && (exec 3</dev/tty) 2>/dev/null; then
  # Probed in a subshell above, so bash never prints its own redirection error.
  exec {TTY_FD}</dev/tty
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

# --- the wizard ---------------------------------------------------------------
# PALETTE_NAMES / PALETTE_HEX / PALETTE_COLUMNS come from lib/derive.sh, sourced
# above. They are deliberately NOT redeclared here: this file used to carry its
# own copy of the first eight, which meant the text wizard silently offered a
# different (and shorter) set of swatches than the Textual UI did.
PALETTE_GRID=4   # how many swatches per line the text wizard prints

ask_color() {
  local var="$1" label="$2" i choice n="${#PALETTE_HEX[@]}"
  # Split from the declaration above: inside a single `local`, the indirection
  # ${!var} is evaluated before `var` itself is usable as a name.
  local cur="${!var}"
  while true; do
    printf '\n  \033[1m%s colour\033[0m\n\n' "$label"
    for i in "${!PALETTE_HEX[@]}"; do
      printf '  %2d) ' "$((i + 1))"
      swatch "${PALETTE_HEX[$i]}"
      # The current swatch is marked with a trailing * rather than a "<- current"
      # tail, which no longer fits now the palette prints as a grid.
      if [ "${PALETTE_HEX[$i],,}" = "${cur,,}" ]; then
        printf ' %-12s' "${PALETTE_NAMES[$i]}*"
      else
        printf ' %-12s' "${PALETTE_NAMES[$i]}"
      fi
      [ $(( (i + 1) % PALETTE_GRID )) -eq 0 ] && echo
    done
    [ $(( n % PALETTE_GRID )) -eq 0 ] || echo
    printf '\n  %2d) custom hex...        (* = current)\n\n' "$((n + 1))"

    printf '  choice, or a #rrggbb value [keep %s]: ' "$cur"
    read -r -u "$TTY_FD" choice || choice=""

    if [ -z "$choice" ]; then
      printf -v "$var" '%s' "$cur"; return
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ]; then
      printf -v "$var" '%s' "${PALETTE_HEX[$((choice - 1))]}"; return
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -eq "$((n + 1))" ]; then
      printf '  hex value: '
      read -r -u "$TTY_FD" choice || choice=""
    fi

    # Accept a hex typed either at the menu or at the custom prompt, with a
    # bare "abc123" treated as "#abc123" since the # is easy to leave off.
    [[ "$choice" =~ ^[0-9a-fA-F]{6}$ ]] && choice="#$choice"
    if valid_hex "$choice"; then
      printf -v "$var" '%s' "$choice"; return
    fi
    printf '  \033[31mNot a choice or a #rrggbb value.\033[0m\n'
  done
}

ask_machine() {
  local answer
  while true; do
    printf '\n  \033[1mMachine name\033[0m  (shown in the tmux bar and the shell prompt)\n\n'
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
    case "${answer,,}" in
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
  local opts=("$@") cur="${!var}" answer i
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
    for i in "${!opts[@]}"; do
      if [ "${opts[$i]#"${answer,,}"}" != "${opts[$i]}" ]; then
        printf -v "$var" '%s' "${opts[$i]}"; return
      fi
    done
    printf '  \033[31mPick one of: %s\033[0m\n' "${opts[*]}"
  done
}

ask_components() {
  printf '\n  \033[1mStatus line components\033[0m  (tmux bar + herdr-statusline, kept identical)\n\n'
  ask_bool SHOW_HOST     "  hostname pill"
  ask_bool SHOW_GPU      "  GPU usage pill"
  if [ "$SHOW_GPU" = 1 ]; then
    ask_bool SHOW_TEMP   "    also show GPU temperature in that pill"
  else
    SHOW_TEMP=0
  fi
  ask_bool SHOW_SLURM    "  Slurm job pill"
  ask_bool SHOW_DATETIME "  date / time pill"

  printf '\n  \033[1moh-my-posh accent placement\033[0m  (machine segment + bottom status chevrons)\n\n'
  ask_choice OMP_ICON_MODE "  leading glyph" fixed slurm
  if [ "$OMP_ICON_MODE" = fixed ]; then
    ask_choice OMP_ICON "  leading glyph colour" "${OMP_CHOICES[@]}"
  else
    printf '    (slurm: primary normally, secondary inside a job shell)\n'
  fi
  ask_choice OMP_TEXT         "  machine-name text" "${OMP_CHOICES[@]}"
  ask_choice OMP_CHEVRON_OK   "  bottom chevrons, exit 0" "${OMP_CHOICES[@]}"
  ask_choice OMP_CHEVRON_ERROR "  bottom chevrons, error" "${OMP_CHOICES[@]}"
}

# The text fallback's counterpart to the UI's Tools checkboxes. Nineteen y/n
# prompts would be miserable, so it prints the list with everything already on
# and takes numbers to switch off -- which also matches how the answer defaults
# actually work.
ask_tools() {
  local i id var picked line
  while true; do
    printf '\n  \033[1mTools to install\033[0m  (%s)\n\n' "$(priv_summary)"
    for i in "${!TOOL_IDS[@]}"; do
      id="${TOOL_IDS[$i]}"; var="TOOL_${id^^}"
      if [ "${!var}" = 1 ]; then
        printf '    %2d) \033[1m[x]\033[0m %s\n' "$((i + 1))" "${TOOL_LABEL[$id]}"
      else
        printf '    %2d) [ ] \033[2m%s\033[0m\n' "$((i + 1))" "${TOOL_LABEL[$id]}"
      fi
    done
    printf '\n  numbers to toggle off/on (space separated), or enter to accept: '
    read -r -u "$TTY_FD" line || line=""
    [ -z "$line" ] && return
    for picked in $line; do
      [[ "$picked" =~ ^[0-9]+$ ]] || continue
      [ "$picked" -ge 1 ] && [ "$picked" -le "${#TOOL_IDS[@]}" ] || continue
      id="${TOOL_IDS[$((picked - 1))]}"; var="TOOL_${id^^}"
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
  local tmp
  tmp="$(mktemp /tmp/dotfiles-omp-preview.XXXXXX.json)"
  sed -e '/^#>>/d' \
      -e "s|@PRIMARY@|$PRIMARY|g" \
      -e "s|@SECONDARY@|$SECONDARY|g" \
      -e "s|@MACHINE_LOWER@|${MACHINE,,}|g" \
      -e "s|@OMP_ICON_COLOR_JOB@|$OMP_ICON_COLOR_JOB|g" \
      -e "s|@OMP_ICON_COLOR@|$OMP_ICON_COLOR|g" \
      -e "s|@OMP_TEXT_COLOR@|$OMP_TEXT_COLOR|g" \
      -e "s|@OMP_CHEVRON_FG@|$OMP_CHEVRON_FG|g" \
      -e "s|@OMP_CHEVRON_ERR@|$OMP_CHEVRON_ERR|g" \
      "$DOTFILES/oh-my-posh/albe-monokai2.omp.json.in" > "$tmp"

  # The trailing sed drops the console-title OSC oh-my-posh emits, which would
  # otherwise print as stray text in the middle of the preview.
  oh-my-posh print primary --config "$tmp" --shell universal 2>/dev/null \
    | sed -e 's/\x1b\][^\x07]*\x07//g' -e 's/^/    /'
  rm -f "$tmp"
}

show_preview() {
  local p s icon_c text_c chev_c
  # Everything the preview needs is a derived value, so derive them exactly the
  # way the install will -- no second, drifting copy of the colour logic here.
  derive
  p="$(hex_rgb "$PRIMARY")"
  s="$(hex_rgb "$SECONDARY")"
  icon_c="$(hex_rgb "$OMP_ICON_COLOR")"
  text_c="$(hex_rgb "$OMP_TEXT_COLOR")"
  chev_c="$(hex_rgb "$OMP_CHEVRON_FG")"
  printf '\n  \033[1mPreview\033[0m\n\n'
  # pane border
  printf '    \033[38;2;%sm' "$p"; printf '─%.0s' {1..48}; printf '\033[0m\n'
  if command -v oh-my-posh >/dev/null 2>&1; then
    omp_live_preview
  else
    # oh-my-posh not installed yet -- hand-drawn approximation of just the
    # machine segment and the bottom chevron line, on the theme's #212224 panel.
    printf '    \033[48;2;33;34;36m\033[38;2;%sm  \033[38;2;%sm%s \033[0m' \
      "$icon_c" "$text_c" "${MACHINE,,}"
    printf '\033[38;2;33;34;36m\033[0m\n'
    printf '    \033[38;2;33;34;36m╰─\033[38;2;%sm \033[0m\n' "$chev_c"
  fi
  # tmux / herdr-statusline: host, gpu, slurm, clock -- only the enabled pills
  [ "$SHOW_HOST" = 1 ] && printf '    \033[48;2;0;0;0m\033[1m\033[38;2;255;255;255m %s \033[0m' "$MACHINE"
  if [ "$SHOW_GPU" = 1 ]; then
    printf '\033[48;2;0;0;0m\033[38;2;%sm GPU ▰▰▱▱ 45%%' "$p"
    [ "$SHOW_TEMP" = 1 ] && printf ' 62°'
    printf ' \033[0m'
  fi
  [ "$SHOW_SLURM" = 1 ] && printf '\033[48;2;0;0;0m\033[38;2;%sm  1 job \033[0m' "$p"
  if [ "$SHOW_DATETIME" = 1 ]; then
    printf '\033[48;2;%sm\033[38;2;0;0;0m\033[0m' "$s"
    printf '\033[48;2;%sm\033[1m\033[38;2;0;0;0m  12:34  2026-07-31 \033[0m' "$p"
  fi
  printf '\n'
  # Claude Code's five bubbles, in the ramp derive() just computed.
  printf '    '
  local rgb
  for rgb in "$CLAUDE_MODEL_RGB" "$CLAUDE_EFFORT_RGB" "$CLAUDE_USAGE_RGB" \
             "$CLAUDE_WEEK_RGB" "$CLAUDE_CTX_RGB"; do
    printf '\033[38;2;%sm\033[48;2;%sm\033[38;2;0;0;0m    \033[0m\033[38;2;%sm\033[0m ' \
      "$rgb" "$rgb" "$rgb"
  done
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
    case "${reply,,}" in
      ''|y|yes) return 0 ;;
      r|redo)   continue ;;
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
    TUI_OUT="$(mktemp "${TMPDIR:-/tmp}/dotfiles-setup.XXXXXX.env")"
    run_tui "$TUI_OUT" || WIZARD_RC=$?
    if [ "$WIZARD_RC" -eq 0 ]; then
      # shellcheck disable=SC1090
      . "$TUI_OUT"
    fi
    rm -f "$TUI_OUT"
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
# A NEW shell needs nothing: bashrc_additions.sh sources the tools-env.sh that
# install_tools() just wrote, and already exports ~/.local/bin, ~/.cargo/bin and
# ~/.local/nvim/bin itself. This is purely for the terminal the install ran in,
# which will otherwise keep saying "command not found" for something that is
# very much installed -- the one thing that reliably makes a fresh setup look
# broken when it is not.
print_path_hint() {
  local missing
  missing="$(tools_missing_path)"
  [ -n "$missing" ] || return 0
  echo ""
  echo "  Tools landed in directories THIS shell doesn't have on PATH yet."
  echo "  A new shell picks them up on its own; for this one, copy-paste:"
  echo ""
  printf '      export PATH="%s:$PATH"\n' "$(printf '%s' "$missing" | paste -sd:)"
  echo ""
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
  print_path_hint
  exit 0
fi
echo ""

# --- plumbing -----------------------------------------------------------------
link() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  # Only a real (non-symlink) file gets backed up, and only once: on a second
  # run dst is already our own symlink, so this never overwrites the backup
  # with our own rendered output.
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    mv "$dst" "$dst.bak"
    echo "Backed up existing $dst -> $dst.bak"
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
# manifest instead of [ ! -L "$dst" ]. The [ ! -e "$dst.bak" ] guard is the
# fallback if the manifest is missing or stale, so a real backup never gets
# clobbered by our own previous copy either way.
copy() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ -e "$dst" ] && ! is_already_managed "$dst" && [ ! -e "$dst.bak" ]; then
    cp -f "$dst" "$dst.bak"
    echo "Backed up existing $dst -> $dst.bak"
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
render_script() {
  render "$1" "$2"
  local out="$GENERATED/$2"
  sed -i "1a # GENERATED by dotfiles/install.sh from $1 -- do not edit; edit the template." "$out"
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

# --- shell ---
link "$DOTFILES/shell/bashrc_functions" "$HOME/.bashrc_functions"
link "$DOTFILES/shell/profile"          "$HOME/.profile"

MARKER="# >>> dotfiles bashrc_additions >>>"
if ! grep -qF "$MARKER" "$HOME/.bashrc" 2>/dev/null; then
  {
    echo ""
    echo "$MARKER"
    echo "source \"$DOTFILES/shell/bashrc_additions.sh\""
    echo "# <<< dotfiles bashrc_additions <<<"
  } >> "$HOME/.bashrc"
  echo "Appended source line to ~/.bashrc"
else
  echo "~/.bashrc already sources dotfiles additions, skipping"
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
echo "  - Open a new shell (or 'source ~/.bashrc') to pick up the changes."
print_path_hint
