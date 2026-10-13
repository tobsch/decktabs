import Foundation

/// Demo mode with made-up sessions for screenshots: `DeckTabs --demo` or `DECKTABS_DEMO=1`.
enum Demo {
    static let enabled = CommandLine.arguments.contains("--demo")
        || ProcessInfo.processInfo.environment["DECKTABS_DEMO"] == "1"

    private struct Spec {
        let title, group, tool, status: String
        let minutesAgo: Double
        var remote: String? = nil
        var unread = false
    }

    private static let specs: [Spec] = [
        Spec(title: "conductor-ops", group: "conductor", tool: "claude", status: "waiting", minutesAgo: 3),
        Spec(title: "api-gateway", group: "backend", tool: "claude", status: "running", minutesAgo: 0),
        Spec(title: "billing-service", group: "backend", tool: "codex", status: "waiting", minutesAgo: 6, unread: true),
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
        let json: [String: Any] = [
            "id": "demo-\(i)", "title": s.title, "group": s.group, "tool": s.tool, "status": s.status,
            "path": (s.remote != nil ? "/home/dev/" : NSHomeDirectory() + "/code/") + s.title,
            "tmux_session": "agentdeck_\(s.title)",
            "last_activity_at": ISO8601DateFormatter().string(from: date),
        ]
        var session = try! JSONDecoder().decode(DeckSession.self,
                                                from: JSONSerialization.data(withJSONObject: json))
        if let remote = s.remote {
            session.remote = remote
            session.remoteID = session.id
        }
        return session
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
