import AppKit
import SwiftUI

struct DetailView: View {
    @EnvironmentObject var store: SessionStore
    @ObservedObject var pool = TerminalPool.shared
    var sidebarHidden = false
    var toggleSidebar: () -> Void = {}
    @AppStorage("conductorPanel") private var showPanel = true

    var body: some View {
        ZStack {
            Color(nsColor: Theme.canvas).ignoresSafeArea()
            if let s = store.selected {
                VStack(spacing: 0) {
                    DetailHeader(session: s, unread: store.isUnread(s), sidebarHidden: sidebarHidden, toggleSidebar: toggleSidebar)
                    Rectangle().fill(Theme.canvasLine).frame(height: 1)
                    HStack(spacing: 0) {
                        if s.isStopped {
                            NotRunning(session: s)
                        } else if pool.failed.contains(s.id) {
                            Disconnected(session: s)
                        } else {
                            TerminalContainer(session: s, revision: pool.revision)
                        }
                        if store.isConductor(s) && showPanel {
                            Rectangle().fill(Theme.canvasLine).frame(width: 1)
                            ConductorPanel(conductor: s)
                                .frame(width: 310)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
            } else if store.loaded {
                EmptyState(symbol: "rectangle.stack", title: String(localized: "No Sessions"),
                           text: String(localized: "Start a session with agent-deck and it shows up here automatically."))
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

struct DetailHeader: View {
    @EnvironmentObject var store: SessionStore
    let session: DeckSession
    let unread: Bool
    private var branch: String? { store.branches[session.id] }
    @AppStorage("conductorPanel") private var showPanel = true
    /// Without the sidebar the traffic lights sit above the header → leave room for them.
    var sidebarHidden = false
    var toggleSidebar: () -> Void = {}

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if sidebarHidden {
                SidebarToggle(action: toggleSidebar, onDark: true)
                    .transition(.opacity)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        if session.isRemote {
                            Image(systemName: "network").font(.system(size: 10))
                        } else {
                            Circle().fill(Theme.color(forGroup: session.group)).frame(width: 6, height: 6)
                        }
                        Text(session.area)
                    }
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                    ToolBadge(tool: session.tool, size: 11.5)
                    if let branch = branch {
                        Text(verbatim: "·").foregroundStyle(.tertiary)
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                            Text(verbatim: branch)
                        }
                        .help(String(localized: "Git branch"))
                    }
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                    Text(session.shortPath)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            StatusPill(session: session, unread: unread)
            HStack(spacing: 2) {
                if !session.isRemote {
                    HeaderButton(symbol: "folder", help: String(localized: "Show folder in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.path)])
                    }
                }
                HeaderButton(symbol: "doc.on.doc", help: String(localized: "Copy attach command")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.attachHint, forType: .string)
                }
                if !session.isRemote {
                    HeaderButton(symbol: session.isStopped ? "play" : "arrow.counterclockwise.circle",
                                 help: session.isStopped ? String(localized: "Start session") : String(localized: "Restart session")) {
                        store.start(session)
                    }
                }
                HeaderButton(symbol: "arrow.clockwise", help: String(localized: "Reconnect terminal")) {
                    TerminalPool.shared.reconnect(session.id)
                }
                if store.isConductor(session) {
                    HeaderButton(symbol: "sidebar.right", help: String(localized: "Show or hide the conductor panel")) {
                        withAnimation(.snappy(duration: 0.25)) { showPanel.toggle() }
                    }
                }
            }
        }
        .padding(.leading, sidebarHidden ? 76 : 18)
        .padding(.trailing, 18)
        .padding(.top, 14)
        .animation(.snappy(duration: 0.25), value: sidebarHidden)
        .padding(.bottom, 12)
        .background(Color(nsColor: Theme.canvas))
        .gesture(WindowDragGesture())
    }
}

struct StatusPill: View {
    let session: DeckSession
    let unread: Bool

    var color: Color {
        if session.isError { return .red }
        if session.isRunning || unread { return .accentColor }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 6) {
            StatusGlyph(session: session, unread: unread)
            Text(statusText(session, unread: unread))
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 26)
                .foregroundStyle(hover ? .primary : .secondary)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hover ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct Disconnected: View {
    @EnvironmentObject var store: SessionStore
    let session: DeckSession

    var body: some View {
        VStack(spacing: 14) {
            EmptyState(symbol: "bolt.horizontal.circle", title: String(localized: "No Connection"),
                       text: session.isRemote
                           ? String(localized: "“\(session.title)” on \(session.remote ?? "") is not reachable right now. Is the machine on?")
                           : String(localized: "tmux session “\(session.tmux_session ?? session.title)” is not reachable right now. Is it still running?"))
            HStack(spacing: 10) {
                Button("Reconnect") { TerminalPool.shared.reconnect(session.id) }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                if !session.isRemote {
                    Button("Start Session") { store.start(session) }
                        .controlSize(.large)
                        .disabled(store.starting.contains(session.id))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
        }
    }
}

/// Floating search field like Spotlight / Things “Quick Find”.
struct QuickSwitcher: View {
    @EnvironmentObject var store: SessionStore
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    var matches: [DeckSession] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.ordered }
        return store.ordered.filter {
            $0.title.lowercased().contains(q) || $0.area.lowercased().contains(q) || $0.path.lowercased().contains(q)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18).ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("Session, area or folder", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18))
                        .focused($focused)
                        .onSubmit(choose)
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.upArrow) { move(-1); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                        .onChange(of: query) { highlighted = 0 }
                }
                .padding(.horizontal, 16)
                .frame(height: 52)

                if !matches.isEmpty {
                    Divider().opacity(0.5)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(Array(matches.enumerated()), id: \.element.id) { i, s in
                                    SessionRow(session: s, unread: store.isUnread(s), showGroup: true,
                                               shortcut: nil, now: Date())
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 3)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(i == highlighted ? Color.accentColor.opacity(0.22) : .clear)
                                        )
                                        .id(i)
                                        .onTapGesture { highlighted = i; choose() }
                                }
                            }
                            .padding(6)
                        }
                        .frame(height: min(CGFloat(matches.count) * 46 + 12, 340))
                        .onChange(of: highlighted) { _, i in proxy.scrollTo(i) }
                    }
                }
            }
            .frame(width: 540)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.28), radius: 30, y: 14)
            .padding(.top, 90)
        }
        .onAppear { focused = true }
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    private func move(_ d: Int) {
        highlighted = min(max(highlighted + d, 0), max(matches.count - 1, 0))
    }

    private func choose() {
        if highlighted < matches.count { store.selectedID = matches[highlighted].id }
        close()
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.12)) { isPresented = false }
    }
}
