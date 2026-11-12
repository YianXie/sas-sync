// SAS Bulletin — a small native macOS app for Ian's HS Daily Bulletin summaries.
// The heavy lifting (Gmail, summarizing, scheduling) lives in ~/.hermes/scripts/sas_bulletin.py
// and the Hermes cron job; this app is the control panel.

import AppKit
import SwiftUI
import WebKit

// MARK: - Paths

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let hermes = home.appendingPathComponent(".hermes")
    static let cli = hermes.appendingPathComponent("scripts/sas_bulletin_cli.sh").path
    static let outDir = hermes.appendingPathComponent("sas_bulletins")
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

    var date: Date? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: stamp)
    }
    var title: String {
        guard let d = date else { return subject }
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"
        return f.string(from: d)
    }
}

struct LastPublish: Codable, Equatable { let stamp: String?; let title: String?; let time: Double? }

struct StatusInfo: Codable {
    var signed_in: Bool = false
    var offline: Bool = false
    var email: String?
    var error: String?
    var job_found: Bool = false
    var job_enabled: Bool = false
    var next_run: String?
    var last_run: String?
    var last_status: String?
    var regen_pending: Bool = false
    var regen_id: String?
    var last_publish: LastPublish?
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

    init() {}
    // Tolerant decoding: missing keys fall back to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.defaults
        for_you = (try? c.decode(Bool.self, forKey: .for_you)) ?? d.for_you
        for_you_max = (try? c.decode(Int.self, forKey: .for_you_max)) ?? d.for_you_max
        deadline_window_days = (try? c.decode(Int.self, forKey: .deadline_window_days)) ?? d.deadline_window_days
        star_deadlines_only_if_relevant = (try? c.decode(Bool.self, forKey: .star_deadlines_only_if_relevant)) ?? d.star_deadlines_only_if_relevant
        college_list_only = (try? c.decode(Bool.self, forKey: .college_list_only)) ?? d.college_list_only
        also_new = (try? c.decode(Bool.self, forKey: .also_new)) ?? d.also_new
        everything_else = (try? c.decode(Bool.self, forKey: .everything_else)) ?? d.everything_else
        notifications = (try? c.decode(Bool.self, forKey: .notifications)) ?? d.notifications
        post_to_chat = (try? c.decode(Bool.self, forKey: .post_to_chat)) ?? d.post_to_chat
        extra_instructions = (try? c.decode(String.self, forKey: .extra_instructions)) ?? d.extra_instructions
    }
    static let defaults = Config()
}

// MARK: - Backend (runs the Python CLI)

enum Backend {
    struct Result { let code: Int32; let out: String; let err: String }

    static func run(_ args: [String]) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = [Paths.cli] + args
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

    static func json<T: Decodable>(_ type: T.Type, _ args: [String]) async -> (T?, String) {
        let r = await run(args)
        let line = r.out.split(separator: "\n").last.map(String.init) ?? ""
        if let data = line.data(using: .utf8), let v = try? JSONDecoder().decode(T.self, from: data) {
            return (v, "")
        }
        let msg = (r.err.isEmpty ? r.out : r.err).split(separator: "\n").suffix(2).joined(separator: " ")
        return (nil, msg.isEmpty ? "No response from backend" : msg)
    }
}

// MARK: - App state

@MainActor
final class AppModel: ObservableObject {
    @Published var bulletins: [Bulletin] = []
    @Published var status = StatusInfo()
    @Published var config = Config()
    @Published var selection: Bulletin.ID?
    @Published var loading = false
    @Published var regenerating: String?          // bulletin id
    @Published var banner: String?
    @Published var pageVersion = 0                // bump to reload the web view
    @Published var showSignIn = false

    private var saveTask: Task<Void, Never>?

    init() {
        loadConfig()
        Task { await refresh() }
    }

    var selected: Bulletin? { bulletins.first { $0.id == selection } }

    func refresh() async {
        loading = true
        async let s = Backend.json(StatusInfo.self, ["status"])
        async let l = Backend.json([Bulletin].self, ["list"])
        let (st, stErr) = await s
        let (list, listErr) = await l
        if let st { status = st } else { banner = "Status error: \(stErr)" }
        if let list {
            bulletins = list
            if selection == nil || !list.contains(where: { $0.id == selection }) {
                selection = list.first(where: { $0.has_page })?.id ?? list.first?.id
            }
        } else if status.signed_in {
            banner = "Couldn't load bulletins: \(listErr)"
        }
        if !status.signed_in && !status.offline { showSignIn = true }
        loading = false
        pageVersion += 1
    }

