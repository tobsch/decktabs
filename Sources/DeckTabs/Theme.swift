import AppKit
import SwiftTerm
import SwiftUI

enum Theme {
    /// Background of the terminal area (and the header above it, so it reads as one surface).
    static let canvas = NSColor(srgbRed: 0.105, green: 0.110, blue: 0.130, alpha: 1)
    static let canvasLine = SwiftUI.Color.white.opacity(0.07)
    static let ink = NSColor(srgbRed: 0.86, green: 0.87, blue: 0.89, alpha: 1)

    /// Calm area colors, stable per group name.
    static let groupPalette: [SwiftUI.Color] = [
        SwiftUI.Color(red: 0.35, green: 0.56, blue: 0.95), SwiftUI.Color(red: 0.93, green: 0.55, blue: 0.25),
        SwiftUI.Color(red: 0.38, green: 0.72, blue: 0.48), SwiftUI.Color(red: 0.72, green: 0.48, blue: 0.90),
        SwiftUI.Color(red: 0.90, green: 0.42, blue: 0.52), SwiftUI.Color(red: 0.30, green: 0.70, blue: 0.75),
        SwiftUI.Color(red: 0.80, green: 0.66, blue: 0.25),
    ]

    static func color(forGroup g: String) -> SwiftUI.Color {
        var h: UInt32 = 5381
        for b in g.lowercased().utf8 { h = (h &* 33) &+ UInt32(b) }
        return groupPalette[Int(h % UInt32(groupPalette.count))]
    }

    /// Short and calm like Things: “now”, “12 min”, “3 h”, “yesterday”, “4 d”.
    static func ago(_ d: Date, now: Date = Date()) -> String {
        if d == .distantPast { return "" }
        let s = max(0, now.timeIntervalSince(d))
        switch s {
        case ..<60: return String(localized: "now")
        case ..<3600: return String(localized: "\(Int(s / 60)) min")
        case ..<86400: return String(localized: "\(Int(s / 3600)) h")
        case ..<172_800: return String(localized: "yesterday")
        case ..<(86400 * 14): return String(localized: "\(Int(s / 86400)) d")
        default: return String(localized: "\(Int(s / 604_800)) w")
        }
    }

    /// Balanced ANSI palette (muted, readable on the dark canvas).
    static let ansi: [SwiftTerm.Color] = [
        "#2a2c33", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#c8ccd4",
        "#5c6370", "#ef7b85", "#a9d48a", "#f0cd8c", "#7cc0f5", "#d291e6", "#6fcad4", "#eef0f4",
    ].map(Self.term)

    private static func term(_ hex: String) -> SwiftTerm.Color {
        let v = UInt32(hex.dropFirst(), radix: 16)!
        func c(_ x: UInt32) -> UInt16 { UInt16((x & 0xff) * 257) }
        return SwiftTerm.Color(red: c(v >> 16), green: c(v >> 8), blue: c(v))
    }
}

/// Status indicator before the title: working = spinning arc, new = blue dot, error = red exclamation mark.
struct StatusGlyph: View {
    let session: DeckSession
    let unread: Bool

    var body: some View {
        ZStack {
            if session.isError {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red)
            } else if session.isRunning {
                Circle().stroke(SwiftUI.Color.secondary.opacity(0.18), lineWidth: 1.6)
                // Angle derived from the clock: a repeatForever animation would also animate
                // layout changes and make the arc fly across the window.
                TimelineView(.animation) { ctx in
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(SwiftUI.Color.accentColor, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .rotationEffect(.degrees(ctx.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 1) * 360))
                }
            } else if unread {
                Circle().fill(SwiftUI.Color.accentColor).frame(width: 8, height: 8)
            } else {
                Circle().stroke(SwiftUI.Color.secondary.opacity(0.35), lineWidth: 1.2).frame(width: 7, height: 7)
            }
        }
        .frame(width: 11, height: 11)
        .help(statusText(session, unread: unread))
    }
}

func statusText(_ s: DeckSession, unread: Bool) -> String {
    if s.isError { return String(localized: "error") }
    if s.isRunning { return String(localized: "working") }
    if unread { return String(localized: "new – waiting for you") }
    switch s.status {
    case "waiting": return String(localized: "ready")
    case "idle": return String(localized: "idle")
    case "stopped": return String(localized: "stopped")
    default: return s.status
    }
}

/// Harness of a session (Claude Code, Codex, …) with a recognizable glyph and color.
struct ToolInfo {
    let name: String
    let symbol: String
    let color: SwiftUI.Color

    init(_ tool: String) {
        switch tool.lowercased() {
        case "claude":
            name = "Claude"; symbol = "asterisk"; color = SwiftUI.Color(red: 0.85, green: 0.47, blue: 0.34)
        case "codex":
            name = "Codex"; symbol = "chevron.left.forwardslash.chevron.right"; color = SwiftUI.Color(red: 0.35, green: 0.62, blue: 0.95)
        case "gemini":
            name = "Gemini"; symbol = "sparkle"; color = SwiftUI.Color(red: 0.40, green: 0.55, blue: 0.98)
        case "opencode":
            name = "OpenCode"; symbol = "curlybraces"; color = SwiftUI.Color(red: 0.55, green: 0.75, blue: 0.45)
        case "cursor":
            name = "Cursor"; symbol = "cursorarrow.rays"; color = SwiftUI.Color(red: 0.70, green: 0.70, blue: 0.75)
        case "hermes":
            name = "Hermes"; symbol = "bolt.fill"; color = SwiftUI.Color(red: 0.85, green: 0.70, blue: 0.30)
        default:
            name = tool.isEmpty ? "Shell" : tool.prefix(1).uppercased() + tool.dropFirst()
            symbol = "terminal"; color = .secondary
        }
    }
}

/// Small tool label: colored glyph + name.
struct ToolBadge: View {
    let tool: String
    var size: CGFloat = 11

    var body: some View {
        let info = ToolInfo(tool)
        HStack(spacing: 3) {
            Image(systemName: info.symbol)
                .font(.system(size: size - 1, weight: .bold))
                .foregroundStyle(info.color)
            Text(verbatim: info.name)
        }
        .help(info.name)
    }
}
