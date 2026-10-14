import SwiftUI

extension Notification.Name {
    /// Opens the settings sheet of the conductor whose session id is the object.
    static let configureConductor = Notification.Name("configureConductor")
}

/// Right-hand panel next to a conductor's terminal: what it wants from you, its workers,
/// and a field to message it.
struct ConductorPanel: View {
    @EnvironmentObject var store: SessionStore
    let conductor: DeckSession

    var body: some View {
        let inbox = store.pendingOutbox(conductor)
        let workers = store.children(of: conductor)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ConductorSummary(conductor: conductor, status: store.status(of: conductor))
                        .overlay(alignment: .topTrailing) {
                            if !conductor.isRemote {
                                Button {
                                    NotificationCenter.default.post(name: .configureConductor, object: conductor.id)
                                } label: {
                                    Image(systemName: "gearshape").font(.system(size: 12))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help(String(localized: "Configure…"))
                            }
                        }

                    PanelSection(title: String(localized: "Inbox"), count: inbox.count) {
                        if inbox.isEmpty {
                            Text("Nothing for you right now.")
                                .font(.system(size: 12)).foregroundStyle(.tertiary)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(inbox) { item in
                                InboxCard(item: item) { store.ack(item, conductor: conductor) }
                                    .transition(.asymmetric(insertion: .opacity,
                                                            removal: .move(edge: .trailing).combined(with: .opacity)))
                            }
                        }
                    }

                    PanelSection(title: String(localized: "Workers"), count: workers.count) {
                        if workers.isEmpty {
                            Text("Sessions this conductor starts show up here.")
                                .font(.system(size: 12)).foregroundStyle(.tertiary)
                                .padding(.vertical, 4)
                        } else {
                            VStack(spacing: 2) {
                                ForEach(workers) { w in WorkerRow(session: w, unread: store.isUnread(w)) }
                            }
                        }
                    }
                }
                .padding(16)
            }
            if !conductor.isRemote {
                Rectangle().fill(Theme.canvasLine).frame(height: 1)
                Composer(conductor: conductor)
            }
        }
        .background(Color(nsColor: Theme.canvas).opacity(0.6))
        .background(Color.white.opacity(0.025))
    }
}

private struct ConductorSummary: View {
    let conductor: DeckSession
    let status: ConductorStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11, weight: .semibold))
                Text(verbatim: status?.name ?? conductor.title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            if let d = status?.description, !d.isEmpty {
                Text(verbatim: d).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Label(status?.heartbeat == true ? String(localized: "Heartbeat on") : String(localized: "Heartbeat off"),
                      systemImage: status?.heartbeat == true ? "waveform.path.ecg" : "pause.circle")
                if let last = DeckSession.parseDate(status?.last_activity_at) {
                    Label(Theme.ago(last), systemImage: "clock")
                        .help(String(localized: "Last activity of its workers"))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
    }
}

private struct PanelSection<Content: View>: View {
    let title: String
    let count: Int
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.6)
                if count > 0 {
                    Text(verbatim: "\(count)").font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                }
            }
            .foregroundStyle(.secondary)
            content
        }
    }
}

private struct InboxCard: View {
    let item: OutboxItem
    let done: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: item.isUrgent ? "exclamationmark.circle.fill" : "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(item.isUrgent ? Color.orange : Color.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: item.text ?? "")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.92))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(item.isUrgent ? String(localized: "Urgent") : String(localized: "Info"))
                        .foregroundStyle(item.isUrgent ? Color.orange : Color.secondary)
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                    Text(Theme.ago(item.date)).foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }
            Spacer(minLength: 0)
            Button(action: done) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(hover ? Color.white : Color.secondary)
                    .background(Circle().fill(Color.white.opacity(hover ? 0.14 : 0.06)))
            }
            .buttonStyle(.plain)
            .help(String(localized: "Done – remove from the inbox"))
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(item.isUrgent ? Color.orange.opacity(0.10) : Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(item.isUrgent ? Color.orange.opacity(0.35) : Color.white.opacity(0.06))
        )
        .onHover { hover = $0 }
    }
}

private struct WorkerRow: View {
    @EnvironmentObject var store: SessionStore
    let session: DeckSession
    let unread: Bool
    @State private var hover = false

    var body: some View {
        Button { store.selectedID = session.id } label: {
            HStack(spacing: 9) {
                StatusGlyph(session: session, unread: unread)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: session.title).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.92))
                    HStack(spacing: 5) {
                        ToolBadge(tool: session.tool, size: 10.5)
                        Text(verbatim: "·").foregroundStyle(.tertiary)
                        Text(statusText(session, unread: unread))
                    }
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(Theme.ago(session.lastActivity))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hover ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Message the conductor without clicking into its terminal (`agent-deck session send`).
private struct Composer: View {
    @EnvironmentObject var store: SessionStore
    let conductor: DeckSession
    @State private var text = ""
    @State private var sending = false
    @State private var sent = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(String(localized: "Message \(store.conductorName(conductor) ?? conductor.title)…"),
                      text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...5)
                .onSubmit(submit)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
            Button(action: submit) {
                Image(systemName: sent ? "checkmark" : "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.white)
                    .background(Circle().fill(canSend || sent ? Color.accentColor : Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help(String(localized: "Send (↩)"))
        }
        .padding(12)
    }

    private var canSend: Bool { !sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func submit() {
        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty, !sending else { return }
        sending = true
        Task {
            let ok = await store.send(msg, to: conductor)
            sending = false
            if ok {
                text = ""
                withAnimation { sent = true }
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation { sent = false }
            } else {
                store.lastError = String(localized: "Could not send the message")
            }
        }
    }
}
