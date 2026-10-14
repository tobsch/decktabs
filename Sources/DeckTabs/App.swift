import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
struct DeckTabsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = SessionStore()
    @State private var showSwitcher = false

    var body: some Scene {
        Window("Agent Deck", id: "main") {
            ContentView(showSwitcher: $showSwitcher)
                .environmentObject(store)
                .onAppear {
                    store.start()
                    KeyState.shared.install()
                }
                .frame(minWidth: 860, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Session") {
                Button("Jump to…") { withAnimation(.easeOut(duration: 0.15)) { showSwitcher = true } }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Next New Session") { store.jumpToNextUnread() }
                    .keyboardShortcut("j", modifiers: .command)
                Divider()
                Button("Next") { store.step(1) }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Previous") { store.step(-1) }
                    .keyboardShortcut("[", modifiers: .command)
                Divider()
                ForEach(0..<9, id: \.self) { i in
                    Button("Session \(i + 1)") { store.select(index: i) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
                Divider()
                Button("By Activity") { store.mode = .activity }
                    .keyboardShortcut("1", modifiers: [.command, .control])
                Button("By Area") { store.mode = .groups }
                    .keyboardShortcut("2", modifiers: [.command, .control])
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .toggleDeckSidebar, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                Button("Reconnect Terminal") {
                    if let id = store.selectedID { TerminalPool.shared.reconnect(id) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(store)
        } label: {
            MenuBarLabel(count: store.unreadCount)
        }
    }
}

/// Menu bar icon. Also opens the main window on first launch: with a MenuBarExtra in the scene list,
/// SwiftUI does not open the `Window` by itself when there is no restored window state.
struct MenuBarLabel: View {
    let count: Int
    @Environment(\.openWindow) private var openWindow
    @State private var didLaunch = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: count > 0 ? "rectangle.stack.fill" : "rectangle.stack")
            if count > 0 { Text(verbatim: "\(count)") }
        }
        .onAppear {
            guard !didLaunch else { return }
            didLaunch = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                    openWindow(id: "main")
                }
            }
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let unread = store.ordered.filter(store.isUnread)
        let running = store.ordered.filter(\.isRunning)
        if !unread.isEmpty {
            Section("New") { ForEach(unread) { item($0) } }
        }
        if !running.isEmpty {
            Section("Working") { ForEach(running) { item($0) } }
        }
        Section("Recently Active") {
            ForEach(store.ordered.filter { !$0.isRunning && !store.isUnread($0) }.prefix(6)) { item($0) }
        }
        Divider()
        Button("Open Agent Deck") { show(nil) }
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func item(_ s: DeckSession) -> some View {
        Button(s.title + "  —  " + s.area) { show(s.id) }
    }

    private func show(_ id: String?) {
        if let id { store.selectedID = id }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        registerHotKey()
        if !Demo.enabled { NotificationHandler.shared.install() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
        return true
    }

    /// Global hotkey ⌃⌥Space brings the window to the front.
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4454_4142), id: 1) // "DTAB"
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKey)
    }
}

extension Notification.Name {
    static let toggleDeckSidebar = Notification.Name("toggleDeckSidebar")
}

struct ContentView: View {
    @EnvironmentObject var store: SessionStore
    @Binding var showSwitcher: Bool
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $columns) {
                Sidebar(showSwitcher: $showSwitcher, toggleSidebar: toggleSidebar)
                    .toolbar(removing: .sidebarToggle)
            } detail: {
                DetailView(sidebarHidden: columns == .detailOnly, toggleSidebar: toggleSidebar)
                    .ignoresSafeArea(.container, edges: .top)
            }
            .toolbar(removing: .title)
            .onReceive(NotificationCenter.default.publisher(for: .toggleDeckSidebar)) { _ in toggleSidebar() }
            .onChange(of: store.sessions) { _, new in
                TerminalPool.shared.prune(keep: Set(new.map(\.id)))
            }
            if showSwitcher {
                QuickSwitcher(isPresented: $showSwitcher)
                    .zIndex(1)
            }
        }
    }

    private func toggleSidebar() {
        withAnimation(.snappy(duration: 0.28)) {
            columns = columns == .detailOnly ? .all : .detailOnly
        }
    }
}
