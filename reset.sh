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

# A read loop rather than `mapfile -t`, which is bash 4: macOS ships 3.2. The
# `[ -n "$line" ]` in the condition is what picks up a final line with no
# trailing newline, which read returns non-zero for.
PATHS=()
while IFS= read -r line || [ -n "$line" ]; do
  PATHS+=("$line")
done < "$MANIFEST"

MARKER_START="# >>> dotfiles bashrc_additions >>>"
MARKER_END="# <<< dotfiles bashrc_additions <<<"
# install.sh appends a second, separate block to ~/.bash_profile when that file
# exists, since bash reads it INSTEAD of the ~/.profile this repo symlinks.
PROFILE_START="# >>> dotfiles bash_profile >>>"
PROFILE_END="# <<< dotfiles bash_profile <<<"
BASHRC_HAS_BLOCK=0
grep -qF "$MARKER_START" "$HOME/.bashrc" 2>/dev/null && BASHRC_HAS_BLOCK=1
PROFILE_HAS_BLOCK=0
grep -qF "$PROFILE_START" "$HOME/.bash_profile" 2>/dev/null && PROFILE_HAS_BLOCK=1

if [ "$ASSUME_YES" -eq 0 ]; then
  echo "This will remove ${#PATHS[@]} dotfiles-managed path(s) and restore any .bak"
  echo "found alongside them, plus strip the dotfiles block from ~/.bashrc if present."
  printf 'Continue? [y/N]: '
  read -r reply || reply=""
  # Spelled out rather than folded with ${reply,,}, which is bash 4; this script
  # has no lib to borrow a to_lower() from and it is two extra patterns.
  case "$reply" in
    y|Y|yes|YES|Yes) ;;
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

# `sed -i` in place is GNU-only: BSD sed takes a MANDATORY backup suffix after
# -i, so the same command line there reads the range as the suffix and deletes
# nothing (or destroys the file, depending on how the words fall). Filtering to
# a temp file and copying the CONTENT back is portable and, unlike a mv, keeps
# the original inode -- which matters because ~/.bashrc may well be a symlink or
# have permissions somebody chose.
strip_block() {
  local file="$1" start="$2" end="$3" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/dotfiles-reset.XXXXXX")"
  if sed "/^${start}\$/,/^${end}\$/d" "$file" > "$tmp"; then
    cat "$tmp" > "$file"
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

if [ "$BASHRC_HAS_BLOCK" -eq 1 ]; then
  strip_block "$HOME/.bashrc" "$MARKER_START" "$MARKER_END" \
    && echo "Removed the dotfiles block from ~/.bashrc"
fi

if [ "$PROFILE_HAS_BLOCK" -eq 1 ]; then
  strip_block "$HOME/.bash_profile" "$PROFILE_START" "$PROFILE_END" \
    && echo "Removed the dotfiles block from ~/.bash_profile"
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
echo "uv itself was left installed, and so was $XDG_CONFIG/dotfiles/uv-env.sh;"
echo "nothing sources that file any more (the ~/.bashrc block is gone), so it is"
echo "inert -- delete it and uv's install dir by hand if you want uv gone too."
echo "The same goes for everything the tools phase installed (oh-my-posh, herdr,"
echo "cargo, the uv tools, Neovim, ...) and for $XDG_CONFIG/dotfiles/tools-env.sh:"
echo "reset undoes this repo's CONFIG, not the software on the machine. Each tool"
echo "has its own uninstall (cargo uninstall, uv tool uninstall, brew uninstall,"
echo "apt remove, or just deleting the binary from ~/.local/bin)."
echo "'$DOTFILES/.generated' (rendered config) was left alone too; it's harmless"
echo "and gitignored, and gets rewritten (or you can rm -rf it) the next time"
echo "install.sh runs."
