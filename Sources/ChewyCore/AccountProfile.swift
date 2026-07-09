import Foundation

public enum AccountTool: String, Codable, CaseIterable, Hashable, Sendable {
    case codex
    case claude
}

public struct AccountProfile: Codable, Equatable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var tool: AccountTool
    public var name: String
    public var slug: String
    public var homePath: String
    public var isImported: Bool
    public var credentialReference: String?
    public var authEnvironmentVariable: String?
    public var emailAddress: String?
    public var organizationUuid: String?
    public var organizationName: String?
    public var accountId: String?
    public var workspaceAccountId: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        tool: AccountTool,
        name: String,
        slug: String,
        homePath: String,
        isImported: Bool,
        credentialReference: String? = nil,
        authEnvironmentVariable: String? = nil,
        emailAddress: String? = nil,
        organizationUuid: String? = nil,
        organizationName: String? = nil,
        accountId: String? = nil,
        workspaceAccountId: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.tool = tool
        self.name = name
        self.slug = slug
        self.homePath = homePath
        self.isImported = isImported
        self.credentialReference = credentialReference
        self.authEnvironmentVariable = authEnvironmentVariable
        self.emailAddress = emailAddress
        self.organizationUuid = organizationUuid
        self.organizationName = organizationName
        self.accountId = accountId
        self.workspaceAccountId = workspaceAccountId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var homeURL: URL {
        URL(fileURLWithPath: homePath, isDirectory: true)
    }
}
