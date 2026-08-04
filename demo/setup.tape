# The setup UI: pick the two accents, name the machine, choose what goes in the
# status bars -- with the prompt, both bars, the Claude Code line and the install
# plan repainting as you do. Those panes are not drawings: they are the real
# oh-my-posh, the string lib/derive.sh assembles, and `lib/tools.sh --plan`.
#
# The launch is inside the Hide block on purpose. `uv run` plus the first pass of
# previews is a few seconds of an empty panel, and this recording is about the UI,
# not about waiting for it. --no-tools keeps ctrl+s to rendering and linking; the
# UI builds its tool list from lib/tools.sh either way, so the pane still shows.

Output demo/setup.gif

Require vhs

Set Shell bash
Set FontFamily "JetBrainsMono Nerd Font Mono"
Set FontSize 13
#1210x730 lands on a 143x40 terminal, which is what it takes for the previews
#column to be 95 cells wide -- under that the status bar truncates its own right
#half, exactly as tmux would, and the recording looks like a bug.
Set Width 1210
Set Height 730
Set Padding 12
Set TypingSpeed 55ms
Set Framerate 24
Set Theme { "name": "monokai", "background": "#272822", "foreground": "#f8f8f2", "cursor": "#f8f8f2", "selection": "#49483e", "black": "#272822", "red": "#f92672", "green": "#a6e22e", "yellow": "#e6db74", "blue": "#66d9ef", "magenta": "#ae81ff", "cyan": "#a1efe4", "white": "#f8f8f2", "brightBlack": "#75715e", "brightRed": "#f92672", "brightGreen": "#a6e22e", "brightYellow": "#e6db74", "brightBlue": "#66d9ef", "brightMagenta": "#ae81ff", "brightCyan": "#a1efe4", "brightWhite": "#f9f8f5" }

Hide
Type `source "$DEMO_DIR/lib.sh"`
Enter
Sleep 1s
Type "dotfiles reconfigure --no-tools"
Enter
Sleep 12s
Show

Sleep 1200ms

# four tabs to the palette. The scrolling controls column takes focus first, then
# the editing row, then the two hex boxes -- the grid is the fifth stop.
Tab
Tab
Tab
Tab
Sleep 800ms

# Each row of the grid is one real scheme, and every pane below follows. Down
# twice from monokai green is dracula's pink; right once is its purple.
Down
Sleep 850ms
Down
Sleep 850ms
Right
Sleep 1100ms

# s hands the arrows to the secondary accent (p takes them back). It starts on
# monokai's yellow, so the same two rows down lands on dracula's orange.
Type "s"
Sleep 800ms
Down
Sleep 750ms
Down
Sleep 1200ms

# the machine name: it goes in the prompt and in both status bars.
Tab
Backspace 7
Type "orion"
Sleep 1400ms

# the status-line toggles. Switching the GPU pill off takes it out of the bar.
Tab
Tab
Space
Sleep 2200ms

# ctrl+s renders every template with these answers and relinks. Held for barely a
# second on purpose: what that output looks like is install.gif's job, and ending
# on a screenful of it would mean this GIF loops back from a wall of paths rather
# than from the panel it is about.
Ctrl+S
Sleep 1s
