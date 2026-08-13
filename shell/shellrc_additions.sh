#!/bin/bash
# Personal shell additions, synced across machines via dotfiles.
#
# Sourced from the tail of ~/.bashrc AND of ~/.zshrc: macOS logs you into zsh,
# most Linux boxes into bash, and the aliases, PATH and prompt have to be the
# same on both. So this is ONE file for both shells, and everything that
# genuinely differs branches on $DOTFILES_SHELL below rather than assuming bash.
#
# It is also read by bash 3.2 (macOS's /bin/bash), so no bash 4 syntax here --
# no ${var,,}, no declare -A, no mapfile. See CLAUDE.md.
#
# Keep this free of anything machine-specific (cluster paths, workspace
# aliases, conda/gcloud init).

#===============================================================================================================================
### WHICH SHELL IS READING THIS
#===============================================================================================================================
# From the shell's own version variable, not from $SHELL (that is the LOGIN
# shell, which says nothing about the shell you are actually in -- `bash` typed
# inside zsh would get zsh's answer) and not from $0 (which is "-zsh", "zsh",
# "bash" or "-bash" depending on how the shell was started).
if [ -n "${ZSH_VERSION:-}" ]; then
  DOTFILES_SHELL=zsh
  DOTFILES_RC="$HOME/.zshrc"
elif [ -n "${BASH_VERSION:-}" ]; then
  DOTFILES_SHELL=bash
  DOTFILES_RC="$HOME/.bashrc"
else
  # dash/ash/ksh, sourcing this through ~/.profile. Everything POSIX below still
  # applies; the interactive extras are skipped by the case branches.
  DOTFILES_SHELL=sh
  DOTFILES_RC="$HOME/.profile"
fi
# Interactive or not, spelled the POSIX way -- zsh sets $- as well, and its
# interactive shells carry the same "i" bash's do, so one test covers both.
case $- in
  *i*) DOTFILES_INTERACTIVE=1 ;;
  *)   DOTFILES_INTERACTIVE=0 ;;
esac

#===============================================================================================================================
### WANDB
#===============================================================================================================================
wbclean() {
  wandb cache cleanup 1
  wandb artifact cache cleanup .
}
#===============================================================================================================================

#===============================================================================================================================
### ALIASES
#===============================================================================================================================
# The two rc aliases follow the shell you are in: under zsh, "bashrc" opens
# ~/.zshrc and "rebash" re-sources it. The names are kept (muscle memory, and
# login-start.sh's guards talk about "rebash"); only what they point at moves.
alias bashrc="nano $DOTFILES_RC"
alias rebash="source $DOTFILES_RC"
alias cda="conda deactivate"
alias dspace="du -h . 2>/dev/null | grep '[0-9\.]\+G'"
alias wbr="pkill -f -u arota 'wandb-service'"
alias jn='jupyter-notebook --no-browser --ip=0.0.0.0 --port 8888 --NotebookApp.allow_origin="*" --NotebookApp.allow_remote_access=True --NotebookApp.disable_check_xsrf=True 2>&1 | rg --line-buffered -om 1 "http://a.*" | { read -r url; printf "%s\n" "$url"; printf "\033]52;c;%s\a" "$(printf "%s" "$url" | base64 | tr -d "\n")" > /dev/tty; }'
alias copy='printf "\e]52;c;$(base64 | tr -d \"\n\")\a"'

# The synced shell functions (syncop, so far). install.sh links the repo's copy
# at ~/.bashrc_functions and nothing else reads it, so it is sourced here -- a
# file installed into $HOME that no shell ever looks at is just litter.
[ -f "$HOME/.bashrc_functions" ] && . "$HOME/.bashrc_functions"
#===============================================================================================================================

