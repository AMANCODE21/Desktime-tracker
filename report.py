#!/usr/bin/env python3
"""Dashboard banata hai: report.html (last 30 din ka data) aur browser me khol deta hai.

Run:  python3 report.py           (banao + kholo)
      python3 report.py --no-open
"""
import json
import os
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.expanduser("~/Library/Application Support/DeskTimeTracker/desktime.db")
# app wali categories.json (menu bar → "Categories edit karo") ho to wahi use karo
CATS_PATH = os.path.expanduser("~/Library/Application Support/DeskTimeTracker/categories.json")
if not os.path.exists(CATS_PATH):
    CATS_PATH = os.path.join(HERE, "categories.json")
TEMPLATE = os.path.join(HERE, "dashboard_template.html")
OUT = os.path.join(HERE, "report.html")
ECHARTS = os.path.join(HERE, "app", "vendor", "echarts.min.js")
DAYS = 30


def build_data():
    with open(CATS_PATH) as f:
        rules = json.load(f)
    since = time.mktime((datetime.now() - timedelta(days=DAYS)).replace(
        hour=0, minute=0, second=0, microsecond=0).timetuple())
    rows = []
    if os.path.exists(DB_PATH):
        db = sqlite3.connect(DB_PATH)
        rows = db.execute(
            "SELECT start,end,app,title,domain,url FROM activity WHERE end>=? ORDER BY start", (since,)).fetchall()

    # har din ke rows: [start_sec, end_sec, app, title, domain, url] — category dashboard khud lagata hai
    days = {}
    for start, end, app, title, domain, url in rows:
        # agar activity raat 12 baje cross kare to do din me baant do
        while start < end:
            d = datetime.fromtimestamp(start)
            midnight = time.mktime((d + timedelta(days=1)).replace(
                hour=0, minute=0, second=0, microsecond=0).timetuple())
            seg_end = min(end, midnight)
            day0 = midnight - 86400
            days.setdefault(d.strftime("%Y-%m-%d"), []).append([
                round(start - day0), round(seg_end - day0), app, title or "", domain or "", url or ""])
            start = seg_end
    # away periods + projects (purane database me ye tables na ho to khaali)
    extras = {"away": [], "projects": [], "recent": [], "running": None}
    if os.path.exists(DB_PATH):
        tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        now = time.time()
        if "away" in tables:
            extras["away"] = [list(r) for r in db.execute(
                "SELECT id,start,end,label FROM away WHERE end>=? ORDER BY start", (since,))]
        if "project" in tables:
            extras["projects"] = [list(r) for r in db.execute(
                "SELECT name,start,COALESCE(end,?) FROM project WHERE COALESCE(end,?)>=? ORDER BY start", (now, now, since))]
            run = db.execute("SELECT name,start FROM project WHERE end IS NULL ORDER BY start DESC LIMIT 1").fetchone()
            extras["running"] = {"name": run[0], "start": run[1]} if run else None
    return {"generated": datetime.now().strftime("%d %b %Y, %I:%M %p"), "extras": extras,
                        "rules": rules, "days": days}


def main():
    data = build_data()
    with open(TEMPLATE) as f:
        html = f.read()
    html = html.replace("/*__DATA__*/null", json.dumps(data, ensure_ascii=False).replace("</", "<\\/"))
    with open(ECHARTS) as f:   # charts library (Apache ECharts) page ke andar hi, internet ki zaroorat nahi
        html = html.replace("<!--ECHARTS-->", "<script>" + f.read() + "</script>")
    with open(OUT, "w") as f:
        f.write(html)
    os.chmod(OUT, 0o600)   # report me aapka data hai — sirf aap padh sako
    print(f"Dashboard ready: {OUT}  ({len(data['days'])} days of data)")
    if "--no-open" not in sys.argv:
        subprocess.run(["open", OUT])


if __name__ == "__main__":
    main()
