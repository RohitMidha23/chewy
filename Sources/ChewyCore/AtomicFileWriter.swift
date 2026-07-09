import Foundation

public enum AtomicFileWriter {
    public static func write(data: Data, to destination: URL, fileManager: FileManager = .default) throws {
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        // No file-protection option: iOS data-protection classes are a no-op on
        // macOS — POSIX 0600 permissions and the Keychain vault are the real boundary.
        try data.write(to: temporary)

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }
}
