import Foundation

enum ProviderSecretSourceKind: String, Codable {
    case managedTOMLField
    case currentProcessEnvironment
    case commandAuthentication
    case userSecureInput
    case unknown
}

struct ProviderSecretMigrationAuthorization: Codable, Equatable {
    let profileID: String
    let sourceKind: ProviderSecretSourceKind
    let sourceDescription: String
    let approvedAt: Date
    let oneTimeReadApproved: Bool
}

enum ProviderSecretMigrationState: String, Codable {
    case authorized
    case secretRead
    case keychainStored
    case configPrepared
    case configCommitted
    case verified
    case committed
    case rolledBack
    case manualRecoveryRequired
}

struct ProviderSecretMigrationJournal: Identifiable, Codable, Equatable {
    let id: String
    let profileID: String
    let sourceKind: ProviderSecretSourceKind
    var state: ProviderSecretMigrationState
    let startedAt: Date
    var updatedAt: Date
    let beforeConfigHash: String?
    var afterConfigHash: String?
    var sanitizedMessage: String
}

enum ProviderSecretMigrationError: LocalizedError {
    case authorizationRequired
    case sourceUnavailable
    case keychainRoundTripMismatch
    case secretLeakedIntoConfiguration
    case legacyBearerStillPresent

    var errorDescription: String? {
        switch self {
        case .authorizationRequired: return "需要针对明确密钥来源单独授权一次性迁移"
        case .sourceUnavailable: return "授权来源当前不可读取，请改用安全输入框手工提供"
        case .keychainRoundTripMismatch: return "助手Keychain写入后读取不一致"
        case .secretLeakedIntoConfiguration: return "生成配置仍包含实际密钥，已阻止"
        case .legacyBearerStillPresent: return "旧Bearer字段未能安全移除，已阻止"
        }
    }
}

protocol ProviderSecretStore {
    func load(profileID: String) throws -> String?
    func save(_ value: String, profileID: String) throws
    func delete(profileID: String) throws
}

struct AppKeychainProviderSecretStore: ProviderSecretStore {
    func load(profileID: String) throws -> String? {
        do {
            return try RelaySecretStore.load(relayID: profileID)
        } catch CodexControlError.missingSecret {
            return nil
        }
    }

    func save(_ value: String, profileID: String) throws {
        try RelaySecretStore.save(value, relayID: profileID)
    }

    func delete(profileID: String) throws {
        try RelaySecretStore.delete(relayID: profileID)
    }
}

struct ProviderSecretMigrationEngine {
    let adapter: CodexConfigurationAdapter
    let store: ProviderSecretStore

    func migrate(
        profile: CodexRelayProfile,
        authorization: ProviderSecretMigrationAuthorization,
        expectedConfigHash: String?,
        readOnce: () throws -> String,
        verify: (CodexRelayProfile, String) throws -> Void
    ) throws -> ProviderSecretMigrationJournal {
        guard authorization.profileID == profile.id,
              authorization.oneTimeReadApproved,
              authorization.sourceKind != .unknown else {
            throw ProviderSecretMigrationError.authorizationRequired
        }
        let transactionID = UUID().uuidString
        let originalData = try adapter.currentConfigData()
        let originalHash = try adapter.currentConfigHash()
        if expectedConfigHash != nil, originalHash != expectedConfigHash {
            throw CodexControlError.externalDrift
        }
        let previousSecret = try store.load(profileID: profile.id)
        var wroteConfiguration = false
        var wroteSecret = false
        var journal = ProviderSecretMigrationJournal(
            id: transactionID,
            profileID: profile.id,
            sourceKind: authorization.sourceKind,
            state: .authorized,
            startedAt: Date(),
            updatedAt: Date(),
            beforeConfigHash: originalHash,
            afterConfigHash: nil,
            sanitizedMessage: "已授权明确来源；尚未读取正文"
        )
        do {
            let secret = try readOnce().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !secret.isEmpty else { throw ProviderSecretMigrationError.sourceUnavailable }
            journal.state = .secretRead
            journal.updatedAt = Date()

            try store.save(secret, profileID: profile.id)
            wroteSecret = true
            guard try store.load(profileID: profile.id) == secret else {
                throw ProviderSecretMigrationError.keychainRoundTripMismatch
            }
            journal.state = .keychainStored
            journal.updatedAt = Date()

            let plan = try adapter.buildPlan(
                profile: profile,
                allowLegacyBearerRemoval: true
            )
            guard !plan.proposed.contains(secret) else {
                throw ProviderSecretMigrationError.secretLeakedIntoConfiguration
            }
            guard !plan.proposed.contains("experimental_bearer_token") else {
                throw ProviderSecretMigrationError.legacyBearerStillPresent
            }
            journal.state = .configPrepared
            journal.updatedAt = Date()
            try adapter.apply(plan, expectedCurrentHash: originalHash)
            wroteConfiguration = true
            journal.state = .configCommitted
            journal.afterConfigHash = try adapter.currentConfigHash()
            journal.updatedAt = Date()

            try verify(profile, secret)
            journal.state = .committed
            journal.updatedAt = Date()
            journal.sanitizedMessage = "密钥已迁移到助手Keychain；配置不含密钥正文"
            return journal
        } catch {
            if wroteConfiguration {
                try? adapter.restoreConfigData(
                    originalData,
                    expectedCurrentHash: try? adapter.currentConfigHash()
                )
            }
            if wroteSecret {
                if let previousSecret {
                    try? store.save(previousSecret, profileID: profile.id)
                } else {
                    try? store.delete(profileID: profile.id)
                }
            }
            journal.state = .rolledBack
            journal.updatedAt = Date()
            journal.sanitizedMessage = error.localizedDescription
            throw error
        }
    }
}
