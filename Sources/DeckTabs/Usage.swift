import SwiftUI

/// Token use of one session (`agent-deck costs sessions --json`), read from the agents' transcripts.
struct TokenUsage: Decodable, Equatable {
    var input_tokens: Int = 0
    var output_tokens: Int = 0
    var cache_read: Int = 0
    var cache_write: Int = 0
    var model: String?

    var total: Int { input_tokens + output_tokens + cache_read + cache_write }

    static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input_tokens: a.input_tokens + b.input_tokens, output_tokens: a.output_tokens + b.output_tokens,
                   cache_read: a.cache_read + b.cache_read, cache_write: a.cache_write + b.cache_write,
                   model: a.model == b.model ? a.model : nil)
    }

    /// Tooltip: where the tokens went. Cache reads dominate long sessions and are cheap.
    var breakdown: String {
        var lines = [
            String(localized: "Output: \(Self.format(output_tokens))"),
            String(localized: "Input: \(Self.format(input_tokens))"),
            String(localized: "Cache written: \(Self.format(cache_write))"),
            String(localized: "Cache read: \(Self.format(cache_read))"),
        ]
        if let model { lines.append(model) }
        return lines.joined(separator: "\n")
    }

    static func format(_ n: Int) -> String {
        let d = Double(n)
        switch n {
        case ..<1000: return "\(n)"
        case ..<1_000_000: return String(format: "%.0f K", d / 1000)
        case ..<10_000_000: return (d / 1_000_000).formatted(.number.precision(.fractionLength(1))) + " M"
        default: return String(format: "%.0f M", d / 1_000_000)
        }
    }
}

/// Role sessions are titled "<role>-<task>"; everything a pipeline spends on one task shares the suffix.
private let rolePrefix = try! Regex(#"^(builder|reviewer|security|ux|qa|screener)-(.+)$"#)

extension SessionStore {
    func usage(of s: DeckSession) -> TokenUsage? { usage[s.id] }

    /// A conductor plus everything it started.
    func conductorUsage(_ c: DeckSession) -> (own: TokenUsage, workers: TokenUsage) {
        let own = usage[c.id] ?? TokenUsage()
        let workers = children(of: c).compactMap { usage[$0.id] }.reduce(TokenUsage(), +)
        return (own, workers)
    }

    /// Workers grouped by task ("builder-x", "qa-x" → "x"), biggest first. Sessions without a role stay alone.
    func taskUsage(_ c: DeckSession) -> [(task: String, roles: Int, usage: TokenUsage)] {
        var groups: [String: (Int, TokenUsage)] = [:]
        for w in children(of: c) {
            guard let u = usage[w.id] else { continue }
            let task = (try? rolePrefix.wholeMatch(in: w.title)).flatMap { $0.output[2].substring.map(String.init) } ?? w.title
            let g = groups[task] ?? (0, TokenUsage())
            groups[task] = (g.0 + 1, g.1 + u)
        }
        return groups.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.usage.total > $1.usage.total }
    }

    /// Imports new transcript lines (`costs sync`, a few seconds of CPU) and reloads the per-session numbers.
    func refreshUsage(sync: Bool) {
        if Demo.enabled { return }
        Task.detached(priority: .utility) {
            if sync { _ = Tools.run(Tools.agentDeck, ["costs", "sync"]) }
            struct Row: Decodable { let session_id: String; let input_tokens: Int; let output_tokens: Int
                                    let cache_read: Int; let cache_write: Int; let model: String? }
            let rows = Tools.run(Tools.agentDeck, ["costs", "sessions", "--json", "--limit", "500"])
                .flatMap { try? JSONDecoder().decode([Row].self, from: $0) } ?? []
            let map = Dictionary(rows.map { ($0.session_id, TokenUsage(input_tokens: $0.input_tokens, output_tokens: $0.output_tokens,
                                                                      cache_read: $0.cache_read, cache_write: $0.cache_write,
                                                                      model: $0.model)) },
                                 uniquingKeysWith: { a, _ in a })
            await MainActor.run { if map != self.usage { self.usage = map } }
        }
    }
}

/// "42 M" with a gauge icon and the breakdown as tooltip.
struct TokenLabel: View {
    let usage: TokenUsage
    var suffix = true

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 9.5))
            Text(verbatim: TokenUsage.format(usage.total) + (suffix ? " " + String(localized: "tokens") : ""))
                .monospacedDigit()
        }
        .help(usage.breakdown)
    }
}
