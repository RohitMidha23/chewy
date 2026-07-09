import Foundation

public struct ChewyPaths: Sendable {
    public let appSupportDirectory: URL

    public init(appSupportDirectory: URL) {
        self.appSupportDirectory = appSupportDirectory
    }

    public var profilesDirectory: URL {
        appSupportDirectory.appendingPathComponent("Profiles", isDirectory: true)
    }

    public var metadataURL: URL {
        appSupportDirectory.appendingPathComponent("profiles.json", isDirectory: false)
    }

    public var launchesDirectory: URL {
        appSupportDirectory.appendingPathComponent("Launches", isDirectory: true)
    }

    public static func defaultPaths(fileManager: FileManager = .default) throws -> ChewyPaths {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ChewyError.applicationSupportUnavailable
        }

        return ChewyPaths(
            appSupportDirectory: base.appendingPathComponent("Chewy", isDirectory: true)
        )
    }
}
