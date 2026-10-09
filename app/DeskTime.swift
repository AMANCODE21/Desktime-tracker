// DeskTime.app — menu bar app jo har 15 second me dekhti hai ki kaunsa app / window / website active hai,
// usko SQLite me save karti hai aur dashboard dikhati hai.
// Build + install:  ./install.sh
import Carbon
import Cocoa
import CryptoKit
import EventKit
import Network
import SQLite3
import ServiceManagement
import UserNotifications
import WebKit

let POLL: TimeInterval = 15         // kitni der me ek baar check kare
let MERGE_GAP: TimeInterval = POLL * 3

// Data ~/Documents ke bahar, kyunki macOS background apps ko Documents padhne nahi deta.
let supportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/DeskTimeTracker")
let dbPath = supportDir.appendingPathComponent("desktime.db").path
let catsURL = supportDir.appendingPathComponent("categories.json")
let backupDir = supportDir.appendingPathComponent("backups")

/// macOS ke system popups — inhe app ki tarah record nahi karte
let ignoredApps: Set<String> = [
    "com.apple.loginwindow", "com.apple.ScreenSaver.Engine", "com.apple.accessibility.universalAccessAuthWarn",
    "com.apple.UserNotificationCenter", "com.apple.SecurityAgent", "com.apple.CoreServicesUIAgent",
    "com.apple.coreautha", "com.apple.LocalAuthenticationRemoteService",
]
let ignoredAppNames: Set<String> = [
    "loginwindow", "ScreenSaverEngine", "universalAccessAuthWarn", "UserNotificationCenter", "SecurityAgent",
    "CoreServicesUIAgent", "coreautha",
]

// MARK: - Settings (categories.json ka "settings" hissa — dashboard ke Settings page se badalta hai)

enum Settings {
    static var goalHours = 8.0
    static var idleMinutes = 2.0          // itne minute keyboard/mouse na chale to "away"
    static var awayMinutes = 5.0          // isse lamba away ho to "Away" list me aata hai (naam / topic de sakte ho)
    static var notifyGoal = true
    static var notifyDistraction = true
    static var distractionMinutes = 30.0
    static var notifyAway = false
    static var retentionDays = 0.0        // 0 = data hamesha rakho
    static var remindMinutes = 10.0       // meeting / task se itne minute pehle reminder
    static var scheduleTime = "10:00"     // roz is time pe aaj ka schedule
    static var notifySchedule = true
    static var notifyGtaskNew = true      // Google Tasks me naya task aaye to alert
    static var notifyGtaskDue = true      // due wale din yaad dilao
    static var gtaskDueTime = "09:00"     // Google sirf date deta hai, isliye is time pe
    static var gtaskSyncMinutes = 5.0     // kitni der me Google Tasks check kare
    static var officeOn = true            // office hours ke bahar ka time "Personal" me
    static var officeStart = "09:00"
    static var officeEnd = "21:00"
    static var officeDays: Set<Int> = [0, 1, 2, 3, 4, 5, 6]   // 0 = Sunday (JS getDay jaisa)

    static func load() {
        guard let data = try? Data(contentsOf: catsURL),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        goalHours = (cfg["goal_hours"] as? Double) ?? goalHours
        let s = cfg["settings"] as? [String: Any] ?? [:]
        idleMinutes = max(1, (s["idle_minutes"] as? Double) ?? idleMinutes)
        awayMinutes = max(2, (s["away_minutes"] as? Double) ?? awayMinutes)
        notifyGoal = (s["notify_goal"] as? Bool) ?? notifyGoal
        notifyDistraction = (s["notify_distraction"] as? Bool) ?? notifyDistraction
        distractionMinutes = max(5, (s["distraction_minutes"] as? Double) ?? distractionMinutes)
        notifyAway = (s["notify_away"] as? Bool) ?? notifyAway
        retentionDays = max(0, (s["retention_days"] as? Double) ?? retentionDays)
        remindMinutes = max(0, (s["remind_minutes"] as? Double) ?? remindMinutes)
        scheduleTime = (s["schedule_time"] as? String) ?? scheduleTime
        notifySchedule = (s["notify_schedule"] as? Bool) ?? notifySchedule
        notifyGtaskNew = (s["notify_gtask_new"] as? Bool) ?? notifyGtaskNew
        notifyGtaskDue = (s["notify_gtask_due"] as? Bool) ?? notifyGtaskDue
        gtaskDueTime = (s["gtask_due_time"] as? String) ?? gtaskDueTime
        gtaskSyncMinutes = min(60, max(1, (s["gtask_sync_minutes"] as? Double) ?? gtaskSyncMinutes))
        officeOn = (s["office_on"] as? Bool) ?? officeOn
        officeStart = (s["office_start"] as? String) ?? officeStart
        officeEnd = (s["office_end"] as? String) ?? officeEnd
        if let d = s["office_days"] as? [Int] { officeDays = Set(d.filter { (0...6).contains($0) }) }
    }

    /// "HH:mm" -> din ki shuruaat se seconds
    static func secs(_ hm: String) -> Double {
        let p = hm.split(separator: ":").compactMap { Double($0) }
        return p.count == 2 ? p[0] * 3600 + p[1] * 60 : 0
    }

    /// [s, e] me se kitna office hours ke andar hai (baaki Personal). Raat ki shift (21:00–06:00) bhi chalti hai.
    static func officeSeconds(_ s: Double, _ e: Double) -> Double {
        guard officeOn, e > s else { return max(0, e - s) }
        let cal = Calendar.current
        let os = secs(officeStart)
        var oe = secs(officeEnd)
        if oe <= os { oe += 86400 }
        var total = 0.0
        var day = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date(timeIntervalSince1970: s)))!
        while day.timeIntervalSince1970 < e {
            if officeDays.contains(cal.component(.weekday, from: day) - 1) {
                let base = day.timeIntervalSince1970
                total += max(0, min(e, base + oe) - max(s, base + os))
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return total
    }
    static func isOffice(_ t: Double) -> Bool { officeSeconds(t, t + 1) > 0 }
}

func notify(_ title: String, _ body: String, url: String? = nil, open: String? = nil) {
    let c = UNMutableNotificationContent()
    c.title = title
    c.body = body
    c.sound = .default
    var info: [String: String] = [:]
    if let url { info["url"] = url }
    if let open { info["open"] = open }
    c.userInfo = info
    if url != nil { c.categoryIdentifier = "meeting" }
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
}

// bundle id -> AppleScript ka type (Chrome jaise sab browsers ka script same hai)
let browsers: [String: String] = [
    "com.google.Chrome": "chrome",
    "com.brave.Browser": "chrome",
    "com.microsoft.edgemac": "chrome",
    "company.thebrowser.Browser": "chrome",
    "com.apple.Safari": "safari",
]

// MARK: - Database

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct Activity { var app, title, url, domain: String }
struct Row { let start, end: Double; let app, title, domain, url: String }

final class Store {
    private var db: OpaquePointer?