#===============================================================================================================================
### PATH (must be before oh-my-posh/zoxide so they are found on first load)
#===============================================================================================================================
[ -f "$HOME/.local/bin/env" ] && . "$HOME/.local/bin/env"
export PATH="$HOME/.local/bin:$PATH"
# uv's install directory, as install.sh actually found it. Usually the line
# above already covers it; this is what makes it permanent on a machine where uv
# went somewhere else (UV_INSTALL_DIR / XDG_BIN_HOME). install.sh writes it.
[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/uv-env.sh" ] \
  && . "${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/uv-env.sh"
# Same idea for everything the tools phase installed: install.sh writes this
# with the directories those tools actually landed in. Most are already covered
# by the lines here; this is what picks up the ones that move per machine --
# Homebrew's prefix above all, which also needs more than PATH (MANPATH,
# HOMEBREW_PREFIX), hence a full `brew shellenv` rather than a directory.
[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/tools-env.sh" ] \
  && . "${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/tools-env.sh"
export PATH="$HOME/.cargo/bin:$PATH"
export PATH="$HOME/bin:$PATH"
export PATH="$HOME/local/bin:$PATH"
export PATH="$HOME/.local/nvim/bin:$PATH"

#===============================================================================================================================
### OH-MY-POSH
#===============================================================================================================================
export POSH_PATH="$HOME/.cache/oh-my-posh/themes/albe-monokai2.omp.json"
if [ "$DOTFILES_INTERACTIVE" = 1 ]; then
  # oh-my-posh emits a different init per shell (bash's hangs off PROMPT_COMMAND,
  # zsh's off precmd hooks), so it has to be told which one it is talking to.
  # Only the two this file supports: there is no `oh-my-posh init sh`.
  #
  # And only a bash that can read it. oh-my-posh's bash init uses `[[ -v VAR ]]`,
  # which is bash 4.2 and later -- macOS's /bin/bash is 3.2, where eval'ing it
  # is a syntax error printed at every single shell start, with a half-defined
  # prompt behind it. Skipped there instead: a plain prompt, and everything else
  # in this file still loads. zsh is the default login shell on that machine
  # anyway, and its init has no such problem.
  _dot_omp=0
  case "$DOTFILES_SHELL" in
    zsh) _dot_omp=1 ;;
    bash)
      if [ "${BASH_VERSINFO[0]}" -gt 4 ] \
         || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
        _dot_omp=1
      fi
      ;;
  esac
  if [ "$_dot_omp" = 1 ] && command -v oh-my-posh >/dev/null 2>&1; then
    eval "$(oh-my-posh init "$DOTFILES_SHELL" --config "$POSH_PATH")"
  fi
  unset _dot_omp
  #=============================================================================================================================

  #=============================================================================================================================
  ### NAVIGATION / FILESYSTEM UTILITIES
  #=============================================================================================================================
  # Up/down searches the history for what you have already typed rather than
  # walking it blindly. Same behaviour, two unrelated mechanisms: bash binds
  # readline functions, zsh binds ZLE widgets.
  if [ "$DOTFILES_SHELL" = bash ]; then
    bind '"\e[A": history-search-backward'
    bind '"\e[B": history-search-forward'
  elif [ "$DOTFILES_SHELL" = zsh ]; then
    # zsh's history-beginning-search-* are the widgets that behave like bash's
    # history-search-* (match the text up to the cursor); zsh's own
    # history-search-* means something else. Both the normal and the application
    # cursor-key sequences are bound, because a terminal left in application
    # mode -- which is what tmux and most full-screen TUIs do -- sends ^[OA
    # rather than ^[[A, and only binding one of the two makes the arrows work
    # everywhere except right after quitting herdr.
    bindkey '^[[A' history-beginning-search-backward
    bindkey '^[OA' history-beginning-search-backward
    bindkey '^[[B' history-beginning-search-forward
    bindkey '^[OB' history-beginning-search-forward

    # zsh has NO completion at all until compinit runs, and nothing else runs it
    # for you (bash gets /etc/bash_completion.d from the distro). Skipped when a
    # framework has already done it -- oh-my-zsh and prezto both define compdef.
    # -u rather than an "insecure directories" prompt at every single login:
    # group-writable completion dirs are the norm on shared machines and HPC.
    if ! typeset -f compdef >/dev/null 2>&1; then
      mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
      autoload -Uz compinit
      compinit -u -d "${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompdump"
    fi
  fi

  case "$DOTFILES_SHELL" in
    bash|zsh)
      command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init "$DOTFILES_SHELL" --cmd cd)"
      ;;
  esac

  # fzf's key bindings and completion. Its own installer writes ~/.fzf.bash and
  # ~/.fzf.zsh; a packaged fzf (apt, brew) never runs that installer and since
  # 0.48 can print the same thing itself -- hence the fallback, which is a no-op
  # on an older fzf that has no such flag.
  if [ -f "$HOME/.fzf.$DOTFILES_SHELL" ]; then
    . "$HOME/.fzf.$DOTFILES_SHELL"
  elif command -v fzf >/dev/null 2>&1; then
    case "$DOTFILES_SHELL" in
      bash|zsh) eval "$(fzf --"$DOTFILES_SHELL" 2>/dev/null)" ;;
    esac
  fi
