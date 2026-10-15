import SwiftUI

/// Token use of one session's current conversation, read from its Claude transcript.
struct TokenUsage: Codable, Equatable {
    var input_tokens: Int = 0
    var output_tokens: Int = 0
    var cache_read: Int = 0
    var cache_write: Int = 0
    var model: String?

    var total: Int { input_tokens + output_tokens + cache_read + cache_write }

    static func - (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input_tokens: a.input_tokens - b.input_tokens, output_tokens: a.output_tokens - b.output_tokens,
                   cache_read: a.cache_read - b.cache_read, cache_write: a.cache_write - b.cache_write, model: a.model)
    }

    static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input_tokens: a.input_tokens + b.input_tokens, output_tokens: a.output_tokens + b.output_tokens,
                   cache_read: a.cache_read + b.cache_read, cache_write: a.cache_write + b.cache_write,
                   model: a.model == b.model || b.total == 0 ? a.model : a.total == 0 ? b.model : nil)
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

struct TokenReset: Codable, Equatable {
    var baseline: TokenUsage
    var date: Date
}

/// Role sessions are titled "<role>-<task>"; everything a pipeline spends on one task shares the suffix.
private let rolePrefix = try! Regex(#"^(builder|reviewer|security|ux|qa|screener)-(.+)$"#)

extension SessionStore {
    /// The task a worker belongs to, from titles like "builder-x" or "qa-x".
    func taskName(of s: DeckSession) -> String? {
        (try? rolePrefix.wholeMatch(in: s.title)).flatMap { $0.output[2].substring.map(String.init) }
    }
}

extension SessionStore {
    /// Tokens since the last reset of this session's counter (or since the conversation started).
    func usage(of s: DeckSession) -> TokenUsage? {
        guard let raw = usage[s.id] else { return nil }
        // A new conversation starts below the old baseline: count it from zero again.
        guard let base = tokenResets[s.id]?.baseline, base.total <= raw.total else { return raw }
        let u = raw - base
        return u.total > 0 ? u : nil
    }

    /// When the counter of a session was last reset, if ever.
    func usageSince(_ s: DeckSession) -> Date? { tokenResets[s.id]?.date }

    /// Starts counting from zero for these sessions (a conductor passes itself and its workers).
    func resetUsage(_ list: [DeckSession]) {
        for s in list { tokenResets[s.id] = TokenReset(baseline: usage[s.id] ?? TokenUsage(), date: Date()) }
    }

    /// A conductor plus everything it started.
    func conductorUsage(_ c: DeckSession) -> (own: TokenUsage, workers: TokenUsage) {
        let own = usage(of: c) ?? TokenUsage()
        let workers = children(of: c).compactMap { usage(of: $0) }.reduce(TokenUsage(), +)
        return (own, workers)
    }

    /// Workers grouped by task ("builder-x", "qa-x" → "x"), biggest first. Sessions without a role stay alone.
    func taskUsage(_ c: DeckSession) -> [(task: String, roles: Int, usage: TokenUsage)] {
        var groups: [String: (Int, TokenUsage)] = [:]
        for w in children(of: c) {
            guard let u = usage(of: w) else { continue }
            let task = taskName(of: w) ?? w.title
            let g = groups[task] ?? (0, TokenUsage())
            groups[task] = (g.0 + 1, g.1 + u)
        }
        return groups.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.usage.total > $1.usage.total }
    }

    /// Counts tokens straight from the Claude transcripts. Each API response is counted once:
    /// Claude Code writes one line per content block, all carrying the same usage (summing lines
    /// over-counts about 2x, which is what `agent-deck costs` does).
    func refreshUsage() {
        if Demo.enabled { return }
        let files = sessions.filter { !$0.isRemote }.compactMap { s in s.transcript_path.map { (s.id, $0) } }
        Task.detached(priority: .utility) {
            let map = await TranscriptScanner.shared.usage(for: files)
            await MainActor.run { if map != self.usage { self.usage = map } }
        }
    }
}

/// Reads Claude transcripts incrementally. Claude Code writes the lines of one response back to back,
/// so remembering the last message id is enough to count each response once. The read position per
/// file is kept in Caches, so a restart of the app does not reread a gigabyte of transcripts.
actor TranscriptScanner {
    static let shared = TranscriptScanner()

    private struct FileState: Codable {
        var offset: UInt64 = 0
        var total = TokenUsage()
        var lastKey: String?
        var lastUsage = TokenUsage()
    }
    private var files: [String: FileState]
    private var dirty = false
    private let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("DeckTabs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("transcript-usage.json")
    }()

    init() {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeckTabs/transcript-usage.json")
        files = (try? JSONDecoder().decode([String: FileState].self, from: Data(contentsOf: url))) ?? [:]
    }

    func usage(for sessions: [(id: String, path: String)]) -> [String: TokenUsage] {
        var out: [String: TokenUsage] = [:]
        for (id, path) in sessions where path.hasSuffix(".jsonl") {
            // Subagents (Task tool) write their own transcripts next to the main one.
            let sub = (path as NSString).deletingPathExtension + "/subagents"
            let extra = ((try? FileManager.default.contentsOfDirectory(atPath: sub)) ?? [])
                .filter { $0.hasSuffix(".jsonl") }.map { sub + "/" + $0 }
            let u = ([path] + extra).map(scan).reduce(TokenUsage(), +)
            if u.total > 0 { out[id] = u }
        }
        if dirty, let data = try? JSONEncoder().encode(files) {
            try? data.write(to: cacheURL, options: .atomic)
            dirty = false
        }
        return out
    }

    private func scan(_ path: String) -> TokenUsage {
        var st = files[path] ?? FileState()
        guard let h = FileHandle(forReadingAtPath: path) else { return st.total }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < st.offset { st = FileState() }   // rewritten: start over
        guard size > st.offset else { return st.total }
        try? h.seek(toOffset: st.offset)
        guard let data = try? h.readToEnd(), let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return st.total }
        let needle = Data("\"usage\"".utf8)
        for line in data[data.startIndex...end].split(separator: UInt8(ascii: "\n")) where line.range(of: needle) != nil {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any], let u = msg["usage"] as? [String: Any] else { continue }
            let key = msg["id"] as? String ?? obj["requestId"] as? String
            let new = TokenUsage(input_tokens: u["input_tokens"] as? Int ?? 0, output_tokens: u["output_tokens"] as? Int ?? 0,
                                 cache_read: u["cache_read_input_tokens"] as? Int ?? 0,
                                 cache_write: u["cache_creation_input_tokens"] as? Int ?? 0,
                                 model: msg["model"] as? String)
            // Another line of the same response: replace its usage instead of adding it again.
            if key != nil, key == st.lastKey { st.total = st.total - st.lastUsage }
            st.lastKey = key
            st.lastUsage = new
            let model = new.model ?? st.total.model
            st.total = st.total + new
            st.total.model = model
        }
        st.offset += UInt64(end - data.startIndex + 1)
        files[path] = st
        dirty = true
        return st.total
    }
}

/// "42 M" with a gauge icon and the breakdown as tooltip.
struct TokenLabel: View {
    let usage: TokenUsage
    var suffix = true
    var since: Date? = nil

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 9.5))
            Text(verbatim: TokenUsage.format(usage.total) + (suffix ? " " + String(localized: "tokens") : ""))
                .monospacedDigit()
        }
        .help((since.map { String(localized: "since \($0.formatted(date: .abbreviated, time: .shortened))") + "\n" } ?? "") + usage.breakdown)
    }
}