    init() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        // Data sirf aapke user ke liye: folder 700, database 600
        chmod(supportDir.path, 0o700)
        sqlite3_open(dbPath, &db)
        for f in [dbPath, dbPath + "-journal", dbPath + "-wal"] where FileManager.default.fileExists(atPath: f) {
            chmod(f, 0o600)
        }
        sqlite3_busy_timeout(db, 3000)
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS activity (
                id     INTEGER PRIMARY KEY,
                start  REAL NOT NULL,
                end    REAL NOT NULL,
                app    TEXT NOT NULL,
                title  TEXT,
                url    TEXT,
                domain TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_start ON activity(start);
            CREATE TABLE IF NOT EXISTS away (
                id    INTEGER PRIMARY KEY,
                start REAL NOT NULL,
                end   REAL NOT NULL,
                label TEXT NOT NULL DEFAULT ''
            );
            CREATE TABLE IF NOT EXISTS task (
                id      INTEGER PRIMARY KEY,
                title   TEXT NOT NULL,
                due     REAL,
                done    INTEGER NOT NULL DEFAULT 0,
                created REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS project (
                id    INTEGER PRIMARY KEY,
                name  TEXT NOT NULL,
                start REAL NOT NULL,
                end   REAL
            );
            """, nil, nil, nil)
        // Purane DB me ye columns nahi the — pehle se ho to ALTER chup-chaap fail ho jata hai
        sqlite3_exec(db, "ALTER TABLE task ADD COLUMN project TEXT NOT NULL DEFAULT ''", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE task ADD COLUMN day TEXT", nil, nil, nil)
        setupGoogleTables()
    }

    private func run(_ sql: String, _ args: [Any], each: ((OpaquePointer) -> Void)? = nil) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case let d as Double: sqlite3_bind_double(st, idx, d)
            case let n as Int64: sqlite3_bind_int64(st, idx, n)
            case let s as String: sqlite3_bind_text(st, idx, s, -1, SQLITE_TRANSIENT)
            default: sqlite3_bind_null(st, idx)
            }
        }
        while sqlite3_step(st) == SQLITE_ROW { each?(st) }
    }

    /// Purane rows me chhota naam ("Code") tha — usko poore naam se badal do.
    func migrateAppNames() {
        var names = ["Code": "Visual Studio Code"]
        for app in NSWorkspace.shared.runningApplications {
            if let short = app.localizedName, let url = app.bundleURL, url.pathExtension == "app" {
                let full = url.deletingPathExtension().lastPathComponent
                if full != short { names[short] = full }
            }
        }
        for (short, full) in names { run("UPDATE activity SET app=? WHERE app=?", [full, short]) }
    }

    /// Purane rows pe bhi privacy rules lagao (password/email/login pages ke title aur link hatao)
    func applyPrivacyToOldData() {
        var fixes: [(Int64, Activity)] = []
        run("SELECT id,app,title,url,domain FROM activity", []) { st in
            let a = Activity(app: col(st, 1), title: col(st, 2), url: col(st, 3), domain: col(st, 4))
            let b = Privacy.apply(a, privateApp: false)
            if b.title != a.title || b.url != a.url || b.domain != a.domain { fixes.append((sqlite3_column_int64(st, 0), b)) }
        }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for (id, b) in fixes { run("UPDATE activity SET title=?, url=?, domain=? WHERE id=?", [b.title, b.url, b.domain, id]) }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        if !fixes.isEmpty { sqlite3_exec(db, "VACUUM", nil, nil, nil) }   // purana text file se bhi mita do
    }

    /// System popups (universalAccessAuthWarn waghaira) jo pehle record ho gaye the, unhe hatao
    func removeIgnoredApps() {
        for name in ignoredAppNames { run("DELETE FROM activity WHERE app=?", [name]) }
    }

    // --- Away (computer se door) ---
    func addAway(_ start: Double, _ end: Double) {
        run("INSERT INTO away(start,end,label) VALUES (?,?,'')", [start, end])
    }
    func setAwayLabel(_ id: Int64, _ label: String) {
        run("UPDATE away SET label=? WHERE id=?", [label, id])
    }
    /// Break ka time / naam badlo (id 0 = naya break). Galat time ho to error message.
    func saveAway(_ id: Int64, _ start: Double, _ end: Double, _ label: String) -> String? {
        let now = Date().timeIntervalSince1970
        guard start > 0, end > start else { return "The end time must be after the start time." }
        guard end - start <= 86400 else { return "A break can’t be longer than a day." }
        guard end <= now + 60 else { return "A break can’t end in the future." }
        if id == 0 { run("INSERT INTO away(start,end,label) VALUES (?,?,?)", [start, end, label]) }
        else { run("UPDATE away SET start=?, end=?, label=? WHERE id=?", [start, end, label, id]) }
        return nil
    }
    func deleteAway(_ id: Int64) { run("DELETE FROM away WHERE id=?", [id]) }
    func awayRows(since: Double, until: Double) -> [[Any]] {
        var out: [[Any]] = []
        run("SELECT id,start,end,label FROM away WHERE end>=? AND start<? ORDER BY start", [since, until]) { st in
            out.append([sqlite3_column_int64(st, 0), sqlite3_column_double(st, 1), sqlite3_column_double(st, 2), col(st, 3)])
        }
        return out
    }

    // --- Projects (haath se chalaya timer) ---
    func runningProject() -> (id: Int64, name: String, start: Double)? {
        var r: (Int64, String, Double)?
        run("SELECT id,name,start FROM project WHERE end IS NULL ORDER BY start DESC LIMIT 1", []) { st in
            r = (sqlite3_column_int64(st, 0), col(st, 1), sqlite3_column_double(st, 2))
        }
        return r
    }
    func startProject(_ name: String) {
        stopProject()
        run("INSERT INTO project(name,start) VALUES (?,?)", [name, Date().timeIntervalSince1970])
    }
    func stopProject() {
        run("UPDATE project SET end=? WHERE end IS NULL", [Date().timeIntervalSince1970])
    }
    func projectRows(since: Double, until: Double) -> [[Any]] {
        var out: [[Any]] = []
        let now = Date().timeIntervalSince1970
        run("SELECT name,start,COALESCE(end,?) FROM project WHERE COALESCE(end,?)>=? AND start<? ORDER BY start",
            [now, now, since, until]) { st in
            out.append([col(st, 0), sqlite3_column_double(st, 1), sqlite3_column_double(st, 2)])
        }
        return out
    }
    func recentProjects(_ limit: Int = 8) -> [String] {
        var out: [String] = []
        run("SELECT name FROM project GROUP BY name ORDER BY MAX(start) DESC LIMIT ?", [Int64(limit)]) { st in
            out.append(col(st, 0))
        }
        return out
    }

    // --- Tasks (DeskTime ke apne: project / General, kisi bhi din ke liye, time ke saath ya bina) ---
    /// due = time wala task (timestamp). day = sirf date wala task ("yyyy-MM-dd").
    func addTask(_ title: String, due: Double?, day: String?, project: String) {
        run("INSERT INTO task(title,due,created,project,day) VALUES (?,?,?,?,?)",
            [title, due as Any, Date().timeIntervalSince1970, project, day as Any])
    }
    /// Sab khule tasks (kisi bhi din ke) — Work me har project ke "kitne baaki, agla kaunsa"
    func openTasks() -> [[String: Any]] {
        var out: [[String: Any]] = []
        run("SELECT id,title,due,day,project FROM task WHERE done=0 ORDER BY COALESCE(day, date(due,'unixepoch','localtime'), '9999'), due, id", []) { st in
            out.append(["id": sqlite3_column_int64(st, 0), "title": col(st, 1),
                        "due": sqlite3_column_type(st, 2) == SQLITE_NULL ? NSNull() : sqlite3_column_double(st, 2) as Any,
                        "day": sqlite3_column_type(st, 3) == SQLITE_NULL ? NSNull() : col(st, 3) as Any, "project": col(st, 4)])
        }
        return out
    }
    func setTaskDone(_ id: Int64, _ done: Bool) { run("UPDATE task SET done=? WHERE id=?", [Int64(done ? 1 : 0), id]) }
    func deleteTask(_ id: Int64) { run("DELETE FROM task WHERE id=?", [id]) }
    /// Is range ke time wale + is range ke date wale tasks. Range me aaj ho to purane baaki (date wale) bhi.
    /// Bina date/time wale purane tasks pehle jaise: jab tak pure na ho tab tak dikhte hain.
    func tasks(since: Double, until: Double) -> [[String: Any]] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let d0 = f.string(from: Date(timeIntervalSince1970: since)), d1 = f.string(from: Date(timeIntervalSince1970: until))
        let now = Date().timeIntervalSince1970, today = f.string(from: Date())
        let carry: Int64 = since <= now && now < until ? 1 : 0
        var out: [[String: Any]] = []
        run("""
            SELECT id,title,due,done,project,day FROM task
            WHERE (due>=? AND due<?)
               OR (due IS NULL AND day IS NOT NULL AND ((day>=? AND day<?) OR (?=1 AND day<? AND done=0)))
               OR (due IS NULL AND day IS NULL AND (done=0 OR created>=?))
            ORDER BY due IS NULL, due, day, id
            """, [since, until, d0, d1, carry, today, since]) { st in
            out.append(["id": sqlite3_column_int64(st, 0), "title": col(st, 1),
                        "due": sqlite3_column_type(st, 2) == SQLITE_NULL ? NSNull() : sqlite3_column_double(st, 2) as Any,
                        "done": sqlite3_column_int(st, 3) == 1, "project": col(st, 4),
                        "day": sqlite3_column_type(st, 5) == SQLITE_NULL ? NSNull() : col(st, 5) as Any])
        }
        return out
    }

    // --- Backup + purana data hatana ---
    /// Roz ek backup (backups/desktime-YYYY-MM-DD.db), aakhri 14 rakhte hain
    func dailyBackup() {
        let fm = FileManager.default
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        chmod(backupDir.path, 0o700)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let path = backupDir.appendingPathComponent("desktime-\(f.string(from: Date())).db").path
        if fm.fileExists(atPath: path) { return }
        var dst: OpaquePointer?
        guard sqlite3_open(path, &dst) == SQLITE_OK else { return }
        if let b = sqlite3_backup_init(dst, "main", db, "main") {
            sqlite3_backup_step(b, -1)
            sqlite3_backup_finish(b)
        }
        sqlite3_close(dst)
        chmod(path, 0o600)
        let old = ((try? fm.contentsOfDirectory(atPath: backupDir.path)) ?? [])
            .filter { $0.hasPrefix("desktime-") && $0.hasSuffix(".db") }.sorted().dropLast(14)
        for name in old { try? fm.removeItem(at: backupDir.appendingPathComponent(name)) }
    }

    /// Settings me "itne din se purana data hatao" set ho to
    func applyRetention(days: Double) {
        guard days > 0 else { return }
        let cutoff = Date().timeIntervalSince1970 - days * 86400
        run("DELETE FROM activity WHERE end<?", [cutoff])
        run("DELETE FROM away WHERE end<?", [cutoff])
        run("DELETE FROM project WHERE end IS NOT NULL AND end<?", [cutoff])
    }

    func insert(_ start: Double, _ end: Double, _ a: Activity) -> Int64 {
        run("INSERT INTO activity(start,end,app,title,url,domain) VALUES (?,?,?,?,?,?)",
            [start, end, a.app, a.title, a.url, a.domain])
        return sqlite3_last_insert_rowid(db)
    }

    func setEnd(_ id: Int64, _ end: Double) {
        run("UPDATE activity SET end=? WHERE id=?", [end, id])
    }

    func rows(since: Double, until: Double = .infinity) -> [Row] {
        var out: [Row] = []
        run("SELECT start,end,app,title,domain,url FROM activity WHERE end>=? AND start<? ORDER BY start",
            [since, until]) { st in
            out.append(Row(start: sqlite3_column_double(st, 0), end: sqlite3_column_double(st, 1),
                           app: col(st, 2), title: col(st, 3), domain: col(st, 4), url: col(st, 5)))
        }
        return out
    }
}

// MARK: - Google Tasks tables
// Token DB me nahi rakhte — refresh token sirf Mac ki Keychain me ("refresh:<email>"), access token sirf memory me.

struct GAccount { let email, userID, status, error: String; let lastSynced: Double; let fails: Int; let nextTry: Double }

extension Store {
    func setupGoogleTables() {
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS gaccount (
                email          TEXT PRIMARY KEY,
                user_id        TEXT NOT NULL DEFAULT '',
                last_synced_at REAL NOT NULL DEFAULT 0,
                status         TEXT NOT NULL DEFAULT 'ok',   -- ok | offline | retry | reauth
                error          TEXT NOT NULL DEFAULT '',
                fails          INTEGER NOT NULL DEFAULT 0,
                next_try       REAL NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS glist (
                account TEXT NOT NULL,
                list_id TEXT NOT NULL,
                title   TEXT NOT NULL DEFAULT '',
                cursor  TEXT,                                 -- agli baar ka updatedMin (RFC 3339)
                PRIMARY KEY (account, list_id)
            );
            CREATE TABLE IF NOT EXISTS gtask (
                id           INTEGER PRIMARY KEY,
                account      TEXT NOT NULL,
                list_id      TEXT NOT NULL,
                google_id    TEXT NOT NULL,
                title        TEXT NOT NULL,
                notes        TEXT,
                due          TEXT,                            -- "YYYY-MM-DD" (Google API time nahi deta)
                status       TEXT NOT NULL,                   -- needsAction | completed
                completed    REAL,
                updated      TEXT NOT NULL,
                link         TEXT,
                first_seen   REAL NOT NULL,
                notified_new INTEGER NOT NULL DEFAULT 0,
                notified_due INTEGER NOT NULL DEFAULT 0,
                UNIQUE (account, google_id)
            );
            CREATE INDEX IF NOT EXISTS idx_gtask_due ON gtask(due, status);
            """, nil, nil, nil)
    }

    func gAccounts() -> [GAccount] {
        var out: [GAccount] = []
        run("SELECT email,user_id,status,error,last_synced_at,fails,next_try FROM gaccount ORDER BY rowid", []) { st in
            out.append(GAccount(email: col(st, 0), userID: col(st, 1), status: col(st, 2), error: col(st, 3),
                                lastSynced: sqlite3_column_double(st, 4), fails: Int(sqlite3_column_int(st, 5)),
                                nextTry: sqlite3_column_double(st, 6)))
        }
        return out
    }
    func gAddAccount(_ email: String, userID: String) {
        run("""
            INSERT INTO gaccount(email,user_id) VALUES (?,?)
            ON CONFLICT(email) DO UPDATE SET user_id=excluded.user_id, status='ok', error='', fails=0, next_try=0
            """, [email, userID])
    }
    func gRemoveAccount(_ email: String) {
        run("DELETE FROM gtask WHERE account=?", [email])
        run("DELETE FROM glist WHERE account=?", [email])
        run("DELETE FROM gaccount WHERE email=?", [email])
    }
    func gSetState(_ email: String, _ status: String, error: String = "", fails: Int = 0, nextTry: Double = 0, synced: Double? = nil) {
        run("UPDATE gaccount SET status=?, error=?, fails=?, next_try=?, last_synced_at=COALESCE(?, last_synced_at) WHERE email=?",
            [status, error, Int64(fails), nextTry, synced as Any, email])
    }

    /// list_id -> cursor ("" = is list ka pehla sync abhi nahi hua)
    func gCursors(_ email: String) -> [String: String] {
        var out: [String: String] = [:]
        run("SELECT list_id, cursor FROM glist WHERE account=?", [email]) { st in out[col(st, 0)] = col(st, 1) }
        return out
    }
    func gSaveList(_ email: String, _ id: String, title: String, cursor: String) {
        run("""
            INSERT INTO glist(account,list_id,title,cursor) VALUES (?,?,?,?)
            ON CONFLICT(account,list_id) DO UPDATE SET title=excluded.title, cursor=excluded.cursor
            """, [email, id, title, cursor])
    }
    func gDropList(_ email: String, _ id: String) {
        run("DELETE FROM gtask WHERE account=? AND list_id=?", [email, id])
        run("DELETE FROM glist WHERE account=? AND list_id=?", [email, id])
    }

