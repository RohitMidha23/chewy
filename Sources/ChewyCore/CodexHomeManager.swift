import Foundation

public final class CodexHomeManager {
    private let paths: ChewyPaths
    private let fileManager: FileManager

    public init(paths: ChewyPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func defaultCodexHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome, isDirectory: true)
                .standardizedFileURL
        }

        let home = environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL
    }

    public func profileHomeURL(slug: String) -> URL {
        paths.profilesDirectory
            .appendingPathComponent("codex", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("home", isDirectory: true)
    }

    public func createDisposableHome(slug: String) throws -> URL {
        let home = profileHomeURL(slug: slug)
        guard !fileManager.fileExists(atPath: home.path) else {
            throw ChewyError.profileAlreadyExists(slug)
        }

        try fileManager.createDirectory(
            at: home,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return home
    }

    public func importCurrentHome(slug: String, sourceHome: URL? = nil) throws -> URL {
        let source = (sourceHome ?? defaultCodexHome()).standardizedFileURL
        guard fileManager.fileExists(atPath: source.path) else {
            throw ChewyError.missingCodexHome(source)
        }

        let destination = try createDisposableHome(slug: slug)
        let copied = try copyImportableFiles(from: source, to: destination)
        guard copied > 0 else {
            try? fileManager.removeItem(at: destination)
            throw ChewyError.noImportableCodexFiles(source)
        }

        return destination
    }

    public func validateCodexHome(_ home: URL) throws {
        guard fileManager.fileExists(atPath: home.path) else {
            throw ChewyError.invalidCodexHome(home)
        }
    }

    @discardableResult
    private func copyImportableFiles(from source: URL, to destination: URL) throws -> Int {
        var copied = 0
        for filename in ["auth.json", "config.toml", "AGENTS.md", "RTK.md"] {
            let sourceFile = source.appendingPathComponent(filename, isDirectory: false)
            guard fileManager.fileExists(atPath: sourceFile.path) else {
                continue
            }

            let destinationFile = destination.appendingPathComponent(filename, isDirectory: false)
            try fileManager.copyItem(at: sourceFile, to: destinationFile)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationFile.path)
            copied += 1
        }

        return copied
    }
}
