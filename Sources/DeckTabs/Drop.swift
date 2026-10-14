import AppKit
import SwiftTerm
import UniformTypeIdentifiers

/// Terminal that accepts dropped files and images like Terminal.app / iTerm:
/// the (shell-escaped) paths are pasted, so Claude Code and Codex attach images natively.
/// For remote sessions the files are uploaded over SSH first and the remote paths are pasted.
final class DropTerminalView: LocalProcessTerminalView {
    var session: DeckSession?
    private var highlighted = false { didSet { updateHighlight() } }
    private var dropLayer: CAShapeLayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard session != nil, Self.canRead(sender.draggingPasteboard) else { return [] }
        highlighted = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { highlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        guard let session else { return false }
        let pb = sender.draggingPasteboard
        window?.makeFirstResponder(self)

        // 1. Real files (Finder, screenshots on the desktop, …)
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            deliver(urls, for: session)
            return true
        }
        // 2. File promises (Photos, Mail attachments, some browsers)
        if let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            let dir = Self.dropFolder()
            let group = DispatchGroup()
            var urls: [URL] = []
            let lock = NSLock()
            for r in receivers {
                group.enter()
                r.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: .main) { url, error in
                    if error == nil { lock.lock(); urls.append(url); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) { [weak self] in
                if !urls.isEmpty { self?.deliver(urls.sorted { $0.path < $1.path }, for: session) }
            }
            return true
        }
        // 3. Raw image data (e.g. dragged out of a browser)
        if let image = NSImage(pasteboard: pb), let url = Self.writePNG(image) {
            deliver([url], for: session)
            return true
        }
        return false
    }

    /// Accent frame while something is dragged over the terminal.
    private func updateHighlight() {
        guard highlighted else { dropLayer?.removeFromSuperlayer(); dropLayer = nil; return }
        wantsLayer = true
        let l = dropLayer ?? CAShapeLayer()
        l.path = CGPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), cornerWidth: 8, cornerHeight: 8, transform: nil)
        l.lineWidth = 2
        l.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        l.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.06).cgColor
        l.zPosition = 1000
        if l.superlayer == nil { layer?.addSublayer(l) }
        dropLayer = l
    }

    // MARK: Delivery

    private func deliver(_ urls: [URL], for session: DeckSession) {
        if let host = session.remoteHost, session.isRemote {
            Task.detached {
                var remotePaths: [String] = []
                for url in urls {
                    if let p = Self.upload(url, to: host) { remotePaths.append(p) }
                }
                let paths = remotePaths
                await MainActor.run {
                    if paths.isEmpty { NSSound.beep() } else { self.paste(paths) }
                }
            }
        } else {
            paste(urls.map(\.path))
        }
    }

    private func paste(_ paths: [String]) {
        pasteText(paths.map(Self.shellEscape).joined(separator: " ") + " ")
    }

    /// Copies a file to `/tmp/decktabs/` on the remote and returns the remote path.
    nonisolated private static func upload(_ url: URL, to host: String) -> String? {
        let safe = url.lastPathComponent.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let stamp = Int(Date().timeIntervalSince1970)
        let remotePath = "/tmp/decktabs/\(stamp)-\(safe)"
        guard let input = FileHandle(forReadingAtPath: url.path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", host, "mkdir -p /tmp/decktabs && cat > \(remotePath)"]
        p.environment = Tools.environment
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        try? input.close()
        return p.terminationStatus == 0 ? remotePath : nil
    }

    // MARK: Helpers

    private static func canRead(_ pb: NSPasteboard) -> Bool {
        pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pb.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
            || NSImage.canInit(with: pb)
    }

    static func dropFolder() -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeckTabs/Drops", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func writePNG(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = dropFolder().appendingPathComponent("image-\(f.string(from: Date())).png")
        return (try? png.write(to: url)) != nil ? url : nil
    }

    /// Backslash-escapes like Terminal.app does for dropped paths.
    static func shellEscape(_ path: String) -> String {
        var out = ""
        for ch in path {
            if " \\'\"()[]{}&;|<>*?!$`#~".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}
