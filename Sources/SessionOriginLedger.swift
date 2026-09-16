// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct V011SessionOriginRecord: Codable, Equatable {
    let profileID: String?
    let label: String
    let firstObservedAt: Date
}

struct V011SessionOriginLedgerPayload: Codable, Equatable {
    var initializedAt: Date?
    var records: [String: V011SessionOriginRecord]

    static let empty = V011SessionOriginLedgerPayload(
        initializedAt: nil,
        records: [:]
    )
}

enum V011SessionOriginLedgerError: LocalizedError {
    case unsafePath
    case invalidKey
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .unsafePath:
            return "历史来源记录目录不安全，已停止写入"
        case .invalidKey:
            return "历史来源记录无法加密"
        case .invalidPayload:
            return "历史来源记录无法安全读取"
        }
    }
}

struct V011SessionOriginLedgerStore {
    let rootURL: URL
    let keyProvider: () throws -> Data
    private let fileManager = FileManager.default

    func load() throws -> V011SessionOriginLedgerPayload {
        let url = fileURL
        guard fileManager.fileExists(atPath: url.path) else {
            return .empty
        }
        try validateRoot(createIfMissing: false)
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw V011SessionOriginLedgerError.unsafePath
        }
        let key = try keyProvider()
        guard key.count == 32 else {
            throw V011SessionOriginLedgerError.invalidKey
        }
        do {
            let plaintext = try ProfileVaultCrypto.open(
                Data(contentsOf: url),
                keyData: key
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(
                V011SessionOriginLedgerPayload.self,
                from: plaintext
            )
        } catch let error as V011SessionOriginLedgerError {
            throw error
        } catch {
            throw V011SessionOriginLedgerError.invalidPayload
        }
    }

