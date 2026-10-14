import AppKit
import SwiftUI

/// The files in a conductor's directory that shape its behavior.
enum ConductorFile: String, CaseIterable, Identifiable {
    case policy = "POLICY.md"
    case instructions = "CLAUDE.md"
    case heartbeat = "HEARTBEAT_RULES.md"
    case learnings = "LEARNINGS.md"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .policy: String(localized: "Policy")
        case .instructions: String(localized: "Instructions")
        case .heartbeat: String(localized: "Heartbeat Rules")
        case .learnings: String(localized: "Learnings")
        }
    }

    var hint: String {
        switch self {
        case .policy: String(localized: "What it may answer on its own and what it escalates to you. Read on every turn.")
        case .instructions: String(localized: "Identity and startup checklist. Read when the conductor starts – restart after editing.")
        case .heartbeat: String(localized: "What it checks on each heartbeat. Only used with the heartbeat on.")
        case .learnings: String(localized: "Patterns the conductor noted for itself. You can edit them too.")
        }
    }

    /// Codex/Hermes/Pi conductors keep their instructions in AGENTS.md.
    func fileName(agent: String?) -> String {
        if self == .instructions, let agent, agent != "claude" { return "AGENTS.md" }
        return rawValue
    }
}

extension SessionStore {
    /// `agent-deck conductor setup` with the given flags; re-running keeps edited files.
    func conductorSetup(_ name: String, _ flags: [String]) async -> Bool {
        if Demo.enabled { return true }
        let ok = await Task.detached {
            Tools.run(Tools.agentDeck, ["conductor", "setup", name, "--json"] + flags) != nil
        }.value
        refreshConductors()
        refresh()
        return ok
    }

    func restartConductor(_ s: DeckSession) {
        if Demo.enabled { return }
        Task.detached {
            _ = Tools.run(Tools.agentDeck, ["session", "restart", s.id])
            await MainActor.run {
                TerminalPool.shared.reconnect(s.id)
                self.refresh()
            }
        }
    }

    /// Stops the conductor; `remove` also deletes its directory (learnings and task log included).
    func teardownConductor(_ name: String, remove: Bool) {
        if Demo.enabled { return }
        Task.detached {
            let ok = Tools.run(Tools.agentDeck, ["conductor", "teardown", name] + (remove ? ["--remove"] : [])) != nil
            await MainActor.run {
                if !ok { self.lastError = String(localized: "Could not remove conductor “\(name)”") }
                self.refreshConductors()
                self.refresh()
            }
        }
    }
}

