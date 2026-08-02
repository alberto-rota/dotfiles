#!/bin/bash
# Everything that is COMPUTED from the wizard's answers, in one place.
#
# Two consumers, deliberately:
#   * install.sh sources this file and calls derive() before rendering.
#   * tui/configure.py EXECUTES it (`bash lib/derive.sh`) with the answers in the
#     environment and parses the KEY=value lines it prints, so the live preview
#     is built by the very same assembly code that renders the real config --
#     not a Python re-implementation that would quietly drift from it.
#
# Reads (all optional, defaults below):
#   PRIMARY SECONDARY MACHINE USER_NAME NEUTRAL_FG
#   SHOW_HOST SHOW_GPU SHOW_TEMP SHOW_SLURM SHOW_DATETIME
#   OMP_ICON_MODE OMP_ICON OMP_TEXT OMP_CHEVRON_OK OMP_CHEVRON_ERROR
#   (and the superseded OMP_COLOR_ICON / OMP_COLOR_TEXT / OMP_COLOR_CHEVRON,
#    which are migrated to the above when the new answers are absent)
# Sets:
#   PRIMARY_DIM MACHINE_LOWER USER_NAME
#   OMP_ICON_COLOR OMP_ICON_COLOR_JOB OMP_TEXT_COLOR OMP_CHEVRON_FG OMP_CHEVRON_ERR
#   CLAUDE_MODEL_RGB CLAUDE_EFFORT_RGB CLAUDE_USAGE_RGB CLAUDE_WEEK_RGB CLAUDE_CTX_RGB
#   TMUX_STATUS_LEFT TMUX_STATUS_RIGHT HSL_STATUS_LEFT HSL_STATUS_RIGHT

# --- the palette offered by both front-ends -------------------------------------
# Lives here rather than in either front-end so the bash wizard and the Textual
# TUI cannot offer different swatches.
# Twenty-four, laid out by the UI as three rows of eight, each row a register
# rather than an arbitrary continuation:
#   1. the original Monokai-ish eight;
#   2. the gaps in it (a true red, a blue, a neutral silver), so either accent
#      can be picked from a real spread rather than from one corner of the wheel;
#   3. pastels -- the same wheel at low saturation and high lightness, for a
#      prompt/bar that reads as tinted rather than as neon.
# All are light enough to carry black text, which most of the pills that use
# them do; the pastel row has the most headroom there by construction.
PALETTE_NAMES=(green     mint      cyan      purple    pink      yellow    orange    peach
               lime      teal      sky       lavender  magenta   red       gold      silver
               sage      seafoam   ice       periwinkle orchid   blush     cream     sand)
PALETTE_HEX=(  '#00ff00' '#a9dc76' '#78dce8' '#ab9df2' '#ff6188' '#ffd866' '#ff7803' '#fc9867'
               '#a6e22e' '#06d6a0' '#61afef' '#c792ea' '#ff79c6' '#ff5555' '#f5bf45' '#d6deeb'
               '#b8e0b0' '#9fe2cf' '#b3e5fc' '#c5cae9' '#e1bee7' '#ffb3c1' '#fff1a8' '#e6d3b3')
# How the UI wraps them; kept here so both front-ends agree on the layout.
PALETTE_COLUMNS=8

# The third choice wherever a component picks a colour ("neutral") -- the
# theme's own default text colour (see transient_prompt in the .omp.json), not
# a taste.
NEUTRAL_FG="${NEUTRAL_FG:-#d6deeb}"

# The choices every per-component colour answer accepts.
OMP_CHOICES=(primary secondary neutral)

# --- validation / colour helpers ------------------------------------------------
valid_hex() { [[ "$1" =~ ^#[0-9a-fA-F]{6}$ ]]; }
# Machine name is substituted into sed replacements and into JSON/tmux strings,
# so keep it to characters that are safe in all three.
valid_machine() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,24}$ ]]; }

hex_rgb() { local h="${1#\#}"; printf '%d;%d;%d' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"; }

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

# One of the three OMP_CHOICES -> an actual hex value. Anything unrecognised
# falls back to the neutral foreground rather than emptying the placeholder,
# which would produce an unparseable .omp.json.
accent_hex() {
  case "$1" in
    primary)   printf '%s' "$PRIMARY" ;;
    secondary) printf '%s' "$SECONDARY" ;;
    *)         printf '%s' "$NEUTRAL_FG" ;;
  esac
}

