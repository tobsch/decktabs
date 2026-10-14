import AppKit
import SwiftUI
import UserNotifications

/// One entry of `agent-deck conductor status --json`.
struct ConductorStatus: Decodable, Equatable {
    let name: String
    let agent: String?
    let session_id: String?
    let running: Bool?
    let heartbeat: Bool?
    let description: String?
    let last_activity_at: String?
}

/// One item a conductor queued for the human (`agent-deck conductor outbox --json`).
struct OutboxItem: Decodable, Identifiable, Equatable {
    let id: String
    let ts: String
    let tier: String
    let text: String?
    let acked: Bool?

    var isUrgent: Bool { tier == "urgent" }
    var date: Date { DeckSession.parseDate(ts) ?? .distantPast }
}

/// agent-deck names the conductor session "conductor-<name>".
private let conductorPrefix = "conductor-"

extension SessionStore {
    func isConductor(_ s: DeckSession) -> Bool {
        conductorStatus.values.contains { $0.session_id == s.id } || s.isConductor
    }

    /// Conductor name for a conductor session ("ops" for "conductor-ops").
    func conductorName(_ s: DeckSession) -> String? {
        if let st = conductorStatus.values.first(where: { $0.session_id == s.id }) { return st.name }
        guard s.isConductor else { return nil }
        return s.title.hasPrefix(conductorPrefix) ? String(s.title.dropFirst(conductorPrefix.count)) : s.title
    }

    func status(of s: DeckSession) -> ConductorStatus? {
        conductorName(s).flatMap { conductorStatus[$0] }
    }

    /// Sessions a conductor launched (directly or via its workers), newest activity first.
    func children(of conductor: DeckSession) -> [DeckSession] {
        sessions.filter { $0.id != conductor.id && conductorAncestor(of: $0)?.id == conductor.id }
    }

    /// The conductor a session descends from via `parent_session_id`, if any.
    func conductorAncestor(of s: DeckSession) -> DeckSession? {
        var seen: Set<String> = [s.id]
        var current = s
        while let pid = current.parent_session_id, !pid.isEmpty, !seen.contains(pid) {
            let parentID = current.remote.map { "\($0)/\(pid)" } ?? pid
            guard let parent = sessions.first(where: { $0.id == parentID }) else { return nil }
            if isConductor(parent) { return parent }
            seen.insert(pid)
            current = parent
        }
        return nil
    }

    func pendingOutbox(_ s: DeckSession) -> [OutboxItem] {
        guard let name = conductorName(s) else { return [] }
        return (outbox[name] ?? []).filter { $0.acked != true }.sorted { $0.date > $1.date }
    }

    var urgentCount: Int {
        outbox.values.joined().filter { $0.isUrgent && $0.acked != true }.count
    }

    func updateBadge() {
        let n = unreadCount + urgentCount
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    // MARK: Polling

    func refreshConductors() {
        if Demo.enabled { return }
        Task.detached {
            struct Status: Decodable { let conductors: [ConductorStatus]? }
            let list = Tools.run(Tools.agentDeck, ["conductor", "status", "--json"])
                .flatMap { try? JSONDecoder().decode(Status.self, from: $0) }?.conductors ?? []
            var boxes: [String: [OutboxItem]] = [:]
            for c in list {
                let data = Tools.run(Tools.agentDeck, ["conductor", "outbox", "--json", "--conductor", c.name])
                boxes[c.name] = data.flatMap { try? JSONDecoder().decode([OutboxItem]?.self, from: $0) } ?? []
            }
            let statuses = Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
            let found = boxes
            await MainActor.run {
                if statuses != self.conductorStatus { self.conductorStatus = statuses }
                if found != self.outbox { withAnimation(.snappy(duration: 0.25)) { self.outbox = found } }
                self.notifyNewUrgent()
                self.updateBadge()
            }
        }
    }

    /// macOS notification for urgent items that arrived since launch.
    private func notifyNewUrgent() {
        let pending = outbox.flatMap { name, items in items.filter { $0.acked != true }.map { (name, $0) } }
        defer {
            notifiedOutbox.formUnion(pending.map(\.1.id))
            outboxPrimed = true
        }
        guard outboxPrimed else { return }
        for (name, item) in pending where item.isUrgent && !notifiedOutbox.contains(item.id) {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Conductor \(name)")
            content.body = item.text ?? ""
            content.sound = .default
            content.userInfo = ["session": conductors.first { conductorName($0) == name }?.id ?? ""]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
        }
    }

    // MARK: Actions

    func ack(_ item: OutboxItem, conductor s: DeckSession) {
        guard let name = conductorName(s) else { return }
        withAnimation(.snappy(duration: 0.25)) {
            outbox[name]?.removeAll { $0.id == item.id }
        }
        updateBadge()
        if Demo.enabled { return }
        Task.detached {
            let ok = Tools.run(Tools.agentDeck, ["conductor", "outbox", "--conductor", name, "--ack", item.id]) != nil
            await MainActor.run {
                if !ok { self.lastError = String(localized: "Could not mark the item as done") }
                self.refreshConductors()
            }
        }
    }

    /// Sends a message into a session (`agent-deck session send`), like typing it in the terminal.
    func send(_ message: String, to s: DeckSession) async -> Bool {
        if Demo.enabled { return true }
        let args: [String] = s.isRemote ? [] : ["session", "send", s.id, message]
        guard !args.isEmpty else { return false }
        return await Task.detached { Tools.run(Tools.agentDeck, args) != nil }.value
    }
}

/// Opens the conductor when its notification is clicked.
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHandler()

    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["session"] as? String
        DispatchQueue.main.async {
            if let id, !id.isEmpty { SessionStore.current?.selectedID = id }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
        completionHandler()
    }
}
