import Foundation

public final class AccountProfileStore {
    private let paths: ChewyPaths
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: ChewyPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func ensureDirectories() throws {
        try fileManager.createDirectory(
            at: paths.appSupportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.createDirectory(
            at: paths.profilesDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.createDirectory(
            at: paths.launchesDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    public func loadProfiles() throws -> [AccountProfile] {
        try ensureDirectories()
        guard fileManager.fileExists(atPath: paths.metadataURL.path) else {
            return []
        }

        let data = try Data(contentsOf: paths.metadataURL)
        return try decoder.decode([AccountProfile].self, from: data)
    }

    public func saveProfiles(_ profiles: [AccountProfile]) throws {
        try ensureDirectories()
        let data = try encoder.encode(profiles)
        try AtomicFileWriter.write(data: data, to: paths.metadataURL, fileManager: fileManager)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.metadataURL.path)
    }

    @discardableResult
    public func removeProfiles(ids: Set<AccountProfile.ID>) throws -> [AccountProfile] {
        var profiles = try loadProfiles()
        profiles.removeAll { ids.contains($0.id) }
        try saveProfiles(profiles)
        return profiles
    }

    public func uniqueSlug(for name: String, tool: AccountTool) throws -> String {
        let base = Self.slugify(name)
        guard !base.isEmpty else {
            throw ChewyError.invalidProfileName
        }

        let profiles = try loadProfiles()
        let existing = Set(profiles.filter { $0.tool == tool }.map(\.slug))
        if !existing.contains(base) {
            return base
        }

        var index = 2
        while existing.contains("\(base)-\(index)") {
            index += 1
        }
        return "\(base)-\(index)"
    }

    @discardableResult
    public func addProfile(
        tool: AccountTool,
        name: String,
        slug: String,
        homeURL: URL,
        isImported: Bool,
        credentialReference: String? = nil,
        authEnvironmentVariable: String? = nil
    ) throws -> AccountProfile {
        var profiles = try loadProfiles()
        guard !profiles.contains(where: { $0.tool == tool && $0.slug == slug }) else {
            throw ChewyError.profileAlreadyExists(slug)
        }

        let now = Date()
        let profile = AccountProfile(
            tool: tool,
            name: name,
            slug: slug,
            homePath: homeURL.path,
            isImported: isImported,
            credentialReference: credentialReference,
            authEnvironmentVariable: authEnvironmentVariable,
            createdAt: now,
            updatedAt: now
        )
        profiles.append(profile)
        try saveProfiles(profiles.sorted { $0.createdAt < $1.createdAt })
        return profile
    }

    /// Inserts or updates a profile, deduping on identity:
    /// - Claude: (emailAddress, organizationUuid)
    /// - Codex: (emailAddress, workspaceAccountId)
    ///
    /// If a matching profile exists, its identity fields and `updatedAt` are refreshed
    /// in place and the updated profile is returned. Otherwise a new profile is appended.
    /// When identity is nil, falls back to the existing (tool, slug) match behavior.
    @discardableResult
    public func upsert(
        tool: AccountTool,
        name: String,
        slug: String,
        homeURL: URL,
        isImported: Bool,
        credentialReference: String? = nil,
        authEnvironmentVariable: String? = nil,
        emailAddress: String? = nil,
        organizationUuid: String? = nil,
        organizationName: String? = nil,
        accountId: String? = nil,
        workspaceAccountId: String? = nil
    ) throws -> AccountProfile {
        var profiles = try loadProfiles()
        let now = Date()

        let matchIndex = profiles.firstIndex { existing in
            guard existing.tool == tool else { return false }
            switch tool {
            case .claude:
                if let emailAddress, let organizationUuid {
                    return existing.emailAddress == emailAddress
                        && existing.organizationUuid == organizationUuid
                }
                // Reconnect re-logs-in with a fresh unique slug but the same stable
                // accountId (and possibly a nil organizationUuid): match on accountId so
                // it updates in place instead of creating a duplicate.
                if let accountId {
                    return existing.accountId == accountId
                }
            case .codex:
                if let emailAddress, let workspaceAccountId {
                    return existing.emailAddress == emailAddress
                        && existing.workspaceAccountId == workspaceAccountId
                }
            }
            // No identity provided: fall back to (tool, slug).
            return existing.slug == slug
        }

        if let matchIndex {
            var profile = profiles[matchIndex]
            profile.name = name
            profile.slug = slug
            profile.homePath = homeURL.path
            profile.isImported = isImported
            profile.credentialReference = credentialReference
            profile.authEnvironmentVariable = authEnvironmentVariable
            profile.emailAddress = emailAddress
            profile.organizationUuid = organizationUuid
            profile.organizationName = organizationName
            profile.accountId = accountId
            profile.workspaceAccountId = workspaceAccountId
            profile.updatedAt = now
            profiles[matchIndex] = profile
            try saveProfiles(profiles.sorted { $0.createdAt < $1.createdAt })
            return profile
        }

        let profile = AccountProfile(
            tool: tool,
            name: name,
            slug: slug,
            homePath: homeURL.path,
            isImported: isImported,
            credentialReference: credentialReference,
            authEnvironmentVariable: authEnvironmentVariable,
            emailAddress: emailAddress,
            organizationUuid: organizationUuid,
            organizationName: organizationName,
            accountId: accountId,
            workspaceAccountId: workspaceAccountId,
            createdAt: now,
            updatedAt: now
        )
        profiles.append(profile)
        try saveProfiles(profiles.sorted { $0.createdAt < $1.createdAt })
        return profile
    }

    public static func slugify(_ value: String) -> String {
        let lowercased = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scalars = lowercased.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }

        return String(scalars)
            .split(separator: "-")
            .joined(separator: "-")
    }
}
