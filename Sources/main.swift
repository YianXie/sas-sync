// SAS Sync — a small native macOS app for Ian's Singapore American School workflow:
//   • HS Daily Bulletin → short personalized summaries
//   • Weekly SAS eNews (sas.edu.sg/enews) → short personalized summaries
//   • Toddle assignments → Google Tasks "School" list
// The heavy lifting lives in ~/.hermes/scripts (sas_bulletin.py, sas_enews.py, sas_tasks.py, sas_google.py)
// and Hermes cron jobs; this app is the control panel.

import AppKit
import SwiftUI
import WebKit

// MARK: - Paths

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let hermes = home.appendingPathComponent(".hermes")
    static let bulletinCLI = hermes.appendingPathComponent("scripts/sas_bulletin_cli.sh").path
    static let tasksCLI = hermes.appendingPathComponent("scripts/sas_tasks_cli.sh").path
    static let enewsCLI = hermes.appendingPathComponent("scripts/sas_enews_cli.sh").path
    static let outDir = hermes.appendingPathComponent("sas_bulletins")
    static let enewsDir = outDir.appendingPathComponent("enews")
    static let enewsURL = URL(string: "https://www.sas.edu.sg/enews")!
    static let config = outDir.appendingPathComponent("config.json")
    static let profile = outDir.appendingPathComponent("profile.md")
}

// MARK: - Models

struct Bulletin: Codable, Identifiable, Hashable {
    let id: String
    let subject: String
    let received: String
    let stamp: String
    let summarized: Bool
    let has_page: Bool
    let page: String

    var date: Date? { Fmt.ymd.date(from: stamp) }
    var title: String {
        guard let d = date else { return subject }
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"
        return f.string(from: d)
    }
}

struct SchoolTask: Codable, Identifiable, Hashable {
    let id: String
    let list: String
    let title: String
    let due: String
    let when: String
    let course: String
    let link: String
    let notes: String
    let completed: Bool
    let toddle: Bool

    var dueDate: Date? { due.isEmpty ? nil : Fmt.ymd.date(from: due) }
}

struct LastPublish: Codable, Equatable { let stamp: String?; let title: String?; let time: Double? }

struct ENewsIssue: Codable, Identifiable, Hashable {
    let id: String          // issue date, YYYY-MM-DD
    let stamp: String
    let title: String
    let summarized: Bool
    let has_page: Bool
    let page: String        // rendered summary
    let raw: String         // archived copy of the eNews page
    let live: Bool          // currently at sas.edu.sg/enews

    var tag: String { "enews:" + id }
    var shortTitle: String {
        guard let d = Fmt.ymd.date(from: stamp) else { return title }
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"
        return f.string(from: d)
    }
}

struct ENewsList: Codable { let issues: [ENewsIssue]; let error: String?; let url: String? }

struct ENewsStatus: Codable {
    var regen_pending: Bool = false
    var regen_id: String?
    var last_publish: LastPublish?
}

struct JobInfo: Codable {
    var found: Bool = false
    var enabled: Bool = false
    var next_run: String?
    var last_run: String?
    var last_status: String?
}

struct StatusInfo: Codable {
    var signed_in: Bool = false
    var offline: Bool = false
    var email: String?
    var error: String?
    var regen_pending: Bool = false
    var regen_id: String?
    var last_publish: LastPublish?
    var jobs: [String: JobInfo]?

    func job(_ k: String) -> JobInfo { jobs?[k] ?? JobInfo() }
}

struct SyncInfo: Codable {
    let time: Double?
    let ok: Bool?
    let added: [[String]]?
    let updated: [[String]]?
    let error: String?
}

struct TasksStatus: Codable {
    var signed_in: Bool = false
    var offline: Bool = false
    var error: String?
    var last_sync: SyncInfo?
}

struct Config: Codable, Equatable {
    var for_you = true
    var for_you_max = 6
    var deadline_window_days = 3
    var star_deadlines_only_if_relevant = true
    var college_list_only = false
    var also_new = true
    var everything_else = true
    var notifications = true
    var post_to_chat = true
    var extra_instructions = ""
    var tasks_notifications = true
    var tasks_lookahead_days = 28
    var enews_notifications = true
    var enews_post_to_chat = false
    var enews_include_other_divisions = false
    var enews_extra_instructions = ""

