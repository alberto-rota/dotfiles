# What ./install.sh actually does once the answers are saved: render every
# template that carries a colour or the machine name, symlink the real config
# path at the rendered copy, and back up anything real it finds in the way.
#
# The Hide block takes the sandbox back to bare first, so this is a FIRST install
# rather than a re-render -- that is the run with the interesting line in it, the
# one where ~/.tmux.conf gets moved aside to ~/.tmux.conf.bak. --no-tools keeps it
# to the config half; the tools phase is its own thing and takes minutes.

Output demo/install.gif

Require vhs

Set Shell bash
Set FontFamily "JetBrainsMono Nerd Font Mono"
Set FontSize 13
# Wide: this is the one tape whose content is absolute paths, two per line.
Set Width 1300
Set Height 820
Set Padding 12
Set TypingSpeed 45ms
Set Framerate 24
Set Theme { "name": "monokai", "background": "#272822", "foreground": "#f8f8f2", "cursor": "#f8f8f2", "selection": "#49483e", "black": "#272822", "red": "#f92672", "green": "#a6e22e", "yellow": "#e6db74", "blue": "#66d9ef", "magenta": "#ae81ff", "cyan": "#a1efe4", "white": "#f8f8f2", "brightBlack": "#75715e", "brightRed": "#f92672", "brightGreen": "#a6e22e", "brightYellow": "#e6db74", "brightBlue": "#66d9ef", "brightMagenta": "#ae81ff", "brightCyan": "#a1efe4", "brightWhite": "#f9f8f5" }

Hide
Type `source "$DEMO_DIR/lib.sh"`
Enter
Sleep 1s
Type "dotfiles uninstall -y"
Enter
Sleep 4s
Type "clear"
Enter
Sleep 500ms
Show

Sleep 700ms
Type "./install.sh -y --no-tools"
Enter
Sleep 6s
