import Foundation

/// Demo mode with made-up sessions for screenshots: `DeckTabs --demo` or `DECKTABS_DEMO=1`.
enum Demo {
    static let enabled = CommandLine.arguments.contains("--demo")
        || ProcessInfo.processInfo.environment["DECKTABS_DEMO"] == "1"

    /// `--demo-select <title>` picks the session shown first (for screenshots).
    static var initialSelection: String {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--demo-select"), i + 1 < args.count { return args[i + 1] }
        return "api-gateway"
    }

    private struct Spec {
        let title, group, tool, status: String
        let minutesAgo: Double
        var remote: String? = nil
        var unread = false
        var parent: Int? = nil
    }

    private static let specs: [Spec] = [
        Spec(title: "conductor-ops", group: "conductor", tool: "claude", status: "waiting", minutesAgo: 3),
        Spec(title: "builder-billing-export", group: "agents", tool: "claude", status: "waiting", minutesAgo: 9, parent: 0),
        Spec(title: "reviewer-billing-export", group: "agents", tool: "claude", status: "running", minutesAgo: 0, parent: 0),
        Spec(title: "security-billing-export", group: "agents", tool: "claude", status: "stopped", minutesAgo: 2, parent: 0),
        Spec(title: "ux-billing-export", group: "agents", tool: "claude", status: "waiting", minutesAgo: 1, parent: 0),
        Spec(title: "qa-billing-export", group: "agents", tool: "claude", status: "running", minutesAgo: 0, parent: 0),
        Spec(title: "builder-dark-mode", group: "agents", tool: "claude", status: "running", minutesAgo: 0, parent: 0),
        Spec(title: "api-gateway", group: "backend", tool: "claude", status: "waiting", minutesAgo: 6, unread: true, parent: 0),
        Spec(title: "builder-sso-login", group: "agents", tool: "claude", status: "stopped", minutesAgo: 90, parent: 0),
        Spec(title: "qa-sso-login", group: "agents", tool: "claude", status: "stopped", minutesAgo: 80, parent: 0),
        Spec(title: "web-dashboard", group: "frontend", tool: "claude", status: "running", minutesAgo: 1),
        Spec(title: "design-system", group: "frontend", tool: "claude", status: "waiting", minutesAgo: 24, unread: true),
        Spec(title: "gpu-benchmarks", group: "lab", tool: "claude", status: "waiting", minutesAgo: 52,
             remote: "build-server"),
        Spec(title: "terraform", group: "infra", tool: "codex", status: "idle", minutesAgo: 140),
        Spec(title: "release-notes", group: "docs", tool: "claude", status: "waiting", minutesAgo: 60 * 26),
        Spec(title: "ios-app", group: "mobile", tool: "claude", status: "waiting", minutesAgo: 60 * 50),
        Spec(title: "data-pipeline", group: "infra", tool: "claude", status: "error", minutesAgo: 60 * 24 * 9),
    ]

    static let sessions: [DeckSession] = specs.enumerated().map { i, s in
        let date = Date().addingTimeInterval(-s.minutesAgo * 60)
        var json: [String: Any] = [
            "id": "demo-\(i)", "title": s.title, "group": s.group, "tool": s.tool, "status": s.status,
            "path": (s.remote != nil ? "/home/dev/" : NSHomeDirectory() + "/code/") + s.title,
            "tmux_session": "agentdeck_\(s.title)",
            "last_activity_at": ISO8601DateFormatter().string(from: date),
            // Listed order is start order, so a task's stages appear as builder, then the checks.
            "created_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double(200 - i) * 600)),
        ]
        if let p = s.parent { json["parent_session_id"] = "demo-\(p)" }
        var session = try! JSONDecoder().decode(DeckSession.self,
                                                from: JSONSerialization.data(withJSONObject: json))
        if let remote = s.remote {
            session.remote = remote
            session.remoteID = session.id
        }
        return session
    }