    init() {}
    // Tolerant decoding: missing keys fall back to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decode(T.self, forKey: k)) ?? def }
        for_you = v(.for_you, d.for_you)
        for_you_max = v(.for_you_max, d.for_you_max)
        deadline_window_days = v(.deadline_window_days, d.deadline_window_days)
        star_deadlines_only_if_relevant = v(.star_deadlines_only_if_relevant, d.star_deadlines_only_if_relevant)
        college_list_only = v(.college_list_only, d.college_list_only)
        also_new = v(.also_new, d.also_new)
        everything_else = v(.everything_else, d.everything_else)
        notifications = v(.notifications, d.notifications)
        post_to_chat = v(.post_to_chat, d.post_to_chat)
        extra_instructions = v(.extra_instructions, d.extra_instructions)
        tasks_notifications = v(.tasks_notifications, d.tasks_notifications)
        tasks_lookahead_days = v(.tasks_lookahead_days, d.tasks_lookahead_days)
        enews_notifications = v(.enews_notifications, d.enews_notifications)
        enews_post_to_chat = v(.enews_post_to_chat, d.enews_post_to_chat)
        enews_include_other_divisions = v(.enews_include_other_divisions, d.enews_include_other_divisions)
        enews_extra_instructions = v(.enews_extra_instructions, d.enews_extra_instructions)
    }
}

enum Fmt {
    static let ymd: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    static func relative(_ ts: Double?) -> String {
        guard let ts else { return "never" }
        let r = RelativeDateTimeFormatter(); r.unitsStyle = .full
        return r.localizedString(for: Date(timeIntervalSince1970: ts), relativeTo: Date())
    }
    static func iso(_ s: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let d = f.date(from: s) ?? { f.formatOptions = [.withInternetDateTime]; return f.date(from: s) }()
        guard let d else { return s }
        let o = DateFormatter(); o.dateFormat = "EEE MMM d, h:mm a"
        return o.string(from: d)
    }
}

// MARK: - Backend (runs the Python CLIs)

enum Backend {
    struct Result { let code: Int32; let out: String; let err: String }

    static func run(_ cli: String, _ args: [String]) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = [cli] + args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out; p.standardError = err
                var errData = Data()
                let errGroup = DispatchGroup(); errGroup.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile(); errGroup.leave()
                }
                do { try p.run() } catch {
                    cont.resume(returning: Result(code: -1, out: "", err: error.localizedDescription)); return
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit(); errGroup.wait()
                cont.resume(returning: Result(code: p.terminationStatus,
                                              out: String(decoding: outData, as: UTF8.self),
                                              err: String(decoding: errData, as: UTF8.self)))
            }
        }
    }

    static func json<T: Decodable>(_ type: T.Type, _ cli: String, _ args: [String]) async -> (T?, String) {
        let r = await run(cli, args)
        let line = r.out.split(separator: "\n").last.map(String.init) ?? ""
        if let data = line.data(using: .utf8), let v = try? JSONDecoder().decode(T.self, from: data) {
            return (v, "")
        }
        let msg = (r.err.isEmpty ? r.out : r.err).split(separator: "\n").suffix(2).joined(separator: " ")
        return (nil, msg.isEmpty ? "No response from backend" : msg)
    }
}

struct OKResult: Codable { let ok: Bool; let output: String? }

// MARK: - App state

@MainActor
final class AppModel: ObservableObject {
    static let assignmentsTag = "__assignments__"

    @Published var bulletins: [Bulletin] = []
    @Published var enews: [ENewsIssue] = []
    @Published var enewsError: String?
    @Published var enewsStatus = ENewsStatus()
    @Published var regeneratingENews: String?     // issue stamp
    @Published var tasks: [SchoolTask] = []
    @Published var status = StatusInfo()
    @Published var tasksStatus = TasksStatus()
    @Published var config = Config()
    @Published var selection: String? = AppModel.assignmentsTag
    @Published var loading = false
    @Published var regenerating: String?          // bulletin id
    @Published var syncing = false
    @Published var completing: Set<String> = []
    @Published var banner: String?
    @Published var pageVersion = 0
    @Published var showSignIn = false

    private var saveTask: Task<Void, Never>?

    init() {
        loadConfig()
        Task { await refresh() }
    }

    var selectedBulletin: Bulletin? { bulletins.first { $0.id == selection } }
    var selectedENews: ENewsIssue? { enews.first { $0.tag == selection } }

