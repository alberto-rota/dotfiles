#!/bin/bash

# Fetching jobs: %j is name, %t is state
# head -n 3 keeps the bar from getting too long
JOBS=$(squeue --me --noheader --format="%j|%t" 2>/dev/null | head -n 16)

if [ -z "$JOBS" ]; then
    echo "#[fg=#555555,bg=#000000] no jobs "
    exit 0
fi

OUTPUT=""
while IFS='|' read -r name state; do
    # Truncate job name to 7 characters
    short_name=$(echo "$name" | cut -c1-7)
    
    if [ "$state" == "R" ]; then
        OUTPUT+="#[fg=#000000,bg=#00ff00]#[fg=#00ff00,bg=#000000] $short_name "
    elif [ "$state" == "PD" ]; then
        OUTPUT+="#[fg=#000000,bg=#ffea02]#[fg=#ffea02,bg=#000000] $short_name "
    fi
done <<< "$JOBS"

echo "$OUTPUT"