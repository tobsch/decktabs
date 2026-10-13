import AppKit
import SwiftTerm
import SwiftUI

/// Keeps one running `tmux attach` per session so switching is instant and scrollback survives.
@MainActor
final class TerminalPool: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    static let shared = TerminalPool()
    private var views: [String: LocalProcessTerminalView] = [:]
    private var started: [String: Date] = [:]
    /// Sessions whose client exited right after starting (session missing etc.).
    @Published private(set) var failed: Set<String> = []
    @Published private(set) var revision = 0

    func view(for session: DeckSession) -> LocalProcessTerminalView? {
        if let v = views[session.id], v.process.running { return v }
        if failed.contains(session.id) { return nil }
        let v = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        v.processDelegate = self
        v.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        v.installColors(Theme.ansi)
        v.nativeBackgroundColor = Theme.canvas
        v.nativeForegroundColor = Theme.ink
        v.caretColor = NSColor.controlAccentColor
        v.selectedTextBackgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35)
        v.optionAsMetaKey = true
        let env = Tools.environment.map { "\($0.key)=\($0.value)" }
        let cmd = session.attachCommand
        v.startProcess(executable: cmd[0], args: Array(cmd.dropFirst()), environment: env,
                       execName: (cmd[0] as NSString).lastPathComponent)
        views[session.id] = v
        started[session.id] = Date()
        return v
    }

    func reconnect(_ id: String) {
        failed.remove(id)
        views[id]?.process.terminate()
        views.removeValue(forKey: id)
        revision += 1
    }

    /// Detach clients of sessions that no longer exist.
    func prune(keep ids: Set<String>) {
        for (id, v) in views where !ids.contains(id) {
            v.process.terminate()
            views.removeValue(forKey: id)
        }
    }

    // MARK: LocalProcessTerminalViewDelegate
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            guard let id = self.views.first(where: { $0.value === source })?.key else { return }
            let quick = Date().timeIntervalSince(self.started[id] ?? .distantPast) < 3
            self.views.removeValue(forKey: id)
            // Immediate exit = session unreachable → show a notice instead of reconnecting forever.
            // Later exit (e.g. Ctrl+Q / detach) → silently reattach on the next render.
            if quick { self.failed.insert(id) }
            self.revision += 1
        }
    }
}

/// Container that hosts the cached terminal of the selected session.
struct TerminalContainer: NSViewRepresentable {
    let session: DeckSession
    let revision: Int

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        host.wantsLayer = true
        host.layer?.backgroundColor = Theme.canvas.cgColor
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        guard let term = TerminalPool.shared.view(for: session) else {
            host.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        if term.superview !== host {
            host.subviews.forEach { $0.removeFromSuperview() }
            term.removeFromSuperview()
            term.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(term)
            NSLayoutConstraint.activate([
                term.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
                term.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -6),
                term.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
                term.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -4),
            ])
        }
        DispatchQueue.main.async { term.window?.makeFirstResponder(term) }
    }
}
