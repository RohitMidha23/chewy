import Foundation

public struct ToolDetector {
    public init() {}

    public func candidatePaths(for executable: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var paths: [String] = []
        if let path = environment["PATH"] {
            paths.append(contentsOf: path.split(separator: ":").map(String.init))
        }

        let home = environment["HOME"] ?? NSHomeDirectory()
        paths.append(contentsOf: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.bun/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.local/bin"
        ])

        var seen = Set<String>()
        return paths.compactMap { directory in
            let url = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(executable, isDirectory: false)
            guard !seen.contains(url.path) else {
                return nil
            }
            seen.insert(url.path)
            return url
        }
    }

    public func findExecutable(named executable: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        candidatePaths(for: executable, environment: environment)
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
