import Foundation
import os

/// Launcher log: unified logging plus an append-only file under ZMF/logs that
/// users can read in-app or share.
final class LauncherLog: @unchecked Sendable {
    static let shared = LauncherLog()

    private let logger = Logger(subsystem: "dev.zmf.javalauncher", category: "launcher")
    private let queue = DispatchQueue(label: "dev.zmf.log")
    let fileURL: URL
    private var handle: FileHandle?

    private init() {
        Paths.ensureLayout()
        fileURL = Paths.logs.appendingPathComponent("launcher.log")
        if let size = FileManager.default.fileSize(fileURL), size > 2_000_000 {
            try? FileManager.default.removeItem(at: fileURL)
        }
        if !FileManager.default.fileExists(fileURL) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
    }

    func info(_ message: String) { write("INFO", message) }
    func warn(_ message: String) { write("WARN", message) }
    func error(_ message: String) { write("ERROR", message) }

    private func write(_ level: String, _ message: String) {
        logger.log("\(level, privacy: .public) \(message, privacy: .public)")
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(level)] \(message)\n"
        queue.async { [weak self] in
            if let data = line.data(using: .utf8) { self?.handle?.write(data) }
        }
    }
}

let zlog = LauncherLog.shared
