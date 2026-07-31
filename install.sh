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
HERDR_CONFIG="$XDG_CONFIG/herdr"

# --- defaults -----------------------------------------------------------------
# The colour defaults reproduce the look this repo was committed with; the machine
# name defaults to this host's short name, which is usually what you want on a
# machine you are setting up for the first time.
PRIMARY="#00ff00"
SECONDARY="#ff7803"
MACHINE="$(hostname -s 2>/dev/null || uname -n 2>/dev/null || echo machine)"

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

# herdr has no separate selection colour: one token drives both the selected row's
# background overlay and the sidebar rail. Used raw, the secondary is bright enough
# that primary-coloured text sitting on top drops to ~2:1 contrast, so the rail gets
# a deepened version of the same hue -- scaled toward black, which keeps the hue and
# lands around 4:1 for the palette here.
darken() {
  local h="${1#\#}" r g b
  r=$(( 0x${h:0:2} * 66 / 100 ))
  g=$(( 0x${h:2:2} * 66 / 100 ))
  b=$(( 0x${h:4:2} * 66 / 100 ))
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

show_preview() {
  local p s
  p="$(hex_rgb "$PRIMARY")"
  s="$(hex_rgb "$SECONDARY")"
  printf '\n  \033[1mPreview\033[0m\n\n'
  # pane border
  printf '    \033[38;2;%sm' "$p"; printf '─%.0s' {1..48}; printf '\033[0m\n'
  # oh-my-posh prompt: machine segment then path, on the theme's #212224 panel
  printf '    \033[48;2;33;34;36m\033[38;2;%sm  \033[38;2;%sm%s \033[0m' \
    "$s" "$p" "${MACHINE,,}"
  printf '\033[38;2;33;34;36m\033[0m\n'
  printf '    \033[38;2;33;34;36m╰─\033[38;2;%sm \033[0m\n' "$s"
  # tmux status line: machine, current session, clock
  printf '    \033[48;2;0;0;0m\033[1m\033[38;2;255;255;255m %s \033[0m' "$MACHINE"
  printf '\033[48;2;%sm\033[38;2;0;0;0m\033[0m' "$s"
  printf '\033[48;2;%sm\033[1m\033[38;2;0;0;0m main \033[0m' "$s"
  printf '\033[48;2;%sm\033[38;2;%sm\033[0m' "$p" "$s"
  printf '\033[48;2;%sm\033[1m\033[38;2;0;0;0m  12:34  2026-07-31 \033[0m\n\n' "$p"
}

if [ "$INTERACTIVE" -eq 1 ]; then
  printf '\n\033[1mdotfiles setup\033[0m\n'
  printf 'Pick the two accent colours and this machine'\''s name, then everything installs.\n'
  while true; do
    ask_color PRIMARY   "Primary"
    ask_color SECONDARY "Secondary"
    ask_machine
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

SECONDARY_DIM="$(darken "$SECONDARY")"
MACHINE_LOWER="${MACHINE,,}"

echo "  primary   $PRIMARY"
echo "  secondary $SECONDARY  (rail $SECONDARY_DIM)"
echo "  machine   $MACHINE"
echo ""

# --- save the answers ---------------------------------------------------------
mkdir -p "$(dirname "$ANSWERS")"
cat > "$ANSWERS" <<EOF
# GENERATED by dotfiles/install.sh -- this machine's theme answers.
# Re-run './install.sh --reconfigure' to change them, or edit and re-run install.sh.
PRIMARY="$PRIMARY"
SECONDARY="$SECONDARY"
MACHINE="$MACHINE"
EOF
echo "Saved answers to $ANSWERS"

# --- plumbing -----------------------------------------------------------------
link() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    mv "$dst" "$dst.bak"
    echo "Backed up existing $dst -> $dst.bak"
  fi
  ln -sfn "$src" "$dst"
  echo "Linked $dst -> $src"
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
    # this). _DIM and _LOWER come first so the shorter names cannot shadow them.
    sed -e '/^#>>/d' \
        -e "s|@PRIMARY@|$PRIMARY|g" \
        -e "s|@SECONDARY_DIM@|$SECONDARY_DIM|g" \
        -e "s|@SECONDARY@|$SECONDARY|g" \
        -e "s|@MACHINE_LOWER@|$MACHINE_LOWER|g" \
        -e "s|@MACHINE@|$MACHINE|g" \
        -e "s|@HERDR_CONFIG@|$HERDR_CONFIG|g" \
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

# --- oh-my-posh ---
render oh-my-posh/albe-monokai2.omp.json.in oh-my-posh/albe-monokai2.omp.json
link "$GENERATED/oh-my-posh/albe-monokai2.omp.json" \
     "$HOME/.cache/oh-my-posh/themes/albe-monokai2.omp.json"

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

echo ""
echo "Done. Notes:"
echo "  - Re-run './install.sh' any time after editing a *.in template; it reuses the"
echo "    saved answers, so it re-renders without prompting. './install.sh --reconfigure'"
echo "    changes the colours or machine name."
echo "  - conda init and any gcloud SDK sourcing are NOT included (machine-specific paths) — re-run"
echo "    'conda init bash' / the gcloud installer on this machine if needed."
echo "  - Workspace aliases (cluster-specific /anvme paths etc.) are intentionally excluded;"
echo "    keep those per-machine or in a separate per-project config."
echo "  - herdr: the config is synced but the file-viewer plugin is not — install it per-machine"
echo "    with 'herdr plugin install smarzban/herdr-file-viewer', and 'herdr server reload-config'"
echo "    to pick up a config change without restarting. Its Monokai content pane needs bat,"
echo "    delta and glow on PATH; without them the viewer falls back to plain text."
echo "  - Open a new shell (or 'source ~/.bashrc') to pick up the changes."
