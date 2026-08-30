import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum ManagedProfileKind: String, Codable {
    case official = "官方模式"
    case relay = "中转模式"
}

struct ManagedConfigurationProfile: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let kind: ManagedProfileKind
    let agent: DesktopAgent
    let relayID: String?
    let createdAt: Date
    var lastVerifiedAt: Date?
    var snapshotID: String
}

struct SnapshotInput {
    let relativePath: String
    let data: Data
    let permissions: Int
}

struct SnapshotFileManifest: Codable, Equatable {
    let relativePath: String
    let sha256: String
    let byteCount: Int
    let permissions: Int
}

struct SnapshotManifest: Identifiable, Codable, Equatable {
    let id: String
    let profileID: String
    let adapterVersion: String
    let createdAt: Date
    let files: [SnapshotFileManifest]
}

private struct EncryptedSnapshotPayload: Codable {
    struct File: Codable {
        let relativePath: String
        let data: Data
        let permissions: Int
    }
    let files: [File]
}

enum SecureProfileVaultError: LocalizedError {
    case invalidRelativePath(String)
    case encodingFailed
    case decryptionFailed
    case keychain(OSStatus)
    case missingSnapshot
    case manifestMismatch
    case testKeychainAccessBlocked
    case legacyKeyMigrationRequired
    case legacyKeyAuthorizationCancelled
    case invalidVaultKey
    case vaultKeyMigrationConflict
    case vaultKeyMigrationVerificationFailed

    var errorDescription: String? {
        switch self {
        case let .invalidRelativePath(path): return "快照路径不在允许范围：\(path)"
        case .encodingFailed: return "快照编码失败"
        case .decryptionFailed: return "快照解密失败"
        case let .keychain(status): return "应用加密密钥访问失败：\(status)"
        case .missingSnapshot: return "找不到加密快照"
        case .manifestMismatch: return "快照校验失败，未继续恢复"
        case .testKeychainAccessBlocked:
            return "自动测试禁止访问真实Keychain"
        case .legacyKeyMigrationRequired:
            return "检测到旧保险箱权限；请在应用内确认迁移后再试"
        case .legacyKeyAuthorizationCancelled:
            return "旧保险箱权限授权未完成；旧条目保持不变"
        case .invalidVaultKey:
            return "保险箱加密密钥格式无效；未继续迁移"
        case .vaultKeyMigrationConflict:
            return "新旧保险箱密钥不一致；旧条目保持不变"
        case .vaultKeyMigrationVerificationFailed:
            return "新保险箱权限无法非交互回读；旧条目保持不变"
        }
    }
}

enum ProfileVaultCrypto {
    static func randomKeyData() -> Data {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    static func seal(_ plaintext: Data, keyData: Data) throws -> Data {
        let key = SymmetricKey(data: keyData)
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw SecureProfileVaultError.encodingFailed }
        return combined
    }

    static func open(_ ciphertext: Data, keyData: Data) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(box, using: SymmetricKey(data: keyData))
        } catch {
            throw SecureProfileVaultError.decryptionFailed
        }
    }
}

enum AppVaultKeyMigrationNeed: Equatable, Sendable {
    case none
    case migrationRequired
    case cleanupRequired
}

struct AppVaultKeyMigrationResult: Equatable, Sendable {
    let copiedLegacyKey: Bool
    let legacyRemoved: Bool
}

protocol AppVaultKeychainBackend: Sendable {
    func copyMatching(
        _ query: [String: Any]
    ) -> (status: OSStatus, data: Data?)