    /// Google ka ek task DB me merge. (account, google_id) unique hai, isliye duplicate kabhi nahi banta;
    /// purana jawab naye ko overwrite nahi karta (updated compare). Return: true agar task pehli baar dikha.
    @discardableResult
    func gUpsert(_ email: String, list: String, _ t: [String: Any], silent: Bool) -> Bool {
        guard let gid = t["id"] as? String else { return false }
        if t["deleted"] as? Bool == true {
            run("DELETE FROM gtask WHERE account=? AND google_id=?", [email, gid])
            return false
        }
        let title = (t["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }   // Google ke khali tasks
        var exists = false
        run("SELECT 1 FROM gtask WHERE account=? AND google_id=?", [email, gid]) { _ in exists = true }
        let status = t["status"] as? String ?? "needsAction"
        run("""
            INSERT INTO gtask(account,list_id,google_id,title,notes,due,status,completed,updated,link,first_seen,notified_new)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(account,google_id) DO UPDATE SET
                list_id=excluded.list_id, title=excluded.title, notes=excluded.notes, status=excluded.status,
                completed=excluded.completed, updated=excluded.updated, link=excluded.link, due=excluded.due,
                notified_due = CASE WHEN excluded.due IS gtask.due THEN gtask.notified_due ELSE 0 END
            WHERE excluded.updated >= gtask.updated
            """, [email, list, gid, String(title.prefix(500)), (t["notes"] as? String).map { String($0.prefix(2000)) } as Any,
                  (t["due"] as? String).map { String($0.prefix(10)) } as Any, status,
                  (t["completed"] as? String).flatMap(rfc3339) as Any, t["updated"] as? String ?? "",
                  t["webViewLink"] as? String as Any, Date().timeIntervalSince1970,
                  Int64(silent || status == "completed" ? 1 : 0)])
        return !exists
    }

    /// Naye aaye tasks jinki notification abhi nahi gayi — aur unhe "announced" mark kar do
    func gTakeUnannounced() -> [(title: String, account: String, due: String)] {
        var out: [(String, String, String)] = []
        run("SELECT title,account,COALESCE(due,'') FROM gtask WHERE notified_new=0 AND status='needsAction' ORDER BY id", []) { st in
            out.append((col(st, 0), col(st, 1), col(st, 2)))
        }
        run("UPDATE gtask SET notified_new=1 WHERE notified_new=0", [])
        return out
    }
    /// Aaj due wale khule tasks jinka reminder abhi nahi gaya — aur unhe mark kar do
    func gTakeDue(_ day: String) -> [(title: String, account: String)] {
        var out: [(String, String)] = []
        run("SELECT title,account FROM gtask WHERE due=? AND status='needsAction' AND notified_due=0 ORDER BY id", [day]) { st in
            out.append((col(st, 0), col(st, 1)))
        }
        run("UPDATE gtask SET notified_due=1 WHERE due=? AND status='needsAction' AND notified_due=0", [day])
        return out
    }

    /// Dashboard ke liye: sab khule tasks + `completedSince` ke baad pure hue
    func gTasks(completedSince: Double) -> [[String: Any]] {
        var out: [[String: Any]] = []
        run("""
            SELECT t.account, COALESCE(l.title,''), t.list_id, t.google_id, t.title, t.due, t.status, t.link, COALESCE(t.notes,'')
            FROM gtask t LEFT JOIN glist l ON l.account=t.account AND l.list_id=t.list_id
            WHERE t.status='needsAction' OR t.completed>=? ORDER BY t.due IS NULL, t.due, t.id
            """, [completedSince]) { st in
            out.append(["account": col(st, 0), "list": col(st, 1), "listId": col(st, 2), "id": col(st, 3), "title": col(st, 4),
                        "due": sqlite3_column_type(st, 5) == SQLITE_NULL ? NSNull() : col(st, 5) as Any,
                        "done": col(st, 6) == "completed",
                        "link": sqlite3_column_type(st, 7) == SQLITE_NULL ? NSNull() : col(st, 7) as Any, "notes": col(st, 8)])
        }
        return out
    }
}

func rfc3339(_ s: String) -> Double? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d.timeIntervalSince1970 }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)?.timeIntervalSince1970
}

func col(_ st: OpaquePointer, _ i: Int32) -> String {
    guard let c = sqlite3_column_text(st, i) else { return "" }
    return String(cString: c)
}

// MARK: - Privacy

/// Kya record nahi karna: password, email, login/payment pages. In jagah sirf app/site ka naam
/// save hota hai — title, poora link aur screen ka content kabhi nahi padha jaata.
enum Privacy {
    static let mark = "🔒 Private"

    /// Inke andar kya chal raha hai wo kabhi nahi padhte (sirf app ka naam)
    static let apps: Set<String> = [
        "com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.apple.MobileSMS",
        "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "com.apple.keychainaccess", "com.apple.Passwords",
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.lastpass.LastPass",
        "org.keepassxc.keepassxc", "com.dashlane.dashlanephonefinal", "com.apple.systempreferences",
    ]
    /// Purane data ke liye, jab bundle id pata nahi
    static let appNames: Set<String> = [
        "mail", "microsoft outlook", "spark", "messages", "whatsapp", "telegram", "keychain access", "passwords",
        "1password", "1password 7", "bitwarden", "lastpass", "keepassxc", "dashlane", "system settings",
    ]
    /// In websites pe sirf site ka naam (jaise "mail.google.com"), page ka title / link nahi
    static let sites = [
        "mail.google.com", "inbox.google.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com",
        "mail.yahoo.com", "mail.proton.me", "mail.zoho.in", "mail.zoho.com", "accounts.google.com",
        "myaccount.google.com", "passwords.google.com", "login.microsoftonline.com", "login.live.com",
        "appleid.apple.com", "account.apple.com", "icloud.com", "1password.com", "bitwarden.com", "lastpass.com",
        "web.whatsapp.com", "web.telegram.org", "paypal.com", "razorpay.com", "paytm.com", "phonepe.com",
        "netbanking", "onlinesbi", "hdfcbank", "icicibank", "axisbank", "kotak", "bank",
    ]
    /// Link ya title me ye shabd ho to login / password / payment page maano
    static let words = [
        "login", "log-in", "log_in", "signin", "sign-in", "sign_in", "sign in", "signup", "sign-up", "password",
        "passwd", "passcode", "oauth", "/auth/", "/sso", "/2fa", "/mfa", "/otp", "two-factor", "verification code",
        "reset password", "password reset", "checkout", "payment", "billing", "credential", "card number",
        "inbox", "gmail", "unlock", "api-key", "api_key", "apikey", "api key", "access-token", "access token",
        "/tokens", "/secrets", "/keys", "private key", "seed phrase", "recovery code", "/security",
    ]

    /// categories.json ke "private" section se aur sites / shabd (app rebuild ke bina badal sakte ho)
    static var extraSites: [String] = []
    static var extraWords: [String] = []
    static func loadExtra() {
        guard let data = try? Data(contentsOf: catsURL),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let p = cfg["private"] as? [String: Any] else { return }
        extraSites = (p["sites"] as? [String] ?? []).map { $0.lowercased() }.filter { !$0.isEmpty }
        extraWords = (p["words"] as? [String] ?? []).map { $0.lowercased() }.filter { !$0.isEmpty }
    }

    static func isPrivateSite(_ domain: String) -> Bool {
        !domain.isEmpty && (sites + extraSites).contains { domain == $0 || domain.hasSuffix("." + $0) || (!$0.contains(".") && domain.contains($0)) }
    }

    static func hasPrivateWord(_ text: String) -> Bool {
        let t = text.lowercased()
        return (words + extraWords).contains { t.contains($0) }
    }

    /// Link se login/token wali cheezein hata do: user:password@, ?query, #fragment
    static func cleanURL(_ s: String) -> String {
        guard var c = URLComponents(string: s), let scheme = c.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return "" }
        c.user = nil; c.password = nil; c.query = nil; c.fragment = nil
        return c.string ?? ""
    }

    /// Ek activity ko privacy rules se guzaro (naye aur purane dono data ke liye)
    static func apply(_ a: Activity, privateApp: Bool) -> Activity {
        var a = a
        a.url = cleanURL(a.url)
        a.domain = domainOf(a.url).isEmpty ? a.domain : domainOf(a.url)
        if privateApp || appNames.contains(a.app.lowercased()) || isPrivateSite(a.domain)
            || hasPrivateWord(a.url) || hasPrivateWord(a.title) {
            a.title = mark
            a.url = ""
        }
        return a
    }
}

// MARK: - Tracking

final class Tracker {
    let store: Store
    var paused = UserDefaults.standard.bool(forKey: "paused") {
        didSet { UserDefaults.standard.set(paused, forKey: "paused"); lastKey = nil; lastActive = 0 }
    }
    private var lastId: Int64 = 0, lastKey: [String]?, lastEnd: Double = 0, lastStart: Double = 0
    /// Aakhri baar keyboard/mouse kab chala — away yahin se shuru hota hai (idle wale 2 min bhi away me)
    private(set) var lastInput: Double = 0
    private var scripts: [String: NSAppleScript] = [:]
    private(set) var lastActive: Double = 0
    /// Abhi wali activity (notifications ke liye)
    private(set) var last: Activity?
    /// Away se lautne pe (kitne second door the)
    var onReturn: ((Double) -> Void)?

    init(store: Store) { self.store = store }

    func tick() {
        let now = Date().timeIntervalSince1970
        guard !paused, let a = current() else { lastKey = nil; last = nil; return }
        // Gap (idle / screen lock / sleep) = "Away" period, user ke jaane ke time se
        if lastActive > 0 {
            let left = min(lastInput > 0 ? lastInput : lastActive + POLL, lastActive + POLL)
            if now - left >= Settings.awayMinutes * 60 {
                // idle wait wala time kaam me gina gaya tha — wo hata do
                if lastId > 0 && lastStart < left && lastEnd + POLL > left { store.setEnd(lastId, left) }
                lastKey = nil
                store.addAway(left, now)
                onReturn?(now - left)
            }
        }
        lastActive = now
        lastInput = now - CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        last = a
        let key = [a.app, a.title, a.url, a.domain]
        if key == lastKey && now - lastEnd <= MERGE_GAP {
            store.setEnd(lastId, now + POLL)
        } else {
            lastId = store.insert(now, now + POLL, a)
            lastKey = key
            lastStart = now
        }
        lastEnd = now
    }

    /// Abhi kya chal raha hai — nil agar user away hai / screen lock hai.
    func current() -> Activity? {
        let anyInput = CGEventType(rawValue: ~0)!
        if CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) >= Settings.idleMinutes * 60 { return nil }
        if let s = CGSessionCopyCurrentDictionary() as? [String: Any],
           (s["CGSSessionScreenIsLocked"] as? Bool) == true { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let bid = app.bundleIdentifier ?? ""
        if ignoredApps.contains(bid) || ignoredAppNames.contains(app.localizedName ?? "") { return nil }

        var a = Activity(app: fullName(app), title: "", url: "", domain: "")
        // Koi password field active hai (macOS "secure input") ya password/email app — kuch mat padho
        if IsSecureEventInputEnabled() || Privacy.apps.contains(bid) {
            a.title = Privacy.mark
            if let kind = browsers[bid], let tab = browserURL(bid, kind), !tab.incognito {
                a.domain = domainOf(Privacy.cleanURL(tab.url))   // sirf site ka naam
            }
            return a
        }
        if let kind = browsers[bid] {
            // Pehle sirf link dekho; private / incognito / login page ho to title padho hi mat
            guard let tab = browserURL(bid, kind) else {
                a.title = windowTitle(app.processIdentifier)   // browser ne permission nahi di
                return Privacy.apply(a, privateApp: false)
            }
            if tab.incognito { a.title = Privacy.mark; return a }
            if let special = browserPage(tab.url) {   // new tab, local file, browser settings
                a.domain = special
                a.title = special == "local file" ? browserTitle(bid, kind) : ""
                return Privacy.apply(a, privateApp: false)
            }
            a.url = tab.url
            a.domain = domainOf(Privacy.cleanURL(tab.url))
            a = Privacy.apply(a, privateApp: false)
            if a.title != Privacy.mark { a.title = browserTitle(bid, kind) }
        } else {
            a.title = windowTitle(app.processIdentifier)
        }
        return Privacy.apply(a, privateApp: false)
    }