    func save(_ payload: V011SessionOriginLedgerPayload) throws {
        try validateRoot(createIfMissing: true)
        let key = try keyProvider()
        guard key.count == 32 else {
            throw V011SessionOriginLedgerError.invalidKey
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let encrypted = try ProfileVaultCrypto.seal(
            encoder.encode(payload),
            keyData: key
        )
        try encrypted.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    var fileURL: URL {
        rootURL.appendingPathComponent("ledger.vault")
    }

    private func validateRoot(createIfMissing: Bool) throws {
        if fileManager.fileExists(atPath: rootURL.path) {
            let values = try rootURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else {
                throw V011SessionOriginLedgerError.unsafePath
            }
        } else if createIfMissing {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } else {
            return
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootURL.path
        )
    }
}

enum V011SessionOriginLedgerBuilder {
    static func merge(
        sessions: [SessionCoreSession],
        into payload: V011SessionOriginLedgerPayload,
        knownProfilesByProvider: [String: (id: String, name: String)],
        now: Date = Date()
    ) -> V011SessionOriginLedgerPayload {
        var result = payload
        let isInitialCapture = payload.initializedAt == nil
        for session in sessions
            where result.records[session.id] == nil {
            let origin: V011SessionOriginRecord
            if session.currentProvider == "openai" {
                origin = V011SessionOriginRecord(
                    profileID: "official",
                    label: "官方",
                    firstObservedAt: now
                )
            } else if !isInitialCapture,
                      let profile = knownProfilesByProvider[
                          session.currentProvider
                      ] {
                origin = V011SessionOriginRecord(
                    profileID: profile.id,
                    label: profile.name,
                    firstObservedAt: now
                )
            } else {
                origin = V011SessionOriginRecord(
                    profileID: nil,
                    label: "历史来源未知",
                    firstObservedAt: now
                )
            }
            result.records[session.id] = origin
        }
        return result
    }
}

struct V011SessionRow: Identifiable, Equatable {
    let id: String
    let title: String
    let originProfileID: String?
    let originLabel: String
    let currentProvider: String
    let createdAt: Date?
    let updatedAt: Date?
    let workingDirectory: String
    let archived: Bool
    let rolloutPath: String

    init(
        session: SessionCoreSession,
        origin: V011SessionOriginRecord?
    ) {
        id = session.id
        title = session.title.isEmpty
            ? "未命名会话" : session.title
        originProfileID = origin?.profileID
        originLabel = origin?.label
            ?? "历史来源未知"
        currentProvider = session.currentProvider
        createdAt = Self.date(session.createdAt)
        updatedAt = Self.date(session.updatedAt)
        workingDirectory = session.cwd
        archived = session.archived
        rolloutPath = session.rolloutPath
    }

    private static func date(
        _ value: SessionCoreJSONValue
    ) -> Date? {
        switch value {
        case let .string(raw):
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [
                .withInternetDateTime,
                .withFractionalSeconds,
            ]
            return fractional.date(from: raw)
                ?? ISO8601DateFormatter().date(from: raw)
        case let .number(raw):
            let seconds = raw > 10_000_000_000
                ? raw / 1_000 : raw
            return Date(timeIntervalSince1970: seconds)
        case .bool, .object, .array, .null:
            return nil
        }
    }
}

extension CodexRelayProfile {
    var v011ProviderID: String {
        providerID
            ?? PreservingTOMLEditor.providerIdentifier(id)
    }

    var v011CredentialReference: String {
        "relay/\(id)"
    }

    var fableProfile: RelayProfile {
        let capability = capabilityProfile
        let modelCapability = capability?.models.first {
            $0.modelID == defaultModel
        }
        let preset = additionalFields["cpaManagedCapture"] == .bool(true) ? nil : Self.recommendedGPT56Limits(
            for: defaultModel
        )
        let resolvedContextWindow = contextWindow
            ?? modelCapability?.contextWindow
            ?? preset?.contextWindow
        let resolvedAutoCompactTokenLimit =
            autoCompactTokenLimit
            ?? modelCapability?.localAutoCompactLimit
            ?? (
                contextWindow == nil
                    && modelCapability?.contextWindow == nil
                    ? preset?.autoCompactTokenLimit
                    : nil
            )
        return RelayProfile(
            id: id,
            providerID: v011ProviderID,
            displayName: name,
            baseURL: baseURL,
            model: defaultModel,
            contextWindow: resolvedContextWindow,
            autoCompactTokenLimit:
                resolvedAutoCompactTokenLimit,
            reasoningEffort:
                reasoningEffort.v011ConfigurationValue,
            credentialReference:
                v011CredentialReference,
            requiresOpenAIAuth:
                additionalFields["cpaManagedCapture"] == .bool(true) ? false : (capability?.requiresOpenAIAuth ?? true),
            upstreamName: capability?.upstreamName,
            modelVerbosity:
                capability?.modelVerbosity.map {
                    .set($0)
                } ?? .preserve,
            serviceTier:
                Self.serviceTierIntent(capability),
            modelCatalogJSON:
                capability?.modelCatalogPath.map {
                    .set($0)
                } ?? .preserve,
            webSearch:
                capability?.webSearch.configuredValue.map {
                    .set($0)
                } ?? .preserve,
            disableResponseStorage:
                capability?.responseStorageDisabled.map {
                    .set($0)
                } ?? .preserve,
            fastMode:
                Self.fastModeIntent(capability),
            supportsWebSockets:
                capability?.supportsWebSockets.map {
                    .set($0)
                } ?? .preserve,
            supportsStandaloneWebSearch:
                capability?.supportsStandaloneWebSearch.map {
                    .set($0)
                } ?? .preserve,
            localGatewayConfirmed: localGatewayConfirmed == true
        )
    }

    private static func serviceTierIntent(
        _ capability: ProviderCapabilityProfile?
    ) -> FableFieldIntent<String> {
        if capability?.serviceTier.requested.kind
            == .followCodex {
            return .remove
        }
        guard let configured = capability?
                .serviceTier.requested.configuredValue else {
            return .preserve
        }
        return .set(configured)
    }

    private static func fastModeIntent(
        _ capability: ProviderCapabilityProfile?
    ) -> FableFieldIntent<Bool> {
        if let explicit = capability?.fastModeEnabled {
            return .set(explicit)
        }
        guard let kind = capability?
                .serviceTier.requested.kind else {
            return .preserve
        }
        switch kind {
        case .fast:
            return .set(true)
        case .standard, .flex:
            return .set(false)
        case .followCodex:
            return .remove
        case .inherit, .providerSpecific:
            return .preserve
        }
    }

    private struct RecommendedLimits {
        let contextWindow: Int
        let autoCompactTokenLimit: Int
    }

    private static func recommendedGPT56Limits(
        for modelID: String
    ) -> RecommendedLimits? {
        let normalized = modelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized == "gpt-5.6"
                || normalized.hasPrefix("gpt-5.6-") else {
            return nil
        }
        return RecommendedLimits(
            contextWindow: 272_000,
            autoCompactTokenLimit: 258_000
        )
    }
}

private extension ReasoningEffort {
    var v011ConfigurationValue: String {
        switch self {
        case .automatic, .medium:
            return "medium"
        case .low:
            return "low"
        case .high:
            return "high"
        case .xhigh:
            return "xhigh"
        case .max:
            return "max"
        case .ultra:
            return "ultra"
        }
    }
}