# Five colours ramped from the primary to the secondary, for the Claude Code
# status line's five bubbles (model, effort, 5h, 7d, context). Interpolated in
# HSL along the SHORTER hue arc, so green->orange travels through yellow rather
# than through the grey midpoint a straight RGB blend would give.
#
# Lightness is floored at 0.50 on the way out: the bubbles carry black text, so
# a dark accent has to be lifted or the label stops being readable (black on
# L=0.25 is ~2.5:1). Nothing is capped from above -- lighter only helps here --
# and saturation is passed through untouched, so picking the silver swatch
# gives grey pills rather than invented colour.
claude_ramp() {
  local p="${PRIMARY#\#}" s="${SECONDARY#\#}"
  awk -v p="$p" -v s="$s" -v n=5 '
    function hex(x, i) { return strtonum("0x" substr(x, i, 2)) / 255 }
    function mx(a, b, c) { return a > b ? (a > c ? a : c) : (b > c ? b : c) }
    function mn(a, b, c) { return a < b ? (a < c ? a : c) : (b < c ? b : c) }
    function torgb(hh, ss, ll, out,   q, pp) {          # HSL -> "r;g;b"
      if (ss == 0) { out = int(ll * 255 + 0.5); return out ";" out ";" out }
      q = ll < 0.5 ? ll * (1 + ss) : ll + ss - ll * ss
      pp = 2 * ll - q
      return int(chan(pp, q, hh + 1/3) * 255 + 0.5) ";" \
             int(chan(pp, q, hh)       * 255 + 0.5) ";" \
             int(chan(pp, q, hh - 1/3) * 255 + 0.5)
    }
    function chan(pp, q, t) {
      if (t < 0) t += 1; if (t > 1) t -= 1
      if (t < 1/6) return pp + (q - pp) * 6 * t
      if (t < 1/2) return q
      if (t < 2/3) return pp + (q - pp) * (2/3 - t) * 6
      return pp
    }
    function tohsl(x, arr,   r, g, b, M, m, d, h, sat, l) {
      r = hex(x, 1); g = hex(x, 3); b = hex(x, 5)
      M = mx(r, g, b); m = mn(r, g, b); d = M - m; l = (M + m) / 2
      if (d == 0) { h = 0; sat = 0 }
      else {
        sat = l > 0.5 ? d / (2 - M - m) : d / (M + m)
        if (M == r)      h = ((g - b) / d + (g < b ? 6 : 0)) / 6
        else if (M == g) h = ((b - r) / d + 2) / 6
        else             h = ((r - g) / d + 4) / 6
      }
      arr[0] = h; arr[1] = sat; arr[2] = l
    }
    BEGIN {
      tohsl(p, a); tohsl(s, b)
      dh = b[0] - a[0]
      if (dh >  0.5) dh -= 1                     # shorter way round the wheel
      if (dh < -0.5) dh += 1
      for (i = 0; i < n; i++) {
        t = (n == 1) ? 0 : i / (n - 1)
        h = a[0] + t * dh; if (h < 0) h += 1; if (h > 1) h -= 1
        sat = a[1] + t * (b[1] - a[1])
        l   = a[2] + t * (b[2] - a[2])
        if (l < 0.50) l = 0.50
        printf "%s%s", torgb(h, sat, l), (i < n - 1 ? " " : "\n")
      }
    }'
}

