#!/usr/bin/env bash
# Re-record the GIFs in this directory with charmbracelet/vhs.
#
#   demo/record.sh              # all of the tapes
#   demo/record.sh setup cli    # just demo/setup.tape and demo/cli.tape
#
# Needs `vhs` on PATH, plus the two things it shells out to (`ttyd`, `ffmpeg`)
# and a headless Chromium it can find -- vhs renders the terminal in a browser.
# It also needs a Nerd Font installed: the prompt and both status bars are mostly
# powerline glyphs, and without one every tape records a wall of tofu.
#
# Every tape runs against a throwaway HOME ($DEMO_HOME) holding its own copy of
# the checkout, rebuilt from scratch here on each run. That is not tidiness --
# the tapes run install.sh and reset.sh for real, and pointing them at the
# machine you are recording on would reinstall it on camera.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DEMO_DIR/.." && pwd)"

export DEMO_DIR
# Short on purpose. install.sh prints absolute paths on both sides of every
# "Linked A -> B", and those lines are already near a terminal's width -- eleven
# characters here is about what a real /home/somebody costs, so the recording
# wraps roughly where a real run on a real machine would.
export DEMO_HOME="${DEMO_HOME:-/tmp/dfdemo}"
# Only so a take does not re-resolve Textual from scratch; harmless if unset.
export DEMO_UV_CACHE="${DEMO_UV_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/uv}"

# The answers every tape opens on: monokai green + yellow, which is what the
# repo's own templates are written around. Both have to be hexes that are
# actually IN the palette -- the grid marks "your accent is here" by hex lookup,
# so an off-palette value opens the setup tape with no marker to move.
DEMO_PRIMARY='#a6e22e'
DEMO_SECONDARY='#ffd866'
DEMO_MACHINE='proxima'

for bin in vhs ttyd ffmpeg; do
  command -v "$bin" >/dev/null || { echo "need $bin on PATH" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# The sandbox.
#
# $DEMO_HOME must not be a path anyone keeps anything in: this deletes it.
case "$DEMO_HOME" in
  "$HOME"|/|"") echo "refusing to use DEMO_HOME=$DEMO_HOME" >&2; exit 1 ;;
esac

# Rebuilt before every tape, not once per run. install.tape resets the sandbox
# and reinstalls, undo.tape uninstalls it, setup.tape saves different answers --
# so without this, what a tape recorded would depend on which tapes ran before
# it, and re-recording one GIF would not reproduce the one it replaced.
build_sandbox() {
echo "==> building $DEMO_HOME"
rm -rf "$DEMO_HOME"
mkdir -p "$DEMO_HOME/.local/bin"

# The working tree, not a clone: bin/ and any local edit have to come along, and
# a tape that recorded a stale HEAD would be worse than no tape. Committed inside
# the copy so the git segment in the prompt preview reads clean.
cp -a "$REPO" "$DEMO_HOME/dotfiles"
rm -rf "$DEMO_HOME/dotfiles/.generated" "$DEMO_HOME/dotfiles/demo/"*.gif
git -C "$DEMO_HOME/dotfiles" checkout -q -B demo
git -C "$DEMO_HOME/dotfiles" -c user.name=demo -c user.email=demo@localhost \
    add -A
git -C "$DEMO_HOME/dotfiles" -c user.name=demo -c user.email=demo@localhost \
    commit -qm "recording sandbox" || true
git -C "$DEMO_HOME/dotfiles" branch --unset-upstream 2>/dev/null || true

# uv and oh-my-posh are what install.sh fetches before it can ask anything, and
# watching two downloads is not what these videos are about. Seed them from the
# recording machine if they are there; otherwise the first tape fetches them,
# which is also correct, just slower.
for bin in uv oh-my-posh; do
  src="$(command -v "$bin" 2>/dev/null || true)"
  [ -n "$src" ] && cp "$src" "$DEMO_HOME/.local/bin/" || true
done

# A real file at a path install.sh takes over, so the backup machinery has
# something to show. Without this every tape reports "no backups", which is true
# of an empty HOME and true of nothing else.
printf '# my own tmux config, from before\nset -g prefix C-a\nset -g mouse on\n' \
  > "$DEMO_HOME/.tmux.conf"

echo "==> installing into the sandbox"
env -i HOME="$DEMO_HOME" \
       PATH="$DEMO_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
       UV_CACHE_DIR="$DEMO_UV_CACHE" TERM=xterm-256color \
    bash "$DEMO_HOME/dotfiles/install.sh" --no-tools --skip-uv -y \
      --primary "$DEMO_PRIMARY" --secondary "$DEMO_SECONDARY" \
      --machine "$DEMO_MACHINE" >/dev/null
}

# ---------------------------------------------------------------------------
tapes=("$@")
if [ ${#tapes[@]} -eq 0 ]; then
  tapes=(setup install cli undo)
fi

cd "$REPO"
for name in "${tapes[@]}"; do
  tape="$DEMO_DIR/${name%.tape}.tape"
  [ -r "$tape" ] || { echo "no such tape: $tape" >&2; exit 1; }
  build_sandbox
  echo "==> $name"
  vhs "$tape"
done

echo
ls -lh "$DEMO_DIR"/*.gif
