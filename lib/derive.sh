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
#   SHOW_HOST SHOW_GPU SHOW_TEMP SHOW_DISK DISK_MOUNTPOINT SHOW_SLURM SHOW_DATETIME
#   BAR_WIDTH BAR_COLOR
#   OMP_ICON_MODE OMP_ICON OMP_TEXT OMP_CHEVRON_OK OMP_CHEVRON_ERROR
#   CLAUDE_SWAP DASSH_SWAP LOGIN_START
#   (and the superseded OMP_COLOR_ICON / OMP_COLOR_TEXT / OMP_COLOR_CHEVRON and
#    HSL_LOGIN, which are migrated to the above when the new answers are absent)
# Sets:
#   PRIMARY_DIM MACHINE_LOWER USER_NAME
#   OMP_ICON_COLOR OMP_ICON_COLOR_JOB OMP_TEXT_COLOR OMP_CHEVRON_FG OMP_CHEVRON_ERR
#   OMP_PATH_COLOR OMP_TIME_COLOR OMP_PY_COLOR
#   OMP_GIT_CLEAN OMP_GIT_BEHIND OMP_GIT_AHEAD OMP_GIT_DIVERGED OMP_GIT_DIRTY
#   BAR_COLOR_HEX
#   CLAUDE_MODEL_RGB CLAUDE_EFFORT_RGB CLAUDE_USAGE_RGB CLAUDE_WEEK_RGB CLAUDE_CTX_RGB
#   CLAUDE_PRIMARY CLAUDE_SECONDARY CLAUDE_PRIMARY_SHIMMER CLAUDE_SECONDARY_SHIMMER
#   CLAUDE_MSG_BG CLAUDE_MSG_BG_HOVER CLAUDE_MEMORY_BG CLAUDE_SELECTION_BG
#   CLAUDE_TRACK_BG CLAUDE_BASH_BG
#   DASSH_PRIMARY DASSH_ACCENT
#   TMUX_STATUS_LEFT TMUX_STATUS_RIGHT HSL_STATUS_LEFT HSL_STATUS_RIGHT

# --- the palette offered by both front-ends -------------------------------------
# Lives here rather than in either front-end so the bash wizard and the Textual
# TUI cannot offer different swatches.
# Forty-eight, as six rows of eight -- and each row is one real, recognisable
# scheme rather than a bag of colours, so "which row" is itself a meaningful
# choice: pick the Catppuccin row and the whole machine reads Catppuccin.
#
# Only each scheme's ACCENT ramp is included, never its backgrounds or greys:
# the primary is used as a *background* with black text on it (the tmux and
# herdr bars, the Claude Code bubbles), so anything dark would be unreadable
# there. Every entry below clears that bar, with the near-whites (dracula/snow,
# nord/snow) as the deliberate low-saturation option -- accent_ramps() passes
# saturation through untouched, so those give grey pills rather than invented
# colour.
#
# Hexes are unique across all six rows, which is what lets the UI mark "this is
# your primary" / "this is your secondary" by looking a colour up in the grid.
PALETTE_ROWS=(monokai catppuccin dracula nord tokyonight neon)
PALETTE_NAMES=(
  # monokai -- this repo's own identity (Monokai Pro's accent ramp)
  green     mint      cyan      purple    pink      yellow    orange    peach
  # catppuccin mocha
  rosewater pink      mauve     red       peach     yellow    green     sky
  # dracula
  pink      purple    cyan      green     yellow    orange    red       snow
  # nord -- frost, then the warmer aurora half
  teal      ice       blue      snow      red       rust      sand      moss
  # tokyo night
  blue      cyan      green     teal      purple    red       orange    yellow
  # neon -- not a scheme so much as a register, and the one the defaults come from
  pink      magenta   purple    blue      cyan      green     yellow    orange
)
PALETTE_HEX=(
  '#a6e22e' '#a9dc76' '#78dce8' '#ab9df2' '#ff6188' '#ffd866' '#ff7803' '#fc9867'
  '#f5e0dc' '#f5c2e7' '#cba6f7' '#f38ba8' '#fab387' '#f9e2af' '#a6e3a1' '#89dceb'
  '#ff79c6' '#bd93f9' '#8be9fd' '#50fa7b' '#f1fa8c' '#ffb86c' '#ff5555' '#f8f8f2'
  '#8fbcbb' '#88c0d0' '#81a1c1' '#eceff4' '#bf616a' '#d08770' '#ebcb8b' '#a3be8c'
  '#7aa2f7' '#7dcfff' '#9ece6a' '#73daca' '#bb9af7' '#f7768e' '#ff9e64' '#e0af68'
  '#ff2d95' '#ff00ff' '#b026ff' '#00b3ff' '#00fff7' '#00ff00' '#fff700' '#ff6600'
)
# How the UI wraps them; kept here so both front-ends agree on the layout. It is
# also the row width the grouping above depends on -- eight per scheme.
PALETTE_COLUMNS=8