fi
# eza takes over ls, identically in bash and zsh, by exactly one mechanism: a
# function, with no alias of the same name left standing beside it. The three
# oddities below are each load-bearing, and all of them come from one fact:
#
#   BOTH SHELLS EXPAND ALIASES WHEN A COMMAND IS *READ*, NOT WHEN IT RUNS.
#
# Debian and Ubuntu's stock ~/.bashrc carries `alias ls='ls --color=auto'`, and
# this file is sourced from the tail of that very file -- so an `ls` alias is
# normally in effect by the time the shell reads these lines. Written plainly as
# `ls() { ...; }`, the parser sees `ls --color=auto ()` and dies with `syntax
# error near unexpected token '('`. That is not cosmetic: a syntax error in a
# sourced file abandons **everything after it**, so the PATH additions, the
# prompt, zoxide, fzf and the login autostart below all silently stop happening
# too -- a broken `ls` is the least of what you notice. zsh fails the same way and
# only reports it better ("defining function based on alias `ls'").
#
# So:
#
# - the definition goes through `eval`, which is what keeps the text `ls()` out of
#   the parse of this file entirely. It is parsed when eval runs instead, by which
#   point the unalias on the line above has already executed;
# - the unalias is INSIDE the `if`, which is only safe *because* of the eval. On
#   its own it would be useless here: an `if ... fi` is read as a single compound
#   command, so an unalias within it runs long after a bare `ls()` beside it was
#   parsed. Hoisting it out of the block instead would work for the eza case and
#   break the other one, below;
# - and nothing at all happens when eza is absent. That is the case the obvious
#   fix gets wrong: parsing is unconditional, so a bare `ls()` inside this block
#   is a syntax error on a machine with the stock alias and no eza -- a plain
#   Ubuntu box, or any machine where eza has not installed yet -- even though the
#   branch is never taken. Unaliasing unconditionally to dodge that would throw
#   away an `ls --color=auto` we did not put there and cannot faithfully restore
#   (bash and zsh even print `alias ls` back in different formats). Leaving it
#   untouched is both simpler and more honest.
#
# "$@" comes LAST so that what you type wins, which for the flags eza resolves
# last-one-wins is a real difference rather than a stylistic one: `ls --level=3`
# on the old spelling (`eza "$@" -lh --tree --level=1 ...`) was silently ignored,
# because the default --level=1 was appended *after* it. Depth 3 of this checkout
# is 56 lines against the default's 14, and you got 14. (Not every flag behaves
# that way -- -1 loses to -l whatever the order -- but the ones that do only work
# in this direction.)
#
# --icons=auto is spelled out rather than left bare, and only this order makes
# that necessary: its value is OPTIONAL (`--icons [<WHEN>]`), so a bare --icons
# sitting immediately before "$@" swallows the first thing after it and `ls .`
# dies with `error: invalid value '.' for '--icons [<WHEN>]'`. =auto is also what
# the bare flag already meant -- eza reads plain --icons as auto, NOT as always --
# so icons stay on a terminal and out of a pipe exactly as before. Any other
# default that grew an optional value would need the same care; -lh, --tree,
# --level=1 and --git cannot, having either no value or a glued one.
if command -v eza >/dev/null 2>&1; then
  unalias ls 2>/dev/null
  eval 'ls() { eza -lh --tree --level=1 --git --icons=auto "$@"; }'
