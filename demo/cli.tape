# The `dotfiles` command. Installing puts it on PATH, and it wraps install.sh,
# reset.sh and lib/tools.sh so none of them needs the checkout to be the working
# directory again -- which is the whole point of it, so the tape starts from a
# directory that is deliberately not the checkout.

Output demo/cli.gif

Require vhs

Set Shell bash
Set FontFamily "JetBrainsMono Nerd Font Mono"
Set FontSize 13
Set Width 1000
Set Height 580
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
Type "dotfiles help"
Enter
Sleep 5s

Type "dotfiles path"
Enter
Sleep 2s