    // Config
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
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? FileManager.default.createDirectory(at: Paths.outDir, withIntermediateDirectories: true)
            if let data = try? enc.encode(snapshot) { try? data.write(to: Paths.config, options: .atomic) }
        }
    }

    // Regenerate
    func regenerate(_ b: Bulletin) async {
        guard regenerating == nil else { return }
        regenerating = b.id
        banner = nil
        let started = Date().timeIntervalSince1970
        let (res, err) = await Backend.json([String: AnyCodable].self, ["regen", b.id])
        guard let res, (res["ok"]?.value as? Bool) == true else {
            banner = "Couldn't start regeneration: \(err)"; regenerating = nil; return
        }
        // Poll until the job publishes a page newer than our request (max ~8 min).
        for _ in 0..<96 {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            let (st, _) = await Backend.json(StatusInfo.self, ["status"])
            if let st {
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
        banner = "Regeneration is taking longer than expected — it will still appear when Hermes finishes."
    }

    func setSchedule(_ on: Bool) async {
        let (res, err) = await Backend.json([String: AnyCodable].self, ["schedule", on ? "on" : "off"])
        if res == nil { banner = "Couldn't change schedule: \(err)" }
        await refresh()
    }

    // Sign-in
    func startSignIn() async -> Bool {
        let r = await Backend.run(["auth-url"])
        guard let line = r.out.split(separator: "\n").last, let url = URL(string: String(line)),
              line.hasPrefix("https://") else {
            banner = "Couldn't create sign-in link: \(r.err)"; return false
        }
        NSWorkspace.shared.open(url)
        return true
    }

    func finishSignIn(_ pasted: String) async -> String? {
        let r = await Backend.run(["auth-code", pasted.trimmingCharacters(in: .whitespacesAndNewlines)])
        if r.out.contains("OK: token saved") {
            showSignIn = false
            banner = "Signed in."
            await refresh()
            return nil
        }
        return (r.err + r.out).split(separator: "\n").suffix(2).joined(separator: " ")
    }
}

/// Minimal Any wrapper for decoding small JSON objects.
struct AnyCodable: Codable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { value = b }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = d }
        else if let s = try? c.decode(String.self) { value = s }
        else { value = NSNull() }
    }
    func encode(to encoder: Encoder) throws {}
}

// MARK: - Web view for summaries

struct SummaryWebView: NSViewRepresentable {
    let fileURL: URL
    let version: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.setValue(false, forKey: "drawsBackground")
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        let key = "\(fileURL.path)#\(version)"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key
        wv.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedKey = ""
        // Links open in the default browser.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url, url.scheme != "file" {
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

// MARK: - Views

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            BulletinList()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            DetailView()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) { StatusPill() }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.loading { ProgressView().controlSize(.small) }
                Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
                    .help("Refresh bulletin list")
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .help("Summary settings (⌘,)")
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
        .frame(minWidth: 860, minHeight: 560)
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
        .fixedSize()                 // let the toolbar measure the full email width
        .padding(.horizontal, 10)
    }
}

struct BulletinList: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List(selection: $model.selection) {
            Section("Bulletins") {
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
        .overlay {
            if model.bulletins.isEmpty && !model.loading {
                ContentUnavailableView("No bulletins", systemImage: "tray",
                                       description: Text(model.status.signed_in ? "Nothing in the last 60 days." : "Sign in to load bulletins."))
            }
        }
    }
}

struct DetailView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let b = model.selected {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(b.subject).font(.title3.bold())
                        if model.regenerating == b.id {
                            Text("Regenerating… this usually takes 1–2 minutes").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        Task { await model.regenerate(b) }
                    } label: {
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

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
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
                Text("The profile decides what counts as “for you”. Changes apply to the next summary — use Regenerate to apply them to an earlier day.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Automatic summaries (weekdays, checks 3–7 PM)", isOn: Binding(
                    get: { model.status.job_enabled },
                    set: { on in Task { await model.setSchedule(on) } }))
                    .disabled(!model.status.job_found)
                Toggle("macOS notification", isOn: $model.config.notifications)
                Toggle("Also post to Hermes Bot Chat", isOn: $model.config.post_to_chat)
                if let next = model.status.next_run, model.status.job_enabled {
                    LabeledContent("Next check", value: prettyDate(next))
                }
            } header: { Text("Delivery") }

            Section {
                LabeledContent("Google account") {
                    Text(model.status.signed_in ? (model.status.email ?? "Signed in") : "Not signed in")
                }
                Button(model.status.signed_in ? "Sign In Again…" : "Sign In…") { model.showSignIn = true }
            } header: { Text("Account") }

            HStack {
                Spacer()
                Button("Restore Defaults") { model.config = Config() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 600)
        .onChange(of: model.config) { _, _ in model.scheduleSave() }
        .sheet(isPresented: $model.showSignIn) { SignInSheet().environmentObject(model) }
    }

    func prettyDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let d = f.date(from: iso) ?? { f.formatOptions = [.withInternetDateTime]; return f.date(from: iso) }()
        guard let d else { return iso }
        let o = DateFormatter(); o.dateFormat = "EEE MMM d, h:mm a"
        return o.string(from: d)
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
            Text("The app only gets read-only access to Gmail so it can find the HS Daily Bulletin.")
                .foregroundStyle(.secondary)
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
struct SASBulletinApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("SAS Bulletin") {
            ContentView().environmentObject(model)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh") { Task { await model.refresh() } }.keyboardShortcut("r")
            }
        }
        Settings {
            SettingsView().environmentObject(model)
        }
    }
}
