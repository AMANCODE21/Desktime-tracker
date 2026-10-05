#!/usr/bin/env python3
"""DeskTime Tracker — har kuch seconds me dekhta hai ki kaunsa app / window / website active hai
aur usko SQLite (data/desktime.db) me save karta hai.

Run:  python3 tracker.py          (foreground, Ctrl+C se band)
      ./install.sh                (login pe apne aap chalega)
"""
import os
import sqlite3
import subprocess
import sys
import time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(HERE, "data", "desktime.db")

POLL_SECONDS = 5          # kitni der me ek baar check kare
IDLE_SECONDS = 120        # itne second keyboard/mouse na chale to "away" maana jayega
MERGE_GAP = POLL_SECONDS * 3  # same activity ke beech itna gap ho to bhi ek hi row me jodo

BROWSERS = {
    "Google Chrome": "chrome",
    "Brave Browser": "chrome",
    "Microsoft Edge": "chrome",
    "Arc": "chrome",
    "Safari": "safari",
}

FRONT_SCRIPT = '''
tell application "System Events"
    set p to first application process whose frontmost is true
    set appName to name of p
    set winTitle to ""
    try
        set winTitle to name of front window of p
    end try
end tell
return appName & "\n" & winTitle
'''


def osascript(script):
    try:
        out = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=4)
        return out.stdout.strip() if out.returncode == 0 else ""
    except subprocess.TimeoutExpired:
        return ""


def idle_seconds():
    try:
        out = subprocess.run(["ioreg", "-c", "IOHIDSystem"], capture_output=True, text=True, timeout=4).stdout
        for line in out.splitlines():
            if "HIDIdleTime" in line:
                return int(line.split("=")[-1].strip()) / 1e9
    except Exception:
        pass
    return 0


def browser_tab(app):
    kind = BROWSERS.get(app)
    if kind == "chrome":
        s = f'tell application "{app}" to return (URL of active tab of front window) & "\\n" & (title of active tab of front window)'
    elif kind == "safari":
        s = 'tell application "Safari" to return (URL of front document) & "\\n" & (name of front document)'
    else:
        return "", ""
    out = osascript(s)
    if "\n" in out:
        url, title = out.split("\n", 1)
        return url, title
    return "", ""


def domain_of(url):
    if "://" not in url:
        return ""
    host = url.split("://", 1)[1].split("/", 1)[0].split(":")[0]
    return host[4:] if host.startswith("www.") else host


def current_activity():
    """(app, title, url, domain) ya None agar user away hai."""
    if idle_seconds() >= IDLE_SECONDS:
        return None
    out = osascript(FRONT_SCRIPT)
    if not out:
        return None
    app, _, title = out.partition("\n")
    if app in ("loginwindow", "ScreenSaverEngine"):
        return None
    url = domain = ""
    if app in BROWSERS:
        url, tab_title = browser_tab(app)
        title = tab_title or title
        domain = domain_of(url)
    return app, title, url, domain


def open_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    db = sqlite3.connect(DB_PATH)
    db.execute("""
        CREATE TABLE IF NOT EXISTS activity (
            id     INTEGER PRIMARY KEY,
            start  REAL NOT NULL,
            end    REAL NOT NULL,
            app    TEXT NOT NULL,
            title  TEXT,
            url    TEXT,
            domain TEXT
        )""")
    db.execute("CREATE INDEX IF NOT EXISTS idx_start ON activity(start)")
    db.commit()
    return db


def main():
    db = open_db()
    last_id, last_key, last_end = None, None, 0
    print(f"DeskTime tracker chalu — har {POLL_SECONDS}s check. Data: {DB_PATH}", flush=True)
    while True:
        now = time.time()
        act = current_activity()
        if act:
            app, title, url, domain = act
            key = (app, title, domain)
            if key == last_key and now - last_end <= MERGE_GAP:
                db.execute("UPDATE activity SET end=? WHERE id=?", (now + POLL_SECONDS, last_id))
            else:
                cur = db.execute(
                    "INSERT INTO activity(start,end,app,title,url,domain) VALUES (?,?,?,?,?,?)",
                    (now, now + POLL_SECONDS, app, title, url, domain))
                last_id, last_key = cur.lastrowid, key
                if "-v" in sys.argv:
                    print(datetime.now().strftime("%H:%M:%S"), app, "|", domain or title, flush=True)
            last_end = now
            db.commit()
        else:
            last_key = None
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nband kar diya.")
