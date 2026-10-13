import AppKit
import Foundation
import SwiftUI

/// One row of `agent-deck list --json`.
struct DeckSession: Decodable, Identifiable, Equatable, Hashable {
    var id: String
    let title: String
    var group: String
    let tool: String
    let status: String
    let path: String
    let tmux_session: String?
    let last_activity_at: String?
    let archived: Bool?
    let parent_session_id: String?
    /// Name of the agent-deck remote (e.g. "build-server"), nil = local.
    var remote: String? = nil
    /// Session ID on the remote (`id` is made unique by prefixing the remote name).
    var remoteID: String? = nil

    var isRemote: Bool { remote != nil }
    /// Sidebar area: the agent-deck group for local sessions, the machine for remote ones.
    var area: String { remote ?? group }

    /// Command the terminal runs to attach.
    var attachCommand: [String] {
        if Demo.enabled { return Demo.terminalCommand(for: self) }
        if let remote, let remoteID { return [Tools.agentDeck, "remote", "attach", remote, remoteID] }
        return [Tools.tmux, "attach-session", "-t", tmux_session ?? title]
    }

    var attachHint: String {
        if let remote { return "agent-deck remote attach \(remote) \(title)" }
        return "tmux attach -t \(tmux_session ?? title)"
    }

    var lastActivity: Date { Self.parseDate(last_activity_at) ?? .distantPast }

    /// agent-deck conductors live in a "conductor" group or are titled "conductor-…".
    var isConductor: Bool {
        group.lowercased().hasPrefix("conductor") || title.lowercased().hasPrefix("conductor")
    }

    var isRunning: Bool { status == "running" || status == "starting" }
    var isError: Bool { status == "error" }

    var shortPath: String {
        if isRemote {
            let p = path.replacingOccurrences(of: #"^/(home|Users)/[^/]+"#, with: "~", options: .regularExpression)
            return (remote ?? "") + ":" + p
        }
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // Go emits nanoseconds, ISO8601DateFormatter only handles milliseconds
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
            var t = s
            t.replaceSubrange(r, with: String(s[r].prefix(4)))
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: t)
        }
        return nil
    }
}

enum Tools {
    static let searchPath = [
        NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
    ]

    static func find(_ name: String) -> String {
        for dir in searchPath {
            let p = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return name
    }

    static let agentDeck = find("agent-deck")
    static let tmux = find("tmux")

    /// Environment for child processes – apps launched from Finder only get a minimal PATH.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath.joined(separator: ":")
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "de_DE.UTF-8"
        env["LC_CTYPE"] = env["LC_CTYPE"] ?? "UTF-8"
        env.removeValue(forKey: "TMUX")
        return env
    }