derive() {
  PRIMARY_DIM="$(darken "$PRIMARY" 50)"
  MACHINE_LOWER="${MACHINE,,}"
  # Not prompted for: the login name is a fact about the machine, not a taste.
  USER_NAME="${USER_NAME:-$(id -un 2>/dev/null || echo "${USER:-user}")}"

  # --- oh-my-posh accent placement ----------------------------------------------
  # Every accented part of the prompt names its own colour (primary, secondary
  # or neutral); this resolves each to a hex value, baked in here rather than
  # left as @PRIMARY@/@SECONDARY@ in the template so the .omp.json placeholders
  # stay a straight substitution either way.
  #
  # Answers written before per-component colours existed are migrated instead of
  # ignored, so re-running install.sh on an already-set-up machine reproduces
  # the look it had: the old ICON toggle meant secondary-or-neutral, TEXT meant
  # primary-or-neutral, and the single CHEVRON toggle meant primary/secondary
  # for ok/error or neutral for both.
  if [ -z "${OMP_ICON:-}" ] && [ -n "${OMP_COLOR_ICON:-}" ]; then
    [ "$OMP_COLOR_ICON" = 1 ] && OMP_ICON=secondary || OMP_ICON=neutral
  fi
  if [ -z "${OMP_TEXT:-}" ] && [ -n "${OMP_COLOR_TEXT:-}" ]; then
    [ "$OMP_COLOR_TEXT" = 1 ] && OMP_TEXT=primary || OMP_TEXT=neutral
  fi
  if [ -z "${OMP_CHEVRON_OK:-}" ] && [ -n "${OMP_COLOR_CHEVRON:-}" ]; then
    if [ "$OMP_COLOR_CHEVRON" = 1 ]; then
      OMP_CHEVRON_OK=primary; OMP_CHEVRON_ERROR="${OMP_CHEVRON_ERROR:-secondary}"
    else
      OMP_CHEVRON_OK=neutral; OMP_CHEVRON_ERROR="${OMP_CHEVRON_ERROR:-neutral}"
    fi
  fi

  OMP_ICON_MODE="${OMP_ICON_MODE:-fixed}"
  OMP_ICON="${OMP_ICON:-secondary}"
  OMP_TEXT="${OMP_TEXT:-primary}"
  OMP_CHEVRON_OK="${OMP_CHEVRON_OK:-primary}"
  OMP_CHEVRON_ERROR="${OMP_CHEVRON_ERROR:-secondary}"

  # The leading glyph has two colours because the template already has two
  # branches for it (a different glyph inside a Slurm job shell, keyed on
  # $SLURM_JOB_NAME). In "fixed" mode both branches get the chosen colour; in
  # "slurm" mode the glyph itself reports the job -- primary on a normal shell,
  # secondary once you are inside an allocation.
  if [ "$OMP_ICON_MODE" = slurm ]; then
    OMP_ICON_COLOR="$PRIMARY"
    OMP_ICON_COLOR_JOB="$SECONDARY"
  else
    OMP_ICON_COLOR="$(accent_hex "$OMP_ICON")"
    OMP_ICON_COLOR_JOB="$OMP_ICON_COLOR"
  fi
  OMP_TEXT_COLOR="$(accent_hex "$OMP_TEXT")"
  OMP_CHEVRON_FG="$(accent_hex "$OMP_CHEVRON_OK")"
  OMP_CHEVRON_ERR="$(accent_hex "$OMP_CHEVRON_ERROR")"

  # --- Claude Code status line ----------------------------------------------------
  # Its five bubbles used to be a fixed palette of their own; they are now the
  # primary -> secondary ramp, so that bar belongs to the same two colours as
  # everything else. As "r;g;b", which is the form the script's bubble() wants.
  read -r CLAUDE_MODEL_RGB CLAUDE_EFFORT_RGB CLAUDE_USAGE_RGB CLAUDE_WEEK_RGB CLAUDE_CTX_RGB \
    <<<"$(claude_ramp)"

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
  local CAP=$'' SEP=$'' SEP2=$''

  TMUX_STATUS_LEFT=""
  if [ "${SHOW_HOST:-1}" = 1 ]; then
    TMUX_STATUS_LEFT+="#[fg=$PRIMARY,bg=#000000]${CAP}#[fg=#ffffff,bg=#000000,bold] $MACHINE #[fg=#000000,bg=$PRIMARY]${SEP}"
  fi
  TMUX_STATUS_LEFT+='#(~/.tmux/other-sessions.sh)'

  # "#00000t0" below is the same deliberate typo the untouched original right side
  # had: it makes tmux drop that one style (invisible, since it only covers a
  # space) rather than paint a visible box -- see herdr-statusline/config.toml.in,
  # which spells the same spot correctly since its layout differs slightly.
  TMUX_STATUS_RIGHT="#[fg=$PRIMARY,bg=#000000]${SEP}#[fg=#ffffff,bg=#00000t0] "
  [ "${SHOW_GPU:-1}" = 1 ]   && TMUX_STATUS_RIGHT+='#(~/.tmux/gpu-status.sh)'
  [ "${SHOW_SLURM:-1}" = 1 ] && TMUX_STATUS_RIGHT+='#(~/.tmux/slurm-status.sh)'
  TMUX_STATUS_RIGHT+="#[fg=#000000,bg=$PRIMARY]${SEP}"
  if [ "${SHOW_DATETIME:-1}" = 1 ]; then
    TMUX_STATUS_RIGHT+="#[fg=#000000,bg=$PRIMARY,bold] %H:%M #[fg=#000000,bg=$PRIMARY,bold]${SEP2} %Y-%m-%d "
  fi
  TMUX_STATUS_RIGHT+="#[fg=$PRIMARY,bg=#000000]${SEP} "

  HSL_STATUS_LEFT=""
  if [ "${SHOW_HOST:-1}" = 1 ]; then
    HSL_STATUS_LEFT="#[fg=$PRIMARY,bg=#000000]${CAP}#[fg=$SECONDARY,bg=#000000,bold] ${USER_NAME}#[fg=#ffffff,bg=#000000,bold]@${MACHINE} #[fg=#000000,bg=$PRIMARY]${SEP}"
  fi

  HSL_STATUS_RIGHT="#[fg=$PRIMARY,bg=#000000]${SEP}#[fg=#ffffff,bg=#000000] "
  [ "${SHOW_GPU:-1}" = 1 ]   && HSL_STATUS_RIGHT+='#($HERDR_PLUGIN_CONFIG_DIR/gpu-status.sh)'
  [ "${SHOW_SLURM:-1}" = 1 ] && HSL_STATUS_RIGHT+='#($HERDR_PLUGIN_CONFIG_DIR/slurm-status.sh)'
  HSL_STATUS_RIGHT+="#[fg=#000000,bg=$PRIMARY]${SEP}"
  if [ "${SHOW_DATETIME:-1}" = 1 ]; then
    HSL_STATUS_RIGHT+="#[fg=#000000,bg=$PRIMARY,bold] %H:%M #[fg=#000000,bg=$PRIMARY,bold]${SEP2} %Y-%m-%d "
  fi
  HSL_STATUS_RIGHT+="#[fg=$PRIMARY,bg=#000000]${SEP} "
}

