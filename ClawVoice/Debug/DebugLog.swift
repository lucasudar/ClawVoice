import Foundation

/// Temporary connection debug logger.
/// TODO: Remove before production release (or repurpose as in-app debug view).
///
/// Logs are written to Documents/clawvoice-debug.log (max 300 lines, rotated on launch).
/// Read via Files app or Xcode's Device File Browser: App > Documents > clawvoice-debug.log
enum DebugLog {

    static let isEnabled = true  // TODO: set false before release

    private static let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("clawvoice-debug.log")
    }()

    private static let queue = DispatchQueue(label: "DebugLog", qos: .utility)
    private static var lineCount = 0
    private static let maxLines = 300

    static func setup() {
        guard isEnabled else { return }
        queue.async { rotate() }
    }

    static func connection(_ msg: String, sessionId: String? = nil, sessionAge: TimeInterval? = nil) {
        guard isEnabled else { return }
        var parts = [msg]
        if let id = sessionId { parts.append("session=\(id.prefix(8))") }
        if let age = sessionAge {
            let mins = Int(age) / 60
            let secs = Int(age) % 60
            parts.append("age=\(mins)m\(secs)s")
        }
        write("🔌 " + parts.joined(separator: " | "))
    }

    static func audio(_ msg: String) {
        guard isEnabled else { return }
        write("🎙 " + msg)
    }

    static func error(_ msg: String) {
        guard isEnabled else { return }
        write("❌ " + msg)
    }

    // MARK: - Internal

    private static func write(_ msg: String) {
        queue.async {
            let ts = ISO8601DateFormatter().string(from: Date())
            let line = "[\(ts)] \(msg)\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    if let fh = try? FileHandle(forWritingTo: fileURL) {
                        fh.seekToEndOfFile()
                        fh.write(data)
                        fh.closeFile()
                    }
                } else {
                    try? data.write(to: fileURL, options: .atomic)
                }
                lineCount += 1
                if lineCount > maxLines { rotate() }
            }
        }
    }

    private static func rotate() {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let keep = Array(lines.suffix(200))
        let trimmed = keep.joined(separator: "\n") + "\n"
        try? trimmed.write(to: fileURL, atomically: true, encoding: .utf8)
        lineCount = keep.count
    }
}