    /// The "ops" conductor with a few items in its inbox.
    @MainActor
    static func applyConductors(to store: SessionStore) {
        let fake = { (o: Int, r: Int) in TokenUsage(input_tokens: o / 50, output_tokens: o, cache_read: r, cache_write: r / 30, model: "claude-opus-5-5") }
        let sizes: [String: (Int, Int)] = ["conductor-ops": (31_000, 8_400_000), "api-gateway": (185_000, 42_000_000),
                                            "billing-service": (27_000, 6_100_000), "web-dashboard": (29_000, 5_000_000)]
        for s in store.sessions { if let v = sizes[s.title] { store.usage[s.id] = fake(v.0, v.1) } }
        let ago = { (m: Double) in ISO8601DateFormatter().string(from: Date().addingTimeInterval(-m * 60)) }
        store.conductorStatus = ["ops": ConductorStatus(
            name: "ops", agent: "claude", session_id: "demo-0", running: true, heartbeat: true,
            description: "Keeps the backend and frontend lanes moving", last_activity_at: ago(1))]
        store.outbox = ["ops": [
            OutboxItem(id: "o1", ts: ago(4), tier: "urgent",
                       text: "billing-service needs a decision: migrate the invoices table now or after the release freeze on Friday?",
                       acked: false),
            OutboxItem(id: "o2", ts: ago(18), tier: "info",
                       text: "api-gateway: rate limiting is on feat/rate-limit, all 214 tests green. Opening the PR once you said yes.",
                       acked: false),
            OutboxItem(id: "o3", ts: ago(41), tier: "info",
                       text: "web-dashboard picked up the new design-system tokens; screenshots are in the PR.",
                       acked: false),
        ]]
    }

    static func conductorFile(_ f: ConductorFile) -> String {
        switch f {
        case .policy: """
            # Conductor Policy

            ## Scope
            Only the backend and frontend sessions. Ignore everything else.

            ## Safe to auto-respond
            - "Should I continue?" for local, reversible work -> yes
            - Questions answered by the repo's conventions

            ## Always escalate
            - Deploys, force-pushes, deleting data
            - Anything with credentials
            - Design decisions with several valid options
            """
        case .instructions: "# Conductor: ops (default profile)\n\nYou are **ops**, a conductor running on **Claude Code**.\n"
        case .heartbeat: "# Heartbeat Rules\n\n- Check waiting sessions first\n- Report errors once, not on every beat\n"
        case .learnings: "# Conductor Learnings\n\n- billing-service: always ask before schema migrations.\n"
        }
    }

    static func seen(_ s: DeckSession) -> Date {
        let unread = specs.first { $0.title == s.title }?.unread ?? false
        return unread ? s.lastActivity.addingTimeInterval(-600) : Date()
    }

    /// Prints a fake agent transcript and then stays alive like an attached tmux client.
    static func terminalCommand(for s: DeckSession) -> [String] {
        let script = transcript(for: s)
        return ["/bin/sh", "-c", "printf '%b' \"$1\"; exec sleep 1000000", "demo", script]
    }

    private static func transcript(for s: DeckSession) -> String {
        let dim = "\\033[2m", bold = "\\033[1m", green = "\\033[32m", cyan = "\\033[36m", off = "\\033[0m"
        let yellow = "\\033[33m"
        return """
        \(bold)✻ \(s.tool == "codex" ? "Codex" : "Claude Code")\(off) \(dim)· \(s.shortPath)\(off)

        \(cyan)❯\(off) add rate limiting to the public endpoints and make sure the tests cover burst traffic

        ● I'll add a token-bucket limiter as middleware and wire it into the public router.

          \(green)Read\(off) src/middleware/index.ts, src/router/public.ts
          \(green)Edit\(off) src/middleware/rateLimit.ts \(dim)(+64 −0)\(off)
          \(green)Edit\(off) src/router/public.ts \(dim)(+3 −1)\(off)
          \(green)Bash\(off) npm test -- rateLimit
             \(green)✓\(off) allows 100 requests per minute per key \(dim)(12 ms)\(off)
             \(green)✓\(off) rejects bursts above the bucket size with 429 \(dim)(9 ms)\(off)
             \(green)✓\(off) refills tokens over time \(dim)(31 ms)\(off)

        ● Done. Public endpoints now share a token bucket per API key (100/min, burst 20).
          Responses over the limit return \(bold)429\(off) with a \(bold)Retry-After\(off) header.

          \(yellow)Next:\(off) want me to expose the limits in the config file as well?

        \(dim)✻ Cooked for 1m 12s\(off)

        \(cyan)❯\(off) 
        """
    }
}
