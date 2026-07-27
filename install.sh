#!/bin/bash
# Symlinks this repo's dotfiles into place. Safe to re-run.
# Existing real files at the target paths are backed up with a .bak suffix.
set -euo pipefail
DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# --- tmux ---
link "$DOTFILES/tmux/.tmux.conf" "$HOME/.tmux.conf"
mkdir -p "$HOME/.tmux"
link "$DOTFILES/tmux/other-sessions.sh" "$HOME/.tmux/other-sessions.sh"
link "$DOTFILES/tmux/slurm-status.sh" "$HOME/.tmux/slurm-status.sh"
chmod +x "$HOME/.tmux/other-sessions.sh" "$HOME/.tmux/slurm-status.sh"

# --- claude ---
mkdir -p "$HOME/.claude/themes"
link "$DOTFILES/claude/settings.json" "$HOME/.claude/settings.json"
link "$DOTFILES/claude/keybindings.json" "$HOME/.claude/keybindings.json"
link "$DOTFILES/claude/statusline-command.sh" "$HOME/.claude/statusline-command.sh"
chmod +x "$HOME/.claude/statusline-command.sh"
for f in "$DOTFILES"/claude/themes/*.json; do
  link "$f" "$HOME/.claude/themes/$(basename "$f")"
done

# --- oh-my-posh ---
mkdir -p "$HOME/.cache/oh-my-posh/themes"
link "$DOTFILES/oh-my-posh/albe-monokai2.omp.json" "$HOME/.cache/oh-my-posh/themes/albe-monokai2.omp.json"

# --- shell ---
link "$DOTFILES/shell/bashrc_functions" "$HOME/.bashrc_functions"
link "$DOTFILES/shell/profile" "$HOME/.profile"

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

echo ""
echo "Done. Notes:"
echo "  - conda init and any gcloud SDK sourcing are NOT included (machine-specific paths) — re-run"
echo "    'conda init bash' / the gcloud installer on this machine if needed."
echo "  - Workspace aliases (cluster-specific /anvme paths etc.) are intentionally excluded;"
echo "    keep those per-machine or in a separate per-project config."
echo "  - Open a new shell (or 'source ~/.bashrc') to pick up the changes."
