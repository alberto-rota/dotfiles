#!/bin/bash
# List ALL tmux sessions ordered by session index; style current vs others.
# Current: blue block + black bold name. Others: blue slant pair + black on yellow name.
current=$(tmux display-message -p '#S')
sep=$(printf '\xee\x82\xbc')   # powerline slanted (U+E0BC)

while IFS= read -r line; do
    id="${line%% *}"
    name="${line#* }"
    if [ "$name" = "$current" ]; then
        # Current session: same style as main status (#S) — blue block, black bold name
        printf '#[fg=#ffea02,bg=#03a1fc]%s#[fg=#000000,bg=#03a1fc,bold] %s #[fg=#03a1fc,bg=#ffea02,nobold]%s' "$sep" "$name" "$sep"
    else
        # Other sessions: blue slanted pair then black on yellow name
        printf '#[fg=#ffea02,bg=#03a1fc]%s#[fg=#03a1fc,bg=#ffea02]%s #[fg=#000000,bg=#ffea02]%s ' "$sep" "$sep" "$name"
    fi
done < <(tmux list-sessions -F '#{session_id} #{session_name}' | sort -t'$' -k2 -n)
