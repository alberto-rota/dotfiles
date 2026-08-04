# Sourced by every tape in here, from inside a Hide block, as the first thing
# the recorded shell does.
#
# The point is that a tape drives a THROWAWAY HOME. These recordings run the
# real install.sh, the real setup UI and the real dotfiles CLI -- that is what
# makes them worth having -- so they must not be able to touch the machine doing
# the recording. record.sh builds $DEMO_HOME from scratch and exports it.
#
# PATH is deliberately narrow: $DEMO_HOME/.local/bin plus the system
# directories, and nothing of the recording user's own. Half of lib/tools.sh is
# a question about what is already on the machine, so leaving ~/.local/bin and
# ~/.cargo/bin out is what makes `dotfiles plan` show a plausible mix of
# "already installed" and "install" instead of one flat column of ticks.

[ -n "${DEMO_HOME:-}" ] || { echo "DEMO_HOME is unset -- run tapes via record.sh" >&2; return 1; }

export HOME="$DEMO_HOME"
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_DATA_HOME="$HOME/.local/share"
export TERM=xterm-256color
export COLORTERM=truecolor

# The setup UI is a uv script. Point it at the recording user's real uv cache so
# a take does not spend eight seconds re-resolving Textual.
[ -n "${DEMO_UV_CACHE:-}" ] && export UV_CACHE_DIR="$DEMO_UV_CACHE"

# Nothing here should think it is being run by an agent or inherit a checkout
# override from the shell that started vhs.
unset DOTFILES_DIR CLAUDECODE CLAUDE_CODE AI_AGENT

# A plain prompt: the recorded machine has not sourced its new ~/.bashrc yet, so
# claiming the oh-my-posh one here would be a lie about the state on screen.
export PS1='\[\e[38;2;117;113;94m\]$\[\e[0m\] '

cd "$HOME/dotfiles"
clear
