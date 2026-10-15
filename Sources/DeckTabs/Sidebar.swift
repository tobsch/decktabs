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
    @State private var configuring: DeckSession?
    @State private var creatingConductor = false

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
                    Section {
                            ForEach(store.conductors) { c in
                                rows([c], now: ctx.date, showGroup: true, conductorFold: store.collapsedConductors.contains(c.id))
                                if !store.collapsedConductors.contains(c.id) {
                                    workerRows(c, now: ctx.date)
                                }
                            }
                    } header: {
                            HStack {
                                SectionTitle("Conductors", symbol: "point.3.connected.trianglepath.dotted")
                                Spacer()
                                Button { creatingConductor = true } label: {
                                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help(String(localized: "New conductor…"))
                                .padding(.top, 4)
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
        .sheet(item: $configuring) { c in ConductorSettingsSheet(conductor: c).environmentObject(store) }
        .sheet(isPresented: $creatingConductor) { NewConductorSheet().environmentObject(store) }
        .onAppear {
            // Screenshots: `--demo-configure` opens the settings of the first conductor.
            if Demo.enabled && CommandLine.arguments.contains("--demo-configure") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { configuring = store.conductors.first }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .configureConductor)) { n in
            configuring = store.sessions.first { $0.id == n.object as? String }
        }
    }

    @ViewBuilder
    private func sessionMenu(_ s: DeckSession) -> some View {
        if !s.isRemote {
            Button(s.isStopped ? "Start" : "Restart") { store.start(s) }
            Divider()
        }
        Button("Reset Token Counter") { store.resetUsage([s]) }
            .disabled(store.usage(of: s) == nil)
        if !s.isRemote && !store.conductors.isEmpty {
            let current = store.conductorAncestor(of: s)
            Menu("Conductor") {
                ForEach(store.conductors.filter { !$0.isRemote }) { c in
                    Toggle(store.conductorName(c) ?? c.title, isOn: Binding(
                        get: { current?.id == c.id },
                        set: { on in if on { store.assign(s, to: c) } }))
                }
                Divider()
                Button("None") { store.assign(s, to: nil) }.disabled(current == nil)
            }
        }
    }

    @ViewBuilder
    private func conductorMenu(_ c: DeckSession) -> some View {
        Button("Configure…") { configuring = c }
            .disabled(c.isRemote)
        Button(c.isStopped ? "Start" : "Restart") { store.start(c) }
            .disabled(c.isRemote)
        Button("Reset Token Counter") { store.resetUsage([c] + store.children(of: c)) }
        Divider()
        Button("New Conductor…") { creatingConductor = true }
    }

    /// A conductor's workers as a funnel: one row per running task with its stages as chips, then the
    /// sessions without a task, then finished tasks folded under "Done".
    @ViewBuilder
    private func workerRows(_ c: DeckSession, now: Date) -> some View {
        let units = store.workUnits(of: c)
        let tasks = units.filter { $0.task != nil && $0.isActive }
        let loose = units.filter { $0.task == nil }
        let done = units.filter { $0.task != nil && !$0.isActive }
        if !tasks.isEmpty {
            WorkerCaption(text: String(localized: "In progress"), strong: true)
            ForEach(tasks) { u in taskRow(u, now: now) }
        }
        if !loose.isEmpty {
            if !tasks.isEmpty || !done.isEmpty { WorkerCaption(text: String(localized: "Other"), strong: true) }
            rows(loose.flatMap(\.sessions), now: now, showGroup: true, nested: true)
        }
        if !done.isEmpty {
            let open = store.showDone.contains(c.id)
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if open { store.showDone.remove(c.id) } else { store.showDone.insert(c.id) }
                }
            } label: {
                HStack(spacing: 4) {
                    WorkerCaption(text: String(localized: "Done") + " (\(done.count))", strong: true)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0)).padding(.top, 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .selectionDisabled()
            if open { ForEach(done) { u in taskRow(u, now: now) } }
        }
    }

    private func taskRow(_ u: WorkUnit, now: Date) -> some View {
        TaskRow(unit: u, selectedID: store.selectedID, now: now,
                shortcut: keys.commandHeld ? store.ordered.firstIndex(of: u.current).flatMap { $0 < 9 ? $0 + 1 : nil } : nil) { s in
            store.selectedID = s.id
        }
        .contextMenu { sessionMenu(u.current) }
        .tag(u.current.id)
    }

    @ViewBuilder
    private func rows(_ list: [DeckSession], now: Date, showGroup: Bool, dropGroup: String? = nil,
                      nested: Bool = false, conductorFold: Bool? = nil, roleOnly: Bool = false) -> some View {
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
                nested: nested,
                label: roleOnly ? store.taskName(of: s).map { String(s.title.dropLast($0.count + 1)) } : nil,
                fold: conductorFold.map { collapsed in
                    FoldState(collapsed: collapsed, count: store.children(of: s).count) { store.toggleCollapsed(s) }
                }
            )
            .contextMenu { if store.isConductor(s) { conductorMenu(s) } else { sessionMenu(s) } }
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

