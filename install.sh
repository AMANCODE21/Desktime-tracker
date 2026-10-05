#!/bin/bash
# Tracker ko login pe apne aap chalu karta hai (macOS LaunchAgent).
DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST="$HOME/Library/LaunchAgents/app.desktimetracker.plist"
mkdir -p "$DIR/data" "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>app.desktimetracker</string>
  <key>ProgramArguments</key><array><string>/usr/bin/python3</string><string>$DIR/tracker.py</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$DIR/data/tracker.log</string>
  <key>StandardErrorPath</key><string>$DIR/data/tracker.log</string>
</dict></plist>
PL
launchctl unload "$PLIST" 2>/dev/null
launchctl load "$PLIST"
echo "✅ Tracker background me chalu. Har login pe apne aap chalega."
echo "   Dashboard dekhne ke liye:  python3 \"$DIR/report.py\""
