import AppKit
import SwiftUI

/// ⌘F in a session: searches the whole tmux history, not just the visible screen. Uses tmux's own
/// copy-mode search, so the attached terminal scrolls to each hit and highlights it.
@MainActor
final class TerminalFind: ObservableObject {
    static let shared = TerminalFind()
    @Published var visible = false
    @Published var term = ""
    /// Hits in the history (nil = not searched yet).
    @Published private(set) var count: Int?
    @Published var focusToken = 0
    private var searched = ""

    static func canSearch(_ s: DeckSession) -> Bool { !s.isRemote && !Demo.enabled && !s.isStopped }

    func open() {
        visible = true
        focusToken += 1
    }

    /// Enter: a new term starts at the bottom and goes up; the same term again finds the next older hit.
    func submit(_ s: DeckSession) {
        guard !term.isEmpty else { return }
        if term == searched { step(s, older: true); return }
        searched = term
        let target = Self.target(s), term = term
        Task.detached {
            Tools.run(Tools.tmux, ["copy-mode", "-t", target])
            Tools.run(Tools.tmux, ["send-keys", "-t", target, "-X", "search-backward", term])
            let n = Self.hits(term, in: target)
            await MainActor.run { self.count = n }
        }
    }

    func step(_ s: DeckSession, older: Bool) {
        guard !searched.isEmpty else { submit(s); return }
        let target = Self.target(s)
        Task.detached {
            Tools.run(Tools.tmux, ["send-keys", "-t", target, "-X", older ? "search-again" : "search-reverse"])
        }
    }

    /// Esc: leave copy mode so the session is live again, and give the keyboard back to the terminal.
    func close(_ s: DeckSession?) {
        visible = false
        count = nil
        searched = ""
        if let s, Self.canSearch(s) {
            let target = Self.target(s)
            Task.detached {
                let inMode = Tools.run(Tools.tmux, ["display", "-p", "-t", target, "#{pane_in_mode}"])
                    .flatMap { String(data: $0, encoding: .utf8) }?.hasPrefix("1") ?? false
                if inMode { Tools.run(Tools.tmux, ["send-keys", "-t", target, "-X", "cancel"]) }
            }
        }
        if let s { TerminalPool.shared.focus(s.id) }
    }

    nonisolated private static func target(_ s: DeckSession) -> String { s.tmux_session ?? s.title }

    /// Counts hits like tmux matches them: case-insensitive unless the term has a capital letter.
    nonisolated private static func hits(_ term: String, in target: String) -> Int {
        guard let data = Tools.run(Tools.tmux, ["capture-pane", "-p", "-J", "-S", "-", "-t", target]),
              let text = String(data: data, encoding: .utf8) else { return 0 }
        let smart: String.CompareOptions = term.contains(where: \.isUppercase) ? [] : [.caseInsensitive]
        var n = 0, range = text.startIndex..<text.endIndex
        while let r = text.range(of: term, options: smart, range: range) {
            n += 1
            range = r.upperBound..<text.endIndex
        }
        return n
    }
}

struct FindBar: View {
    @ObservedObject var find = TerminalFind.shared
    let session: DeckSession
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Search history", text: $find.term)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .frame(width: 200)
                .focused($focused)
                .onSubmit { find.submit(session) }
                .onExitCommand { find.close(session) }
            if let n = find.count {
                Text(n == 0 ? String(localized: "no hits") : String(localized: "\(n) hits"))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(n == 0 ? .orange : .secondary)
            }
            Button { find.step(session, older: true) } label: { Image(systemName: "chevron.up") }
                .help(String(localized: "Older hit (Enter, ⌘G)"))
            Button { find.step(session, older: false) } label: { Image(systemName: "chevron.down") }
                .help(String(localized: "Newer hit (⇧⌘G)"))
            Button { find.close(session) } label: { Image(systemName: "xmark") }
                .help(String(localized: "Close (Esc)"))
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
        .padding(10)
        .onAppear { focused = true }
        .onChange(of: find.focusToken) { focused = true }
    }
}
