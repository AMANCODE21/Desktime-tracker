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
    static var awayMinutes = 15.0         // isse lamba away ho to "Away" list me aata hai
    static var notifyGoal = true
    static var notifyDistraction = true
    static var distractionMinutes = 30.0
    static var notifyAway = false
    static var retentionDays = 0.0        // 0 = data hamesha rakho
    static var remindMinutes = 10.0       // meeting / task se itne minute pehle reminder
    static var scheduleTime = "10:00"     // roz is time pe aaj ka schedule
    static var notifySchedule = true

    static func load() {
        guard let data = try? Data(contentsOf: catsURL),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        goalHours = (cfg["goal_hours"] as? Double) ?? goalHours
        let s = cfg["settings"] as? [String: Any] ?? [:]
        idleMinutes = max(1, (s["idle_minutes"] as? Double) ?? idleMinutes)
        awayMinutes = max(5, (s["away_minutes"] as? Double) ?? awayMinutes)
        notifyGoal = (s["notify_goal"] as? Bool) ?? notifyGoal
        notifyDistraction = (s["notify_distraction"] as? Bool) ?? notifyDistraction
        distractionMinutes = max(5, (s["distraction_minutes"] as? Double) ?? distractionMinutes)
        notifyAway = (s["notify_away"] as? Bool) ?? notifyAway
        retentionDays = max(0, (s["retention_days"] as? Double) ?? retentionDays)
        remindMinutes = max(0, (s["remind_minutes"] as? Double) ?? remindMinutes)
        scheduleTime = (s["schedule_time"] as? String) ?? scheduleTime
        notifySchedule = (s["notify_schedule"] as? Bool) ?? notifySchedule
    }
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

    // --- Tasks (DeskTime ke apne, time ke saath ya bina) ---
    func addTask(_ title: String, due: Double?) {
        run("INSERT INTO task(title,due,created) VALUES (?,?,?)", [title, due as Any, Date().timeIntervalSince1970])
    }
    func setTaskDone(_ id: Int64, _ done: Bool) { run("UPDATE task SET done=? WHERE id=?", [Int64(done ? 1 : 0), id]) }
    func deleteTask(_ id: Int64) { run("DELETE FROM task WHERE id=?", [id]) }
    /// Is range ke time wale tasks + bina time wale khule tasks
    func tasks(since: Double, until: Double) -> [[String: Any]] {
        var out: [[String: Any]] = []
        run("SELECT id,title,due,done FROM task WHERE (due>=? AND due<?) OR (due IS NULL AND (done=0 OR created>=?)) ORDER BY due IS NULL, due, id",
            [since, until, since]) { st in
            out.append(["id": sqlite3_column_int64(st, 0), "title": col(st, 1),
                        "due": sqlite3_column_type(st, 2) == SQLITE_NULL ? NSNull() : sqlite3_column_double(st, 2) as Any,
                        "done": sqlite3_column_int(st, 3) == 1])
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
    private var lastId: Int64 = 0, lastKey: [String]?, lastEnd: Double = 0
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
        // Lamba gap (idle / screen lock / sleep) = "Away" period
        if lastActive > 0 && now - lastActive >= Settings.awayMinutes * 60 {
            store.addAway(lastActive + POLL, now)
            onReturn?(now - lastActive)
        }
        lastActive = now
        last = a
        let key = [a.app, a.title, a.url, a.domain]
        if key == lastKey && now - lastEnd <= MERGE_GAP {
            store.setEnd(lastId, now + POLL)
        } else {
            lastId = store.insert(now, now + POLL, a)
            lastKey = key
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
        guard SecItemCopyMatching(q, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete(_ account: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
    }
}

final class GoogleTasks {
    private let cfgURL = supportDir.appendingPathComponent("google.json")
    private(set) var clientID = ""
    private(set) var accounts: [String] = []
    private var access: [String: (token: String, exp: Double)] = [:]
    private(set) var cache: [[String: Any]] = []
    private(set) var lastError: String?
    private var listener: NWListener?

    init() { load() }

    var configured: Bool { !clientID.isEmpty && Keychain.get("client-secret") != nil }

    private func load() {
        guard let d = try? Data(contentsOf: cfgURL), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        clientID = j["client_id"] as? String ?? ""
        accounts = j["accounts"] as? [String] ?? []
    }
    private func save() {
        if let d = try? JSONSerialization.data(withJSONObject: ["client_id": clientID, "accounts": accounts], options: .prettyPrinted) {
            try? d.write(to: cfgURL)
            chmod(cfgURL.path, 0o600)
        }
    }

    func setClient(id: String, secret: String) {
        clientID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { Keychain.set(s, "client-secret") }
        save()
    }

    var info: [String: Any] {
        ["configured": configured, "clientId": clientID, "accounts": accounts, "error": lastError ?? NSNull()]
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
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            DispatchQueue.main.async { cb(code, body) }
        }.resume()
    }

    private static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // --- Connect: browser me Google login, jawab 127.0.0.1 pe aata hai ---
    func connect(_ done: @escaping (String?) -> Void) {
        guard configured, let secret = Keychain.get("client-secret") else { return done("Add the Client ID and secret first.") }
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
                    let parts = idt.split(separator: ".")
                    var payload = parts.count > 1 ? String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") : ""
                    while payload.count % 4 != 0 { payload += "=" }
                    let email = (Data(base64Encoded: payload).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["email"] as? String ?? "Google account"
                    Keychain.set(refresh, "refresh:" + email)
                    if let tok = body["access_token"] as? String { self.access[email] = (tok, Date().timeIntervalSince1970 + 3000) }
                    if !self.accounts.contains(email) { self.accounts.append(email) }
                    self.save()
                    self.refresh { _ in finish(nil) }
                }
            }
        }
        l.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { finish("Sign-in timed out. Try again.") }
    }

    func disconnect(_ email: String) {
        if let r = Keychain.get("refresh:" + email) {
            call(URL(string: "https://oauth2.googleapis.com/revoke")!, method: "POST", form: ["token": r]) { _, _ in }
        }
        Keychain.delete("refresh:" + email)
        access[email] = nil
        accounts.removeAll { $0 == email }
        cache.removeAll { $0["account"] as? String == email }
        save()
    }

    private func token(_ email: String, _ cb: @escaping (String?) -> Void) {
        if let a = access[email], a.exp > Date().timeIntervalSince1970 + 60 { return cb(a.token) }
        guard let r = Keychain.get("refresh:" + email), let secret = Keychain.get("client-secret") else { return cb(nil) }
        call(URL(string: "https://oauth2.googleapis.com/token")!, method: "POST", form: [
            "client_id": clientID, "client_secret": secret, "refresh_token": r, "grant_type": "refresh_token"]) { status, body in
            guard status == 200, let tok = body["access_token"] as? String else {
                self.lastError = "\(email): sign-in expired — connect it again in Settings."
                return cb(nil)
            }
            self.access[email] = (tok, Date().timeIntervalSince1970 + ((body["expires_in"] as? Double) ?? 3600))
            cb(tok)
        }
    }

    /// Sab accounts ki sab lists ke tasks (khule + pichhle 3 din me pure hue)
    func refresh(_ done: @escaping ([[String: Any]]) -> Void) {
        guard configured, !accounts.isEmpty else { cache = []; return done([]) }
        var all: [[String: Any]] = [], pending = accounts.count
        lastError = nil
        let f = ISO8601DateFormatter()
        let since = f.string(from: Date().addingTimeInterval(-3 * 86400))
        for email in accounts {
            token(email) { tok in
                guard let tok else { pending -= 1; if pending == 0 { self.cache = all; done(all) }; return }
                self.call(URL(string: "https://tasks.googleapis.com/tasks/v1/users/@me/lists?maxResults=50")!, bearer: tok) { _, body in
                    let lists = body["items"] as? [[String: Any]] ?? []
                    var left = lists.count
                    if left == 0 { pending -= 1; if pending == 0 { self.cache = all; done(all) } }
                    for list in lists {
                        let lid = list["id"] as? String ?? ""
                        var c = URLComponents(string: "https://tasks.googleapis.com/tasks/v1/lists/\(lid)/tasks")!
                        c.queryItems = [.init(name: "showCompleted", value: "true"), .init(name: "showHidden", value: "true"),
                                        .init(name: "completedMin", value: since), .init(name: "maxResults", value: "100")]
                        let openURL = c.url!
                        c.queryItems = [.init(name: "showCompleted", value: "false"), .init(name: "maxResults", value: "100")]
                        let pendingURL = c.url!
                        var seen = Set<String>(), got = 0
                        for u in [pendingURL, openURL] {
                            self.call(u, bearer: tok) { _, b in
                                for t in b["items"] as? [[String: Any]] ?? [] {
                                    guard let id = t["id"] as? String, !seen.contains(id), let title = t["title"] as? String, !title.isEmpty else { continue }
                                    seen.insert(id)
                                    all.append(["account": email, "list": list["title"] as? String ?? "", "listId": lid, "id": id, "title": title,
                                                "due": (t["due"] as? String).map { String($0.prefix(10)) } ?? NSNull(),
                                                "done": t["status"] as? String == "completed", "link": t["webViewLink"] as? String ?? NSNull()])
                                }
                                got += 1
                                if got == 2 {
                                    left -= 1
                                    if left == 0 { pending -= 1; if pending == 0 { self.cache = all; done(all) } }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func setDone(account: String, list: String, id: String, done: Bool, _ cb: @escaping () -> Void) {
        token(account) { tok in
            guard let tok, let url = URL(string: "https://tasks.googleapis.com/tasks/v1/lists/\(list)/tasks/\(id)") else { return cb() }
            self.call(url, method: "PATCH", json: done ? ["status": "completed"] : ["status": "needsAction", "completed": NSNull()], bearer: tok) { _, _ in
                if let i = self.cache.firstIndex(where: { $0["id"] as? String == id }) { self.cache[i]["done"] = done }
                cb()
            }
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
                    replyHandler(self.json(["access": access, "events": events, "reminders": rem, "tasks": tasks,
                                            "google": self.google.info, "gtasks": g]), nil)
                }
                // Google Tasks: cache turant, aur "fresh" maanga ho to dobara lao
                if (body["fresh"] as? Bool) == true { self.google.refresh(send) } else { send(self.google.cache) }
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
            if !title.isEmpty { store.addTask(String(title.prefix(200)), due: body["due"] as? Double) }
            replyHandler("ok", nil)
        case "taskDone":
            store.setTaskDone((body["id"] as? NSNumber)?.int64Value ?? 0, body["done"] as? Bool ?? true)
            replyHandler("ok", nil)
        case "deleteTask":
            store.deleteTask((body["id"] as? NSNumber)?.int64Value ?? 0)
            replyHandler("ok", nil)
        case "setAwayLabel":
            store.setAwayLabel((body["id"] as? NSNumber)?.int64Value ?? 0, String((body["label"] as? String ?? "").prefix(40)))
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
            if let t = s["schedule_time"] as? String, t.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil { cur["schedule_time"] = t }
            for k in ["idle_minutes", "away_minutes", "distraction_minutes", "retention_days", "remind_minutes"] {
                if let v = s[k] as? Double { cur[k] = v }
            }
            for k in ["notify_goal", "notify_distraction", "notify_away", "notify_schedule"] {
                if let v = s[k] as? Bool { cur[k] = v }
            }
            cfg["settings"] = cur
        }
        if let p = body["private"] as? [String: Any] {
            var cur = cfg["private"] as? [String: Any] ?? [:]
            let clean = { (v: Any?) in (v as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty } }
            cur["sites"] = clean(p["sites"])
            cur["words"] = clean(p["words"])
            cfg["private"] = cur
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
    let google = GoogleTasks()
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
        }
        if ticks % Int(3600 / POLL) == 0 { dailyChores() }   // har ghante
        if ticks % Int(300 / POLL) == 1 { google.refresh { _ in } }   // Google Tasks har 5 min
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
        if tracker.last == nil && tracker.lastActive > 0 { return ["state": "break", "since": tracker.lastActive + POLL] }
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
            notify("Task at \(tf.string(from: Date(timeIntervalSince1970: due)))", t["title"] as? String ?? "", open: "agenda")
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
        } else if info["open"] as? String == "agenda" {
            dashboard.show(view: "agenda")
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
        let prod = todayRows().reduce(0.0) { $0 + (rules.productive(rules.categorize($1.0.app, $1.0.domain)) == true ? $1.1 : 0) }
        if prod >= Settings.goalHours * 3600 {
            goalNotifiedDay = today
            UserDefaults.standard.set(today, forKey: "goalNotifiedDay")
            notify("Goal reached 🎉", "\(fmt(prod)) of productive work today.")
        }
    }

    /// Lagatar unproductive (social media / entertainment) pe bahut der — ek halka reminder
    private func checkDistraction() {
        guard Settings.notifyDistraction, let a = tracker.last else { distractionStreak = 0; return }
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
        for (r, secs) in todayRows() {
            let cat = rules.categorize(r.app, r.domain)
            byCat[cat, default: 0] += secs
            total += secs
            if rules.productive(cat) == true { prod += secs }
        }

        let head = total > 0 ? "Today: \(fmt(total)) · \(Int((prod / total * 100).rounded()))% productive"
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
        sub.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        sub.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        sub.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = main
    }

    private func installCategoriesFile() {
        guard !FileManager.default.fileExists(atPath: catsURL.path),
              let bundled = Bundle.main.url(forResource: "categories", withExtension: "json") else { return }
        try? FileManager.default.copyItem(at: bundled, to: catsURL)
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