# --- emit mode ------------------------------------------------------------------
# Only when EXECUTED, not when sourced: print every derived value as one
# KEY=value line (no value can contain a newline), for tui/configure.py to read.
# The palette goes out as one name:hex-per-field line, same reason as above --
# one definition, two front-ends.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  PRIMARY="${PRIMARY:-#00ff00}"
  SECONDARY="${SECONDARY:-#ff7803}"
  MACHINE="${MACHINE:-machine}"
  derive
  printf 'PALETTE='
  for i in "${!PALETTE_HEX[@]}"; do printf '%s:%s ' "${PALETTE_NAMES[$i]}" "${PALETTE_HEX[$i]}"; done
  printf '\n'
  printf 'PALETTE_COLUMNS=%s\n' "$PALETTE_COLUMNS"
  for v in PRIMARY SECONDARY MACHINE PRIMARY_DIM MACHINE_LOWER USER_NAME NEUTRAL_FG \
           OMP_ICON_COLOR OMP_ICON_COLOR_JOB OMP_TEXT_COLOR OMP_CHEVRON_FG OMP_CHEVRON_ERR \
           CLAUDE_MODEL_RGB CLAUDE_EFFORT_RGB CLAUDE_USAGE_RGB CLAUDE_WEEK_RGB CLAUDE_CTX_RGB \
           TMUX_STATUS_LEFT TMUX_STATUS_RIGHT HSL_STATUS_LEFT HSL_STATUS_RIGHT; do
    printf '%s=%s\n' "$v" "${!v}"
  done
fi