    func refresh() async {
        loading = true
        async let s = Backend.json(StatusInfo.self, Paths.bulletinCLI, ["status"])
        async let ts = Backend.json(TasksStatus.self, Paths.tasksCLI, ["json-status"])
        async let en = Backend.json(ENewsList.self, Paths.enewsCLI, ["list"])   // public page, no sign-in needed
        async let es = Backend.json(ENewsStatus.self, Paths.enewsCLI, ["status"])
        let (st, stErr) = await s
        if let st { status = st } else { banner = "Status error: \(stErr)" }
        if let t = (await ts).0 { tasksStatus = t }
        let (el, elErr) = await en
        if let el { enews = el.issues; enewsError = el.error } else { enewsError = elErr }
        if let e = (await es).0 { enewsStatus = e }
        if status.signed_in {
            async let l = Backend.json([Bulletin].self, Paths.bulletinCLI, ["list"])
            async let t = Backend.json([SchoolTask].self, Paths.tasksCLI, ["json-list"])
            let (list, listErr) = await l
            let (tl, tErr) = await t
            if let list { bulletins = list } else { banner = "Couldn't load bulletins: \(listErr)" }
            if let tl { tasks = tl } else { banner = "Couldn't load assignments: \(tErr)" }
        } else if !status.offline {
            showSignIn = true
        }
        loading = false
        pageVersion += 1
    }

    // MARK: Config
    func loadConfig() {
        if let data = try? Data(contentsOf: Paths.config),
           let c = try? JSONDecoder().decode(Config.self, from: data) { config = c }
    }

    func scheduleSave() {
        saveTask?.cancel()
        let snapshot = config
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            // Merge into the existing file so keys written by the scripts are preserved.
            var dict = (try? JSONSerialization.jsonObject(with: Data(contentsOf: Paths.config))) as? [String: Any] ?? [:]
            if let data = try? JSONEncoder().encode(snapshot),
               let mine = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                dict.merge(mine) { _, new in new }
            }
            try? FileManager.default.createDirectory(at: Paths.outDir, withIntermediateDirectories: true)
            if let out = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
                try? out.write(to: Paths.config, options: .atomic)
            }
        }
    }

    // MARK: Bulletins
    func regenerate(_ b: Bulletin) async {
        guard regenerating == nil else { return }
        regenerating = b.id
        banner = nil
        let started = Date().timeIntervalSince1970
        let (res, err) = await Backend.json(OKResult.self, Paths.bulletinCLI, ["regen", b.id])
        guard let res, res.ok else {
            banner = "Couldn't start regeneration: \(res?.output ?? err)"; regenerating = nil; return
        }
        for _ in 0..<96 {   // poll up to ~8 min
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if let st = (await Backend.json(StatusInfo.self, Paths.bulletinCLI, ["status"])).0 {
                status = st
                if !st.regen_pending, let t = st.last_publish?.time, t > started {
                    regenerating = nil
                    await refresh()
                    selection = b.id
                    banner = "Regenerated \(b.title)."
                    return
                }
            }
        }
        regenerating = nil
        banner = "Regeneration is taking longer than expected — it will appear when Hermes finishes."
    }

    // MARK: eNews
    func regenerate(_ issue: ENewsIssue) async {
        guard regeneratingENews == nil else { return }
        regeneratingENews = issue.id
        banner = nil
        let started = Date().timeIntervalSince1970
        let (res, err) = await Backend.json(OKResult.self, Paths.enewsCLI, ["regen", issue.id])
        guard let res, res.ok else {
            banner = "Couldn't start eNews summary: \(res?.output ?? err)"; regeneratingENews = nil; return
        }
        for _ in 0..<96 {   // poll up to ~8 min
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if let st = (await Backend.json(ENewsStatus.self, Paths.enewsCLI, ["status"])).0 {
                enewsStatus = st
                if !st.regen_pending, let t = st.last_publish?.time, t > started {
                    regeneratingENews = nil
                    await refresh()
                    selection = issue.tag
                    banner = "Summarized \(issue.title)."
                    return
                }
            }
        }
        regeneratingENews = nil
        banner = "The eNews summary is taking longer than expected — it will appear when Hermes finishes."
    }

    // MARK: Assignments
    func syncNow() async {
        guard !syncing else { return }
        syncing = true
        let r = await Backend.run(Paths.tasksCLI, ["sync"])
        syncing = false
        let lines = r.out.split(separator: "\n").map(String.init)
        if r.code != 0 {
            banner = "Sync failed: " + (lines.last ?? r.err.split(separator: "\n").last.map(String.init) ?? "unknown error")
        } else {
            let added = lines.filter { $0.hasPrefix("ADDED") }.count
            let moved = lines.filter { $0.hasPrefix("DUE->") }.count
            banner = (added + moved == 0) ? "Assignments are up to date."
                : "Sync done: \(added) added, \(moved) due date\(moved == 1 ? "" : "s") changed."
        }
        await refresh()
    }

    func complete(_ t: SchoolTask) async {
        completing.insert(t.id)
        let (res, err) = await Backend.json(OKResult.self, Paths.tasksCLI, ["complete", t.id])
        completing.remove(t.id)
        if res?.ok == true {
            withAnimation { tasks.removeAll { $0.id == t.id } }
            banner = "Completed “\(t.title)”."
        } else {
            banner = "Couldn't complete task: \(err)"
        }
    }

    // MARK: Schedules
    func setSchedule(_ on: Bool, _ which: String) async {
        let (res, err) = await Backend.json(OKResult.self, Paths.bulletinCLI, ["schedule", on ? "on" : "off", which])
        if res?.ok != true { banner = "Couldn't change schedule: \(res?.output ?? err)" }
        if let st = (await Backend.json(StatusInfo.self, Paths.bulletinCLI, ["status"])).0 { status = st }
    }

    // MARK: Sign-in (one Google sign-in shared by both features)
    func startSignIn() async -> Bool {
        let r = await Backend.run(Paths.bulletinCLI, ["auth-url"])
        guard let line = r.out.split(separator: "\n").last, line.hasPrefix("https://"),
              let url = URL(string: String(line)) else {
            banner = "Couldn't create sign-in link: \(r.err)"; return false
        }
        NSWorkspace.shared.open(url)
        return true
    }

    func finishSignIn(_ pasted: String) async -> String? {
        let r = await Backend.run(Paths.bulletinCLI, ["auth-code", pasted.trimmingCharacters(in: .whitespacesAndNewlines)])
        if r.out.contains("OK: token saved") {
            showSignIn = false
            banner = "Signed in."
            await refresh()
            return nil
        }
        return (r.err + r.out).split(separator: "\n").suffix(2).joined(separator: " ")
    }
}

