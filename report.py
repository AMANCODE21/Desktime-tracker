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
DB_PATH = os.path.join(HERE, "data", "desktime.db")
CATS_PATH = os.path.join(HERE, "categories.json")
TEMPLATE = os.path.join(HERE, "dashboard_template.html")
OUT = os.path.join(HERE, "report.html")
DAYS = 30


def load_rules():
    with open(CATS_PATH) as f:
        cfg = json.load(f)
    return cfg


def categorize(cfg, app, domain):
    if domain:
        for key, cat in cfg["domains"].items():
            if domain == key or domain.endswith("." + key) or key in domain:
                return cat
    name = app.lower()
    apps = cfg["apps"]
    if name in apps:
        return apps[name]
    for key, cat in apps.items():
        if len(key) >= 5 and key in name:
            return cat
    return "Other"


def build_data():
    cfg = load_rules()
    since = time.mktime((datetime.now() - timedelta(days=DAYS)).replace(
        hour=0, minute=0, second=0, microsecond=0).timetuple())
    rows = []
    if os.path.exists(DB_PATH):
        db = sqlite3.connect(DB_PATH)
        rows = db.execute(
            "SELECT start,end,app,title,domain FROM activity WHERE end>=? ORDER BY start", (since,)).fetchall()

    days = {}
    for start, end, app, title, domain in rows:
        # agar activity raat 12 baje cross kare to do din me baant do
        while start < end:
            d = datetime.fromtimestamp(start)
            midnight = time.mktime((d + timedelta(days=1)).replace(
                hour=0, minute=0, second=0, microsecond=0).timetuple())
            seg_end = min(end, midnight)
            day0 = midnight - 86400
            days.setdefault(d.strftime("%Y-%m-%d"), []).append([
                round(start - day0), round(seg_end - day0), app, title or "", domain or "",
                categorize(cfg, app, domain or "")])
            start = seg_end
    return {"generated": datetime.now().strftime("%d %b %Y, %I:%M %p"),
            "categories": cfg["categories"], "days": days}


def main():
    data = build_data()
    with open(TEMPLATE) as f:
        html = f.read()
    html = html.replace("/*__DATA__*/null", json.dumps(data, ensure_ascii=False).replace("</", "<\\/"))
    with open(OUT, "w") as f:
        f.write(html)
    print(f"Dashboard ready: {OUT}  ({len(data['days'])} din ka data)")
    if "--no-open" not in sys.argv:
        subprocess.run(["open", OUT])


if __name__ == "__main__":
    main()