    static func run(_ exe: String, _ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
}

enum SidebarMode: String, CaseIterable {
    case activity, groups
    var label: String { self == .activity ? String(localized: "Activity") : String(localized: "Areas") }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published var sessions: [DeckSession] = []
    @Published var selectedID: String? {
        didSet { if let selectedID { markSeen(selectedID) } }
    }
    @Published var lastError: String?
    @Published var loaded = false
    @Published var mode: SidebarMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "sidebarMode") }
    }
    /// When a session was last looked at – drives "new" (like unread in Mail).
    @Published private(set) var lastSeen: [String: Date]

    private var timer: Timer?
    private var remoteTimer: Timer?
    private var remoteSessions: [DeckSession] = []
    private var localSessions: [DeckSession]?

    init() {
        mode = SidebarMode(rawValue: UserDefaults.standard.string(forKey: "sidebarMode") ?? "") ?? .activity
        let raw = UserDefaults.standard.dictionary(forKey: "lastSeen") as? [String: Double] ?? [:]
        lastSeen = raw.mapValues { Date(timeIntervalSince1970: $0) }
        selectedID = UserDefaults.standard.string(forKey: "selectedID")
    }

    var conductors: [DeckSession] { sessions.filter(\.isConductor) }
    var others: [DeckSession] { sessions.filter { !$0.isConductor } }

    /// Current git branch per local session (refreshed every 10 s).
    @Published private(set) var branches: [String: String] = [:]

    func refreshBranches() {
        let local = sessions.filter { !$0.isRemote }.map { ($0.id, $0.path) }
        Task.detached {
            var result: [String: String] = [:]
            for (id, path) in local {
                guard let data = Tools.run("/usr/bin/git", ["-C", path, "branch", "--show-current"]),
                      let b = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !b.isEmpty else { continue }
                result[id] = b
            }
            let found = result
            await MainActor.run { if found != self.branches { self.branches = found } }
        }
    }

    /// All local agent-deck groups, including empty ones (drop targets).
    @Published private(set) var knownGroups: [String] = []

    var groups: [(name: String, sessions: [DeckSession], isRemote: Bool)] {
        var byArea = Dictionary(grouping: others, by: \.area)
        for g in knownGroups where byArea[g] == nil && !g.lowercased().hasPrefix("conductor") { byArea[g] = [] }
        return byArea
            .map { (name: $0.key, sessions: $0.value, isRemote: $0.value.first?.isRemote ?? false) }
            .sorted {
                let a = $0.sessions.first?.lastActivity ?? .distantPast
                let b = $1.sessions.first?.lastActivity ?? .distantPast
                return a != b ? a > b : $0.name < $1.name
            }
    }

    /// Move a local session into another agent-deck group (drag & drop in "Areas").
    func move(sessionID: String, toGroup group: String) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionID }),
              !sessions[i].isRemote, sessions[i].group != group else { return }
        withAnimation(.snappy(duration: 0.25)) { sessions[i].group = group }
        if Demo.enabled { return }
        if let j = localSessions?.firstIndex(where: { $0.id == sessionID }) { localSessions?[j].group = group }
        Task.detached {
            let ok = Tools.run(Tools.agentDeck, ["group", "move", sessionID, group]) != nil
            await MainActor.run {
                if !ok { self.lastError = String(localized: "Moving to “\(group)” failed") }
                self.refresh()
            }
        }
    }

    func refreshGroups() {
        Task.detached {
            struct G: Decodable { let path: String }
            struct L: Decodable { let groups: [G] }
            let names = Tools.run(Tools.agentDeck, ["group", "list", "--json"])
                .flatMap { try? JSONDecoder().decode(L.self, from: $0) }?.groups.map(\.path) ?? []
            await MainActor.run { if names != self.knownGroups { self.knownGroups = names } }
        }
    }

    /// Order as shown in the sidebar (for ⌘1–9 and ⌘[ ⌘]).
    var ordered: [DeckSession] {
        mode == .activity ? conductors + others : conductors + groups.flatMap(\.sessions)
    }

    var unreadCount: Int { sessions.filter(isUnread).count }

    func isUnread(_ s: DeckSession) -> Bool {
        guard !s.isRunning, s.id != selectedID || !NSApp.isActive else { return false }
        guard let seen = lastSeen[s.id] else { return false }
        return s.lastActivity > seen.addingTimeInterval(2)
    }

    func markSeen(_ id: String) {
        lastSeen[id] = Date()
        persistSeen()
    }

    private func persistSeen() {
        if Demo.enabled { return }
        UserDefaults.standard.set(lastSeen.mapValues(\.timeIntervalSince1970), forKey: "lastSeen")
    }

    func start() {
        guard timer == nil else { return }
        if Demo.enabled {
            sessions = Demo.sessions
            knownGroups = Array(Set(Demo.sessions.filter { !$0.isRemote }.map(\.group))).sorted()
            for s in sessions { lastSeen[s.id] = Demo.seen(s) }
            selectedID = sessions.first { $0.title == "api-gateway" }?.id
            loaded = true
            NSApp.dockTile.badgeLabel = "\(unreadCount)"
            branches = Dictionary(uniqueKeysWithValues: sessions.filter { !$0.isRemote }.map { ($0.id, "main") })
            branches[sessions.first { $0.title == "api-gateway" }?.id ?? ""] = "feat/rate-limit"
            return
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refreshRemotes()
        refreshGroups()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refreshBranches() }
        remoteTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshRemotes()
                self?.refreshGroups()
                self?.refreshBranches()
            }
        }
    }

    /// Sessions on agent-deck remotes (over SSH, so polled less often).
    func refreshRemotes() {
        Task.detached {
            struct Remote: Decodable { let name: String }
            let names = (Tools.run(Tools.agentDeck, ["remote", "list", "--json"])
                .flatMap { try? JSONDecoder().decode([Remote].self, from: $0) } ?? []).map(\.name)
            var all: [DeckSession] = []
            for name in names {
                guard let data = Tools.run(Tools.agentDeck, ["remote", "sessions", name, "--json"]),
                      let list = try? JSONDecoder().decode([DeckSession].self, from: data) else { continue }
                all += list.map { s in
                    var r = s
                    r.remoteID = s.id
                    r.remote = name
                    r.id = "\(name)/\(s.id)"
                    return r
                }
            }
            let found = all
            await MainActor.run {
                self.remoteSessions = found
                self.apply(nil, keepLocal: true)
            }
        }
    }

    func refresh() {
        Task.detached {
            let data = Tools.run(Tools.agentDeck, ["list", "--json"])
            await MainActor.run { self.apply(data) }
        }
    }

    private func apply(_ data: Data?, keepLocal: Bool = false) {
        loaded = true
        if !keepLocal && data == nil {
            lastError = String(localized: "agent-deck is not responding")
            return
        }
        do {
            if let data { localSessions = try JSONDecoder().decode([DeckSession].self, from: data) }
            let list = ((localSessions ?? []) + remoteSessions)
                .filter { $0.archived != true }
                .sorted { $0.lastActivity > $1.lastActivity }
            // New sessions start as "seen" so the first launch does not mark everything new.
            var changed = false
            for s in list where lastSeen[s.id] == nil {
                lastSeen[s.id] = max(s.lastActivity, Date(timeIntervalSince1970: 0))
                changed = true
            }
            // Whatever is open while the app is frontmost counts as seen.
            if let sel = selectedID, NSApp.isActive { lastSeen[sel] = Date(); changed = true }
            if changed { persistSeen() }
            if list != sessions {
                withAnimation(.snappy(duration: 0.3)) { sessions = list }
            }
            lastError = nil
            if selectedID == nil || !list.contains(where: { $0.id == selectedID }) {
                selectedID = ordered.first?.id
            }
            UserDefaults.standard.set(selectedID, forKey: "selectedID")
            let n = unreadCount
            NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
        } catch {
            lastError = String(localized: "Could not read agent-deck output")
        }
    }

    func select(index: Int) {
        let o = ordered
        if index < o.count { selectedID = o[index].id }
    }

    func step(_ delta: Int) {
        let o = ordered
        guard !o.isEmpty else { return }
        let i = o.firstIndex { $0.id == selectedID } ?? 0
        selectedID = o[(i + delta + o.count) % o.count].id
    }

    /// Jumps to the oldest new session (⌘J).
    func jumpToNextUnread() {
        if let s = ordered.last(where: isUnread) { selectedID = s.id }
    }

    var selected: DeckSession? { sessions.first { $0.id == selectedID } }
}
