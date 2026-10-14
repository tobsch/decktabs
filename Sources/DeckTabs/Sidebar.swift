import SwiftUI

/// Tracks whether ⌘ is held – the sidebar then shows shortcuts instead of times.
@MainActor
final class KeyState: ObservableObject {
    static let shared = KeyState()
    @Published var commandHeld = false
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            if held != self.commandHeld {
                withAnimation(.easeOut(duration: 0.12)) { self.commandHeld = held }
            }
            return event
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var store: SessionStore
    @ObservedObject var keys = KeyState.shared
    @Binding var showSwitcher: Bool
    var toggleSidebar: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SearchButton { showSwitcher = true }
                SidebarToggle(action: toggleSidebar, onDark: false)
            }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 8)

            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                List(selection: $store.selectedID) {
                    if !store.conductors.isEmpty {
                        Section {
                            ForEach(store.conductors) { c in
                                rows([c], now: ctx.date, showGroup: true)
                                if store.mode == .activity {
                                    rows(store.children(of: c), now: ctx.date, showGroup: true, nested: true)
                                }
                            }
                        } header: {
                            SectionTitle("Conductors", symbol: "point.3.connected.trianglepath.dotted")
                        }
                    }
                    switch store.mode {
                    case .activity:
                        ForEach(buckets(now: ctx.date), id: \.title) { b in
                            Section { rows(b.sessions, now: ctx.date, showGroup: true) } header: {
                                SectionTitle(b.title)
                            }
                        }
                    case .groups:
                        ForEach(store.groups, id: \.name) { g in
                            Section {
                                rows(g.sessions, now: ctx.date, showGroup: false, dropGroup: g.isRemote ? nil : g.name)
                                if g.sessions.isEmpty {
                                    Text("Drop here")
                                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                                        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                                        .padding(.leading, 21)
                                        .dropTarget(g.name, store: store)
                                }
                            } header: {
                                SectionTitle(g.name, symbol: g.isRemote ? "network" : nil,
                                             dot: g.isRemote ? nil : Theme.color(forGroup: g.name))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .dropTarget(g.isRemote ? nil : g.name, store: store)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }

            footer
        }
        .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 380)
    }

    @ViewBuilder
    private func rows(_ list: [DeckSession], now: Date, showGroup: Bool, dropGroup: String? = nil,
                      nested: Bool = false) -> some View {
        ForEach(list) { s in
            let inbox = store.pendingOutbox(s)
            SessionRow(
                session: s,
                unread: store.isUnread(s),
                showGroup: showGroup,
                shortcut: keys.commandHeld ? store.ordered.firstIndex(of: s).flatMap { $0 < 9 ? $0 + 1 : nil } : nil,
                now: now,
                inboxCount: inbox.count,
                inboxUrgent: inbox.contains(where: \.isUrgent),
                nested: nested
            )
            .tag(s.id)
            .draggableSession(s, enabled: store.mode == .groups)
            .dropTarget(dropGroup, store: store)
        }
    }

    /// Time buckets like in Things: Today, Yesterday, This Week, Earlier.
    private func buckets(now: Date) -> [(title: String, sessions: [DeckSession])] {
        let cal = Calendar.current
        var today: [DeckSession] = [], yesterday: [DeckSession] = [], week: [DeckSession] = [], older: [DeckSession] = []
        for s in store.others {
            let d = s.lastActivity
            if cal.isDateInToday(d) || d > now { today.append(s) }
            else if cal.isDateInYesterday(d) { yesterday.append(s) }
            else if now.timeIntervalSince(d) < 7 * 86400 { week.append(s) }
            else { older.append(s) }
        }
        return [(String(localized: "Today"), today), (String(localized: "Yesterday"), yesterday),
                (String(localized: "This Week"), week), (String(localized: "Earlier"), older)]
            .filter { !$0.1.isEmpty }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if let err = store.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Picker("", selection: $store.mode) {
                ForEach(SidebarMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct SectionTitle: View {
    let text: String
    var symbol: String?
    var dot: Color?

    init(_ text: String, symbol: String? = nil, dot: Color? = nil) {
        self.text = text; self.symbol = symbol; self.dot = dot
    }

    var body: some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }
}

struct SessionRow: View {
    let session: DeckSession
    let unread: Bool
    let showGroup: Bool
    let shortcut: Int?
    let now: Date
    var inboxCount = 0
    var inboxUrgent = false
    /// Worker of a conductor: indented under it with a tree line.
    var nested = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if nested {
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1).padding(.leading, 6)
            }
            StatusGlyph(session: session, unread: unread)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 13, weight: unread ? .semibold : .regular))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    ToolBadge(tool: session.tool)
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                    if session.isRemote {
                        Image(systemName: "network").font(.system(size: 9))
                        Text(showGroup ? session.area : session.path)
                    } else if showGroup {
                        Circle().fill(Theme.color(forGroup: session.group)).frame(width: 5, height: 5)
                        Text(session.group)
                    } else {
                        Text(session.shortPath).truncationMode(.head)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if inboxCount > 0 {
                Text(verbatim: "\(inboxCount)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(inboxUrgent ? Color.white : Color.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(inboxUrgent ? Color.orange : Color.primary.opacity(0.1)))
                    .help(String(localized: "Items in the conductor's inbox"))
            }
            Group {
                if let shortcut {
                    Text(verbatim: "⌘\(shortcut)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        .transition(.opacity)
                } else {
                    Text(Theme.ago(session.lastActivity, now: now))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(unread ? Color.accentColor : Color.secondary.opacity(0.8))
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

struct SearchButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                Text("Jump to…")
                Spacer()
                Text("⌘K").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(hover ? 0.08 : 0.05))
            )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

extension View {
    /// In “Areas” local sessions can be dragged into another group; remote sessions cannot.
    @ViewBuilder
    func draggableSession(_ s: DeckSession, enabled: Bool) -> some View {
        if enabled && !s.isRemote && !s.isConductor {
            self.draggable(s.id) {
                Label(s.title, systemImage: "rectangle.stack")
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func dropTarget(_ group: String?, store: SessionStore) -> some View {
        if let group {
            modifier(DropHighlight(group: group, store: store))
        } else {
            self
        }
    }
}

private struct DropHighlight: ViewModifier {
    let group: String
    let store: SessionStore
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(targeted ? 0.18 : 0))
                    .padding(.horizontal, -6)
            )
            .dropDestination(for: String.self) { ids, _ in
                for id in ids { store.move(sessionID: id, toGroup: group) }
                return !ids.isEmpty
            } isTargeted: { t in
                withAnimation(.easeOut(duration: 0.1)) { targeted = t }
            }
    }
}

/// Custom sidebar toggle (the system button is barely visible on the dark terminal).
struct SidebarToggle: View {
    let action: () -> Void
    let onDark: Bool
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .regular))
                .frame(width: 28, height: 28)
                .foregroundStyle(onDark ? Color.white.opacity(hover ? 0.9 : 0.55) : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill((onDark ? Color.white : Color.primary).opacity(hover ? 0.08 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Toggle sidebar (⌃⌘S)")
    }
}