    /// Website nahi hai to page ki pehchaan: "new tab", "local file", "DeskTime dashboard", "browser settings"
    private func browserPage(_ url: String) -> String? {
        let u = url.lowercased()
        if u.hasPrefix("http://") || u.hasPrefix("https://") { return nil }
        if u.isEmpty || u.contains("newtab") || u.hasPrefix("about:blank") || u.hasPrefix("chrome-search:") || u.hasPrefix("favorites://") {
            return "new tab"
        }
        if u.hasPrefix("file:") { return u.contains("desktime") && u.contains("report.html") ? "DeskTime dashboard" : "local file" }
        return "browser settings"
    }

    /// App ka poora naam (.app file ka naam) — jaise VS Code ka "Code" nahi, "Visual Studio Code".
    private func fullName(_ app: NSRunningApplication) -> String {
        if let url = app.bundleURL, url.pathExtension == "app" { return url.deletingPathExtension().lastPathComponent }
        return app.localizedName ?? app.bundleIdentifier ?? "Unknown"
    }

    private func windowTitle(_ pid: pid_t) -> String {
        let app = AXUIElementCreateApplication(pid)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let win else { return "" }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
        else { return "" }
        return title as? String ?? ""
    }

    private func run(_ key: String, _ src: String) -> String? {
        if scripts[key] == nil { scripts[key] = NSAppleScript(source: src) }
        var err: NSDictionary?
        return scripts[key]?.executeAndReturnError(&err).stringValue
    }

    /// Active tab ka link + incognito hai ya nahi (title yahan nahi padhte)
    private func browserURL(_ bid: String, _ kind: String) -> (url: String, incognito: Bool)? {
        let src = kind == "chrome" ? """
            tell application id "\(bid)"
                set m to "normal"
                try
                    set m to mode of front window
                end try
                return m & linefeed & (URL of active tab of front window)
            end tell
            """ : "tell application id \"\(bid)\" to return \"normal\" & linefeed & (URL of front document)"
        guard let out = run(bid + ":url", src) else { return nil }
        let parts = out.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return (String(parts[1]), parts[0] == "incognito")
    }

    private func browserTitle(_ bid: String, _ kind: String) -> String {
        let src = kind == "chrome" ? "tell application id \"\(bid)\" to return title of active tab of front window"
                                   : "tell application id \"\(bid)\" to return name of front document"
        return run(bid + ":title", src) ?? ""
    }
}

func domainOf(_ url: String) -> String {
    guard let r = url.range(of: "://") else { return "" }
    var host = String(url[r.upperBound...].split(separator: "/", maxSplits: 1).first ?? "")
    host = String(host.split(separator: "@").last ?? "")
    host = String(host.split(separator: ":").first ?? "").lowercased()
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
}

// MARK: - Categories

struct Rules {
    var categories: [String: Any] = [:]
    var domains: [(String, String)] = []
    var apps: [String: String] = [:]

    static func load() -> Rules {
        var r = Rules()
        guard let data = try? Data(contentsOf: catsURL),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return r }
        r.categories = cfg["categories"] as? [String: Any] ?? [:]
        // lambi key pehle, taaki "docs.google.com" "google.com" se pehle match ho
        r.domains = (cfg["domains"] as? [String: String] ?? [:]).sorted { $0.key.count > $1.key.count }
        r.apps = cfg["apps"] as? [String: String] ?? [:]
        return r
    }

    func categorize(_ app: String, _ domain: String) -> String {
        if !domain.isEmpty {
            for (key, cat) in domains where domain == key || domain.hasSuffix("." + key) { return cat }
            for (key, cat) in domains where domain.contains(key) { return cat }
        }
        let name = app.lowercased()
        if let cat = apps[name] { return cat }
        for (key, cat) in apps.sorted(by: { $0.key.count > $1.key.count }) where key.count >= 5 && name.contains(key) {
            return cat
        }
        return "Other"
    }

    func color(_ cat: String) -> NSColor {
        let info = (categories[cat] ?? categories["Other"]) as? [String: Any]
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let hex = (isDark ? info?["dark"] as? String : nil) ?? info?["color"] as? String ?? "#8a93a3"
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0x868e96
        return NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    func productive(_ cat: String) -> Bool? {
        (categories[cat] as? [String: Any])?["productive"] as? Bool
    }
}

func fmt(_ sec: Double) -> String {
    let s = Int(sec.rounded()), h = s / 3600, m = s % 3600 / 60
    if h > 0 { return "\(h)h \(String(format: "%02d", m))m" }
    if m > 0 { return "\(m)m" }
    return "\(s)s"
}

// MARK: - Agenda (Mac ka Calendar + Reminders — Google account System Settings → Internet Accounts se judta hai)

final class Agenda {
    let store = EKEventStore()

    static let linkRegex = try! NSRegularExpression(pattern:
        #"https?://(meet\.google\.com/[a-z0-9\-]+|[\w.-]*zoom\.us/(j|my)/[^\s<>"]+|teams\.microsoft\.com/l/meetup-join/[^\s<>"]+|[\w.-]*webex\.com/[^\s<>"]+)"#,
        options: [.caseInsensitive])

    var access: String {
        let st = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            if st == .fullAccess { return "granted" }
        }
        if st == .authorized { return "granted" }
        return st == .notDetermined ? "ask" : "denied"
    }

    func requestAccess(_ done: @escaping () -> Void) {
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { _, _ in
                self.store.requestFullAccessToReminders { _, _ in DispatchQueue.main.async(execute: done) }
            }
        } else {
            store.requestAccess(to: .event) { _, _ in
                self.store.requestAccess(to: .reminder) { _, _ in DispatchQueue.main.async(execute: done) }
            }
        }
    }

    /// Meeting ka link (Meet / Zoom / Teams / Webex) — event ke URL, location ya notes se
    static func meetingLink(_ e: EKEvent) -> String? {
        for text in [e.url?.absoluteString, e.location, e.notes].compactMap({ $0 }) {
            let r = NSRange(text.startIndex..., in: text)
            if let m = linkRegex.firstMatch(in: text, range: r), let rr = Range(m.range, in: text) { return String(text[rr]) }
        }
        return nil
    }

    func events(_ start: Date, _ end: Date) -> [EKEvent] {
        guard access == "granted" else { return [] }
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: pred).filter { $0.status != .canceled }.sorted { $0.startDate < $1.startDate }
    }

    func eventsJSON(_ start: Date, _ end: Date) -> [[String: Any]] {
        events(start, end).map { e in
            ["id": e.eventIdentifier ?? "", "title": e.title ?? "(no title)", "start": e.startDate.timeIntervalSince1970,
             "end": e.endDate.timeIntervalSince1970, "allDay": e.isAllDay, "calendar": e.calendar?.title ?? "",
             "color": e.calendar.map { hex($0.color) } ?? "#8a93a3", "link": Agenda.meetingLink(e) ?? NSNull(),
             "location": (e.location ?? "").count > 80 ? "" : (e.location ?? "")] as [String: Any]
        }
    }

    /// Apple Reminders jinki due date is range me hai (callback me — EventKit async hai)
    func reminders(_ start: Date, _ end: Date, _ done: @escaping ([[String: Any]]) -> Void) {
        let st = EKEventStore.authorizationStatus(for: .reminder)
        var ok = st == .authorized
        if #available(macOS 14.0, *) { ok = ok || st == .fullAccess }
        guard ok else { return done([]) }
        let pred = store.predicateForIncompleteReminders(withDueDateStarting: start, ending: end, calendars: nil)
        store.fetchReminders(matching: pred) { list in
            let out = (list ?? []).compactMap { r -> [String: Any]? in
                guard let due = r.dueDateComponents?.date else { return nil }
                return ["title": r.title ?? "", "due": due.timeIntervalSince1970, "list": r.calendar?.title ?? ""]
            }
            DispatchQueue.main.async { done(out) }
        }
    }

    private func hex(_ c: NSColor) -> String {
        guard let s = c.usingColorSpace(.sRGB) else { return "#8a93a3" }
        return String(format: "#%02x%02x%02x", Int(s.redComponent * 255), Int(s.greenComponent * 255), Int(s.blueComponent * 255))
    }
}

// MARK: - Google Tasks (OAuth: login Google ke page pe browser me; token sirf Mac ki Keychain me)

enum Keychain {
    static let service = "app.desktimetracker.google"

    static func set(_ value: String, _ account: String) {
        delete(account)
        SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                    kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock, kSecValueData: Data(value.utf8)] as CFDictionary, nil)
    }
    static func get(_ account: String) -> String? {
        var out: CFTypeRef?
        let q = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                 kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary
        guard SecItemCopyMatching(q, &out) == errSecSuccess, let d = out as? Data else { return migrate(account) }
        return String(data: d, encoding: .utf8)
    }
    /// App ID badalne se pehle wala item (koi bhi "*.desktime.google" service) naye naam pe le aao
    private static func migrate(_ account: String) -> String? {
        var found: CFTypeRef?
        let q = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: account,
                 kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll] as CFDictionary
        guard SecItemCopyMatching(q, &found) == errSecSuccess, let items = found as? [[String: Any]],
              let old = items.compactMap({ $0[kSecAttrService as String] as? String })
                .first(where: { $0 != service && $0.hasSuffix(".desktime.google") }) else { return nil }
        var out: CFTypeRef?
        let dq = [kSecClass: kSecClassGenericPassword, kSecAttrService: old, kSecAttrAccount: account,
                  kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary
        guard SecItemCopyMatching(dq, &out) == errSecSuccess, let d = out as? Data,
              let v = String(data: d, encoding: .utf8) else { return nil }
        set(v, account)
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: old, kSecAttrAccount: account] as CFDictionary)
        return v
    }
    static func delete(_ account: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
    }
}

final class GoogleTasks {
    private let store: Store
    private let cfgURL = supportDir.appendingPathComponent("google.json")
    private(set) var clientID = ""
    // Keychain sirf zaroorat pe aur ek hi baar padho — har padhai pe macOS password popup dikha sakta hai
    private var hasSecret = false
    private var secretMemo: String?
    private var refreshMemo: [String: String] = [:]
    private var access: [String: (token: String, exp: Double)] = [:]
    private var listener: NWListener?
    private var syncing = Set<String>()
    private let monitor = NWPathMonitor()
    private(set) var online = true

