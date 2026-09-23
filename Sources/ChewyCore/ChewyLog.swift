import Foundation
import os

/// Minimal diagnostics log for Chewy. Every line goes to the unified log
/// (subsystem `io.github.rohitmidha23.chewy`) AND, once `configure` has run, to a
/// size-capped plain-text file under Application Support so a user can attach it
/// to a bug report without knowing `log show`.
///
/// Rules for callers: NEVER pass tokens, credential blobs, or response bodies.
/// Percentages, HTTP status codes, account emails, slugs and decisions are fine.
public enum ChewyLog {
    public static let subsystem = "io.github.rohitmidha23.chewy"
    private static let logger = Logger(subsystem: subsystem, category: "chewy")

    private static let lock = NSLock()
    private nonisolated(unsafe) static var fileURL: URL?
    /// Rotate when the file grows past this (one generation kept as `.1`).
    private static let maxBytes = 512 * 1024

    private nonisolated(unsafe) static let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Point the file sink at `<directory>/chewy.log` (directory is created 0700).
    public static func configure(directory: URL, fileManager: FileManager = .default) {
        lock.lock(); defer { lock.unlock() }
        try? fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        fileURL = directory.appendingPathComponent("chewy.log", isDirectory: false)
    }

    /// The current log file location, if configured (for "Open log" affordances).
    public static var currentFileURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return fileURL
    }

    public static func info(_ message: String) { write(level: "INFO", message) }
    public static func warn(_ message: String) { write(level: "WARN", message) }
    public static func error(_ message: String) { write(level: "ERROR", message) }

    private static func write(level: String, _ message: String) {
        switch level {
        case "ERROR": logger.error("\(message, privacy: .public)")
        case "WARN": logger.warning("\(message, privacy: .public)")
        default: logger.info("\(message, privacy: .public)")
        }
        lock.lock(); defer { lock.unlock() }
        guard let fileURL else { return }
        let line = "\(timestamp.string(from: Date())) [\(level)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue,
           size > maxBytes {
            let rotated = fileURL.appendingPathExtension("1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: fileURL, to: rotated)
        }
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