/// One task under a conductor: its name, and its stages (builder, then the checks) as chips.
/// The row opens the session working right now; a chip opens that stage.
struct TaskRow: View {
    let unit: WorkUnit
    let selectedID: String?
    let now: Date
    let shortcut: Int?
    let select: (DeckSession) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1).padding(.leading, 6)
            StatusGlyph(session: unit.current, unread: false)
            VStack(alignment: .leading, spacing: 4) {
                Text(unit.displayName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                HStack(spacing: 3) {
                    ForEach(unit.sessions) { s in chip(s) }
                }
            }
            Spacer(minLength: 4)
            if let shortcut {
                Text(verbatim: "⌘\(shortcut)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            } else {
                Text(Theme.ago(unit.lastActivity, now: now))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        // A chip may have opened another stage than the row's own session: still mark the task.
        .background(alignment: .center) {
            if let selectedID, selectedID != unit.current.id, unit.sessions.contains(where: { $0.id == selectedID }) {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)).padding(.horizontal, -6)
            }
        }
        .help(unit.task ?? "")
    }

    private func role(_ s: DeckSession) -> String {
        guard let task = unit.task, s.title.hasSuffix("-" + task) else { return s.title }
        return String(s.title.dropLast(task.count + 1))
    }

    private func chip(_ s: DeckSession) -> some View {
        let selected = s.id == selectedID
        let tint: Color = s.isError ? .red : s.isRunning ? .accentColor : s.isStopped ? .secondary : .orange
        return Button { select(s) } label: {
            HStack(spacing: 3) {
                Circle().fill(tint.opacity(s.isStopped ? 0.4 : 1)).frame(width: 5, height: 5)
                Text(role(s))
            }
            .font(.system(size: 10, weight: selected ? .semibold : .regular))
            .foregroundStyle(s.isStopped ? .tertiary : .secondary)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Capsule().fill(Color.primary.opacity(selected ? 0.14 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(role(s) + ": " + statusText(s, unread: false))
    }
}

/// Caption between a conductor's workers: a task name, or "Done" above finished work.
struct WorkerCaption: View {
    let text: String
    let strong: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: strong ? .semibold : .medium))
            .foregroundStyle(strong ? .secondary : .tertiary)
            .textCase(strong ? .uppercase : nil)
            .lineLimit(1)
            .padding(.leading, 13)
            .padding(.top, 4)
            .selectionDisabled()
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
    /// Shorter title, e.g. just the role when a task caption sits above the row.
    var label: String? = nil
    /// Conductor row: disclosure chevron to fold its workers.
    var fold: FoldState? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if nested {
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1).padding(.leading, 6)
            }
            StatusGlyph(session: session, unread: unread)
            VStack(alignment: .leading, spacing: 2) {
                Text(label ?? session.title)
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
            if let fold, fold.count > 0 {
                Button(action: fold.toggle) {
                    HStack(spacing: 3) {
                        if fold.collapsed {
                            Text(verbatim: "\(fold.count)").font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(fold.collapsed ? 0 : 90))
                    }
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, minHeight: 18)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(fold.collapsed ? String(localized: "Show workers") : String(localized: "Hide workers"))
            }
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

struct FoldState {
    let collapsed: Bool
    let count: Int
    let toggle: () -> Void
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
