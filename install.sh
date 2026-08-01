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

# oh-my-posh accent placement: whether the machine segment's leading glyph and
# its text pick up the accent colours, and whether the bottom chevron line
# colours itself by exit status. Off falls back to a neutral foreground so the
# element is still visible, just not accented.
OMP_COLOR_ICON=1
OMP_COLOR_TEXT=1
OMP_COLOR_CHEVRON=1
# Fallback foreground when an OMP_COLOR_* toggle is off -- the theme's own
# default text colour (see transient_prompt in the .omp.json), not a taste.
NEUTRAL_FG="#d6deeb"

RECONFIGURE=0
ASSUME_YES=0

usage() {
  cat <<EOF
Usage: ./install.sh [options]

  -r, --reconfigure     Re-ask for colours and machine name even if answers are saved.
      --primary HEX     Set the primary colour non-interactively (e.g. --primary '#78dce8').
      --secondary HEX   Set the secondary colour non-interactively.
      --machine NAME    Set the machine name non-interactively.
  -y, --non-interactive Never prompt; use saved answers, or the defaults if none.
  -h, --help            Show this message.

With no options: prompts on the first run, then reuses the saved answers from
$ANSWERS
EOF
}

# --- colour helpers -----------------------------------------------------------
valid_hex() { [[ "$1" =~ ^#[0-9a-fA-F]{6}$ ]]; }
# Machine name is substituted into sed replacements and into JSON/tmux strings,
# so keep it to characters that are safe in all three.
valid_machine() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,24}$ ]]; }

hex_rgb() { local h="${1#\#}"; printf '%d;%d;%d' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"; }
swatch()  { printf '\033[48;2;%sm    \033[0m' "$(hex_rgb "$1")"; }

# Scale a colour toward black by a percentage, keeping its hue. Used for herdr's
# sidebar rail: one token there paints both the rail and the selected row's
# background, and the row's text is the primary colour, so the rail has to be a
# DARKENED primary -- raw would be primary-on-primary. 50% is the balance point
# (~3.8:1 for the bold row text on it, ~2.8:1 for the rail against the panel).
darken() {
  local h="${1#\#}" pct="$2" r g b
  r=$(( 0x${h:0:2} * pct / 100 ))
  g=$(( 0x${h:2:2} * pct / 100 ))
  b=$(( 0x${h:4:2} * pct / 100 ))
  printf '#%02x%02x%02x' "$r" "$g" "$b"
}

# --- arg parsing --------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -r|--reconfigure) RECONFIGURE=1 ;;
    -y|--non-interactive) ASSUME_YES=1 ;;
    --primary)   PRIMARY_ARG="${2:?--primary needs a value}"; shift ;;
    --secondary) SECONDARY_ARG="${2:?--secondary needs a value}"; shift ;;
    --machine)   MACHINE_ARG="${2:?--machine needs a value}"; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

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

# --- the wizard ---------------------------------------------------------------
PALETTE_NAMES=(green   mint     cyan     purple   pink     yellow   orange   peach)
PALETTE_HEX=(  '#00ff00' '#a9dc76' '#78dce8' '#ab9df2' '#ff6188' '#ffd866' '#ff7803' '#fc9867')

ask_color() {
  local var="$1" label="$2" i choice n="${#PALETTE_HEX[@]}"
  # Split from the declaration above: inside a single `local`, the indirection
  # ${!var} is evaluated before `var` itself is usable as a name.
  local cur="${!var}"
  while true; do
    printf '\n  \033[1m%s colour\033[0m\n\n' "$label"
    for i in "${!PALETTE_HEX[@]}"; do
      printf '    %d) ' "$((i + 1))"
      swatch "${PALETTE_HEX[$i]}"
      printf '  %-7s %s' "${PALETTE_NAMES[$i]}" "${PALETTE_HEX[$i]}"
      [ "${PALETTE_HEX[$i],,}" = "${cur,,}" ] && printf '   <- current'
      echo
    done
    printf '    %d) custom hex...\n\n' "$((n + 1))"

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
  local var="$1" label="$2" cur="${!var}" hint answer
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
  ask_bool OMP_COLOR_ICON    "  colour the leading glyph"
  ask_bool OMP_COLOR_TEXT    "  colour the machine-name text"
  ask_bool OMP_COLOR_CHEVRON "  colour the bottom chevrons by exit status"
}