    func add(_ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct AppVaultSystemKeychainBackend:
    AppVaultKeychainBackend {
    func copyMatching(
        _ query: [String: Any]
    ) -> (status: OSStatus, data: Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )
        return (status, result as? Data)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

enum AppVaultKeyStore {
    static let service =
        "io.github.liewlf.aiaccessassistant.snapshot-key.v2"
    static let account = "profile-vault-v2"
    static let legacyService =
        "io.github.liewlf.aiaccessassistant.snapshot-key"
    static let legacyAccount = "profile-vault-v1"

    private static let authenticationUIFailValue =
        "u_AuthUIF" as CFString

    static func loadOrCreate() throws -> Data {
        try requireLiveKeychain()
        return try loadOrCreate(
            using: AppVaultSystemKeychainBackend()
        )
    }

    static func loadOrCreate(
        using backend: any AppVaultKeychainBackend
    ) throws -> Data {
        let current = backend.copyMatching(
            nonInteractiveLookupQuery
        )
        if current.status == errSecSuccess {
            return try validatedKey(current.data)
        }
        guard current.status == errSecItemNotFound else {
            throw SecureProfileVaultError.keychain(
                current.status
            )
        }
        let legacy = backend.copyMatching(
            nonInteractiveLegacyPresenceQuery
        )
        if legacy.status == errSecSuccess
            || legacy.status == errSecInteractionNotAllowed
            || legacy.status == errSecAuthFailed {
            throw SecureProfileVaultError
                .legacyKeyMigrationRequired
        }
        guard legacy.status == errSecItemNotFound else {
            throw SecureProfileVaultError.keychain(
                legacy.status
            )
        }

        let key = ProfileVaultCrypto.randomKeyData()
        try addAndVerifyCurrentKey(
            key,
            using: backend
        )
        return key
    }

    static func migrationNeed() throws
        -> AppVaultKeyMigrationNeed {
        try requireLiveKeychain()
        return try migrationNeed(
            using: AppVaultSystemKeychainBackend()
        )
    }

    static func migrationNeed(
        using backend: any AppVaultKeychainBackend
    ) throws -> AppVaultKeyMigrationNeed {
        let current = backend.copyMatching(
            nonInteractiveCurrentPresenceQuery
        )
        let currentExists: Bool
        switch current.status {
        case errSecSuccess:
            currentExists = true
        case errSecItemNotFound:
            currentExists = false
        default:
            throw SecureProfileVaultError.keychain(
                current.status
            )
        }

        let legacy = backend.copyMatching(
            nonInteractiveLegacyPresenceQuery
        )
        let legacyExists: Bool
        switch legacy.status {
        case errSecSuccess,
             errSecInteractionNotAllowed,
             errSecAuthFailed:
            legacyExists = true
        case errSecItemNotFound:
            legacyExists = false
        default:
            throw SecureProfileVaultError.keychain(
                legacy.status
            )
        }
        guard legacyExists else { return .none }
        return currentExists
            ? .cleanupRequired
            : .migrationRequired
    }

    static func migrateLegacyKey() throws
        -> AppVaultKeyMigrationResult {
        try requireLiveKeychain()
        return try migrateLegacyKey(
            using: AppVaultSystemKeychainBackend()
        )
    }

    static func migrateLegacyKey(
        using backend: any AppVaultKeychainBackend
    ) throws -> AppVaultKeyMigrationResult {
        let authorizationContext = LAContext()
        authorizationContext.localizedReason =
            "迁移AI接入助手旧保险箱权限；密码仅由macOS处理"
        let current = backend.copyMatching(
            nonInteractiveLookupQuery
        )
        let currentKey: Data?
        switch current.status {
        case errSecSuccess:
            currentKey = try validatedKey(current.data)
        case errSecItemNotFound:
            currentKey = nil
        default:
            throw SecureProfileVaultError.keychain(
                current.status
            )
        }

        let legacy = backend.copyMatching(
            interactiveLegacyLookupQuery(
                context: authorizationContext
            )
        )
        if legacy.status == errSecItemNotFound {
            return AppVaultKeyMigrationResult(
                copiedLegacyKey: false,
                legacyRemoved: true
            )
        }
        if legacy.status == errSecUserCanceled
            || legacy.status == errSecAuthFailed {
            throw SecureProfileVaultError
                .legacyKeyAuthorizationCancelled
        }
        guard legacy.status == errSecSuccess else {
            throw SecureProfileVaultError.keychain(
                legacy.status
            )
        }
        let legacyKey = try validatedKey(legacy.data)
        if let currentKey {
            guard currentKey == legacyKey else {
                throw SecureProfileVaultError
                    .vaultKeyMigrationConflict
            }
        } else {
            try addAndVerifyCurrentKey(
                legacyKey,
                using: backend
            )
        }

        let verified = backend.copyMatching(
            nonInteractiveLookupQuery
        )
        guard verified.status == errSecSuccess,
              try validatedKey(verified.data) == legacyKey else {
            throw SecureProfileVaultError
                .vaultKeyMigrationVerificationFailed
        }
        let deleteStatus = backend.delete(
            interactiveLegacyDeleteQuery(
                context: authorizationContext
            )
        )
        return AppVaultKeyMigrationResult(
            copiedLegacyKey: currentKey == nil,
            legacyRemoved:
                deleteStatus == errSecSuccess
                || deleteStatus == errSecItemNotFound
        )
    }

    static func delete() throws {
        try requireLiveKeychain()
        let status = AppVaultSystemKeychainBackend().delete(
            nonInteractiveDeleteQuery
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureProfileVaultError.keychain(status)
        }
    }

    static var nonInteractiveLookupQuery: [String: Any] {
        var query = nonInteractiveDeleteQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    /// Startup migration discovery checks only item metadata. Key bytes are
    /// read later by an explicit feature action that needs the vault.
    static var nonInteractiveCurrentPresenceQuery:
        [String: Any] {
        var query = nonInteractiveQuery(baseQuery)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    static var nonInteractiveDeleteQuery: [String: Any] {
        nonInteractiveQuery(baseQuery)
    }

    static var nonInteractiveLegacyPresenceQuery:
        [String: Any] {
        var query = nonInteractiveQuery(legacyBaseQuery)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    private static func interactiveLegacyLookupQuery(
        context: LAContext
    ) -> [String: Any] {
        var query = interactiveQuery(
            legacyBaseQuery,
            context: context
        )
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    private static func interactiveLegacyDeleteQuery(
        context: LAContext
    ) -> [String: Any] {
        interactiveQuery(
            legacyBaseQuery,
            context: context
        )
    }

    private static func nonInteractiveQuery(
        _ base: [String: Any]
    ) -> [String: Any] {
        var query = base
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        // Build86 proved the LAContext flag alone did not suppress a legacy
        // macOS ACL partition prompt. Keep the public Security query key and
        // its documented fail value without referencing the deprecated Swift
        // symbol, so an auth-required lookup returns immediately.
        query[kSecUseAuthenticationUI as String] =
            authenticationUIFailValue
        return query
    }

    private static func interactiveQuery(
        _ base: [String: Any],
        context: LAContext
    ) -> [String: Any] {
        var query = base
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static var legacyBaseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: legacyAccount,
        ]
    }

    private static func addAndVerifyCurrentKey(
        _ key: Data,
        using backend: any AppVaultKeychainBackend
    ) throws {
        var add = baseQuery
        add[kSecValueData as String] = key
        add[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = backend.add(add)
        if status != errSecSuccess
            && status != errSecDuplicateItem {
            throw SecureProfileVaultError.keychain(status)
        }
        let verified = backend.copyMatching(
            nonInteractiveLookupQuery
        )
        guard verified.status == errSecSuccess,
              try validatedKey(verified.data) == key else {
            throw SecureProfileVaultError
                .vaultKeyMigrationVerificationFailed
        }
    }

    private static func validatedKey(
        _ data: Data?
    ) throws -> Data {
        guard let data, data.count == 32 else {
            throw SecureProfileVaultError.invalidVaultKey
        }
        return data
    }

    private static func requireLiveKeychain() throws {
        if ProcessInfo.processInfo.environment[
            "AI_ACCESS_ASSISTANT_TESTING"
        ] == "1" {
            throw SecureProfileVaultError
                .testKeychainAccessBlocked
        }
    }
}

struct SecureProfileVault {
    let rootURL: URL
    let keyProvider: () throws -> Data

    init(rootURL: URL, keyProvider: @escaping () throws -> Data = AppVaultKeyStore.loadOrCreate) {
        self.rootURL = rootURL
        self.keyProvider = keyProvider
    }

    func saveSnapshot(
        profileID: String,
        adapterVersion: String,
        inputs: [SnapshotInput]
    ) throws -> SnapshotManifest {
        try prepareRoot()
        for input in inputs where !Self.isSafeRelativePath(input.relativePath) {
            throw SecureProfileVaultError.invalidRelativePath(input.relativePath)
        }
        let snapshotID = UUID().uuidString
        let manifest = SnapshotManifest(
            id: snapshotID,
            profileID: profileID,
            adapterVersion: adapterVersion,
            createdAt: Date(),
            files: inputs.map {
                SnapshotFileManifest(
                    relativePath: $0.relativePath,
                    sha256: Self.sha256($0.data),
                    byteCount: $0.data.count,
                    permissions: $0.permissions
                )
            }
        )
        let payload = EncryptedSnapshotPayload(files: inputs.map {
            .init(relativePath: $0.relativePath, data: $0.data, permissions: $0.permissions)
        })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(payload)
        let encrypted = try ProfileVaultCrypto.seal(plaintext, keyData: keyProvider())
        let manifestData = try encoder.encode(manifest)
        try encrypted.write(to: encryptedURL(snapshotID), options: .atomic)
        try manifestData.write(to: manifestURL(snapshotID), options: .atomic)
        try setPermissions(encryptedURL(snapshotID), mode: 0o600)
        try setPermissions(manifestURL(snapshotID), mode: 0o600)
        return manifest
    }

    func loadSnapshot(_ manifest: SnapshotManifest) throws -> [SnapshotInput] {
        let url = encryptedURL(manifest.id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SecureProfileVaultError.missingSnapshot
        }
        let plaintext = try ProfileVaultCrypto.open(Data(contentsOf: url), keyData: keyProvider())
        let payload = try JSONDecoder().decode(EncryptedSnapshotPayload.self, from: plaintext)
        let inputs = payload.files.map {
            SnapshotInput(relativePath: $0.relativePath, data: $0.data, permissions: $0.permissions)
        }
        let actual = inputs.map {
            SnapshotFileManifest(
                relativePath: $0.relativePath,
                sha256: Self.sha256($0.data),
                byteCount: $0.data.count,
                permissions: $0.permissions
            )
        }
        guard actual == manifest.files else { throw SecureProfileVaultError.manifestMismatch }
        return inputs
    }

    func deleteSnapshot(_ manifest: SnapshotManifest) throws {
        for url in [encryptedURL(manifest.id), manifestURL(manifest.id)] {
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw SecureProfileVaultError.missingSnapshot
            }
            try FileManager.default.removeItem(at: url)
        }
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("..") && !path.contains("~")
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func prepareRoot() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try setPermissions(rootURL, mode: 0o700)
    }

    private func encryptedURL(_ id: String) -> URL { rootURL.appendingPathComponent("\(id).vault") }
    private func manifestURL(_ id: String) -> URL { rootURL.appendingPathComponent("\(id).manifest.json") }

    private func setPermissions(_ url: URL, mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}

enum SimulatedSwitchPhase: String, Codable, CaseIterable {
    case preflight
    case snapshotCurrent
    case writeRecoveryPoint
    case validateTarget
    case simulateAtomicReplace
    case verify
    case committed
    case rolledBack
}

struct SimulatedSwitchTransaction: Identifiable, Codable, Equatable {
    let id: String
    let fromProfileID: String
    let toProfileID: String
    var phase: SimulatedSwitchPhase
    let startedAt: Date
    var completedAt: Date?
    var message: String
}

struct SwitchJournalStore {
    let fileURL: URL

    func save(_ transaction: SimulatedSwitchTransaction) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(transaction).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func loadPending() throws -> SimulatedSwitchTransaction? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let transaction = try decoder.decode(SimulatedSwitchTransaction.self, from: Data(contentsOf: fileURL))
        return [.committed, .rolledBack].contains(transaction.phase) ? nil : transaction
    }
}

enum SimulatedSwitchError: LocalizedError {
    case injectedFailure(SimulatedSwitchPhase)
    case unsupported

    var errorDescription: String? {
        switch self {
        case let .injectedFailure(phase): return "模拟切换在 \(phase.rawValue) 失败，已回滚"
        case .unsupported: return "当前组合没有安全托管证据"
        }
    }
}

final class SimulatedSwitchEngine {
    private(set) var activeProfileID: String
    private(set) var transaction: SimulatedSwitchTransaction?
    private let journalStore: SwitchJournalStore?

    init(activeProfileID: String, journalStore: SwitchJournalStore? = nil) {
        self.activeProfileID = activeProfileID
        self.journalStore = journalStore
    }

    func switchProfile(
        to targetID: String,
        compatibility: CompatibilityRecord,
        failAt: SimulatedSwitchPhase? = nil
    ) throws -> SimulatedSwitchTransaction {
        guard compatibility.level == .simulation else { throw SimulatedSwitchError.unsupported }
        let original = activeProfileID
        var journal = SimulatedSwitchTransaction(
            id: UUID().uuidString,
            fromProfileID: original,
            toProfileID: targetID,
            phase: .preflight,
            startedAt: Date(),
            completedAt: nil,
            message: "模拟事务进行中；未读取或写入真实配置"
        )
        transaction = journal
        try journalStore?.save(journal)
        do {
            for phase in [
                SimulatedSwitchPhase.preflight,
                .snapshotCurrent,
                .writeRecoveryPoint,
                .validateTarget,
                .simulateAtomicReplace,
                .verify,
            ] {
                journal.phase = phase
                transaction = journal
                try journalStore?.save(journal)
                if failAt == phase { throw SimulatedSwitchError.injectedFailure(phase) }
            }
            activeProfileID = targetID
            journal.phase = .committed
            journal.completedAt = Date()
            journal.message = "模拟切换完成；真实配置零写入"
            transaction = journal
            try journalStore?.save(journal)
            return journal
        } catch {
            activeProfileID = original
            journal.phase = .rolledBack
            journal.completedAt = Date()
            journal.message = error.localizedDescription
            transaction = journal
            try? journalStore?.save(journal)
            throw error
        }
    }

    func pendingRecoveryTransaction() throws -> SimulatedSwitchTransaction? {
        try journalStore?.loadPending()
    }
}
