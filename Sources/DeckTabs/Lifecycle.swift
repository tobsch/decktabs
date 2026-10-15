import SwiftUI

extension DeckSession {
    /// No agent process: stopped by hand or crashed. The terminal TUI starts these on Enter.
    var isStopped: Bool { status == "stopped" || status == "error" }
}

extension SessionStore {
    /// `agent-deck session start` (stopped) or `restart` (crashed or running), then reattach the terminal.
    func start(_ s: DeckSession) {
        guard !s.isRemote, !starting.contains(s.id) else { return }
        if Demo.enabled { return }
        starting.insert(s.id)
        let verb = s.status == "stopped" ? "start" : "restart"
        Task.detached {
            let ok = Tools.run(Tools.agentDeck, ["session", verb, s.id]) != nil
            await MainActor.run {
                self.starting.remove(s.id)
                if !ok { self.lastError = String(localized: "Could not start “\(s.title)”") }
                TerminalPool.shared.reconnect(s.id)
                self.refresh()
            }
        }
    }
}

/// Shown instead of the terminal while a session has no running agent.
struct NotRunning: View {
    @EnvironmentObject var store: SessionStore
    let session: DeckSession

    var body: some View {
        let busy = store.starting.contains(session.id)
        VStack(spacing: 14) {
            EmptyState(symbol: session.isError ? "exclamationmark.triangle" : "pause.circle",
                       title: session.isError ? String(localized: "Session Ended With an Error") : String(localized: "Session Stopped"),
                       text: session.isError
                           ? String(localized: "The agent in “\(session.title)” exited. Restart it to pick up where the conversation left off.")
                           : String(localized: "“\(session.title)” is not running. Start it to continue."))
            Button {
                store.start(session)
            } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small) } else { Image(systemName: "play.fill") }
                    Text(session.isError ? String(localized: "Restart") : String(localized: "Start"))
                }
                .frame(minWidth: 90)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(busy || session.isRemote)
            if session.isRemote {
                Text("Remote sessions are started on their machine.")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
