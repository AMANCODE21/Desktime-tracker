#!/bin/bash
# Auto-start band karta hai (data delete nahi hota).
PLIST="$HOME/Library/LaunchAgents/app.desktimetracker.plist"
launchctl unload "$PLIST" 2>/dev/null && rm -f "$PLIST"
echo "⏹  Tracker band. Purana data data/desktime.db me safe hai."