// MARK: - Web view for summaries

struct SummaryWebView: NSViewRepresentable {
    let fileURL: URL
    let version: Int
    /// When set, the file is loaded as an HTML string with this base URL (archived web pages, so relative
    /// images/CSS resolve against the real site).
    var baseURL: URL? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.setValue(false, forKey: "drawsBackground")
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        let key = "\(fileURL.path)#\(version)#\(baseURL?.absoluteString ?? "")"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key
        if let baseURL {
            let html = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "<p>Archived page is missing.</p>"
            wv.loadHTMLString(html, baseURL: baseURL)
        } else {
            wv.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedKey = ""
        static func sameDocument(_ a: URL?, _ b: URL?) -> Bool {
            guard let a, let b, var ca = URLComponents(url: a, resolvingAgainstBaseURL: false),
                  var cb = URLComponents(url: b, resolvingAgainstBaseURL: false) else { return false }
            ca.fragment = nil; cb.fragment = nil
            return ca.url == cb.url
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url, url.scheme != "file",
               !(url.fragment != nil && Self.sameDocument(url, webView.url)) {   // in-page anchors stay here
                NSWorkspace.shared.open(url); decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url {
                if url.isFileURL { webView.load(action.request) } else { NSWorkspace.shared.open(url) }
            }
            return nil
        }
    }
}

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            if model.selection == AppModel.assignmentsTag {
                AssignmentsView()
            } else if model.selection?.hasPrefix("enews:") == true {
                ENewsDetail()
            } else {
                BulletinDetail()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) { StatusPill() }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.loading { ProgressView().controlSize(.small) }
                Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
                    .help("Refresh")
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .help("Settings (⌘,)")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let b = model.banner {
                HStack {
                    Text(b).font(.callout)
                    Spacer()
                    Button { model.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .padding(10).background(.thinMaterial)
            }
        }
        .sheet(isPresented: $model.showSignIn) { SignInSheet().environmentObject(model) }
        .frame(minWidth: 880, minHeight: 580)
    }
}