/// Sheet to configure an existing conductor: description, heartbeat and its Markdown files.
struct ConductorSettingsSheet: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    let conductor: DeckSession

    @State private var description = ""
    @State private var heartbeat = false
    @State private var file: ConductorFile = .policy
    @State private var texts: [ConductorFile: String] = [:]
    @State private var original: [ConductorFile: String] = [:]
    @State private var saving = false
    @State private var confirmRemove = false

    private var status: ConductorStatus? { store.status(of: conductor) }
    private var name: String { store.conductorName(conductor) ?? conductor.title }
    private var dir: URL { URL(fileURLWithPath: conductor.path) }

    private func url(_ f: ConductorFile) -> URL { dir.appendingPathComponent(f.fileName(agent: status?.agent)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 18, weight: .medium)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Conductor “\(name)”").font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 5) {
                        ToolBadge(tool: status?.agent ?? conductor.tool)
                        Text(verbatim: "·").foregroundStyle(.tertiary)
                        Text(verbatim: conductor.shortPath).font(.system(size: 11, design: .monospaced))
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                } label: { Image(systemName: "folder") }
                    .help(String(localized: "Show folder in Finder"))
            }
            .padding(18)

            Divider()

            Form {
                TextField("Description", text: $description, prompt: Text("What this conductor looks after"))
                Toggle(isOn: $heartbeat) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Heartbeat")
                        Text("Wakes the conductor on a schedule to check its sessions. Costs a turn each time.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 140)

            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $file) {
                    ForEach(ConductorFile.allCases) { f in
                        Text(f.label + (texts[f] != original[f] ? " •" : "")).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack(spacing: 6) {
                    Text(file.hint)
                    if isSymlink(file) {
                        Label(String(localized: "linked file"), systemImage: "link")
                            .help(symlinkTarget(file) ?? "")
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { texts[file] ?? "" }, set: { texts[file] = $0 }))
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)

            Divider()

            HStack {
                Button("Remove…", role: .destructive) { confirmRemove = true }
                Button("Restart") { store.restartConductor(conductor) }
                    .help(String(localized: "Restart the conductor so it rereads its instructions"))
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
            .padding(14)
        }
        .frame(width: 720, height: 680)
        .onAppear(perform: load)
        .confirmationDialog("Remove conductor “\(name)”?", isPresented: $confirmRemove) {
            Button("Stop, keep files") { store.teardownConductor(name, remove: false); dismiss() }
            Button("Remove with all files", role: .destructive) { store.teardownConductor(name, remove: true); dismiss() }
        } message: {
            Text("Removing the files also deletes its learnings and task log. Its worker sessions keep running.")
        }
    }

    private func load() {
        description = status?.description ?? ""
        heartbeat = status?.heartbeat ?? false
        for f in ConductorFile.allCases {
            let text = (try? String(contentsOf: url(f), encoding: .utf8))
                ?? (Demo.enabled ? Demo.conductorFile(f) : "")
            texts[f] = text
            original[f] = text
        }
    }

    private func save() {
        saving = true
        // Files: write through symlinks so linked files (e.g. a policy kept in a repo) stay linked.
        if !Demo.enabled {
            for f in ConductorFile.allCases where texts[f] != original[f] {
                let target = url(f).resolvingSymlinksInPath()
                do { try (texts[f] ?? "").write(to: target, atomically: false, encoding: .utf8) } catch {
                    store.lastError = String(localized: "Could not save \(f.rawValue)")
                }
            }
        }
        let changedMeta = description != (status?.description ?? "") || heartbeat != (status?.heartbeat ?? false)
        Task {
            if changedMeta {
                let ok = await store.conductorSetup(name, ["--description", description,
                                                           heartbeat ? "--heartbeat" : "--no-heartbeat"])
                if !ok { store.lastError = String(localized: "Could not update conductor “\(name)”") }
            }
            saving = false
            dismiss()
        }
    }

    private func isSymlink(_ f: ConductorFile) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: url(f).path)[.type]) as? FileAttributeType) == .typeSymbolicLink
    }

    private func symlinkTarget(_ f: ConductorFile) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url(f).path)
    }
}

/// Sheet to create a new conductor (`agent-deck conductor setup`).
struct NewConductorSheet: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var agent = "claude"
    @State private var heartbeat = false
    @State private var working = false
    @State private var error: String?

    private var validName: Bool { name.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_-]{0,40}$"#, options: .regularExpression) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Conductor").font(.system(size: 15, weight: .semibold)).padding([.horizontal, .top], 18)
            Text("A conductor is a long-running session that watches your other sessions, answers routine questions and escalates the rest to your inbox.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18).padding(.top, 4)
            Form {
                TextField("Name", text: $name, prompt: Text("e.g. home, work, infra"))
                TextField("Description", text: $description, prompt: Text("What this conductor looks after"))
                Picker("Agent", selection: $agent) {
                    ForEach(["claude", "codex", "hermes", "pi"], id: \.self) { a in
                        Label { Text(ToolInfo(a).name) } icon: { Image(systemName: ToolInfo(a).symbol) }.tag(a)
                    }
                }
                Toggle("Heartbeat", isOn: $heartbeat)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 18)
            }
            HStack {
                Text("Edit its policy afterwards via Configure…")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!validName || working)
            }
            .padding(14)
        }
        .frame(width: 480)
    }

    private func create() {
        working = true
        Task {
            var flags = ["--agent", agent, heartbeat ? "--heartbeat" : "--no-heartbeat"]
            if !description.isEmpty { flags += ["--description", description] }
            let ok = await store.conductorSetup(name, flags)
            working = false
            if ok {
                if !Demo.enabled {
                    _ = await Task.detached { [name] in
                        Tools.run(Tools.agentDeck, ["session", "start", "conductor-\(name)"])
                    }.value
                    store.refresh()
                }
                dismiss()
            } else {
                error = String(localized: "agent-deck could not create the conductor.")
            }
        }
    }
}
