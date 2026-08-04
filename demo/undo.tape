# Taking it back off. install.sh records every path it touches in a manifest and
# saves any real file it displaced as <file>.bak; reset.sh -- which is what
# `dotfiles uninstall` runs -- reads that manifest back and puts the machine as it
# found it. The sandbox has a hand-written ~/.tmux.conf from before the install,
# so there is a genuine backup here to watch come back.

Output demo/undo.gif

Require vhs

Set Shell bash
Set FontFamily "JetBrainsMono Nerd Font Mono"
Set FontSize 13
Set Width 1060
Set Height 640
Set Padding 12
Set TypingSpeed 55ms
Set Framerate 24
Set Theme { "name": "monokai", "background": "#272822", "foreground": "#f8f8f2", "cursor": "#f8f8f2", "selection": "#49483e", "black": "#272822", "red": "#f92672", "green": "#a6e22e", "yellow": "#e6db74", "blue": "#66d9ef", "magenta": "#ae81ff", "cyan": "#a1efe4", "white": "#f8f8f2", "brightBlack": "#75715e", "brightRed": "#f92672", "brightGreen": "#a6e22e", "brightYellow": "#e6db74", "brightBlue": "#66d9ef", "brightMagenta": "#ae81ff", "brightCyan": "#a1efe4", "brightWhite": "#f9f8f5" }

Hide
Type `source "$DEMO_DIR/lib.sh"`
Enter
Sleep 1s
Type "cd ~"
Enter
Sleep 300ms
Type "clear"
Enter
Sleep 500ms
Show

Sleep 700ms
Type "ls -l ~/.tmux.conf"
Enter
Sleep 1500ms

Type "dotfiles backups"
Enter
Sleep 2200ms

# Unpiped. `| head -24` would frame the Restored line nicely and cost a
# "write error: Broken pipe" from reset.sh the moment head walked away, which
# looks exactly like a bug in the thing being demonstrated.
Type "dotfiles uninstall -y"
Enter
Sleep 3200ms

# Same path, and it is a real file again, with what was in it before.
Type "ls -l ~/.tmux.conf; head -3 ~/.tmux.conf"
Enter
Sleep 2500ms
