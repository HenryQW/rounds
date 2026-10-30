#!/bin/sh
# Opens one demo scene under scripts/watch-frames.sh and exits 1 if any resize flag shows: the session window's
# regression check (.claude/skills/watching-window-frames). Run scripts/bundle.sh first.
# Usage: scripts/check-frames.sh [scene] (default window-turn: after 2 s sessions come into Your Turn and the banner goes).
# It waits until the user is idle for 10 s, quits the installed app for the run (the same global shortcut) and opens it
# again at the end. It sends no keys or pointer events.
cd "$(dirname "$0")/.."
LOG=$(mktemp)
idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ { print int($NF / 1000000000); exit }'; }
until [ "$(idle)" -ge 10 ]; do sleep 2; done
RUNNING=$(pgrep -x Rounds >/dev/null && echo 1 || echo 0)
if [ "$RUNNING" = 1 ]; then pkill -x Rounds; sleep 1; fi
scripts/watch-frames.sh 16s > "$LOG" 2>&1 &
sleep 2
build/Rounds.app/Contents/MacOS/Rounds --demo --demo-scene "${1:-window-turn}" >/dev/null 2>&1 &
pid=$!
sleep 12
kill "$pid"
wait 2>/dev/null
if [ "$RUNNING" = 1 ]; then open /Applications/Rounds.app; fi
# Content BOUNCE and FLIP alone are SwiftUI's own layout passes; a flag on a resize or a slide is a fault the user sees.
if grep '<<' "$LOG" | grep -qE 'resized|slideIn'; then echo "RED"; cat "$LOG"; rm -f "$LOG"; exit 1; fi
echo "GREEN ($(grep -c resized "$LOG") resizes)"
rm -f "$LOG"
