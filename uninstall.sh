#!/bin/bash
# DeskTime.app hatata hai (data delete nahi hota).
# Pehle menu bar se "Open at Login" off kar do, fir ye chalao.
if pgrep -x DeskTime >/dev/null; then
  osascript -e 'tell application "DeskTime" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do pgrep -x DeskTime >/dev/null || break; sleep 1; done
fi
[ -d "$HOME/Applications/DeskTime.app" ] && rm -rf "$HOME/Applications/DeskTime.app"
echo "⏹  DeskTime removed. Your data is still in ~/Library/Application Support/DeskTimeTracker."