struct StatusPill: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let s = model.status
        HStack(spacing: 6) {
            Circle().fill(s.offline ? .orange : (s.signed_in ? .green : .red)).frame(width: 8, height: 8)
            if s.offline { Text("Offline") }
            else if s.signed_in { Text(s.email ?? "Signed in") }
            else { Button("Sign in…") { model.showSignIn = true } }
        }
        .font(.callout).foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10)
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var overdueCount: Int {
        let today = Fmt.ymd.string(from: Date())
        return model.tasks.filter { !$0.due.isEmpty && $0.due < today }.count
    }

    var body: some View {
        List(selection: $model.selection) {
            Section("SAS eNews · Weekly") {
                if model.enews.isEmpty {
                    Label(model.enewsError == nil ? "Loading…" : "Couldn't load eNews", systemImage: "envelope.open")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.enews) { e in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(e.shortTitle).font(.headline)
                                if e.live {
                                    Text("LATEST").font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(Capsule().fill(.blue.opacity(0.2))).foregroundStyle(.blue)
                                }
                            }
                            Text(e.has_page ? "Summary ready" : "Not summarized")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.regeneratingENews == e.id { ProgressView().controlSize(.small) }
                        else if e.has_page { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    }
                    .tag(e.tag)
                    .contextMenu {
                        Button(e.has_page ? "Regenerate Summary" : "Generate Summary") { Task { await model.regenerate(e) } }
                            .disabled(model.regeneratingENews != nil)
                        Button("Open on sas.edu.sg") { NSWorkspace.shared.open(Paths.enewsURL) }
                    }
                }
            }
            Section("Toddle") {
                HStack {
                    Label("Assignments", systemImage: "checklist")
                    Spacer()
                    if model.syncing { ProgressView().controlSize(.small) }
                    else if overdueCount > 0 {
                        Text("\(overdueCount)").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(.red)).foregroundStyle(.white)
                    } else if !model.tasks.isEmpty {
                        Text("\(model.tasks.count)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(AppModel.assignmentsTag)
            }
            Section("HS Daily Bulletin") {
                ForEach(model.bulletins) { b in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.title).font(.headline)
                            Text(b.has_page ? "Summary ready" : (b.summarized ? "Summarized (no page)" : "Not summarized"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.regenerating == b.id { ProgressView().controlSize(.small) }
                        else if b.has_page { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    }
                    .tag(b.id)
                    .contextMenu {
                        Button("Regenerate Summary") { Task { await model.regenerate(b) } }
                            .disabled(model.regenerating != nil)
                    }
                }
            }
        }
    }
}

// MARK: Assignments

struct AssignmentsView: View {
    @EnvironmentObject var model: AppModel

    struct Group: Identifiable { let id: String; let title: String; let color: Color; let items: [SchoolTask] }

    var groups: [Group] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func days(_ t: SchoolTask) -> Int? {
            guard let d = t.dueDate else { return nil }
            return cal.dateComponents([.day], from: today, to: cal.startOfDay(for: d)).day
        }
        var buckets: [String: [SchoolTask]] = [:]
        for t in model.tasks {
            let k: String
            switch days(t) {
            case nil: k = "none"
            case let n? where n < 0: k = "overdue"
            case 0: k = "today"
            case 1: k = "tomorrow"
            case let n? where n <= 7: k = "week"
            default: k = "later"
            }
            buckets[k, default: []].append(t)
        }
        let order: [(String, String, Color)] = [("overdue", "Overdue", .red), ("today", "Today", .orange),
                                                ("tomorrow", "Tomorrow", .yellow), ("week", "Next 7 days", .blue),
                                                ("later", "Later", .secondary), ("none", "No due date", .secondary)]
        return order.compactMap { k, title, c in buckets[k].map { Group(id: k, title: title, color: c, items: $0) } }
    }

    var syncLine: String {
        guard let s = model.tasksStatus.last_sync else { return "Not synced yet from this app" }
        if s.ok == false { return "Last sync failed \(Fmt.relative(s.time)) — \(s.error ?? "")" }
        let a = s.added?.count ?? 0, u = s.updated?.count ?? 0
        return "Synced \(Fmt.relative(s.time))" + (a + u > 0 ? " · \(a) added, \(u) updated" : "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("School assignments").font(.title3.bold())
                    Text(syncLine).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await model.syncNow() } } label: {
                    Label(model.syncing ? "Syncing…" : "Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(model.syncing || !model.status.signed_in)
                .help("Pull new assignments from Toddle into Google Tasks")
                Button { NSWorkspace.shared.open(URL(string: "https://tasks.google.com/")!) } label: {
                    Image(systemName: "arrow.up.forward.app")
                }.help("Open Google Tasks")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if model.tasks.isEmpty {
                ContentUnavailableView {
                    Label(model.status.signed_in ? "All caught up" : "Not signed in",
                          systemImage: model.status.signed_in ? "checkmark.seal" : "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text(model.status.signed_in ? "No open tasks in your Google Tasks “School” list."
                                                : "Sign in to sync Toddle assignments.")
                }
            } else {
                List {
                    ForEach(groups) { g in
                        Section {
                            ForEach(g.items) { t in TaskRow(task: t) }
                        } header: {
                            HStack(spacing: 6) {
                                Circle().fill(g.color).frame(width: 7, height: 7)
                                Text(g.title)
                                Text("\(g.items.count)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

struct TaskRow: View {
    @EnvironmentObject var model: AppModel
    let task: SchoolTask

    var subtitle: String {
        var parts: [String] = []
        if !task.course.isEmpty { parts.append(task.course) }
        if !task.when.isEmpty { parts.append(task.when) }
        else if let d = task.dueDate {
            let f = DateFormatter(); f.dateFormat = "EEE MMM d"; parts.append(f.string(from: d))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if model.completing.contains(task.id) {
                ProgressView().controlSize(.small).frame(width: 18)
            } else {
                Button { Task { await model.complete(task) } } label: {
                    Image(systemName: "circle").font(.system(size: 16)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Mark as done (completes it in Google Tasks)")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).lineLimit(2)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let url = URL(string: task.link), !task.link.isEmpty {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "link") }
                    .buttonStyle(.borderless)
                    .help(task.link.contains("toddle") ? "Open in Toddle" : "Open source email")
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Mark as Done") { Task { await model.complete(task) } }
            if !task.notes.isEmpty {
                Button("Copy Notes") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(task.notes, forType: .string)
                }
            }
        }
    }
}

// MARK: Bulletin detail

struct BulletinDetail: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let b = model.selectedBulletin {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(b.subject).font(.title3.bold())
                        if model.regenerating == b.id {
                            Text("Regenerating… this usually takes 1–2 minutes").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { Task { await model.regenerate(b) } } label: {
                        Label(b.has_page ? "Regenerate" : "Generate Summary", systemImage: "sparkles")
                    }
                    .disabled(model.regenerating != nil || !model.status.signed_in)
                    .help("Re-summarize this day with your current settings")
                    if b.has_page {
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: b.page)) } label: {
                            Image(systemName: "safari")
                        }.help("Open in browser")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                if b.has_page {
                    SummaryWebView(fileURL: URL(fileURLWithPath: b.page), version: model.pageVersion)
                } else {
                    ContentUnavailableView {
                        Label("No summary yet", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text("This bulletin hasn't been summarized. Click Generate Summary.")
                    }
                }
            }
        } else {
            ContentUnavailableView("Select a bulletin", systemImage: "newspaper")
        }
    }
}

// MARK: eNews detail

struct ENewsDetail: View {
    @EnvironmentObject var model: AppModel
    @State private var showOriginal = false

    var caption: String {
        if let e = model.selectedENews, model.regeneratingENews == e.id { return "Summarizing… this usually takes 1–2 minutes" }
        if let err = model.enewsError { return err == "offline" ? "Offline — showing the saved copy" : "Couldn't check for updates: \(err)" }
        return "New issue every Friday after school (~3:15 PM) · \(Paths.enewsURL.host ?? "")/enews"
    }

    var body: some View {
        if let e = model.selectedENews {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(e.title).font(.title3.bold())
                        Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Picker("", selection: $showOriginal) {
                        Text("Summary").tag(false)
                        Text("Full eNews").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Button { Task { await model.regenerate(e) } } label: {
                        Label(e.has_page ? "Regenerate" : "Generate Summary", systemImage: "sparkles")
                    }
                    .disabled(model.regeneratingENews != nil)
                    .help("Summarize this issue with your current settings")
                    Button {
                        NSWorkspace.shared.open(e.live || !e.has_page ? Paths.enewsURL : URL(fileURLWithPath: e.page))
                    } label: { Image(systemName: "safari") }
                    .help(e.live ? "Open sas.edu.sg/enews in browser" : "Open summary in browser")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                if showOriginal {
                    SummaryWebView(fileURL: URL(fileURLWithPath: e.raw), version: model.pageVersion, baseURL: Paths.enewsURL)
                } else if e.has_page {
                    SummaryWebView(fileURL: URL(fileURLWithPath: e.page), version: model.pageVersion)
                } else {
                    ContentUnavailableView {
                        Label("No summary yet", systemImage: "envelope.open")
                    } description: {
                        Text("This eNews issue hasn't been summarized. Click Generate Summary, or switch to Full eNews.")
                    }
                }
            }
        } else {
            ContentUnavailableView("Select an eNews issue", systemImage: "envelope.open")
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    func scheduleBinding(_ which: String) -> Binding<Bool> {
        Binding(get: { model.status.job(which).enabled },
                set: { on in Task { await model.setSchedule(on, which) } })
    }

    var body: some View {
        TabView {
            bulletinTab.tabItem { Label("Bulletin", systemImage: "newspaper") }
            enewsTab.tabItem { Label("eNews", systemImage: "envelope.open") }
            assignmentsTab.tabItem { Label("Assignments", systemImage: "checklist") }
            accountTab.tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .frame(width: 540)
        .onChange(of: model.config) { _, _ in model.scheduleSave() }
        .sheet(isPresented: $model.showSignIn) { SignInSheet().environmentObject(model) }
    }

    var bulletinTab: some View {
        Form {
            Section {
                Toggle("⭐ “For you” section", isOn: $model.config.for_you)
                Stepper("Up to \(model.config.for_you_max) items", value: $model.config.for_you_max, in: 1...12)
                    .disabled(!model.config.for_you).padding(.leading, 18)
                Toggle("Star urgent deadlines only if they match my interests",
                       isOn: $model.config.star_deadlines_only_if_relevant)
                    .disabled(!model.config.for_you).padding(.leading, 18)
                Toggle("Star college visits only from my college list", isOn: $model.config.college_list_only)
                    .disabled(!model.config.for_you).padding(.leading, 18)
                Toggle("🆕 “Also new today” section", isOn: $model.config.also_new)
                Toggle("Folded “Everything else” section", isOn: $model.config.everything_else)
                Stepper("Urgent deadline window: \(model.config.deadline_window_days) day\(model.config.deadline_window_days == 1 ? "" : "s")",
                        value: $model.config.deadline_window_days, in: 0...14)
            } header: { Text("Summary sections") }

            Section {
                TextField("Extra instructions", text: $model.config.extra_instructions,
                          prompt: Text("e.g. Always mention robotics and FRC items"), axis: .vertical)
                    .lineLimit(2...5)
                HStack {
                    Button("Edit My Interests Profile…") {
                        NSWorkspace.shared.open([Paths.profile],
                                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                                configuration: NSWorkspace.OpenConfiguration())
                    }
                    Button("Open Summaries Folder") { NSWorkspace.shared.open(Paths.outDir) }
                }
            } header: { Text("Personalization") } footer: {
                Text("Changes apply to the next summary — use Regenerate to apply them to an earlier day.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Automatic summaries (weekdays, checks 3–7 PM)", isOn: scheduleBinding("bulletin"))
                    .disabled(!model.status.job("bulletin").found)
                Toggle("macOS notification", isOn: $model.config.notifications)
                Toggle("Also post to Hermes Bot Chat", isOn: $model.config.post_to_chat)
                if let next = model.status.job("bulletin").next_run, model.status.job("bulletin").enabled {
                    LabeledContent("Next check", value: Fmt.iso(next))
                }
            } header: { Text("Delivery") }

            HStack {
                Spacer()
                Button("Restore Bulletin Defaults") {
                    var d = Config()   // only reset bulletin keys; keep assignment + eNews settings
                    d.tasks_notifications = model.config.tasks_notifications
                    d.tasks_lookahead_days = model.config.tasks_lookahead_days
                    d.enews_notifications = model.config.enews_notifications
                    d.enews_post_to_chat = model.config.enews_post_to_chat
                    d.enews_include_other_divisions = model.config.enews_include_other_divisions
                    d.enews_extra_instructions = model.config.enews_extra_instructions
                    model.config = d
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 620)
    }

    var enewsTab: some View {
        Form {
            Section {
                Toggle("Include Elementary, Middle School and Alumni sections", isOn: $model.config.enews_include_other_divisions)
                TextField("Extra instructions", text: $model.config.enews_extra_instructions,
                          prompt: Text("e.g. Always list Booster spirit days"), axis: .vertical)
                    .lineLimit(2...5)
            } header: { Text("Summary") } footer: {
                Text("The eNews is written for parents of every division; the summary keeps what matters to a high schooler, ranked with your interests profile. “For you” uses the same item limit as the bulletin.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Automatic summary (Thu & Fri, checks 3–8 PM)", isOn: scheduleBinding("enews"))
                    .disabled(!model.status.job("enews").found)
                Toggle("macOS notification", isOn: $model.config.enews_notifications)
                Toggle("Also post to Hermes Bot Chat", isOn: $model.config.enews_post_to_chat)
                if let next = model.status.job("enews").next_run, model.status.job("enews").enabled {
                    LabeledContent("Next check", value: Fmt.iso(next))
                }
            } header: { Text("Delivery") } footer: {
                Text("eNews comes out the last school day of each week, usually Friday ~3:15 PM. The page at sas.edu.sg/enews is checked every 10 minutes and summarized once when a new issue appears.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Open sas.edu.sg/enews") { NSWorkspace.shared.open(Paths.enewsURL) }
                    Button("Open eNews Folder") { NSWorkspace.shared.open(Paths.enewsDir) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 460)
    }

    var assignmentsTab: some View {
        Form {
            Section {
                Toggle("Automatic sync every 2 hours (7 AM – 11 PM)", isOn: scheduleBinding("tasks"))
                    .disabled(!model.status.job("tasks").found)
                Toggle("Turn Toddle announcements into tasks (AI)", isOn: scheduleBinding("announcements"))
                    .disabled(!model.status.job("announcements").found)
                Toggle("Notify me when new assignments are added", isOn: $model.config.tasks_notifications)
                Stepper("Look ahead \(model.config.tasks_lookahead_days) days on the Toddle calendar",
                        value: $model.config.tasks_lookahead_days, in: 7...90, step: 7)
                if let next = model.status.job("tasks").next_run, model.status.job("tasks").enabled {
                    LabeledContent("Next sync", value: Fmt.iso(next))
                }
            } header: { Text("Toddle → Google Tasks") } footer: {
                Text("Assignments come from the Toddle calendar and Toddle reminder / due-date emails, and go into the “School” list in Google Tasks. Duplicates are skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Open Google Tasks") { NSWorkspace.shared.open(URL(string: "https://tasks.google.com/")!) }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 340)
    }

    var accountTab: some View {
        Form {
            Section {
                LabeledContent("Google account") {
                    Text(model.status.signed_in ? (model.status.email ?? "Signed in") : "Not signed in")
                }
                Button(model.status.signed_in ? "Sign In Again…" : "Sign In…") { model.showSignIn = true }
            } header: { Text("Google") } footer: {
                Text("One sign-in covers both features: read-only Gmail and Calendar, plus Google Tasks.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 220)
    }
}

struct SignInSheet: View {
    @EnvironmentObject var model: AppModel
    @State private var pasted = ""
    @State private var opened = false
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Sign in with your SAS Google account", systemImage: "person.badge.key").font(.title3.bold())
            Text("SAS Sync reads Gmail and your Toddle calendar (read-only) and adds assignments to Google Tasks.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Open the Google sign-in page and allow access.")
                Button(opened ? "Open Sign-in Page Again" : "Open Sign-in Page") {
                    Task { opened = await model.startSignIn() }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("2. Your browser will show “can't connect to localhost”. That's expected — copy the whole address bar and paste it here:")
                    .fixedSize(horizontal: false, vertical: true)
                TextField("http://localhost:1/?state=…&code=…", text: $pasted)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!opened)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Cancel") { model.showSignIn = false }.keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Finish Sign-in") {
                    busy = true
                    Task { error = await model.finishSignIn(pasted); busy = false }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!pasted.contains("code=") || busy)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}

// MARK: - App

@main
struct SASSyncApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("SAS Sync") {
            ContentView().environmentObject(model)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh") { Task { await model.refresh() } }.keyboardShortcut("r")
                Button("Sync Assignments Now") { Task { await model.syncNow() } }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
        Settings {
            SettingsView().environmentObject(model)
        }
    }
}
