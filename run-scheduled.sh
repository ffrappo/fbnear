#!/bin/bash
# Twice-daily fbnear run: harvest today + tomorrow, publish web data.
export PATH="$PATH:/usr/bin:/bin"
LOG=/Users/ffrappo/works/artifacts/fbnear/scheduled.log
cd /Users/ffrappo/works/repos/fbnear
echo "=== $(date '+%F %T') scheduled run ===" >> "$LOG"
caffeinate -i ./.build/debug/fbnear --date today --radius 15 --tabs 2 --dashboard --publish >> "$LOG" 2>&1
caffeinate -i ./.build/debug/fbnear --date tomorrow --radius 15 --tabs 2 --publish >> "$LOG" 2>&1
echo "=== $(date '+%F %T') done ===" >> "$LOG"