show_preview() {
  local p s icon_c text_c chev_c
  p="$(hex_rgb "$PRIMARY")"
  s="$(hex_rgb "$SECONDARY")"
  icon_c="$s";  [ "$OMP_COLOR_ICON" = 1 ] || icon_c="$(hex_rgb "$NEUTRAL_FG")"
  text_c="$p";  [ "$OMP_COLOR_TEXT" = 1 ] || text_c="$(hex_rgb "$NEUTRAL_FG")"
  chev_c="$p";  [ "$OMP_COLOR_CHEVRON" = 1 ] || chev_c="$(hex_rgb "$NEUTRAL_FG")"
  printf '\n  \033[1mPreview\033[0m\n\n'
  # pane border
  printf '    \033[38;2;%sm' "$p"; printf '─%.0s' {1..48}; printf '\033[0m\n'
  # oh-my-posh prompt: machine segment then path, on the theme's #212224 panel
  printf '    \033[48;2;33;34;36m\033[38;2;%sm  \033[38;2;%sm%s \033[0m' \\
    "$icon_c" "$text_c" "${MACHINE,,}"
  printf '\033[38;2;33;34;36m\033[0m\n'
  printf '    \033[38;2;33;34;36m╰─\033[38;2;%sm \033[0m\n' "$chev_c"
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
  printf '\n\n'
}
if [ "$INTERACTIVE" -eq 1 ]; then
  printf '\n\033[1mdotfiles setup\033[0m\n'
  printf 'Pick the two accent colours and this machine'\''s name, then everything installs.\n'
  while true; do
    ask_color PRIMARY   "Primary"
    ask_color SECONDARY "Secondary"
    ask_machine
    ask_components
    show_preview
    printf '  Install with these? [\033[1mY\033[0m]es / [r]edo / [q]uit: '
    read -r -u "$TTY_FD" reply || reply=""
    case "${reply,,}" in
      ''|y|yes) break ;;
      r|redo)   continue ;;
      q|quit|n|no) echo "Aborted; nothing was changed."; exit 1 ;;
      *) printf '  \033[31mAnswer y, r or q.\033[0m\n' ;;
    esac
  done
elif [ -n "${PRIMARY_ARG:-}${SECONDARY_ARG:-}${MACHINE_ARG:-}" ]; then
  echo "Using the values given on the command line."
elif [ "$HAD_ANSWERS" -eq 1 ]; then
  echo "Using saved theme from $ANSWERS (--reconfigure to change)."
elif [ -z "$TTY_FD" ]; then
  echo "No saved theme and no terminal to prompt on; using defaults."
else
  echo "Using saved theme (--reconfigure to change)."
fi

PRIMARY_DIM="$(darken "$PRIMARY" 50)"
MACHINE_LOWER="${MACHINE,,}"
# Not prompted for: the login name is a fact about the machine, not a taste.
USER_NAME="$(id -un 2>/dev/null || echo "${USER:-user}")"

# --- oh-my-posh accent placement -----------------------------------------------
# Each OMP_COLOR_* toggle picks between the accent colour and the neutral
# fallback; baked in here (not left as @PRIMARY@/@SECONDARY@ in the template)
# so the .omp.json placeholders stay a straight substitution either way.
OMP_ICON_COLOR="$SECONDARY";  [ "$OMP_COLOR_ICON" = 1 ]    || OMP_ICON_COLOR="$NEUTRAL_FG"
OMP_TEXT_COLOR="$PRIMARY";    [ "$OMP_COLOR_TEXT" = 1 ]    || OMP_TEXT_COLOR="$NEUTRAL_FG"
OMP_CHEVRON_FG="$PRIMARY"
OMP_CHEVRON_ERR="$SECONDARY"
if [ "$OMP_COLOR_CHEVRON" != 1 ]; then OMP_CHEVRON_FG="$NEUTRAL_FG"; OMP_CHEVRON_ERR="$NEUTRAL_FG"; fi

# --- status line assembly -------------------------------------------------------
# tmux's status bar and herdr-statusline are meant to look identical (see
# CLAUDE.md), so both are assembled here from the same SHOW_* toggles rather
# than templated with sed conditionals, which tmux.conf/toml have no syntax for.
# Colours are baked in as literal hex, same reasoning as the OMP_* colours above.
# The powerline glyphs (U+E0BA/E0BC/E0BB) match the ones already hand-placed in
# the untoggleable parts of these bars, so a toggled segment doesn't visually
# clash with its neighbours.
# $'...' ANSI-C quoting so these survive as exact codepoints regardless of the
# editor/terminal in between -- raw PUA glyphs pasted straight into a shell
# script are exactly the kind of thing that silently turns into nothing.
CAP=$''; SEP=$''; SEP2=$''

TMUX_STATUS_LEFT=""
if [ "$SHOW_HOST" = 1 ]; then
  TMUX_STATUS_LEFT+="#[fg=$PRIMARY,bg=#000000]${CAP}#[fg=#ffffff,bg=#000000,bold] $MACHINE #[fg=#000000,bg=$PRIMARY]${SEP}"