    init(store: Store) {
        self.store = store
        load()
        // Internet wapas aaye to turant sync
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let was = self.online
            self.online = path.status == .satisfied
            if !was && self.online { self.refresh(force: true) { _ in } }
        }
        monitor.start(queue: .main)
    }

    var configured: Bool { !clientID.isEmpty && hasSecret }

    private func secret() -> String? {
        if secretMemo == nil { secretMemo = Keychain.get("client-secret") }
        return secretMemo
    }
    private func refreshToken(_ email: String) -> String? {
        if refreshMemo[email] == nil { refreshMemo[email] = Keychain.get("refresh:" + email) }
        return refreshMemo[email]
    }
    var accounts: [String] { store.gAccounts().map(\.email) }
    /// Sab khule tasks + pichhle 3 din me pure hue (dashboard aur subah ka schedule)
    var cache: [[String: Any]] { store.gTasks(completedSince: Date().timeIntervalSince1970 - 3 * 86400) }

    private func load() {
        guard let d = try? Data(contentsOf: cfgURL), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        clientID = j["client_id"] as? String ?? ""
        hasSecret = j["has_secret"] as? Bool ?? !clientID.isEmpty   // purani file me ye flag nahi tha
        // Purana version accounts google.json me rakhta tha — ab DB me
        if let old = j["accounts"] as? [String], !old.isEmpty {
            let have = Set(accounts)
            for e in old where !have.contains(e) { store.gAddAccount(e, userID: "") }
            save()
        }
    }
    private func save() {
        if let d = try? JSONSerialization.data(withJSONObject: ["client_id": clientID, "has_secret": hasSecret] as [String: Any], options: .prettyPrinted) {
            try? d.write(to: cfgURL)
            chmod(cfgURL.path, 0o600)
        }
    }

    func setClient(id: String, secret: String) {
        clientID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { Keychain.set(s, "client-secret"); secretMemo = s; hasSecret = true }
        save()
    }

    var info: [String: Any] {
        let accs = store.gAccounts()
        let errs = accs.compactMap { a -> String? in
            switch a.status {
            case "reauth": return "\(a.email): access expired or was removed — click Reconnect in Settings."
            case "retry": return "\(a.email): \(a.error) Will try again soon."
            default: return nil
            }
        }
        let error: Any = !online && !accs.isEmpty ? "Offline — showing saved tasks. They’ll sync when you’re back online."
                       : errs.isEmpty ? NSNull() as Any : errs.joined(separator: "\n")
        return ["configured": configured, "clientId": clientID, "accounts": accs.map(\.email), "online": online, "error": error,
                "details": accs.map { ["email": $0.email, "status": $0.status, "error": $0.error,
                                       "lastSynced": $0.lastSynced > 0 ? $0.lastSynced : NSNull()] as [String: Any] }]
    }

    // --- HTTP ---
    private func call(_ url: URL, method: String = "GET", form: [String: String]? = nil, json: [String: Any]? = nil,
                      bearer: String? = nil, _ cb: @escaping (Int, [String: Any]) -> Void) {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let form {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var c = URLComponents()
            c.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            req.httpBody = (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0   // 0 = network nahi mila
            let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            DispatchQueue.main.async { cb(code, body) }
        }.resume()
    }

    private static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func jwtPayload(_ jwt: String) -> [String: Any] {
        let parts = jwt.split(separator: ".")
        var p = parts.count > 1 ? String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") : ""
        while p.count % 4 != 0 { p += "=" }
        return Data(base64Encoded: p).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    // --- Connect: browser me Google login, jawab 127.0.0.1 pe aata hai ---
    func connect(_ done: @escaping (String?) -> Void) {
        guard configured, let secret = secret() else { return done("Add the Client ID and secret first.") }
        listener?.cancel()
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = GoogleTasks.b64url(Data(bytes))
        let challenge = GoogleTasks.b64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = UUID().uuidString
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let l = try? NWListener(using: params) else { return done("Could not start the sign-in helper.") }
        listener = l
        var finished = false
        let finish: (String?) -> Void = { err in
            guard !finished else { return }
            finished = true
            l.cancel()
            done(err)
        }
        l.stateUpdateHandler = { st in
            guard case .ready = st, let port = l.port?.rawValue else { return }
            var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            c.queryItems = [.init(name: "client_id", value: self.clientID), .init(name: "redirect_uri", value: "http://127.0.0.1:\(port)"),
                            .init(name: "response_type", value: "code"), .init(name: "scope", value: "openid email https://www.googleapis.com/auth/tasks"),
                            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
                            .init(name: "state", value: state), .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent select_account")]
            NSWorkspace.shared.open(c.url!)
        }
        l.newConnectionHandler = { conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
                let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let q = URLComponents(string: "http://x" + path)?.queryItems ?? []
                let code = q.first { $0.name == "code" }?.value
                let ok = code != nil && q.first { $0.name == "state" }?.value == state
                let page = ok ? "Connected. You can close this tab and go back to DeskTime." : "Sign-in didn’t finish. Go back to DeskTime and try again."
                let html = "<!doctype html><meta charset=utf-8><title>DeskTime</title><body style=\"font:16px -apple-system;padding:40px\">\(page)</body>"
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(html.utf8.count)\r\n\r\n\(html)"
                conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
                guard path.contains("code=") || path.contains("error=") else { return }   // favicon waghaira
                guard ok, let code, let port = l.port?.rawValue else { return finish("Sign-in was cancelled.") }
                self.call(URL(string: "https://oauth2.googleapis.com/token")!, method: "POST", form: [
                    "code": code, "client_id": self.clientID, "client_secret": secret, "code_verifier": verifier,
                    "grant_type": "authorization_code", "redirect_uri": "http://127.0.0.1:\(port)"]) { status, body in
                    guard status == 200, let refresh = body["refresh_token"] as? String, let idt = body["id_token"] as? String else {
                        return finish((body["error_description"] as? String) ?? "Google didn’t return a sign-in token.")
                    }
                    // Google ke page pe "Tasks" wala box untick kiya ho to token bekaar hai
                    guard (body["scope"] as? String ?? "").contains("auth/tasks") else {
                        self.call(URL(string: "https://oauth2.googleapis.com/revoke")!, method: "POST", form: ["token": refresh]) { _, _ in }
                        return finish("Tick the “View and edit your tasks” box on Google’s page, then try again.")
                    }
                    let claims = GoogleTasks.jwtPayload(idt)
                    let email = claims["email"] as? String ?? "Google account"
                    Keychain.set(refresh, "refresh:" + email)
                    self.refreshMemo[email] = refresh
                    if let tok = body["access_token"] as? String {
                        self.access[email] = (tok, Date().timeIntervalSince1970 + ((body["expires_in"] as? Double) ?? 3600))
                    }
                    self.store.gAddAccount(email, userID: claims["sub"] as? String ?? "")
                    self.sync(email, force: true) { finish(nil) }
                }
            }
        }
        l.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { finish("Sign-in timed out. Try again.") }
    }

    func disconnect(_ email: String) {
        if let r = refreshToken(email) {
            call(URL(string: "https://oauth2.googleapis.com/revoke")!, method: "POST", form: ["token": r]) { _, _ in }
        }
        Keychain.delete("refresh:" + email)
        refreshMemo[email] = nil
        access[email] = nil
        store.gRemoveAccount(email)
    }

    // --- Token + API call (401 pe ek baar naya token lekar dobara) ---
    private enum Result { case ok([String: Any]), offline, reauth, retry(String) }

    private func token(_ email: String, force: Bool, _ cb: @escaping (Result) -> Void) {
        if !force, let a = access[email], a.exp > Date().timeIntervalSince1970 + 120 { return cb(.ok(["token": a.token])) }
        guard let r = refreshToken(email), let secret = secret() else { return cb(.reauth) }
        call(URL(string: "https://oauth2.googleapis.com/token")!, method: "POST", form: [
            "client_id": clientID, "client_secret": secret, "refresh_token": r, "grant_type": "refresh_token"]) { status, body in
            if status == 200, let tok = body["access_token"] as? String {
                self.access[email] = (tok, Date().timeIntervalSince1970 + ((body["expires_in"] as? Double) ?? 3600))
                return cb(.ok(["token": tok]))
            }
            self.access[email] = nil
            if status == 0 { return cb(.offline) }
            // invalid_grant = user ne access hata diya, password badla, ya token expire (7 din wala "Testing" app)
            if body["error"] as? String == "invalid_grant" { return cb(.reauth) }
            cb(.retry((body["error_description"] as? String) ?? "Google sign-in failed (\(status))."))
        }
    }

    private func api(_ email: String, _ url: URL, method: String = "GET", json: [String: Any]? = nil, retried: Bool = false,
                     _ cb: @escaping (Result) -> Void) {
        token(email, force: retried) { auth in
            guard case .ok(let t) = auth, let tok = t["token"] as? String else { return cb(auth) }
            self.call(url, method: method, json: json, bearer: tok) { status, body in
                let err = body["error"] as? [String: Any] ?? [:]
                let reason = ((err["errors"] as? [[String: Any]])?.first?["reason"] as? String ?? "") + " " + (err["status"] as? String ?? "")
                switch status {
                case 200..<300: cb(.ok(body))
                case 0: cb(.offline)
                case 401 where !retried: self.api(email, url, method: method, json: json, retried: true, cb)
                case 401: cb(.reauth)
                case 403 where reason.contains("insufficientPermissions") || (err["message"] as? String ?? "").contains("insufficient authentication scopes"):
                    cb(.reauth)
                case 429:
                    cb(.retry("Google is rate-limiting requests."))
                case 403 where reason.lowercased().contains("ratelimit"):
                    cb(.retry("Google is rate-limiting requests."))
                case 500...:
                    cb(.retry("Google Tasks is having trouble (\(status))."))
                default:
                    cb(.retry((err["message"] as? String).map { String($0.prefix(160)) } ?? "Google Tasks error \(status)."))
                }
            }
        }
    }

    /// nextPageToken ke saath saare pages
    private func pages(_ email: String, _ base: URLComponents, pageToken: String? = nil, items: [[String: Any]] = [],
                       _ cb: @escaping (Result?, [[String: Any]]) -> Void) {
        var c = base
        if let pageToken { c.queryItems = (c.queryItems ?? []) + [.init(name: "pageToken", value: pageToken)] }
        api(email, c.url!) { r in
            guard case .ok(let body) = r else { return cb(r, items) }
            let all = items + (body["items"] as? [[String: Any]] ?? [])
            if let next = body["nextPageToken"] as? String, !next.isEmpty, all.count < 5000 {
                self.pages(email, base, pageToken: next, items: all, cb)
            } else {
                cb(nil, all)
            }
        }
    }

    // --- Sync engine ---

    /// Sab accounts sync karo. force = abhi turant (interval aur retry-wait dono chhod ke).
    func refresh(force: Bool = false, _ done: @escaping ([[String: Any]]) -> Void) {
        let emails = configured ? accounts : []
        guard !emails.isEmpty else { return done(cache) }
        var left = emails.count
        for e in emails { sync(e, force: force) { left -= 1; if left == 0 { done(self.cache) } } }
    }

    /// Ek account: lists → har list ke badle hue tasks (updatedMin) → DB me merge → naye tasks ki notification
    private func sync(_ email: String, force: Bool, _ done: @escaping () -> Void) {
        guard let acc = store.gAccounts().first(where: { $0.email == email }), !syncing.contains(email) else { return done() }
        let now = Date().timeIntervalSince1970
        if acc.status == "reauth" && !force { return done() }
        if !force && acc.nextTry > now { return done() }                                       // retry ka wait
        if !force && acc.status == "ok" && now - acc.lastSynced < Settings.gtaskSyncMinutes * 60 - 5 { return done() }
        guard online else {
            if acc.status != "reauth" { store.gSetState(email, "offline", fails: acc.fails, nextTry: acc.nextTry) }
            return done()
        }
        syncing.insert(email)
        // 2 min peeche ka cursor: Mac/Google ki ghadi ka farq aur sync ke beech badle tasks na chhootein
        let f = ISO8601DateFormatter()
        let cursor = f.string(from: Date(timeIntervalSince1970: now - 120))
        let finish: (Result?) -> Void = { r in
            self.syncing.remove(email)
            switch r {
            case .offline:
                self.store.gSetState(email, "offline", fails: acc.fails, nextTry: 0)
            case .reauth:
                if acc.status != "reauth" {
                    notify("Google Tasks disconnected", "\(email): access expired or was removed. Open Settings → Google Tasks → Reconnect.", open: "settings")
                }
                self.access[email] = nil
                self.store.gSetState(email, "reauth", error: "Access expired or was removed.")
            case .retry(let msg):
                // 1, 2, 4, 8 … minute, zyada se zyada 1 ghanta
                let fails = acc.fails + 1
                let wait = min(3600, 60 * pow(2, Double(min(fails - 1, 6)))) + Double.random(in: 0...20)
                self.store.gSetState(email, "retry", error: msg, fails: fails, nextTry: now + wait)
            case .ok, nil:
                self.store.gSetState(email, "ok", synced: Date().timeIntervalSince1970)
                self.announceNew()
            }
            done()
        }
        var lists = URLComponents(string: "https://tasks.googleapis.com/tasks/v1/users/@me/lists")!
        lists.queryItems = [.init(name: "maxResults", value: "100")]
        pages(email, lists) { err, items in
            if let err { return finish(err) }
            let known = self.store.gCursors(email)
            let ids = Set(items.compactMap { $0["id"] as? String })
            for gone in known.keys where !ids.contains(gone) { self.store.gDropList(email, gone) }   // list Google pe delete hui
            self.syncLists(email, items[...], known, cursor, finish)
        }
    }

    private func syncLists(_ email: String, _ lists: ArraySlice<[String: Any]>, _ known: [String: String], _ cursor: String,
                           _ done: @escaping (Result?) -> Void) {
        guard let list = lists.first else { return done(nil) }
        guard let lid = list["id"] as? String,
              let path = lid.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))),
              let base = URLComponents(string: "https://tasks.googleapis.com/tasks/v1/lists/\(path)/tasks") else {
            return syncLists(email, lists.dropFirst(), known, cursor, done)
        }
        let item = { (k: String, v: String) in URLQueryItem(name: k, value: v) }
        let since = known[lid].flatMap { $0.isEmpty ? nil : $0 }
        let passes: [[URLQueryItem]] = since.map {
            // Incremental: sirf cursor ke baad badle — pure hue, chhupe aur delete hue bhi, taaki DB sahi rahe
            [[item("updatedMin", $0), item("showCompleted", "true"), item("showHidden", "true"), item("showDeleted", "true"), item("maxResults", "100")]]
        } ?? [
            // Pehli baar: saare khule tasks + pichhle 3 din me pure hue
            [item("showCompleted", "false"), item("maxResults", "100")],
            [item("showCompleted", "true"), item("showHidden", "true"), item("maxResults", "100"),
             item("completedMin", ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 86400)))],
        ]
        fetchPasses(email, base, passes[...], []) { err, tasks in
            if let err { return done(err) }
            // Pehli baar wale tasks chup-chaap import (purane tasks pe notifications ki baarish nahi)
            for t in tasks { self.store.gUpsert(email, list: lid, t, silent: since == nil) }
            self.store.gSaveList(email, lid, title: list["title"] as? String ?? "", cursor: cursor)
            self.syncLists(email, lists.dropFirst(), known, cursor, done)
        }
    }

    private func fetchPasses(_ email: String, _ base: URLComponents, _ passes: ArraySlice<[URLQueryItem]>, _ got: [[String: Any]],
                             _ done: @escaping (Result?, [[String: Any]]) -> Void) {
        guard let q = passes.first else { return done(nil, got) }
        var c = base
        c.queryItems = q
        pages(email, c) { err, items in
            if let err { return done(err, got) }
            self.fetchPasses(email, base, passes.dropFirst(), got + items, done)
        }
    }

    // --- Notifications ---

    private func announceNew() {
        let fresh = store.gTakeUnannounced()
        guard !fresh.isEmpty, Settings.notifyGtaskNew else { return }
        let multi = accounts.count > 1
        if fresh.count <= 3 {
            for t in fresh {
                let bits = [t.due.isEmpty ? nil : "Due \(GoogleTasks.prettyDay(t.due))", multi ? t.account : nil].compactMap { $0 }
                notify("New task: \(t.title)", bits.isEmpty ? "From Google Tasks" : bits.joined(separator: " · "), open: "agenda")
            }
        } else {
            notify("\(fresh.count) new Google tasks", fresh.prefix(4).map { "☐ \($0.title)" }.joined(separator: "\n"), open: "agenda")
        }
    }

    /// Google Tasks API sirf date deta hai, time nahi — isliye due wale din Settings.gtaskDueTime pe ek baar yaad dilao
    func checkDue() {
        guard Settings.notifyGtaskDue else { return }
        let parts = Settings.gtaskDueTime.split(separator: ":").compactMap { Int($0) }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        guard parts.count == 2, (c.hour ?? 0) * 60 + (c.minute ?? 0) >= parts[0] * 60 + parts[1] else { return }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let due = store.gTakeDue(df.string(from: Date()))
        guard !due.isEmpty else { return }
        if due.count <= 3 {
            for t in due { notify("Due today: \(t.title)", accounts.count > 1 ? "Google Tasks · \(t.account)" : "Google Tasks", open: "agenda") }
        } else {
            notify("\(due.count) Google tasks due today", due.prefix(4).map { "☐ \($0.title)" }.joined(separator: "\n"), open: "agenda")
        }
    }

    private static func prettyDay(_ ymd: String) -> String {
        let p = DateFormatter()
        p.dateFormat = "yyyy-MM-dd"
        guard let d = p.date(from: ymd) else { return ymd }
        if Calendar.current.isDateInToday(d) { return "today" }
        if Calendar.current.isDateInTomorrow(d) { return "tomorrow" }
        let f = DateFormatter()
        f.dateFormat = "EEE, d MMM"
        return f.string(from: d)
    }

    func setDone(account: String, list: String, id: String, done: Bool, _ cb: @escaping () -> Void) {
        guard let url = URL(string: "https://tasks.googleapis.com/tasks/v1/lists/\(list)/tasks/\(id)") else { return cb() }
        api(account, url, method: "PATCH", json: done ? ["status": "completed"] : ["status": "needsAction", "completed": NSNull()]) { r in
            if case .ok(let task) = r { self.store.gUpsert(account, list: list, task, silent: true) }
            cb()
        }
    }
}

