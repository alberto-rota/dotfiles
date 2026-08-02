#!/bin/bash
# Personal .bashrc additions, synced across machines via dotfiles.
# Sourced from the tail of ~/.bashrc — keep this file free of anything
# machine-specific (cluster paths, workspace aliases, conda/gcloud init).

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
alias bashrc="nano ~/.bashrc"
alias rebash="source ~/.bashrc"
alias cda="conda deactivate"
alias dspace="du -h . 2>/dev/null | grep '[0-9\.]\+G'"
alias wbr="pkill -f -u arota 'wandb-service'"
alias jn='jupyter-notebook --no-browser --ip=0.0.0.0 --port 8888 --NotebookApp.allow_origin="*" --NotebookApp.allow_remote_access=True --NotebookApp.disable_check_xsrf=True 2>&1 | rg --line-buffered -om 1 "http://a.*" | { read -r url; printf "%s\n" "$url"; printf "\033]52;c;%s\a" "$(printf "%s" "$url" | base64 | tr -d "\n")" > /dev/tty; }'
alias copy='printf "\e]52;c;$(base64 | tr -d \"\n\")\a"'
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
if [[ $- == *i* ]]; then
  command -v oh-my-posh >/dev/null 2>&1 && eval "$(oh-my-posh init bash --config "$POSH_PATH")"
  #=============================================================================================================================

  #=============================================================================================================================
  ### NAVIGATION / FILESYSTEM UTILITIES
  #=============================================================================================================================
  bind '"\e[A": history-search-backward'
  bind '"\e[B": history-search-forward'

  command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init bash --cmd cd)"
fi
[ -f ~/.fzf.bash ] && source ~/.fzf.bash
command -v eza >/dev/null 2>&1 && alias ls="eza $@ -lh --tree --level=1 --git --icons"

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
export TERM=tmux-256color
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
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