# ${var,,} is bash 4, and macOS ships bash 3.2 as /bin/bash -- which is the
# shell this file is sourced into there. tr is the exact stand-in for the ASCII
# these are ever asked to fold (hex digits, a hostname), at the cost of a fork,
# so call it once per value rather than once per comparison.
to_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Which scheme a flat index belongs to, and its "scheme/name" label. Both
# front-ends show that label rather than a bare hex, since "monokai / pink" says
# far more than "#ff6188".
palette_group_of() { printf '%s' "${PALETTE_ROWS[$(( $1 / PALETTE_COLUMNS ))]}"; }

# The index of a hex in the palette, or -1 for a custom colour. Only the needle
# is folded: every hex in PALETTE_HEX above is written lower-case, so folding
# each of the 48 in turn would be 48 forks to answer a question the table
# already answers.
palette_index() {
  local want i
  want="$(to_lower "$1")"
  for i in "${!PALETTE_HEX[@]}"; do
    [ "${PALETTE_HEX[$i]}" = "$want" ] && { printf '%s' "$i"; return 0; }
  done
  printf '%s' -1
}

# "  (monokai / pink)", or "  (custom)" -- for the prompts in both wizards.
palette_label() {
  local idx; idx="$(palette_index "$1")"
  if [ "$idx" -lt 0 ]; then printf '  (custom)'; return; fi
  printf '  (%s / %s)' "$(palette_group_of "$idx")" "${PALETTE_NAMES[$idx]}"
}

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
# The disk pill's mountpoint: an absolute path, substituted the same three
# places the machine name is, so the same conservative character set applies --
# plus "/", which a path obviously needs. Bounded to 48 characters, matching
# the UI's Input(max_length=48).
valid_mountpoint() { [[ "$1" =~ ^/[A-Za-z0-9._/-]{0,47}$ ]]; }
# The progress bars' width, in cells. Bounded well short of anything that could
# blow a pill past the space a status bar actually has.
valid_bar_width() { [[ "$1" =~ ^[0-9]{1,2}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 20 ]; }

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

# Everything ramped between the two accents, in one awk pass. Three lines out,
# each "<kind> <value> <value> ...":
#
#   claude  five stops, as "r;g;b" -- the Claude Code status line's bubbles
#                                     (model, effort, 5h, 7d, context)
#   omp     four stops, as hex     -- the oh-my-posh segments that report
#                                     something rather than carrying a language's
#                                     brand colour, in the order they are read
#                                     across the line: path, git, execution
#                                     time, python
#   git     five shades, as hex    -- that git stop, per branch state
#
# All interpolated in HSL along the SHORTER hue arc, so green->orange travels
# through yellow rather than through the grey midpoint a straight RGB blend
# would give.
#
# Lightness is floored on the way out, and by a DIFFERENT amount for each ramp,
# because the two lines use these colours for opposite jobs. The Claude bubbles
# carry black text, so a dark accent has to be lifted or the label stops being
# readable (black on L=0.25 is ~2.5:1) -- hence 0.50. Every oh-my-posh segment
# is a foreground on the theme's #212224 panel, where the floor is only about
# the colour itself staying visible against a near-black, so it can sit lower.
# Nothing is capped from above -- lighter only helps in both places -- and
# saturation is passed through untouched, so picking one of the near-white
# swatches (dracula/snow, nord/snow) gives grey pills and a grey prompt rather
# than invented colour.
#
# The git shades are the one thing here that is NOT a position on the accent
# ramp. They take the hue and saturation of the git stop and walk only
# LIGHTNESS, 0.45 -> 0.73 in five even steps, ordered by how much the tree wants
# doing about it: clean, behind, ahead, diverged, dirty. So the segment stays
# the one colour the rest of the prompt has agreed on and simply gets brighter
# the more there is to deal with -- quiet when there is nothing to do, loud when
# there is. Spending the whole primary->secondary ramp on those five states
# instead would read beautifully with two contrasting accents and then collapse
# into five near-identical colours the moment somebody picks two neighbours out
# of one palette row, at which point the segment stops reporting the state at
# all. Lightness is the one axis that survives every pair, including a primary
# and a secondary that are the same colour.
#
# One awk invocation and not three: the HSL conversions below are thirty lines
# of it, and derive() is re-run on every keystroke in the setup UI.
#
# NOTE FOR ANYONE ADDING A RAMP: the awk program is wrapped in single quotes, so
# **no comment inside it may contain an apostrophe** -- `Claude Code's` in one
# closes the program, and bash then tries to parse `for (i = 0; ...)` itself and
# dies with `syntax error near unexpected token '('` pointing at a line that is
# perfectly good awk. Every existing comment in there is apostrophe-free for this
# reason; prose that wants one belongs out here, like the paragraph below.
#
# The fourth ramp, "shimmer", is the pair of colours Claude Code's own UI theme
# pulses to while it is working. Its theme pairs most accented keys with a lighter
# "*Shimmer" partner -- permission/permissionShimmer, autoAccept/autoAcceptShimmer,
# promptBorder/promptBorderShimmer -- and overriding a base without its partner
# leaves the pulse flashing Claude Code's own blue over our accent, so both
# accents get one. See claude/themes/accent.json.in.
#
# +0.12 lightness is what Claude Code's own pairs use: #b1b9f9 -> #cfd7ff,
# #af87ff -> #d0b4ff and #888888 -> #a6a6a6 are all within a hundredth of it.
# Above 0.80 it goes the other way instead, because a shimmer is only doing its
# job if it DIFFERS from the base, and lightening one of the near-white swatches
# (dracula/snow, nord/snow) clips against white and pulses to a standstill. Down
# is as good as up there, and it is the same reasoning as the git band being
# centred on its stop rather than fixed: keep the contrast, whatever was picked.
#
# CLAUDE_SWAP turns round the two accents Claude Code paints its own UI with --
# the menus, the mode indicators, the command blocks and the answer text -- and
# nothing else. That is why it is a flag into awk rather than two swapped shell
# variables: "shimmer" and "tint" read their ends from it while "omp", "git" and
# "claude" go on running primary -> secondary. It exists because Claude Code is
# the one place the primary lands on a lot of text you read all day (permission
# prompts, the spinner, every inline code span in an answer) while the secondary
# only ever flags a mode, so the accent that reads best there is not always the
# one that reads best as a background.
#
# The "claude" ramp -- the status bar bubbles -- is deliberately outside it. A
# bar is read the way the tmux and hsl bars beside it are read, and turning one
# of the three round would make the row of them disagree about which accent
# comes first. This answer is about the colours INSIDE the program.
#
# The fifth ramp, "tint", is the filled blocks Claude Code draws BEHIND white
# text -- your own messages, a bash message, a # memory, a selection, the
# unfilled half of the usage bar. They are the accent hue at a fixed low
# lightness rather than a position on the ramp, because a background has one
# job (sit under text and stay legible) and the lightnesses upstream chose for
# them are already right: rgb(55,55,55) for a message block is L=0.22.
# Saturation is CAPPED at 0.40 rather than passed through, the only place in
# this file that does that: at L=0.22 a fully saturated accent stops being a
# tinted grey and becomes a colour, which is a background competing with the
# text on top of it. A grey accent still gives exactly upstream greys.
accent_ramps() {
  local p="${PRIMARY#\#}" s="${SECONDARY#\#}"
  # Hex is decoded by hand rather than with strtonum(), which is a gawk
  # extension: macOS's /usr/bin/awk is the one true awk and would abort with
  # "calling undefined function strtonum" -- taking the Claude Code status
  # line's colour ramp and half the prompt's with it. index() into a digit
  # string is POSIX awk.
  awk -v p="$p" -v s="$s" -v swap="${CLAUDE_SWAP:-0}" '
    function hex(x, i,   d, v) {
      v = 0
      for (d = 0; d < 2; d++)
        v = v * 16 + index("0123456789abcdef", tolower(substr(x, i + d, 1))) - 1
      return v / 255
    }
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
    function tohex(hh, ss, ll,   c) {                   # HSL -> "#rrggbb"
      split(torgb(hh, ss, ll), c, ";")
      return sprintf("#%02x%02x%02x", c[1], c[2], c[3])
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
    # Position t (0 = primary, 1 = secondary) along the ramp, into h/sat/l.
    function stop(t, floor) {
      h = a[0] + t * dh; if (h < 0) h += 1; if (h > 1) h -= 1
      sat = a[1] + t * (b[1] - a[1])
      l   = a[2] + t * (b[2] - a[2])
      if (l < floor) l = floor
    }
    BEGIN {
      tohsl(p, a); tohsl(s, b)
      dh = b[0] - a[0]
      if (dh >  0.5) dh -= 1                     # shorter way round the wheel
      if (dh < -0.5) dh += 1

      # Where the Claude Code UI takes its two accents from. cp is the ramp
      # position of the accent it calls primary and cs of the one it calls
      # secondary, so swap=1 runs those backwards along the same line. See the
      # CLAUDE_SWAP paragraph above the awk block -- and note what is NOT below:
      # the status line does not use these.
      cp = swap ? 1 : 0
      cs = swap ? 0 : 1

      # The status bar bubbles, and deliberately NOT swap-aware: it is a bar,
      # read the way the tmux and hsl bars beside it are read, and those two run
      # primary -> secondary. CLAUDE_SWAP is about the colours inside the
      # program -- the menus, the commands and the answer text.
      line = "claude"
      for (i = 0; i < 5; i++) { stop(i / 4, 0.50); line = line " " torgb(h, sat, l) }
      print line

      # Four stops, left to right across the prompt line. The second one is the
      # git segment: its hue and saturation are kept back to seed the shades
      # below, so the branch states and the rest of the prompt cannot drift
      # apart -- they are literally the same colour at different lightnesses.
      line = "omp"
      for (i = 0; i < 4; i++) {
        stop(i / 3, 0.45)
        if (i == 1) { gh = h; gs = sat; gl = l }
        line = line " " tohex(h, sat, l)
      }
      print line

      # clean, behind, ahead, diverged, dirty -- least to most to deal with,
      # over a lightness band centred on the lightness of the git stop. Pinning
      # the centre into [0.56, 0.78] is what keeps the band both readable on the
      # #212224 panel at the bottom and short of white at the top, whatever was
      # picked; a band at FIXED lightness would have done the first two jobs and
      # then turned the near-white swatches (dracula/snow, nord/snow) khaki,
      # since dragging a hue-60 near-white down to L=0.45 is exactly the
      # invented colour the rest of this file goes out of its way not to make.
      gc = gl; if (gc < 0.56) gc = 0.56; if (gc > 0.78) gc = 0.78
      line = "git"
      for (i = 0; i < 5; i++) line = line " " tohex(gh, gs, gc - 0.14 + i * 0.07)
      print line

      # The two shimmer partners. Reasoning is above the awk block, since it
      # cannot be written in here: an apostrophe would close the program.
      line = "shimmer"
      for (i = 0; i < 2; i++) {
        stop(i == 0 ? cp : cs, 0)          # Claude primary, then its secondary
        line = line " " tohex(h, sat, l > 0.80 ? l - 0.12 : l + 0.12)
      }
      print line

      # The filled blocks, in the order the emit list reads them: message,
      # message hovered, memory, selection, the empty half of the usage bar --
      # all from the accent Claude Code calls primary -- and then the bash
      # message block, from its secondary, so it sits with bashBorder around it.
      # Lightnesses are the ones upstream picked for these same five keys.
      stop(cp, 0); ph = h; ps = sat > 0.40 ? 0.40 : sat
      stop(cs, 0); sh = h; ss = sat > 0.40 ? 0.40 : sat
      print "tint " tohex(ph, ps, 0.22) " " tohex(ph, ps, 0.28) \
              " " tohex(ph, ps, 0.25) " " tohex(ph, ps, 0.31) \
              " " tohex(ph, ps, 0.38) " " tohex(sh, ss, 0.25)
    }'
}

derive() {
  PRIMARY_DIM="$(darken "$PRIMARY" 50)"
  MACHINE_LOWER="$(to_lower "$MACHINE")"
  # Not prompted for: the login name is a fact about the machine, not a taste.
  USER_NAME="${USER_NAME:-$(id -un 2>/dev/null || echo "${USER:-user}")}"

  # --- what opens when you open a terminal --------------------------------------
  # Three-way, and normalised here rather than defaulted in install.sh's own
  # defaults block, because it has a predecessor to migrate: HSL_LOGIN was the
  # boolean "start hsl at login", so a theme.env written before dasshboard
  # existed says HSL_LOGIN=1 and means LOGIN_START=herdr. Only migrated when the
  # new answer is genuinely unset -- same rule as the OMP_COLOR_* block below,
  # and the reason install.sh initialises LOGIN_START empty and calls derive()
  # once up front to normalise it.
  #
  # Anything unrecognised falls back to "none" rather than aborting the install.
  # This answer is the one that decides what a login does, so a typo in a
  # hand-edited theme.env must cost you an autostart, never a shell.
  if [ -z "${LOGIN_START:-}" ] && [ -n "${HSL_LOGIN:-}" ]; then
    [ "$HSL_LOGIN" = 1 ] && LOGIN_START=herdr || LOGIN_START=none
  fi
  case "${LOGIN_START:-}" in
    herdr|dasshboard|none) ;;
    *) LOGIN_START=none ;;
  esac

  # --- the progress bars' own answers --------------------------------------------
  # Shared by the GPU pill's two bars and the disk pill's one: which of the two
  # accents fills them, and how many cells wide they are. Same "fall back rather
  # than abort" rule as LOGIN_START above -- a typo in a hand-edited theme.env
  # must cost you a bar's width or colour, never the install.
  BAR_COLOR="${BAR_COLOR:-primary}"
  case "$BAR_COLOR" in
    primary|secondary) ;;
    *) BAR_COLOR=primary ;;
  esac
  BAR_COLOR_HEX="$(accent_hex "$BAR_COLOR")"

  BAR_WIDTH="${BAR_WIDTH:-8}"
  valid_bar_width "$BAR_WIDTH" || BAR_WIDTH=8

  DISK_MOUNTPOINT="${DISK_MOUNTPOINT:-/}"
  valid_mountpoint "$DISK_MOUNTPOINT" || DISK_MOUNTPOINT=/

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

  # --- the accent ramps -----------------------------------------------------------
  # One awk pass, three ramps out (see accent_ramps() above). The Claude bar's
  # five bubbles and the four reporting segments of the prompt all used to be
  # fixed palettes of their own; they are now positions between the two accents,
  # so every line on the screen belongs to the same two colours.
  #
  # The loop reads the three lines rather than calling three functions, which is
  # what makes it one fork. `while read ... done <<<` runs in this shell, not a
  # subshell, so the assignments below survive it.
  local ramp_kind ramp_rest
  while read -r ramp_kind ramp_rest; do
    case "$ramp_kind" in
      # As "r;g;b", which is the form the Claude script's bubble() wants.
      claude) read -r CLAUDE_MODEL_RGB CLAUDE_EFFORT_RGB CLAUDE_USAGE_RGB \
                      CLAUDE_WEEK_RGB CLAUDE_CTX_RGB <<<"$ramp_rest" ;;
      # The git stop is consumed inside awk (it seeds the shades on the next
      # line), so it goes into a throwaway here: nothing in the template wants
      # the un-shaded value, since even a clean tree is a state.
      omp)    read -r OMP_PATH_COLOR _ OMP_TIME_COLOR OMP_PY_COLOR <<<"$ramp_rest" ;;
      git)    read -r OMP_GIT_CLEAN OMP_GIT_BEHIND OMP_GIT_AHEAD \
                      OMP_GIT_DIVERGED OMP_GIT_DIRTY <<<"$ramp_rest" ;;
      # The pulse partners for Claude Code's own UI theme -- see the "shimmer"
      # block in accent_ramps() and claude/themes/accent.json.in.
      shimmer) read -r CLAUDE_PRIMARY_SHIMMER CLAUDE_SECONDARY_SHIMMER <<<"$ramp_rest" ;;
      # The blocks Claude Code fills behind text, same file. Backgrounds, so
      # these are the only accent-derived colours here that are capped rather
      # than passed through -- see the "tint" paragraph in accent_ramps().
      tint)    read -r CLAUDE_MSG_BG CLAUDE_MSG_BG_HOVER CLAUDE_MEMORY_BG \
                       CLAUDE_SELECTION_BG CLAUDE_TRACK_BG CLAUDE_BASH_BG <<<"$ramp_rest" ;;
    esac
  done <<<"$(accent_ramps)"

  # Claude Code's own two accents, which are this machine's two accents unless
  # CLAUDE_SWAP says otherwise. Resolved here rather than left as @PRIMARY@ /
  # @SECONDARY@ in claude/themes/accent.json.in for the same reason the OMP_*
  # colours are: one assembly, and the template stays a straight substitution.
  # The five ramps above already read their ends from the same answer, so the
  # theme, the status line bubbles, the shimmers and the tints cannot disagree
  # about which way round Claude Code is.
  CLAUDE_SWAP="${CLAUDE_SWAP:-0}"
  if [ "$CLAUDE_SWAP" = 1 ]; then
    CLAUDE_PRIMARY="$SECONDARY"; CLAUDE_SECONDARY="$PRIMARY"
  else
    CLAUDE_PRIMARY="$PRIMARY";   CLAUDE_SECONDARY="$SECONDARY"
  fi

  # dasshboard's own two colours. Its config calls them "primary" and "accent",
  # and install.sh now writes this machine's answer straight into them --
  # patching just those two keys of its [theme] table in place rather than
  # rendering the whole file, since the rest of it (tiles, hosts, sections) is
  # dasshboard's own persistent state, not ours to own. DASSH_SWAP turns them
  # round the same way CLAUDE_SWAP does for Claude Code's UI and for the same
  # reason: dasshboard's "primary" paints the chrome you read all the time
  # (the wordmark, section titles, hairlines) while "accent" only highlights
  # the selected tile, so which of the two reads best in each role is not
  # always the one this machine calls primary.
  DASSH_SWAP="${DASSH_SWAP:-0}"
  if [ "$DASSH_SWAP" = 1 ]; then
    DASSH_PRIMARY="$SECONDARY"; DASSH_ACCENT="$PRIMARY"
  else
    DASSH_PRIMARY="$PRIMARY";   DASSH_ACCENT="$SECONDARY"
  fi

  # --- status line assembly -------------------------------------------------------
  # tmux's status bar and hsl's (bin/hsl, the herdr wrapper) are meant to look
  # identical (see CLAUDE.md), so both are assembled here from the same
  # SHOW_* toggles rather
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
  # space) rather than paint a visible box -- the hsl half below spells the same
  # spot correctly, since its layout differs slightly.
  TMUX_STATUS_RIGHT="#[fg=$PRIMARY,bg=#000000]${SEP}#[fg=#ffffff,bg=#00000t0] "
  [ "${SHOW_GPU:-1}" = 1 ]   && TMUX_STATUS_RIGHT+='#(~/.tmux/gpu-status.sh)'
  [ "${SHOW_DISK:-1}" = 1 ]  && TMUX_STATUS_RIGHT+='#(~/.tmux/disk-status.sh)'
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

  # The same two scripts the tmux bar above calls, at the same paths. They used
  # to be reached through $HERDR_PLUGIN_CONFIG_DIR, because the herdr-statusline
  # plugin exported only that to its `#(...)` commands and so the scripts had to
  # be linked into its config dir. bin/hsl runs a tmux server we configure
  # ourselves, so that constraint is gone and both bars can name one path -- one
  # fewer way for them to drift, and one fewer copy of each script to link.
  HSL_STATUS_RIGHT="#[fg=$PRIMARY,bg=#000000]${SEP}#[fg=#ffffff,bg=#000000] "
  [ "${SHOW_GPU:-1}" = 1 ]   && HSL_STATUS_RIGHT+='#(~/.tmux/gpu-status.sh)'
  [ "${SHOW_DISK:-1}" = 1 ]  && HSL_STATUS_RIGHT+='#(~/.tmux/disk-status.sh)'
  [ "${SHOW_SLURM:-1}" = 1 ] && HSL_STATUS_RIGHT+='#(~/.tmux/slurm-status.sh)'
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
  # name:hex:scheme per field -- the scheme is what lets the UI label each row.
  printf 'PALETTE='
  for i in "${!PALETTE_HEX[@]}"; do
    printf '%s:%s:%s ' "${PALETTE_NAMES[$i]}" "${PALETTE_HEX[$i]}" "$(palette_group_of "$i")"
  done
  printf '\n'
  printf 'PALETTE_ROWS=%s\n' "${PALETTE_ROWS[*]}"
  printf 'PALETTE_COLUMNS=%s\n' "$PALETTE_COLUMNS"
  for v in PRIMARY SECONDARY MACHINE PRIMARY_DIM MACHINE_LOWER USER_NAME NEUTRAL_FG \
           OMP_ICON_COLOR OMP_ICON_COLOR_JOB OMP_TEXT_COLOR OMP_CHEVRON_FG OMP_CHEVRON_ERR \
           OMP_PATH_COLOR OMP_TIME_COLOR OMP_PY_COLOR \
           OMP_GIT_CLEAN OMP_GIT_BEHIND OMP_GIT_AHEAD OMP_GIT_DIVERGED OMP_GIT_DIRTY \
           BAR_COLOR_HEX \
           CLAUDE_MODEL_RGB CLAUDE_EFFORT_RGB CLAUDE_USAGE_RGB CLAUDE_WEEK_RGB CLAUDE_CTX_RGB \
           CLAUDE_PRIMARY CLAUDE_SECONDARY \
           CLAUDE_PRIMARY_SHIMMER CLAUDE_SECONDARY_SHIMMER \
           CLAUDE_MSG_BG CLAUDE_MSG_BG_HOVER CLAUDE_MEMORY_BG \
           CLAUDE_SELECTION_BG CLAUDE_TRACK_BG CLAUDE_BASH_BG \
           DASSH_PRIMARY DASSH_ACCENT \
           TMUX_STATUS_LEFT TMUX_STATUS_RIGHT HSL_STATUS_LEFT HSL_STATUS_RIGHT; do
    printf '%s=%s\n' "$v" "${!v}"
  done
fi