fi
TMUX_STATUS_LEFT+='#(~/.tmux/other-sessions.sh)'

# "#00000t0" below is the same deliberate typo the untouched original right side
# had: it makes tmux drop that one style (invisible, since it only covers a
# space) rather than paint a visible box -- see herdr-statusline/config.toml.in,
# which spells the same spot correctly since its layout differs slightly.
TMUX_STATUS_RIGHT="#[fg=$PRIMARY,bg=#000000]${SEP}#[fg=#ffffff,bg=#00000t0] "
[ "$SHOW_GPU" = 1 ]   && TMUX_STATUS_RIGHT+='#(~/.tmux/gpu-status.sh)'
[ "$SHOW_SLURM" = 1 ] && TMUX_STATUS_RIGHT+='#(~/.tmux/slurm-status.sh)'
TMUX_STATUS_RIGHT+="#[fg=#000000,bg=$PRIMARY]${SEP}"
if [ "$SHOW_DATETIME" = 1 ]; then
  TMUX_STATUS_RIGHT+="#[fg=#000000,bg=$PRIMARY,bold] %H:%M #[fg=#000000,bg=$PRIMARY,bold]${SEP2} %Y-%m-%d "
fi
TMUX_STATUS_RIGHT+="#[fg=$PRIMARY,bg=#000000]${SEP} "

HSL_STATUS_LEFT=""
if [ "$SHOW_HOST" = 1 ]; then
  HSL_STATUS_LEFT="#[fg=$PRIMARY,bg=#000000]${CAP}#[fg=$SECONDARY,bg=#000000,bold] ${USER_NAME}#[fg=#ffffff,bg=#000000,bold]@${MACHINE} #[fg=#000000,bg=$PRIMARY]${SEP}"
fi

HSL_STATUS_RIGHT="#[fg=$PRIMARY,bg=#000000]${SEP}#[fg=#ffffff,bg=#000000] "
[ "$SHOW_GPU" = 1 ]   && HSL_STATUS_RIGHT+='#($HERDR_PLUGIN_CONFIG_DIR/gpu-status.sh)'
[ "$SHOW_SLURM" = 1 ] && HSL_STATUS_RIGHT+='#($HERDR_PLUGIN_CONFIG_DIR/slurm-status.sh)'
HSL_STATUS_RIGHT+="#[fg=#000000,bg=$PRIMARY]${SEP}"
if [ "$SHOW_DATETIME" = 1 ]; then
  HSL_STATUS_RIGHT+="#[fg=#000000,bg=$PRIMARY,bold] %H:%M #[fg=#000000,bg=$PRIMARY,bold]${SEP2} %Y-%m-%d "
fi
HSL_STATUS_RIGHT+="#[fg=$PRIMARY,bg=#000000]${SEP} "

echo "  primary   $PRIMARY  (herdr sidebar rail $PRIMARY_DIM)"
echo "  secondary $SECONDARY"
echo "  machine   $MACHINE"
echo "  status    host=$SHOW_HOST gpu=$SHOW_GPU temp=$SHOW_TEMP slurm=$SHOW_SLURM datetime=$SHOW_DATETIME"
echo "  omp       icon=$OMP_COLOR_ICON text=$OMP_COLOR_TEXT chevron=$OMP_COLOR_CHEVRON"
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
OMP_COLOR_ICON=$OMP_COLOR_ICON
OMP_COLOR_TEXT=$OMP_COLOR_TEXT
OMP_COLOR_CHEVRON=$OMP_COLOR_CHEVRON
EOF
echo "Saved answers to $ANSWERS"

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
        -e "s|@OMP_ICON_COLOR@|$OMP_ICON_COLOR|g" \
        -e "s|@OMP_TEXT_COLOR@|$OMP_TEXT_COLOR|g" \
        -e "s|@OMP_CHEVRON_FG@|$OMP_CHEVRON_FG|g" \
        -e "s|@OMP_CHEVRON_ERR@|$OMP_CHEVRON_ERR|g" \
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
link "$DOTFILES/claude/statusline-command.sh" "$HOME/.claude/statusline-command.sh"
chmod +x "$DOTFILES/claude/statusline-command.sh"
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
echo "  - herdr: the config is synced but the file-viewer plugin is not — install it per-machine"
echo "    with 'herdr plugin install smarzban/herdr-file-viewer', and 'herdr server reload-config'"
echo "    to pick up a config change without restarting. Its Monokai content pane needs bat,"
echo "    delta and glow on PATH; without them the viewer falls back to plain text."
echo "  - Open a new shell (or 'source ~/.bashrc') to pick up the changes."