// MARK: - Dashboard

/// Dashboard window. Page (dashboard_template.html) data `dt` bridge se maangta hai:
///   {type:"days", from:"2026-10-01", to:"2026-10-31"}  → {"2026-10-05": [[start,end,app,title,domain,url], ...]}
///   {type:"setCategory", kind:"app"|"domain", key, cat}  → nayi rules (categories.json)
final class Dashboard: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKUIDelegate {
    private(set) var window: NSWindow?
    private var pendingView: String?
    private var web: WKWebView!
    let store: Store
    let agenda: Agenda
    let google: GoogleTasks
    var status: () -> [String: Any] = { [:] }

    init(store: Store, agenda: Agenda, google: GoogleTasks) { self.store = store; self.agenda = agenda; self.google = google }

    func show(view: String? = nil) {
        if let view { pendingView = view }
        if window == nil {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()   // koi cookie / cache disk pe nahi
            config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "dt")
            web = WKWebView(frame: .zero, configuration: config)
            web.navigationDelegate = self
            web.uiDelegate = self
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 860),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "DeskTime"
            w.contentView = web
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 420, height: 400)
            w.center()
            w.setFrameAutosaveName("Dashboard")
            window = w
            reload()
        } else if window?.isVisible == false {
            reload()   // band window dobara khuli — disk se naya UI lo (install.sh ke baad purana page na dikhe)
        } else {
            web.evaluateJavaScript("window.refresh && refresh()")
            if let v = pendingView { web.evaluateJavaScript("window.goView && goView('\(v)')"); pendingView = nil }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Dashboard ki files ~/Library/Application Support/DeskTimeTracker/web me hoti hain (install.sh rakhta hai),
    /// taaki UI badalne pe app dobara build na ho aur macOS permission na maange.
    private func webFile(_ name: String, _ ext: String) -> String? {
        let local = supportDir.appendingPathComponent("web/\(name).\(ext)")
        let url = FileManager.default.fileExists(atPath: local.path) ? local : Bundle.main.url(forResource: name, withExtension: ext)
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    func reload() {
        guard window != nil, var template = webFile("dashboard_template", "html") else { return }
        template = template.replacingOccurrences(of: "<!--ECHARTS-->",
                                                 with: "<script>" + (webFile("echarts.min", "js") ?? "") + "</script>")
        let genFmt = DateFormatter()
        genFmt.dateFormat = "dd MMM yyyy, hh:mm a"
        let data = "{\"generated\":\(json(genFmt.string(from: Date()))),\"rules\":\(rulesJSON()),\"days\":{}}"
        let start = pendingView.map { "#\($0)/" + { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }() } ?? ""
        pendingView = nil
        web.loadHTMLString(template.replacingOccurrences(of: "/*__DATA__*/null", with: data)
            .replacingOccurrences(of: "/*__START__*/''", with: "'\(start)'"), baseURL: nil)
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        let body = message.body as? [String: Any] ?? [:]
        switch body["type"] as? String {
        case "days":
            replyHandler(daysJSON(from: body["from"] as? String ?? "", to: body["to"] as? String ?? ""), nil)
        case "summary":   // mini calendar ke liye: har din ka total seconds
            replyHandler(summaryJSON(from: body["from"] as? String ?? "", to: body["to"] as? String ?? ""), nil)
        case "setCategory":
            setCategory(kind: body["kind"] as? String ?? "", key: body["key"] as? String ?? "",
                        cat: body["cat"] as? String ?? "")
            replyHandler(rulesJSON(), nil)
        case "extras":    // away periods + projects for a range
            let (a, b) = range(body["from"] as? String ?? "", body["to"] as? String ?? "")
            let running = store.runningProject()
            replyHandler(json(["away": store.awayRows(since: a, until: b), "projects": store.projectRows(since: a, until: b),
                               "recent": store.recentProjects(),
                               "running": running.map { ["name": $0.name, "start": $0.start] as [String: Any] } ?? NSNull()]), nil)
        case "status":    // abhi kaam / break / paused
            replyHandler(json(status()), nil)
        case "agenda":
            let (a, b) = range(body["from"] as? String ?? "", body["to"] as? String ?? "")
            let s = Date(timeIntervalSince1970: a), e = Date(timeIntervalSince1970: b)
            let events = agenda.eventsJSON(s, e), tasks = store.tasks(since: a, until: b), access = agenda.access
            agenda.reminders(s, e) { rem in
                let send = { (g: [[String: Any]]) in
                    replyHandler(self.json(["access": access, "events": events, "reminders": rem, "tasks": tasks, "projects": self.store.recentProjects(20), "openTasks": self.store.openTasks(),
                                            "google": self.google.info, "gtasks": g]), nil)
                }
                // Google Tasks: cache turant, aur "fresh" maanga ho to dobara lao
                if (body["fresh"] as? Bool) == true { self.google.refresh(force: true, send) } else { send(self.google.cache) }
            }
        case "googleInfo":
            replyHandler(json(google.info), nil)
        case "googleSaveClient":
            google.setClient(id: body["clientId"] as? String ?? "", secret: body["clientSecret"] as? String ?? "")
            replyHandler(json(google.info), nil)
        case "googleConnect":
            google.connect { err in replyHandler(self.json(["error": err.map { $0 as Any } ?? NSNull(), "info": self.google.info]), nil) }
        case "googleDisconnect":
            google.disconnect(body["email"] as? String ?? "")
            replyHandler(json(google.info), nil)
        case "gtaskDone":
            google.setDone(account: body["account"] as? String ?? "", list: body["list"] as? String ?? "",
                           id: body["id"] as? String ?? "", done: body["done"] as? Bool ?? true) { replyHandler("ok", nil) }
        case "requestCalendar":
            agenda.requestAccess { replyHandler(self.agenda.access, nil) }
        case "openURL":   // Join button — sirf meeting / https links
            if let u = body["url"] as? String, u.lowercased().hasPrefix("https://"), let url = URL(string: u) { NSWorkspace.shared.open(url) }
            replyHandler("ok", nil)
        case "openPrivacy":
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            replyHandler("ok", nil)
        case "openSettings":
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
            replyHandler("ok", nil)
        case "addTask":
            let title = (body["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let project = (body["project"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let day = (body["day"] as? String).flatMap { $0.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? $0 : nil }
            if !title.isEmpty { store.addTask(String(title.prefix(200)), due: body["due"] as? Double, day: day, project: String(project.prefix(60))) }
            replyHandler("ok", nil)
        case "taskDone":
            store.setTaskDone((body["id"] as? NSNumber)?.int64Value ?? 0, body["done"] as? Bool ?? true)
            replyHandler("ok", nil)
        case "deleteTask":
            store.deleteTask((body["id"] as? NSNumber)?.int64Value ?? 0)
            replyHandler("ok", nil)
        case "setAwayLabel":
            store.setAwayLabel((body["id"] as? NSNumber)?.int64Value ?? 0, String((body["label"] as? String ?? "").prefix(100)))
            replyHandler("ok", nil)
        case "saveAway":  // break edit / naya break: {id (0 = naya), start, end, label}
            let label = (body["label"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let err = store.saveAway((body["id"] as? NSNumber)?.int64Value ?? 0, (body["start"] as? NSNumber)?.doubleValue ?? 0,
                                     (body["end"] as? NSNumber)?.doubleValue ?? 0, String(label.prefix(100)))
            replyHandler(json(["error": err.map { $0 as Any } ?? NSNull()]), nil)
        case "deleteAway":
            store.deleteAway((body["id"] as? NSNumber)?.int64Value ?? 0)
            replyHandler("ok", nil)
        case "projectStart":
            let name = (body["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { store.startProject(String(name.prefix(60))) }
            replyHandler("ok", nil)
        case "projectStop":
            store.stopProject()
            replyHandler("ok", nil)
        case "saveSettings":
            saveSettings(body)
            replyHandler(rulesJSON(), nil)
        case "save":      // CSV export — user khud jagah chunta hai
            saveFile(name: body["name"] as? String ?? "desktime.csv", content: body["content"] as? String ?? "")
            replyHandler("ok", nil)
        case "print":     // PDF ke liye print dialog
            if let window, let op = Optional(web.printOperation(with: NSPrintInfo.shared)) {
                op.view?.frame = web.bounds
                op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            }
            replyHandler("ok", nil)
        default:
            replyHandler(nil, "unknown message")
        }
    }

    /// from..to (dono shamil) din ke rows, har din ke midnight se seconds me
    private func daysJSON(from: String, to: String) -> String {
        let cal = Calendar.current
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        guard let d0 = dayFmt.date(from: from), let d1 = dayFmt.date(from: to),
              let end = cal.date(byAdding: .day, value: 1, to: d1) else { return "{}" }
        var days: [String: [[Any]]] = [:]
        for r in store.rows(since: d0.timeIntervalSince1970, until: end.timeIntervalSince1970) {
            var s = max(r.start, d0.timeIntervalSince1970)
            let e = min(r.end, end.timeIntervalSince1970)
            while s < e {   // raat 12 baje cross kare to do din me baant do
                let day0 = cal.startOfDay(for: Date(timeIntervalSince1970: s))
                let base = day0.timeIntervalSince1970
                let segEnd = min(e, cal.date(byAdding: .day, value: 1, to: day0)!.timeIntervalSince1970)
                days[dayFmt.string(from: day0), default: []].append(
                    [Int((s - base).rounded()), Int((segEnd - base).rounded()), r.app, r.title, r.domain, r.url])
                s = segEnd
            }
        }
        return json(days)
    }

    /// "yyyy-MM-dd" se "yyyy-MM-dd" (dono shamil) → (start, end) timestamps
    private func range(_ from: String, _ to: String) -> (Double, Double) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d0 = f.date(from: from), let d1 = f.date(from: to),
              let end = Calendar.current.date(byAdding: .day, value: 1, to: d1) else { return (0, 0) }
        return (d0.timeIntervalSince1970, end.timeIntervalSince1970)
    }

    private func saveSettings(_ body: [String: Any]) {
        guard let data = try? Data(contentsOf: catsURL),
              var cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let g = body["goal_hours"] as? Double, g > 0, g <= 16 { cfg["goal_hours"] = g }
        if let s = body["settings"] as? [String: Any] {
            var cur = cfg["settings"] as? [String: Any] ?? [:]
            for k in ["schedule_time", "gtask_due_time", "office_start", "office_end"] {
                if let t = s[k] as? String, t.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil { cur[k] = t }
            }
            for k in ["idle_minutes", "away_minutes", "distraction_minutes", "retention_days", "remind_minutes", "gtask_sync_minutes"] {
                if let v = s[k] as? Double { cur[k] = v }
            }
            for k in ["notify_goal", "notify_distraction", "notify_away", "notify_schedule", "notify_gtask_new", "notify_gtask_due", "office_on"] {
                if let v = s[k] as? Bool { cur[k] = v }
            }
            if let d = s["office_days"] as? [Int] { cur["office_days"] = Array(Set(d.filter { (0...6).contains($0) })).sorted() }
            cfg["settings"] = cur
        }
        if let p = body["private"] as? [String: Any] {
            var cur = cfg["private"] as? [String: Any] ?? [:]
            let clean = { (v: Any?) in (v as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty } }
            cur["sites"] = clean(p["sites"])
            cur["words"] = clean(p["words"])
            cfg["private"] = cur
        }
        // Projects: naam + pehchaan wale shabd (folder / repo / site / title me ho to time us project me)
        if let list = body["projects"] as? [[String: Any]] {
            var seen = Set<String>()
            cfg["projects"] = list.compactMap { p -> [String: Any]? in
                let name = String((p["name"] as? String ?? "").trimmingCharacters(in: .whitespaces).prefix(60))
                guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
                let match = (p["match"] as? [String] ?? []).map { String($0.trimmingCharacters(in: .whitespaces).lowercased().prefix(100)) }.filter { !$0.isEmpty }
                return ["name": name, "match": Array(match.prefix(20))]
            }.prefix(50).map { $0 }
        }
        if let out = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? out.write(to: catsURL)
        }
        Settings.load()
        Privacy.loadExtra()
    }

    private func saveFile(name: String, content: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        guard let window else { return }
        panel.beginSheetModal(for: window) { resp in
            if resp == .OK, let url = panel.url { try? content.write(to: url, atomically: true, encoding: .utf8) }
        }
    }

    private func summaryJSON(from: String, to: String) -> String {
        let cal = Calendar.current
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        guard let d0 = dayFmt.date(from: from), let d1 = dayFmt.date(from: to),
              let end = cal.date(byAdding: .day, value: 1, to: d1) else { return "{}" }
        var totals: [String: Int] = [:]
        for r in store.rows(since: d0.timeIntervalSince1970, until: end.timeIntervalSince1970) {
            totals[dayFmt.string(from: Date(timeIntervalSince1970: r.start)), default: 0] += Int(r.end - r.start)
        }
        return json(totals)
    }

    private func rulesJSON() -> String {
        guard let data = try? Data(contentsOf: catsURL),
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return "{}" }
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
    }

    /// Dashboard se category badli — categories.json me likh do
    private func setCategory(kind: String, key: String, cat: String) {
        guard ["app", "domain"].contains(kind), !key.isEmpty,
              let data = try? Data(contentsOf: catsURL),
              var cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let section = kind == "app" ? "apps" : "domains"
        var map = cfg[section] as? [String: String] ?? [:]
        map[kind == "app" ? key.lowercased() : key] = cat
        cfg[section] = map
        if let out = try? JSONSerialization.data(withJSONObject: cfg,
                                                 options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? out.write(to: catsURL)
        }
    }

    private func json(_ obj: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed])) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
    }

    // Dashboard ke links default browser me kholo
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith config: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { NSWorkspace.shared.open(url) }
        return nil
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    let store = Store()
    let agenda = Agenda()
    lazy var google = GoogleTasks(store: store)
    lazy var tracker = Tracker(store: store)
    lazy var dashboard = Dashboard(store: store, agenda: agenda, google: google)
    var statusItem: NSStatusItem!
    var timer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        installCategoriesFile()
        Settings.load()
        Privacy.loadExtra()
        store.migrateAppNames()
        store.applyPrivacyToOldData()
        store.removeIgnoredApps()
        dailyChores()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: "meeting",
            actions: [UNNotificationAction(identifier: "join", title: "Join", options: [.foreground])], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        dashboard.status = { [weak self] in self?.status() ?? [:] }
        tracker.onReturn = { secs in
            if Settings.notifyAway {
                notify("Welcome back", "You were away for \(fmt(secs)). Label it (meeting, lunch…) in the dashboard.")
            }
        }
        setupMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let img = NSImage(systemSymbolName: "timer", accessibilityDescription: "DeskTime")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Window title padhne ke liye Accessibility permission chahiye — pehli baar macOS khud poochega
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        if !UserDefaults.standard.bool(forKey: "loginSetupDone") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginSetupDone")
        }

        // Khud kholi (Spotlight / Applications) to dashboard dikhao; login pe apne aap chali to chup-chaap menu bar me
        let ev = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = ev?.eventID == AEEventID(kAEOpenApplication)
            && ev?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        if !atLogin { DispatchQueue.main.async { self.dashboard.show() } }

        tick()
        let t = Timer(timeInterval: POLL, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)   // menu khula ho tab bhi chalta rahe
        timer = t
    }

    private var ticks = 0
    private var distractionStreak = 0.0, distractionNotified = false
    private var goalNotifiedDay = UserDefaults.standard.string(forKey: "goalNotifiedDay") ?? ""

    func tick() {
        ticks += 1
        if ticks % Int(60 / POLL) == 0 {   // har minute: settings / private list dobara padho, goal check
            Settings.load()
            Privacy.loadExtra()
            checkGoal()
            checkReminders()
            checkSchedule()
            google.refresh { _ in }   // har account apne interval / retry-wait ke hisaab se khud decide karta hai
            google.checkDue()
        }
        if ticks % Int(3600 / POLL) == 0 { dailyChores() }   // har ghante
        if ticks == 1 { google.refresh(force: true) { _ in } }   // app khulte hi Google Tasks
        tracker.tick()
        checkDistraction()
        let total = todayRows().reduce(0) { $0 + $1.1 }
        var title = tracker.paused ? " Paused" : " " + fmt(total)
        if let st = status()["since"] as? Double, status()["state"] as? String == "break" {
            title = " ☕ Break " + fmt(Date().timeIntervalSince1970 - st)
        }
        if let p = store.runningProject() { title += "  · " + p.name }
        statusItem.button?.title = title
    }

    /// Abhi kya haal hai: "active", "break" (keyboard/mouse se door), ya "paused"
    func status() -> [String: Any] {
        if tracker.paused { return ["state": "paused"] }
        if tracker.last == nil && tracker.lastActive > 0 { return ["state": "break", "since": min(tracker.lastInput > 0 ? tracker.lastInput : tracker.lastActive + POLL, tracker.lastActive + POLL)] }
        return ["state": "active"]
    }

    // --- Reminders: meeting / task se pehle, aur subah ka schedule ---
    private var reminded = Set(UserDefaults.standard.stringArray(forKey: "reminded") ?? [])

    private func checkReminders() {
        let lead = Settings.remindMinutes * 60
        guard lead > 0 else { return }
        let now = Date()
        let tf = DateFormatter()
        tf.dateFormat = "h:mm a"
        for e in agenda.events(now, now.addingTimeInterval(lead + 60)) where !e.isAllDay {
            let key = "e|\(e.eventIdentifier ?? "")|\(e.startDate.timeIntervalSince1970)"
            guard !reminded.contains(key), e.startDate.timeIntervalSince(now) <= lead, e.startDate > now.addingTimeInterval(-60) else { continue }
            remember(key)
            let mins = max(0, Int((e.startDate.timeIntervalSince(now) / 60).rounded()))
            let link = Agenda.meetingLink(e)
            notify(mins == 0 ? "Starting now: \(e.title ?? "Meeting")" : "In \(mins) min: \(e.title ?? "Meeting")",
                   "\(tf.string(from: e.startDate)) – \(tf.string(from: e.endDate))" + (link != nil ? " · Click to join" : ""),
                   url: link, open: link == nil ? "agenda" : nil)
        }
        for t in store.tasks(since: now.timeIntervalSince1970, until: now.timeIntervalSince1970 + lead + 60) {
            guard let due = t["due"] as? Double, (t["done"] as? Bool) == false, let id = t["id"] as? Int64 else { continue }
            let key = "t|\(id)|\(due)"
            guard !reminded.contains(key), due - now.timeIntervalSince1970 <= lead else { continue }
            remember(key)
            let proj = t["project"] as? String ?? ""
            notify("Task at \(tf.string(from: Date(timeIntervalSince1970: due)))" + (proj.isEmpty ? "" : " · \(proj)"),
                   t["title"] as? String ?? "", open: "agenda")
        }
    }

    private func remember(_ key: String) {
        reminded.insert(key)
        if reminded.count > 300 { reminded = Set(reminded.suffix(200)) }
        UserDefaults.standard.set(Array(reminded), forKey: "reminded")
    }

    /// Roz Settings.scheduleTime (default 10:00) pe aaj ka schedule — ek baar
    private func checkSchedule() {
        guard Settings.notifySchedule else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        guard UserDefaults.standard.string(forKey: "scheduleDay") != today else { return }
        let parts = Settings.scheduleTime.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        guard (c.hour ?? 0) * 60 + (c.minute ?? 0) >= parts[0] * 60 + parts[1] else { return }
        UserDefaults.standard.set(today, forKey: "scheduleDay")
        let day0 = Calendar.current.startOfDay(for: Date()), day1 = day0.addingTimeInterval(86400)
        let events = agenda.events(Date(), day1).filter { !$0.isAllDay }
        let tasks = store.tasks(since: day0.timeIntervalSince1970, until: day1.timeIntervalSince1970).filter { ($0["done"] as? Bool) == false }
        let tf = DateFormatter()
        tf.dateFormat = "h:mm a"
        let lines = events.prefix(4).map { "\(tf.string(from: $0.startDate))  \($0.title ?? "")" }
        let f2 = DateFormatter()
        f2.dateFormat = "yyyy-MM-dd"
        let gToday = google.cache.filter { ($0["done"] as? Bool) == false && ($0["due"] as? String).map { $0 <= f2.string(from: Date()) } == true }
        let taskCount = tasks.count + gToday.count
        let head = "\(events.count) meeting\(events.count == 1 ? "" : "s"), \(taskCount) task\(taskCount == 1 ? "" : "s") today"
        let gLines = gToday.prefix(3).map { "☐ \($0["title"] as? String ?? "")" }
        notify("Today’s schedule", ([head] + lines + gLines).joined(separator: "\n"), open: "agenda")
    }

    // Notification pe click: meeting link kholo ya dashboard ka Agenda
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let u = info["url"] as? String, u.lowercased().hasPrefix("https://"), let url = URL(string: u) {
            NSWorkspace.shared.open(url)
        } else if let view = info["open"] as? String, ["agenda", "settings"].contains(view) {
            dashboard.show(view: view)
        }
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    private func dailyChores() {
        store.dailyBackup()
        store.applyRetention(days: Settings.retentionDays)
    }

    /// Aaj ka productive goal pura hua to ek baar notification
    private func checkGoal() {
        guard Settings.notifyGoal else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        guard goalNotifiedDay != today else { return }
        let rules = Rules.load()
        let day0 = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let prod = todayRows().reduce(0.0) {
            $0 + (rules.productive(rules.categorize($1.0.app, $1.0.domain)) == true ? Settings.officeSeconds(max($1.0.start, day0), $1.0.end) : 0)
        }
        if prod >= Settings.goalHours * 3600 {
            goalNotifiedDay = today
            UserDefaults.standard.set(today, forKey: "goalNotifiedDay")
            notify("Goal reached 🎉", "\(fmt(prod)) of productive work today.")
        }
    }

    /// Lagatar unproductive (social media / entertainment) pe bahut der — ek halka reminder
    private func checkDistraction() {
        guard Settings.notifyDistraction, let a = tracker.last, Settings.isOffice(Date().timeIntervalSince1970) else { distractionStreak = 0; return }
        let rules = Rules.load()
        if rules.productive(rules.categorize(a.app, a.domain)) == false {
            distractionStreak += POLL
            if distractionStreak >= Settings.distractionMinutes * 60 && !distractionNotified {
                distractionNotified = true
                notify("Time check", "\(fmt(distractionStreak)) on \(a.domain.isEmpty ? a.app : a.domain). Back to work?")
            }
        } else {
            distractionStreak = 0
            distractionNotified = false
        }
    }

    /// Aaj ke rows: (row, aaj ke andar kitne second)
    func todayRows() -> [(Row, Double)] {
        let day0 = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        return store.rows(since: day0).map { ($0, $0.end - max($0.start, day0)) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let rules = Rules.load()
        var byCat: [String: Double] = [:]
        var total = 0.0, prod = 0.0
        var personal = 0.0
        let day0 = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        for (r, secs) in todayRows() {
            let cat = rules.categorize(r.app, r.domain)
            let office = Settings.officeSeconds(max(r.start, day0), r.end)
            byCat[cat, default: 0] += office
            if secs - office > 0 { byCat["Personal", default: 0] += secs - office; personal += secs - office }
            total += secs
            if rules.productive(cat) == true { prod += office }
        }
        byCat = byCat.filter { $0.value > 0 }

        let work = total - personal
        let head = total > 0 ? "Today: \(fmt(total)) · \(work > 0 ? Int((prod / work * 100).rounded()) : 0)% productive"
                             : "No activity today yet"
        menu.addItem(NSMenuItem(title: head, action: nil, keyEquivalent: ""))
        for (cat, secs) in byCat.sorted(by: { $0.value > $1.value }) {
            let item = add(menu, "\(cat)  —  \(fmt(secs))", #selector(openDashboard))
            item.image = dot(rules.color(cat))
            item.indentationLevel = 1
        }
        let tf = DateFormatter()
        tf.dateFormat = "h:mm a"
        let upcoming = agenda.events(Date(), Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400)).filter { !$0.isAllDay }
        if let next = upcoming.first {
            menu.addItem(.separator())
            let it = add(menu, "Next: \(tf.string(from: next.startDate))  \(next.title ?? "")", #selector(openAgenda))
            it.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)
        }
        menu.addItem(.separator())
        if let p = store.runningProject() {
            menu.addItem(NSMenuItem(title: "Project: \(p.name) — \(fmt(Date().timeIntervalSince1970 - p.start))", action: nil, keyEquivalent: ""))
            add(menu, "Stop Project", #selector(stopProject))
        } else {
            let item = NSMenuItem(title: "Start Project", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for name in store.recentProjects() {
                let it = add(sub, name, #selector(startRecentProject(_:)))
                it.representedObject = name
            }
            if !sub.items.isEmpty { sub.addItem(.separator()) }
            add(sub, "New Project…", #selector(newProject))
            item.submenu = sub
            menu.addItem(item)
        }
        menu.addItem(.separator())
        add(menu, "Open Dashboard", #selector(openDashboard), "d")
        add(menu, tracker.paused ? "Resume Tracking" : "Pause Tracking", #selector(togglePause), "p")
        menu.addItem(.separator())
        if !AXIsProcessTrusted() {
            add(menu, "⚠️  Allow Accessibility (for window titles)…", #selector(openAccessibility))
        }
        add(menu, "Edit Categories…", #selector(editCategories))
        add(menu, "Open Data Folder", #selector(openDataFolder))
        let login = add(menu, "Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        add(menu, "Quit DeskTime", #selector(NSApplication.terminate(_:)), "q").target = NSApp
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
            color.setFill()
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            return true
        }
    }

    // Upar ka "DeskTime" menu: ⌘D / ⌘R / ⌘W / ⌘C / ⌘Q shortcuts
    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let sub = NSMenu()
        appItem.submenu = sub
        add(sub, "Open Dashboard", #selector(openDashboard), "d")
        add(sub, "Refresh", #selector(refreshDashboard), "r")
        sub.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        sub.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // Edit menu — iske bina text boxes me Cmd+V / Cmd+X / Cmd+Z kaam nahi karte
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = main
    }

    private func installCategoriesFile() {
        if !FileManager.default.fileExists(atPath: catsURL.path),
           let bundled = Bundle.main.url(forResource: "categories", withExtension: "json") {
            try? FileManager.default.copyItem(at: bundled, to: catsURL)
        }
        // Office hours ke bahar ka time is category me jaata hai — purani file me na ho to jodo
        guard let data = try? Data(contentsOf: catsURL),
              var cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var cats = cfg["categories"] as? [String: Any] ?? [:]
        guard cats["Personal"] == nil else { return }
        cats["Personal"] = ["slot": 8, "color": "#4fa3b5", "dark": "#4b97a8", "productive": NSNull()] as [String: Any]
        cfg["categories"] = cats
        if let out = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? out.write(to: catsURL)
        }
    }

    /// App pehle se chal rahi ho aur dobara kholi (Dock / Spotlight / Applications) — dashboard dikhao
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        dashboard.show()
        return true
    }

    @objc func openDashboard() { dashboard.show() }
    @objc func openAgenda() { dashboard.show(view: "agenda") }
    @objc func stopProject() { store.stopProject(); tick() }
    @objc func startRecentProject(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { store.startProject(name); tick() }
    }
    @objc func newProject() {
        let alert = NSAlert()
        alert.messageText = "Start a project"
        alert.informativeText = "Time runs until you stop it from this menu."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Project name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { store.startProject(String(name.prefix(60))); tick() }
        }
    }
    @objc func refreshDashboard() { dashboard.show() }
    @objc func togglePause() { tracker.paused.toggle(); tick() }
    @objc func editCategories() { NSWorkspace.shared.open(catsURL) }
    @objc func openDataFolder() { NSWorkspace.shared.open(supportDir) }

    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
