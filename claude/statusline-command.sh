#!/usr/bin/env bash
# Claude Code status line — oh-my-posh "bubbles" look: separate rounded
# pills rendered with CaskaydiaCove NFM Nerd Font glyphs and 24-bit truecolor.
#
#   ( model )  ( effort )  ( 5h bar )  ( 7d bar )  ( context bar )
#
# Each bubble is a filled segment capped by the rounded half-circle glyphs
# U+E0B6 () / U+E0B4 (), drawn in the bubble's colour on the default
# terminal background so the pills float separately.
#
# Fields come straight from the statusLine stdin JSON:
#   model    .model.display_name
#   effort   .effort.level                              (low|medium|high|xhigh|max)
#   5h       .rate_limits.five_hour.used_percentage     (fallback: .cost.total_cost_usd)
#   7d       .rate_limits.seven_day.used_percentage
#   context  .context_window.used_percentage

input=$(cat)

model_raw=$(echo "$input" | jq -r '.model.display_name // "Claude"')

# Map verbose display names to short family labels.
short_model_name() {
  local lower=${1,,}
  case "$lower" in
    *fable*)  printf 'Fable' ;;
    *opus*)   printf 'Opus' ;;
    *sonnet*) printf 'Sonnet' ;;
    *haiku*)  printf 'Haiku' ;;
    *)        printf '%s' "$1" ;;
  esac
}
model=$(short_model_name "$model_raw")
effort=$(echo "$input" | jq -r '.effort.level // empty')
ctx=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
rl5h=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
rl5h_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
rl7d=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
rl7d_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')

# --- symbols (plain Unicode, no Nerd Font PUA — renders in any monospace font) ---
CAP_L=''    # U+25D6 left half circle  -> rounded pill cap
CAP_R=''    # U+25D7 right half circle -> rounded pill cap
I_MODEL='◆'  # U+25C6 diamond   -> model
I_EFFORT='▲' # U+25B2 triangle  -> effort/level
I_USAGE='● '  # U+25CF disc      -> 5h usage
I_WEEK='◷ '   # U+25F7 quarter   -> weekly usage
I_CTX='■ '    # U+25A0 square    -> context
I_RESET='↻'  # U+21BB reload    -> reset time
BAR_FILLED='▰'  # U+25B0
BAR_EMPTY='▱'   # U+25B1
BAR_W=8

# progress_bar <percentage> [width]  -> ▰▰▱▱… (no trailing newline)
progress_bar() {
  local pct=$1 width=${2:-$BAR_W} filled empty i bar=""
  if [ -z "$pct" ]; then
    for ((i = 0; i < width; i++)); do bar+="$BAR_EMPTY"; done
    printf '%s' "$bar"
    return
  fi
  filled=$(awk -v p="$pct" -v w="$width" 'BEGIN {
    f = int(p * w / 100 + 0.5)
    if (f > w) f = w
    if (f < 0) f = 0
    print f
  }')
  empty=$((width - filled))
  for ((i = 0; i < filled; i++)); do bar+="$BAR_FILLED"; done
  for ((i = 0; i < empty; i++)); do bar+="$BAR_EMPTY"; done
  printf '%s' "$bar"
}

# Parse resets_at (unix epoch or ISO-8601) into local _RESET_DATE, _RESET_DAY, _RESET_TIME.
parse_reset_ts() {
  local ts=$1
  [ -z "$ts" ] && return 1
  if [[ "$ts" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    _RESET_DATE=$(date -d "@${ts%.*}" +%Y-%m-%d 2>/dev/null) || return 1
    _RESET_DAY=$(date -d "@${ts%.*}" +%a 2>/dev/null)
    _RESET_TIME=$(date -d "@${ts%.*}" +%H:%M 2>/dev/null)
  else
    _RESET_DATE=$(date -d "$ts" +%Y-%m-%d 2>/dev/null) || return 1
    _RESET_DAY=$(date -d "$ts" +%a 2>/dev/null)
    _RESET_TIME=$(date -d "$ts" +%H:%M 2>/dev/null)
  fi
}

reset_suffix() {
  local ts=$1
  parse_reset_ts "$ts" || return
  [ -n "$_RESET_TIME" ] && printf ' %s %s' "$I_RESET" "$_RESET_TIME"
}

# Weekly: always show weekday; append HH:MM only when reset is today.
weekly_reset_suffix() {
  local ts=$1 today
  parse_reset_ts "$ts" || return
  today=$(date +%Y-%m-%d)
  if [ "$_RESET_DATE" = "$today" ]; then
    printf ' %s %s %s' "$I_RESET" "$_RESET_DAY" "$_RESET_TIME"
  else
    printf ' %s %s' "$I_RESET" "$_RESET_DAY"
  fi
}

# --- assemble the text inside each bubble ---
[ -z "$effort" ] && effort="n/a"

if [ -n "$rl5h" ]; then
  usage=$(printf '%s5H %s %.0f%%%s' "$I_USAGE" "$(progress_bar "$rl5h")" "$rl5h" "$(reset_suffix "$rl5h_reset")")
elif [ -n "$cost" ]; then
  usage=$(printf '%s5H $%.2f' "$I_USAGE" "$cost")
else
  usage="${I_USAGE}—"
fi

if [ -n "$rl7d" ]; then
  weekly=$(printf '%s7D %s%s' "$I_WEEK" "$(progress_bar "$rl7d")" "$(weekly_reset_suffix "$rl7d_reset")")
else
  weekly="${I_WEEK}—"
fi

if [ -n "$ctx" ]; then
  ctxtxt=$(printf '%sCTX %s %.0f%%' "$I_CTX" "$(progress_bar "$ctx")" "$ctx")
else
  ctxtxt="${I_CTX}—"
fi

esc=$'\033'
R="${esc}[0m"

out=""
# bubble <fg "r;g;b"> <bg "r;g;b"> <text> : rounded cap, filled body, rounded cap
bubble() {
  local fg=$1 bg=$2 txt=$3
  # left cap (accent fg on black bg) + body (fg on bg) + right cap + trailing gap
  out+="${R}${esc}[48;2;0;0;0m${esc}[38;2;${bg}m${CAP_L}${esc}[48;2;${bg}m${esc}[38;2;${fg}m ${txt} ${R}${esc}[38;2;${bg}m${CAP_R}${R}"
}

bubble "0;0;0" "58;134;255" "${I_MODEL} ${model}"       # blue   model
bubble "0;0;0" "131;56;236" "${I_EFFORT} ${effort}"     # purple effort
bubble "0;0;0" "255;120;110" "${usage}"                   # pink   5h usage
bubble "0;0;0" "255;140;0" "${weekly}"                  # orange weekly
bubble "0;0;0" "6;214;160" "${ctxtxt}"                     # teal   context

printf '%s' "${out% }"