fi
# Debian and Ubuntu ship these two under different names, because the obvious
# ones were already taken by unrelated packages. Aliased only when the real
# name is missing, so a machine that got them from cargo/brew (where they are
# called bat and fd) is left alone -- and so the alias never shadows a newer
# binary that install.sh put in ~/.local/bin or ~/.cargo/bin.
command -v bat >/dev/null 2>&1 || { command -v batcat >/dev/null 2>&1 && alias bat="batcat"; }
command -v fd  >/dev/null 2>&1 || { command -v fdfind >/dev/null 2>&1 && alias fd="fdfind"; }
#===============================================================================================================================
#===============================================================================================================================
### TMUX
#===============================================================================================================================
# TERM is only set when the terminfo database actually HAS that entry. macOS's
# is ancient (ncurses 5.7) and carries no tmux-256color at all, so exporting it
# there points every curses program at a terminal it cannot look up -- "terminal
# database is inadequate", and vim/less/htop refuse to start. Inside tmux this
# is a no-op either way: tmux sets TERM itself from default-terminal.
if infocmp tmux-256color >/dev/null 2>&1; then
  export TERM=tmux-256color
fi
export COLORTERM=truecolor
export TMUX_TMPDIR="$HOME/.tmux"
tma() {
  tmux attach -t$1
}
tmc() {
  local name=$1
  local tag=${name:0:1}
  tmux new-session -s "$name" -t "$tag"
}
alias tml="tmux ls"
#===============================================================================================================================

# ---- User Jupyter runtime (no systemd /run) ----
export XDG_RUNTIME_DIR="$HOME/.xdg/runtime"
export JUPYTER_RUNTIME_DIR="$HOME/.local/share/jupyter/runtime"
export IPYTHONDIR="$HOME/.ipython"
export XDG_CACHE_HOME="$HOME/.cache"
# -----------------------------------------------

export no_proxy=localhost,127.0.0.1
export NO_PROXY=localhost,127.0.0.1
unset http_proxy
unset https_proxy
unset HTTP_PROXY
unset HTTPS_PROXY

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
# nvm's completion file is written in bash and calls `complete`, so it is bash
# only: sourced from zsh it is an error per line, not a degraded completion.
[ "$DOTFILES_SHELL" = bash ] && [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

#===============================================================================================================================
### LOGIN AUTOSTART  (herdr, or a dasshboard home screen, if that was asked for)
#===============================================================================================================================
# LAST, deliberately: when it does start something it blocks until you quit it,
# so anything after this line would not run until then. install.sh renders it
# from shell/login-start.sh.in with the answer baked in, so when the answer is
# "none" this is a file that returns on its second line. NO_LOGIN_START=1 skips
# it whatever the answer is.
#
# The [ -f ] is what makes the window between `git pull` and the install run
# harmless: this file is symlinked straight out of the repo, so it is renamed the
# moment you pull, while login-start.sh only appears when install.sh next
# renders it. Until then the autostart no-ops -- which is the right way for this
# particular file to be missing. (It was hsl-login.sh before the answer grew a
# third value; install.sh unlinks that one on the way past.)
if [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/login-start.sh" ]; then
  . "${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/login-start.sh"
fi
