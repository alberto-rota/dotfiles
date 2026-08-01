#!/bin/bash
# Undoes install.sh: removes every symlink/copy it made and restores whatever
# real file was there before, from the .bak link()/copy() saved. Safe to run
# even if install.sh only partially completed, and safe to re-run.
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XDG_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
MANIFEST="$XDG_CONFIG/dotfiles/manifest.txt"

ASSUME_YES=0
usage() {
  cat <<EOF
Usage: ./reset.sh [options]

Removes every path install.sh symlinked or copied into place (from
$MANIFEST), and restores the original file from its .bak if install.sh backed
one up when it first took over that path. Also strips the dotfiles block it
appended to ~/.bashrc.

  -y, --non-interactive Don't ask for confirmation.
  -h, --help             Show this message.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--non-interactive) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ ! -r "$MANIFEST" ]; then
  echo "No manifest at $MANIFEST -- has install.sh ever run on this machine? Nothing to do."
  exit 0
fi

mapfile -t PATHS < "$MANIFEST"

MARKER_START="# >>> dotfiles bashrc_additions >>>"
MARKER_END="# <<< dotfiles bashrc_additions <<<"
BASHRC_HAS_BLOCK=0
grep -qF "$MARKER_START" "$HOME/.bashrc" 2>/dev/null && BASHRC_HAS_BLOCK=1

if [ "$ASSUME_YES" -eq 0 ]; then
  echo "This will remove ${#PATHS[@]} dotfiles-managed path(s) and restore any .bak"
  echo "found alongside them, plus strip the dotfiles block from ~/.bashrc if present."
  printf 'Continue? [y/N]: '
  read -r reply || reply=""
  case "${reply,,}" in
    y|yes) ;;
    *) echo "Aborted; nothing was changed."; exit 1 ;;
  esac
fi

for dst in "${PATHS[@]}"; do
  [ -n "$dst" ] || continue
  if [ -L "$dst" ] || [ -e "$dst" ]; then
    rm -f "$dst"
  fi
  if [ -e "$dst.bak" ]; then
    mv "$dst.bak" "$dst"
    echo "Restored $dst from backup"
  else
    echo "Removed $dst (no backup -- there was nothing here before install.sh)"
  fi
done

if [ "$BASHRC_HAS_BLOCK" -eq 1 ]; then
  sed -i "/^${MARKER_START}\$/,/^${MARKER_END}\$/d" "$HOME/.bashrc"
  echo "Removed the dotfiles block from ~/.bashrc"
fi

if command -v herdr >/dev/null 2>&1; then
  if herdr plugin unlink herdr-workspace-prefix >/dev/null 2>&1; then
    echo "Unlinked herdr plugin herdr-workspace-prefix"
  fi
fi

rm -f "$MANIFEST"

echo ""
echo "Done. Theme answers at $XDG_CONFIG/dotfiles/theme.env were left alone --"
echo "remove that file too if you want the next install.sh to prompt from scratch."
echo "'$DOTFILES/.generated' (rendered config) was left alone too; it's harmless"
echo "and gitignored, and gets rewritten (or you can rm -rf it) the next time"
echo "install.sh runs."
