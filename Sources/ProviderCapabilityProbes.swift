import CryptoKit
import Darwin
import Foundation

enum ProviderProbeTier: String, Codable, Sendable {
    case core
    case optional
}

enum ProviderCapabilityProbeKind:
    String, Codable, CaseIterable, Sendable {
    case configurationSyntax = "configuration_syntax"
    case authentication
    case responsesText = "responses_text"
    case configurationCAS = "configuration_cas"
    case modelCatalog = "model_catalog"
    case serviceTier = "service_tier"
    case webSearchResponses = "web_search_responses"
    case webSearchStandalone = "web_search_standalone"
    case webSearchMCP = "web_search_mcp"
    case webSearchCitations = "web_search_citations"
    case remoteCompaction = "remote_compaction"
    case imageInput = "image_input"
}

enum ProviderProbeCostClass: String, Codable, Sendable {
    case localOnly = "local_only"
    case minimalRequest = "minimal_request"
    case extraBillable = "extra_billable"
}

struct ProviderCapabilityProbePlan: Equatable, Sendable {
    let kind: ProviderCapabilityProbeKind
    let tier: ProviderProbeTier
    let costClass: ProviderProbeCostClass
    let maximumRequests: Int
    let maximumOutputTokens: Int
    let timeoutSeconds: Int
    let requiresExplicitConsent: Bool
    let usesSyntheticInputOnly: Bool

    static let core: [ProviderCapabilityProbePlan] = [
        ProviderCapabilityProbePlan(
            kind: .configurationSyntax,
            tier: .core,
            costClass: .localOnly,
            maximumRequests: 0,
            maximumOutputTokens: 0,
            timeoutSeconds: 5,
            requiresExplicitConsent: false,
            usesSyntheticInputOnly: true
        ),
        ProviderCapabilityProbePlan(
            kind: .authentication,
            tier: .core,
            costClass: .localOnly,
            maximumRequests: 0,
            maximumOutputTokens: 0,
            timeoutSeconds: 5,
            requiresExplicitConsent: false,
            usesSyntheticInputOnly: true
        ),
        ProviderCapabilityProbePlan(
            kind: .responsesText,
            tier: .core,
            costClass: .minimalRequest,
            maximumRequests: 1,
            maximumOutputTokens: 8,
            timeoutSeconds: 20,
            requiresExplicitConsent: false,
            usesSyntheticInputOnly: true
        ),
        ProviderCapabilityProbePlan(
            kind: .configurationCAS,
            tier: .core,
            costClass: .localOnly,
            maximumRequests: 0,
            maximumOutputTokens: 0,
            timeoutSeconds: 5,
            requiresExplicitConsent: false,
            usesSyntheticInputOnly: true
        ),
    ]

    static let optional: [ProviderCapabilityProbePlan] = [
        optionalPlan(.modelCatalog, cost: .minimalRequest),
        optionalPlan(
            .serviceTier,
            cost: .extraBillable,
            consent: true
        ),
        optionalPlan(
            .webSearchResponses,
            cost: .extraBillable,
            consent: true
        ),
        optionalPlan(
            .webSearchStandalone,
            cost: .extraBillable,
            consent: true
        ),
        optionalPlan(.webSearchMCP, cost: .localOnly),
        optionalPlan(
            .webSearchCitations,
            cost: .extraBillable,
            consent: true
        ),
        optionalPlan(
            .remoteCompaction,
            cost: .extraBillable,
            consent: true
        ),
        optionalPlan(
            .imageInput,
            cost: .extraBillable,
            consent: true
        ),
    ]

    private static func optionalPlan(
        _ kind: ProviderCapabilityProbeKind,
        cost: ProviderProbeCostClass,
        consent: Bool = false
    ) -> ProviderCapabilityProbePlan {
        ProviderCapabilityProbePlan(
            kind: kind,
            tier: .optional,
            costClass: cost,
            maximumRequests: cost == .localOnly ? 0 : 1,
            maximumOutputTokens: cost == .localOnly ? 0 : 32,
            timeoutSeconds: cost == .localOnly ? 5 : 30,
            requiresExplicitConsent: consent,
            usesSyntheticInputOnly: true
        )
    }
}

enum ProviderCapabilityOptionalRequestFactory {
    static func make(
        kind: ProviderCapabilityProbeKind,
        modelID: String,
        userConsented: Bool
    ) throws -> Data {
        guard let plan = ProviderCapabilityProbePlan.optional
                .first(where: { $0.kind == kind }),
              [
                  ProviderCapabilityProbeKind.serviceTier,
                  .webSearchResponses,
                  .imageInput,
              ].contains(kind) else {
            throw ProviderCapabilityProbeReceiptError.unknownPlan
        }
        guard !plan.requiresExplicitConsent
                || userConsented else {
            throw ProviderCapabilityProbeReceiptError
                .consentRequired
        }
        let model = modelID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !model.isEmpty,
              model.utf8.count <= 512,
              !model.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw ProviderCapabilityProbeReceiptError
                .invalidIdentity
        }

        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_output_tokens": .integer(
                Int64(plan.maximumOutputTokens)
            ),
        ]
        switch kind {
        case .serviceTier:
            body["input"] = .array([
                .object([
                    "role": .string("user"),
                    "content": .array([
                        .object([
                            "type": .string("input_text"),
                            "text": .string("Reply only FAST_OK."),
                        ]),
                    ]),
                ]),
            ])
            body["service_tier"] = .string("fast")
        case .webSearchResponses:
            body["input"] = .array([
                .object([
                    "role": .string("user"),
                    "content": .array([
                        .object([
                            "type": .string("input_text"),
                            "text": .string(
                                "Find one current public fact. Reply with one sentence and one source."
                            ),
                        ]),
                    ]),
                ]),
            ])
            body["tools"] = .array([
                .object([
                    "type": .string("web_search"),
                    "search_context_size": .string("low"),
                ]),
            ])
            body["tool_choice"] = .string("required")
        case .imageInput:
            body["input"] = .array([
                .object([
                    "role": .string("user"),
                    "content": .array([
                        .object([
                            "type": .string("input_text"),
                            "text": .string(
                                "Reply only IMAGE_OK if the image input was accepted."
                            ),
                        ]),
                        .object([
                            "type": .string("input_image"),
                            "image_url": .string(
                                "data:image/png;base64,"
                                    + SyntheticImageProbeFixture
                                        .onePixelPNG.data
                                        .base64EncodedString()
                            ),
                            "detail": .string("low"),
                        ]),
                    ]),
                ]),
            ])
        default:
            throw ProviderCapabilityProbeReceiptError.unknownPlan
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(JSONValue.object(body))
    }
}

struct ProviderProbeStageObservation:
    Codable, Equatable, Sendable {
    let configured: String?
    let emitted: String?
    let accepted: String?
    let actual: String?
    let fallback: String?
}

enum ProviderProbeEvidenceLevel:
    Int, Codable, Comparable, Sendable {
    case none = 0
    case declared = 1
    case request = 2
    case response = 3
    case fixedContractAndLive = 4

    static func < (
        lhs: ProviderProbeEvidenceLevel,
        rhs: ProviderProbeEvidenceLevel
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct ProviderCapabilityProbeReceipt:
    Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: String
    let kind: ProviderCapabilityProbeKind
    let tier: ProviderProbeTier
    let status: ProviderCapabilityStatus
    let providerID: String
    let profileID: String?
    let capabilityProfileSHA256: String?
    let modelID: String?
    let codexContractID: String
    let transactionID: String
    let observedAt: Date
    let stage: ProviderProbeStageObservation
    let evidenceLevel: ProviderProbeEvidenceLevel
    let responseStructureSHA256: String?
    let evidenceComponents: [String]
    let evidenceSHA256: String
    let requestCount: Int
    let maximumOutputTokens: Int
    let timeoutSeconds: Int
}

enum ProviderCapabilityProbeReceiptError:
    LocalizedError, Equatable {
    case unknownPlan
    case consentRequired
    case invalidIdentity
    case invalidBounds
    case sensitiveEvidence
    case invalidEvidenceHash

    var errorDescription: String? {
        switch self {
        case .unknownPlan:
            return "能力探针没有受管计划"
        case .consentRequired:
            return "该能力探针可能产生额外费用，需用户明确确认"
        case .invalidIdentity:
            return "能力探针缺少Provider、合同或事务标识"
        case .invalidBounds:
            return "能力探针超出请求、token或超时上限"
        case .sensitiveEvidence:
            return "能力探针证据包含敏感正文，已拒绝保存"
        case .invalidEvidenceHash:
            return "能力探针缺少可验证结构hash"
        }
    }
}

enum ProviderCapabilityProbeReceiptFactory {
    static func issue(
        kind: ProviderCapabilityProbeKind,
        status: ProviderCapabilityStatus,
        providerID: String,
        modelID: String?,
        codexContractID: String,
        transactionID: String,
        observedAt: Date,
        stage: ProviderProbeStageObservation,
        evidenceLevel: ProviderProbeEvidenceLevel,
        responseStructureSHA256: String?,
        evidenceComponents: [String],
        requestCount: Int,
        userConsented: Bool,
        containsSensitiveEvidence: Bool,
        profileID: String? = nil,
        capabilityProfileSHA256: String? = nil
    ) throws -> ProviderCapabilityProbeReceipt {
        guard let plan = (
            ProviderCapabilityProbePlan.core
                + ProviderCapabilityProbePlan.optional
        ).first(where: { $0.kind == kind }) else {
            throw ProviderCapabilityProbeReceiptError.unknownPlan
        }
        if plan.requiresExplicitConsent, !userConsented {
            throw ProviderCapabilityProbeReceiptError
                .consentRequired
        }
        let provider = providerID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let contract = codexContractID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let transaction = transactionID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !provider.isEmpty,
              !contract.isEmpty,
              !transaction.isEmpty else {
            throw ProviderCapabilityProbeReceiptError
                .invalidIdentity
        }
        let normalizedProfileID = normalizedOptional(
            profileID
        )
        let normalizedProfileHash = normalizedOptional(
            capabilityProfileSHA256
        )
        if profileID != nil,
           normalizedProfileID == nil {
            throw ProviderCapabilityProbeReceiptError
                .invalidIdentity
        }
        if let normalizedProfileHash,
           !isSHA256(normalizedProfileHash) {
            throw ProviderCapabilityProbeReceiptError
                .invalidEvidenceHash
        }
        guard requestCount >= 0,
              requestCount <= plan.maximumRequests,
              plan.maximumOutputTokens >= 0,
              plan.timeoutSeconds > 0 else {
            throw ProviderCapabilityProbeReceiptError.invalidBounds
        }
        guard !containsSensitiveEvidence else {
            throw ProviderCapabilityProbeReceiptError
                .sensitiveEvidence
        }
        if let responseStructureSHA256,
           !isSHA256(responseStructureSHA256) {
            throw ProviderCapabilityProbeReceiptError
                .invalidEvidenceHash
        }
        let components = evidenceComponents.filter {
            !$0.isEmpty
        }
        guard !components.isEmpty else {
            throw ProviderCapabilityProbeReceiptError
                .invalidEvidenceHash
        }
        let receipt = ProviderCapabilityProbeReceipt(
            schemaVersion:
                ProviderCapabilityProbeReceipt
                    .currentSchemaVersion,
            id: UUID().uuidString,
            kind: kind,
            tier: plan.tier,
            status: status,
            providerID: provider,
            profileID: normalizedProfileID,
            capabilityProfileSHA256:
                normalizedProfileHash,
            modelID: modelID,
            codexContractID: contract,
            transactionID: transaction,
            observedAt: observedAt,
            stage: stage,
            evidenceLevel: evidenceLevel,
            responseStructureSHA256: responseStructureSHA256,
            evidenceComponents: components,
            evidenceSHA256: "",
            requestCount: requestCount,
            maximumOutputTokens: plan.maximumOutputTokens,
            timeoutSeconds: plan.timeoutSeconds
        )
        return ProviderCapabilityProbeReceipt(
            schemaVersion: receipt.schemaVersion,
            id: receipt.id,
            kind: receipt.kind,
            tier: receipt.tier,
            status: receipt.status,
            providerID: receipt.providerID,
            profileID: receipt.profileID,
            capabilityProfileSHA256:
                receipt.capabilityProfileSHA256,
            modelID: receipt.modelID,
            codexContractID: receipt.codexContractID,
            transactionID: receipt.transactionID,
            observedAt: receipt.observedAt,
            stage: receipt.stage,
            evidenceLevel: receipt.evidenceLevel,
            responseStructureSHA256:
                receipt.responseStructureSHA256,
            evidenceComponents:
                receipt.evidenceComponents,
            evidenceSHA256: evidenceSHA256(receipt),
            requestCount: receipt.requestCount,
            maximumOutputTokens:
                receipt.maximumOutputTokens,
            timeoutSeconds: receipt.timeoutSeconds
        )
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func hasValidEvidenceHash(
        _ receipt: ProviderCapabilityProbeReceipt
    ) -> Bool {
        isSHA256(receipt.evidenceSHA256)
            && evidenceSHA256(receipt)
                == receipt.evidenceSHA256
    }

    private static func evidenceSHA256(
        _ receipt: ProviderCapabilityProbeReceipt
    ) -> String {
        var canonicalComponents: [String] = [
            receipt.kind.rawValue,
            receipt.tier.rawValue,
            receipt.status.rawValue,
            receipt.providerID,
            receipt.profileID ?? "",
            receipt.capabilityProfileSHA256 ?? "",
            receipt.modelID ?? "",
            receipt.codexContractID,
            receipt.transactionID,
            ISO8601DateFormatter().string(
                from: receipt.observedAt
            ),
            receipt.stage.configured ?? "",
            receipt.stage.emitted ?? "",
            receipt.stage.accepted ?? "",
            receipt.stage.actual ?? "",
            receipt.stage.fallback ?? "",
            receipt.evidenceLevel.rawValue.description,
            receipt.responseStructureSHA256 ?? "",
            receipt.requestCount.description,
        ]
        canonicalComponents.append(
            contentsOf: receipt.evidenceComponents
        )
        return sha256(
            Data(
                canonicalComponents.joined(
                    separator: "\u{001F}"
                ).utf8
            )
        )
    }

    private static func normalizedOptional(
        _ value: String?
    ) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum ProviderCapabilityProfileIdentity {
    private struct ConfigurationIdentity: Encodable {
        let providerID: String
        let upstreamName: String?
        let baseURL: String
        let wireAPI: String
        let models: [ProviderModelCapability]
        let defaultModel: String
        let modelCatalogPath: String?
        let serviceTier: ProviderServiceTierIntent
        let fastModeEnabled: Bool?
        let remoteCompactionActivation:
            RemoteCompactionActivation
        let remoteCompactionRequiredUpstreamName: String?
        let webSearchConfiguredValue: String?
        let imageInputDeclared: Bool?
        let requiresOpenAIAuth: Bool?
        let responseStorageDisabled: Bool?
        let modelVerbosity: String?
        let supportsWebSockets: Bool?
        let supportsStandaloneWebSearch: Bool?
    }

    static func sha256(
        _ profile: ProviderCapabilityProfile
    ) throws -> String {
        let imageInputDeclared: Bool?
        switch profile.imageInput {
        case .requested, .verified:
            imageInputDeclared = true
        case .unsupported:
            imageInputDeclared = false
        case .unknown, .degraded:
            imageInputDeclared = nil
        }
        let identity = ConfigurationIdentity(
            providerID: profile.providerID,
            upstreamName: profile.upstreamName,
            baseURL: profile.baseURL,
            wireAPI: profile.wireAPI,
            models: profile.models,
            defaultModel: profile.defaultModel,
            modelCatalogPath: profile.modelCatalogPath,
            serviceTier: profile.serviceTier.requested,
            fastModeEnabled: profile.fastModeEnabled,
            remoteCompactionActivation:
                profile.remoteCompaction.activation,
            remoteCompactionRequiredUpstreamName:
                profile.remoteCompaction
                    .requiredUpstreamName,
            webSearchConfiguredValue:
                profile.webSearch.configuredValue,
            imageInputDeclared: imageInputDeclared,
            requiresOpenAIAuth:
                profile.requiresOpenAIAuth,
            responseStorageDisabled:
                profile.responseStorageDisabled,
            modelVerbosity: profile.modelVerbosity,
            supportsWebSockets:
                profile.supportsWebSockets,
            supportsStandaloneWebSearch:
                profile.supportsStandaloneWebSearch
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return ProviderCapabilityProbeReceiptFactory.sha256(
            try encoder.encode(identity)
        )
    }
}

enum ProviderCapabilityProbeEvidenceGate {
    static func latest(
        kind: ProviderCapabilityProbeKind,
        receipts: [ProviderCapabilityProbeReceipt],
        expectedProviderID: String,
        expectedCodexContractID: String,
        expectedProfileID: String? = nil,
        expectedCapabilityProfileSHA256: String? = nil,
        now: Date = Date(),
        maximumAge: TimeInterval = 86_400
    ) -> ProviderCapabilityProbeReceipt? {
        receipts.filter { receipt in
            let profileMatches = expectedProfileID == nil
                || receipt.profileID == expectedProfileID
            let capabilityProfileMatches =
                expectedCapabilityProfileSHA256 == nil
                || receipt.capabilityProfileSHA256
                    == expectedCapabilityProfileSHA256
            guard receipt.schemaVersion
                    == ProviderCapabilityProbeReceipt
                        .currentSchemaVersion,
                  receipt.kind == kind,
                  receipt.providerID == expectedProviderID,
                  receipt.codexContractID
                    == expectedCodexContractID,
                  profileMatches,
                  capabilityProfileMatches,
                  receipt.observedAt <= now,
                  now.timeIntervalSince(receipt.observedAt)
                    <= maximumAge,
                  ProviderCapabilityProbeReceiptFactory
                    .hasValidEvidenceHash(receipt),
                  receipt.responseStructureSHA256.map(
                      ProviderCapabilityProbeReceiptFactory
                        .isSHA256
                  ) != false,
                  let plan = (
                      ProviderCapabilityProbePlan.core
                        + ProviderCapabilityProbePlan.optional
                  ).first(where: { $0.kind == receipt.kind }),
                  receipt.tier == plan.tier,
                  receipt.requestCount >= 0,
                  receipt.requestCount <= plan.maximumRequests,
                  receipt.maximumOutputTokens
                    == plan.maximumOutputTokens,
                  receipt.timeoutSeconds == plan.timeoutSeconds else {
                return false
            }
            return true
        }.max(by: { $0.observedAt < $1.observedAt })
    }

    static func currentReceipts(
        _ receipts: [ProviderCapabilityProbeReceipt],
        expectedProviderID: String,
        expectedCodexContractID: String,
        expectedProfileID: String? = nil,
        expectedCapabilityProfileSHA256: String? = nil,
        now: Date = Date(),
        maximumAge: TimeInterval = 86_400
    ) -> [ProviderCapabilityProbeReceipt] {
        ProviderCapabilityProbeKind.allCases.compactMap {
            latest(
                kind: $0,
                receipts: receipts,
                expectedProviderID: expectedProviderID,
                expectedCodexContractID:
                    expectedCodexContractID,
                expectedProfileID: expectedProfileID,
                expectedCapabilityProfileSHA256:
                    expectedCapabilityProfileSHA256,
                now: now,
                maximumAge: maximumAge
            )
        }
    }
}

struct ProviderCapabilityProbeReceiptDocument:
    Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let receipts: [ProviderCapabilityProbeReceipt]
    let payloadHMACSHA256: String?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        receipts: [ProviderCapabilityProbeReceipt],
        payloadHMACSHA256: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.receipts = receipts
        self.payloadHMACSHA256 = payloadHMACSHA256
    }
}

private struct ProviderCapabilityProbeReceiptPayload:
    Codable, Equatable, Sendable {
    let schemaVersion: Int
    let receipts: [ProviderCapabilityProbeReceipt]
}

enum ProviderCapabilityProbeReceiptStoreError:
    LocalizedError, Equatable {
    case unsafePath
    case payloadTooLarge
    case unsupportedSchema(Int)
    case invalidReceipt
    case sourceChanged
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .unsafePath:
            return "能力探针回执文件不安全"
        case .payloadTooLarge:
            return "能力探针回执文件过大"
        case let .unsupportedSchema(version):
            return "能力探针回执Schema \(version)不受支持"
        case .invalidReceipt:
            return "能力探针回执内容无效"
        case .sourceChanged:
            return "能力探针回执已被其他进程修改"
        case .writeFailed:
            return "能力探针回执无法安全写入"
        }
    }
}

struct ProviderCapabilityProbeReceiptStore {
    static let maximumBytes = 2 * 1_024 * 1_024
    static let maximumReceipts = 256

    let fileURL: URL
    private let fileManager: FileManager
    private let writer: ProviderCapabilityProbeAtomicWriter
    private let keyProvider: @Sendable () throws -> Data

    init(
        fileURL: URL,
        keyProvider: @escaping @Sendable () throws -> Data,
        fileManager: FileManager = .default,
        writer: ProviderCapabilityProbeAtomicWriter =
            ProviderCapabilityProbeAtomicWriter()
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.keyProvider = keyProvider
        self.fileManager = fileManager
        self.writer = writer
    }

    func load() throws -> [ProviderCapabilityProbeReceipt] {
        guard let data = try currentData() else { return [] }
        return try decode(data).receipts
    }

    func append(
        _ newReceipts: [ProviderCapabilityProbeReceipt]
    ) throws {
        guard !newReceipts.isEmpty else { return }
        try validate(newReceipts)
        let current = try currentData()
        if current == nil {
            try migrateLegacyParentPermissionsForFirstWrite()
        }
        let expectedHash = current.map {
            ProviderCapabilityProbeReceiptFactory.sha256($0)
        }
        var merged: [ProviderCapabilityProbeReceipt]
        if let current {
            merged = try decode(current).receipts
        } else {
            merged = []
        }
        let newIDs = Set(newReceipts.map(\.id))
        merged.removeAll { newIDs.contains($0.id) }
        merged.append(contentsOf: newReceipts)
        merged.sort { $0.observedAt < $1.observedAt }
        if merged.count > Self.maximumReceipts {
            merged.removeFirst(
                merged.count - Self.maximumReceipts
            )
        }
        let data = try encodeSignedDocument(receipts: merged)
        guard data.count <= Self.maximumBytes else {
            throw ProviderCapabilityProbeReceiptStoreError
                .payloadTooLarge
        }
        try writer.write(
            data,
            to: fileURL,
            expectedCurrentHash: expectedHash
        )
    }

    private func migrateLegacyParentPermissionsForFirstWrite()
        throws {
        let directory = fileURL.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ProviderCapabilityProbeReceiptStoreError
                .unsafePath
        }
        defer { _ = Darwin.close(descriptor) }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR,
              information.st_uid == geteuid() else {
            throw ProviderCapabilityProbeReceiptStoreError
                .unsafePath
        }
        let permissions = information.st_mode & mode_t(0o777)
        guard permissions == mode_t(0o700)
                || permissions == mode_t(0o755) else {
            throw ProviderCapabilityProbeReceiptStoreError
                .unsafePath
        }
        if permissions == mode_t(0o755) {
            guard Darwin.fchmod(descriptor, mode_t(0o700)) == 0,
                  Darwin.fsync(descriptor) == 0 else {
                throw ProviderCapabilityProbeReceiptStoreError
                    .writeFailed
            }
        }
    }

    private func currentData() throws -> Data? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        try validatePermissions(
            at: fileURL.deletingLastPathComponent(),
            expectedType: S_IFDIR,
            expectedPermissions: 0o700
        )
        try validatePermissions(
            at: fileURL,
            expectedType: S_IFREG,
            expectedPermissions: 0o600
        )
        let values = try fileURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw ProviderCapabilityProbeReceiptStoreError
                .unsafePath
        }
        guard let size = values.fileSize,
              size > 0,
              size <= Self.maximumBytes else {
            throw ProviderCapabilityProbeReceiptStoreError
                .payloadTooLarge
        }
        return try Data(
            contentsOf: fileURL,
            options: .mappedIfSafe
        )
    }

    private func decode(
        _ data: Data
    ) throws -> ProviderCapabilityProbeReceiptDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document: ProviderCapabilityProbeReceiptDocument
        do {
            document = try decoder.decode(
                ProviderCapabilityProbeReceiptDocument.self,
                from: data
            )
        } catch {
            throw ProviderCapabilityProbeReceiptStoreError
                .invalidReceipt
        }
        guard document.schemaVersion
                == ProviderCapabilityProbeReceiptDocument
                    .currentSchemaVersion else {
            throw ProviderCapabilityProbeReceiptStoreError
                .unsupportedSchema(document.schemaVersion)
        }
        guard let payloadHMACSHA256 =
                document.payloadHMACSHA256,
              ProviderCapabilityProbeReceiptFactory
                .isSHA256(payloadHMACSHA256),
              try hasValidDocumentHMAC(document) else {
            throw ProviderCapabilityProbeReceiptStoreError
                .invalidReceipt
        }
        try validate(document.receipts)
        return document
    }

    private func encodeSignedDocument(
        receipts: [ProviderCapabilityProbeReceipt]
    ) throws -> Data {
        let schemaVersion =
            ProviderCapabilityProbeReceiptDocument
                .currentSchemaVersion
        let payload = ProviderCapabilityProbeReceiptPayload(
            schemaVersion: schemaVersion,
            receipts: receipts
        )
        let payloadData = try encode(payload)
        let document = ProviderCapabilityProbeReceiptDocument(
            schemaVersion: schemaVersion,
            receipts: receipts,
            payloadHMACSHA256: try hmacSHA256(payloadData)
        )
        return try encode(document)
    }

    private func encode<Value: Encodable>(
        _ value: Value
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(value)
        } catch {
            throw ProviderCapabilityProbeReceiptStoreError
                .invalidReceipt
        }
    }

    private func hasValidDocumentHMAC(
        _ document: ProviderCapabilityProbeReceiptDocument
    ) throws -> Bool {
        guard let expected = document.payloadHMACSHA256,
              let expectedData = data(fromHex: expected) else {
            return false
        }
        let payload = ProviderCapabilityProbeReceiptPayload(
            schemaVersion: document.schemaVersion,
            receipts: document.receipts
        )
        let payloadData = try encode(payload)
        let keyData = try keyProvider()
        guard keyData.count >= 32 else {
            throw ProviderCapabilityProbeReceiptStoreError
                .invalidReceipt
        }
        return HMAC<SHA256>.isValidAuthenticationCode(
            expectedData,
            authenticating: payloadData,
            using: SymmetricKey(data: keyData)
        )
    }

    private func hmacSHA256(_ data: Data) throws -> String {
        let keyData = try keyProvider()
        guard keyData.count >= 32 else {
            throw ProviderCapabilityProbeReceiptStoreError
                .invalidReceipt
        }
        return Data(
            HMAC<SHA256>.authenticationCode(
                for: data,
                using: SymmetricKey(data: keyData)
            )
        ).map { String(format: "%02x", $0) }.joined()
    }

    private func data(fromHex value: String) -> Data? {
        guard value.count.isMultiple(of: 2) else { return nil }
        var result = Data()
        result.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16)
            else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }

    private func validatePermissions(
        at url: URL,
        expectedType: mode_t,
        expectedPermissions: mode_t
    ) throws {
        var information = stat()
        guard lstat(url.path, &information) == 0,
              information.st_mode & S_IFMT == expectedType,
              information.st_mode & mode_t(0o777)
                == expectedPermissions else {
            throw ProviderCapabilityProbeReceiptStoreError
                .unsafePath
        }
    }

    private func validate(
        _ receipts: [ProviderCapabilityProbeReceipt]
    ) throws {
        guard receipts.count <= Self.maximumReceipts,
              Set(receipts.map(\.id)).count == receipts.count,
              receipts.allSatisfy({ receipt in
                  receipt.schemaVersion
                      == ProviderCapabilityProbeReceipt
                          .currentSchemaVersion
                      && !receipt.id.isEmpty
                      && !receipt.providerID.isEmpty
                      && !receipt.codexContractID.isEmpty
                      && !receipt.transactionID.isEmpty
                      && receipt.profileID.map {
                          !$0.trimmingCharacters(
                              in: .whitespacesAndNewlines
                          ).isEmpty
                      } != false
                      && receipt.capabilityProfileSHA256.map(
                          ProviderCapabilityProbeReceiptFactory
                              .isSHA256
                      ) != false
                      && !receipt.evidenceComponents.isEmpty
                      && ProviderCapabilityProbeReceiptFactory
                          .hasValidEvidenceHash(receipt)
                      && receipt.responseStructureSHA256.map(
                          ProviderCapabilityProbeReceiptFactory
                              .isSHA256
                      ) != false
              }) else {
            throw ProviderCapabilityProbeReceiptStoreError
                .invalidReceipt
        }
    }
}

struct ProviderCapabilityProbeAtomicWriter {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func write(
        _ data: Data,
        to url: URL,
        expectedCurrentHash: String?
    ) throws {
        try validateTarget(url)
        try validateParentIfPresent(
            url.deletingLastPathComponent()
        )
        try verifyCurrentHash(
            url,
            expected: expectedCurrentHash
        )
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let directoryValues = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true,
              permissions(at: directory) == 0o700 else {
            throw ProviderCapabilityProbeReceiptStoreError
                .unsafePath
        }
        let temporary = directory.appendingPathComponent(
            ".provider-probes-\(UUID().uuidString).tmp"
        )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw ProviderCapabilityProbeReceiptStoreError
                .writeFailed
        }
        var removeTemporary = true
        defer {
            _ = close(descriptor)
            if removeTemporary {
                try? fileManager.removeItem(at: temporary)
            }
        }
        do {
            try writeAll(data, descriptor: descriptor)
            guard fchmod(descriptor, mode_t(0o600)) == 0,
                  fsync(descriptor) == 0 else {
                throw ProviderCapabilityProbeReceiptStoreError
                    .writeFailed
            }
            try verifyCurrentHash(
                url,
                expected: expectedCurrentHash
            )
            guard rename(temporary.path, url.path) == 0,
                  chmod(url.path, mode_t(0o600)) == 0 else {
                throw ProviderCapabilityProbeReceiptStoreError
                    .writeFailed
            }
            removeTemporary = false
            let directoryDescriptor = open(
                directory.path,
                O_RDONLY | O_CLOEXEC
            )
            guard directoryDescriptor >= 0 else {
                throw ProviderCapabilityProbeReceiptStoreError
                    .writeFailed
            }
            defer { _ = close(directoryDescriptor) }
            guard fsync(directoryDescriptor) == 0 else {
                throw ProviderCapabilityProbeReceiptStoreError
                    .writeFailed
            }
        } catch let error as
            ProviderCapabilityProbeReceiptStoreError {
            throw error
        } catch {
            throw ProviderCapabilityProbeReceiptStoreError
                .writeFailed
        }
    }

    private func validateTarget(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              permissions(at: url) == 0o600 else {
            throw ProviderCapabilityProbeReceiptStoreError
                .unsafePath
        }
    }

    private func validateParentIfPresent(
        _ directory: URL
    ) throws {
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }
        var information = stat()
        guard lstat(directory.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR,
              information.st_mode & mode_t(0o777) == 0o700 else {
            throw ProviderCapabilityProbeReceiptStoreError
                .unsafePath
        }
    }

    private func permissions(at url: URL) -> mode_t? {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            return nil
        }
        return information.st_mode & mode_t(0o777)
    }

    private func verifyCurrentHash(
        _ url: URL,
        expected: String?
    ) throws {
        let actual: String?
        if fileManager.fileExists(atPath: url.path) {
            actual =
                ProviderCapabilityProbeReceiptFactory.sha256(
                    try Data(contentsOf: url)
                )
        } else {
            actual = nil
        }
        guard actual == expected else {
            throw ProviderCapabilityProbeReceiptStoreError
                .sourceChanged
        }
    }

    private func writeAll(
        _ data: Data,
        descriptor: Int32
    ) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw ProviderCapabilityProbeReceiptStoreError
                        .writeFailed
                }
                offset += count
            }
        }
    }
}

enum ProviderProbeSuiteDecision:
    String, Codable, Equatable, Sendable {
    case allowSwitch = "allow_switch"
    case allowSwitchWithDifferences =
        "allow_switch_with_differences"
    case blockBeforeWrite = "block_before_write"
}

struct ProviderProbeSuiteResult: Equatable, Sendable {
    let decision: ProviderProbeSuiteDecision
    let latestByKind:
        [ProviderCapabilityProbeKind: ProviderCapabilityProbeReceipt]
    let missingOrFailedCore: [ProviderCapabilityProbeKind]
    let optionalDifferences: [ProviderCapabilityProbeKind]
    let permitsAutomaticRollback: Bool

    static func evaluate(
        _ receipts: [ProviderCapabilityProbeReceipt]
    ) -> ProviderProbeSuiteResult {
        let latest = Dictionary(
            grouping: receipts,
            by: \ProviderCapabilityProbeReceipt.kind
        ).compactMapValues { values in
            values.max(by: { $0.observedAt < $1.observedAt })
        }
        let coreKinds = ProviderCapabilityProbePlan.core
            .map(\.kind)
        let optionalKinds = ProviderCapabilityProbePlan.optional
            .map(\.kind)
        let coreFailures = coreKinds.filter {
            latest[$0]?.status != .verified
        }
        let differences = optionalKinds.filter {
            guard let status = latest[$0]?.status else {
                return false
            }
            return status != .verified
        }
        let decision: ProviderProbeSuiteDecision
        if !coreFailures.isEmpty {
            decision = .blockBeforeWrite
        } else if differences.isEmpty {
            decision = .allowSwitch
        } else {
            decision = .allowSwitchWithDifferences
        }
        return ProviderProbeSuiteResult(
            decision: decision,
            latestByKind: latest,
            missingOrFailedCore: coreFailures,
            optionalDifferences: differences,
            permitsAutomaticRollback: false
        )
    }
}

enum ProviderSwitchFailurePoint:
    String, Codable, Equatable, Sendable {
    case preflight
    case beforeWrite = "before_write"
    case afterManagedFieldWrite = "after_managed_field_write"
    case optionalProbe = "optional_probe"
    case externalThirdValue = "external_third_value"
    case stateCache = "state_cache"
}

struct ProviderSwitchRecoveryContext:
    Equatable, Sendable {
    let failurePoint: ProviderSwitchFailurePoint
    let liveWriteOccurred: Bool
    let liveConfigurationUsable: Bool
    let dataIntegrityAtRisk: Bool
    let exactForwardRepairFields: [String]
    let transactionWrittenFields: [String]
    let restorePointCASValid: Bool
}

enum ProviderSwitchRecoveryAction:
    Equatable, Sendable {
    case stopWithoutRollback
    case refreshStateOnly
    case recordOptionalDifference
    case preserveCurrentState
    case applyMinimalForwardRepair([String])
    case freezeForDecision
    case rollbackWrittenFields([String])
}

struct ProviderSwitchRecoveryDecision:
    Equatable, Sendable {
    let action: ProviderSwitchRecoveryAction
    let permitsConfigurationWrite: Bool
    let permitsRollback: Bool
    let showsRecoveryAction: Bool
}

enum ProviderSwitchRecoveryPolicy {
    static func decide(
        _ context: ProviderSwitchRecoveryContext
    ) -> ProviderSwitchRecoveryDecision {
        if context.failurePoint == .externalThirdValue {
            return decision(.freezeForDecision)
        }
        if context.failurePoint == .stateCache {
            return decision(.refreshStateOnly)
        }
        if context.failurePoint == .optionalProbe {
            return decision(.recordOptionalDifference)
        }
        guard context.liveWriteOccurred else {
            return decision(.stopWithoutRollback)
        }
        if context.failurePoint == .preflight
            || context.failurePoint == .beforeWrite {
            return decision(.freezeForDecision)
        }
        let forwardFields = normalizedFields(
            context.exactForwardRepairFields
        )
        if !forwardFields.isEmpty {
            return decision(
                .applyMinimalForwardRepair(forwardFields),
                permitsConfigurationWrite: true,
                showsRecoveryAction: true
            )
        }
        if context.liveConfigurationUsable,
           !context.dataIntegrityAtRisk {
            return decision(.preserveCurrentState)
        }
        let writtenFields = normalizedFields(
            context.transactionWrittenFields
        )
        if context.restorePointCASValid,
           !writtenFields.isEmpty,
           !context.liveConfigurationUsable
                || context.dataIntegrityAtRisk {
            return decision(
                .rollbackWrittenFields(writtenFields),
                permitsConfigurationWrite: true,
                permitsRollback: true,
                showsRecoveryAction: true
            )
        }
        return decision(.freezeForDecision)
    }

    private static func normalizedFields(
        _ fields: [String]
    ) -> [String] {
        var seen = Set<String>()
        return fields.compactMap { value in
            let normalized = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !normalized.isEmpty,
                  seen.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }
    }

    private static func decision(
        _ action: ProviderSwitchRecoveryAction,
        permitsConfigurationWrite: Bool = false,
        permitsRollback: Bool = false,
        showsRecoveryAction: Bool = false
    ) -> ProviderSwitchRecoveryDecision {
        ProviderSwitchRecoveryDecision(
            action: action,
            permitsConfigurationWrite:
                permitsConfigurationWrite,
            permitsRollback: permitsRollback,
            showsRecoveryAction: showsRecoveryAction
        )
    }
}

struct ProviderWebSearchProbeInput: Equatable, Sendable {
    let configuredValue: String?
    let mode: ProviderWebSearchMode
    let supportsStandaloneWebSearch: Bool?
    let responsesToolCallObserved: Bool
    let responsesResultObserved: Bool
    let providerNativeResultObserved: Bool
    let mcpToolCallObserved: Bool
    let mcpResultObserved: Bool
    let citationCount: Int?
    let normalResponsesRequestPassed: Bool
    let evidenceID: String?
}

struct ProviderWebSearchProbeAssessment: Equatable, Sendable {
    let capability: ProviderWebSearchCapability
    let evidenceLevel: ProviderProbeEvidenceLevel
    let normalResponsesRequestIsSearchEvidence: Bool
}

enum ProviderWebSearchProbe {
    static func assess(
        _ input: ProviderWebSearchProbeInput
    ) -> ProviderWebSearchProbeAssessment {
        let configured = normalized(input.configuredValue)
        let configuredForSearch = configured == "live"
            || configured == "indexed"
        var status: ProviderCapabilityStatus = .unknown
        var evidence: ProviderProbeEvidenceLevel = .none
        switch input.mode {
        case .codexLive, .passthrough:
            if configuredForSearch {
                status = .requested
                evidence = .declared
            }
            if configuredForSearch,
               input.responsesToolCallObserved {
                evidence = .request
            }
            if configuredForSearch,
               input.responsesToolCallObserved,
               input.responsesResultObserved {
                status = .verified
                evidence = .response
            }
        case .providerNative:
            if input.supportsStandaloneWebSearch == true {
                status = .requested
                evidence = .declared
            }
            if input.providerNativeResultObserved {
                status = .verified
                evidence = .response
            }
        case .mcp:
            if input.mcpToolCallObserved {
                status = .requested
                evidence = .request
            }
            if input.mcpToolCallObserved,
               input.mcpResultObserved {
                status = .verified
                evidence = .response
            }
        case .unknown:
            break
        }
        let citations: ProviderCapabilityStatus
        if let count = input.citationCount {
            citations = count > 0 ? .verified : (
                status == .verified ? .degraded : .unknown
            )
        } else {
            citations = .unknown
        }
        return ProviderWebSearchProbeAssessment(
            capability: ProviderWebSearchCapability(
                status: status,
                mode: input.mode,
                citations: citations,
                configuredValue: input.configuredValue,
                evidenceID: input.evidenceID
            ),
            evidenceLevel: evidence,
            normalResponsesRequestIsSearchEvidence: false
        )
    }

    private static func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
    }
}

struct CodexRemoteCompactionContract: Equatable, Sendable {
    let contractID: String
    let appVersion: String
    let appBuild: String
    let cliVersion: String
    let cliSHA256: String
    let activationProviderName: String
    let featureName: String
    let evidenceID: String

    static let current6067 = CodexRemoteCompactionContract(
        contractID:
            "codex-remote-compaction-26.727.40816-6067-cli-0.146.0-alpha.9.2-v1",
        appVersion: "26.727.40816",
        appBuild: "6067",
        cliVersion: "0.146.0-alpha.9.2",
        cliSHA256:
            "68474c6192406b8a0278243c8283b87a84798a69fb498f30c3715861f8082542",
        activationProviderName: "OpenAI",
        featureName: "remote_compaction_v2",
        evidenceID: "cli-0.146.0-alpha.9.2-remote-compaction-v2"
    )

    func matches(_ identity: CodexDesktopBuildIdentity) -> Bool {
        appVersion == identity.appVersion
            && appBuild == identity.appBuild
            && cliVersion == identity.cliVersion
            && cliSHA256 == identity.cliSHA256.lowercased()
    }
}

struct CodexRemoteCompactionProbeInput: Equatable, Sendable {
    let identity: CodexDesktopBuildIdentity
    let providerDisplayName: String
    let providerInternalName: String?
    let wireAPI: String
    let isKnownAzureResponses: Bool
    let featureEnabled: Bool?
    let remoteCompactionEventObserved: Bool
    let localAutoCompactTriggered: Bool
}

struct CodexRemoteCompactionProbeAssessment:
    Equatable, Sendable {
    let capability: ProviderRemoteCompactionCapability
    let evidenceLevel: ProviderProbeEvidenceLevel
    let localAutoCompactCountsAsRemoteEvidence: Bool
    let contractMatched: Bool
}

struct CodexRemoteCompactionProbe: Sendable {
    let contracts: [CodexRemoteCompactionContract]

    init(
        contracts: [CodexRemoteCompactionContract] = [
            .current6067,
        ]
    ) {
        self.contracts = contracts
    }

    func assess(
        _ input: CodexRemoteCompactionProbeInput
    ) -> CodexRemoteCompactionProbeAssessment {
        guard let contract = contracts.first(where: {
            $0.matches(input.identity)
        }) else {
            return result(
                status: .unknown,
                activation: .unknown,
                requiredName: nil,
                evidenceID: nil,
                level: .none,
                contractMatched: false
            )
        }
        guard input.wireAPI.lowercased() == "responses" else {
            return result(
                status: .unsupported,
                activation: .unknown,
                requiredName: contract.activationProviderName,
                evidenceID: contract.evidenceID,
                level: .none,
                contractMatched: true
            )
        }
        let activation: RemoteCompactionActivation
        if input.isKnownAzureResponses {
            activation = .endpoint
        } else if input.providerInternalName
                    == contract.activationProviderName {
            activation = .providerName
        } else {
            return result(
                status: .unsupported,
                activation: .providerName,
                requiredName: contract.activationProviderName,
                evidenceID: contract.evidenceID,
                level: .none,
                contractMatched: true
            )
        }
        guard let featureEnabled = input.featureEnabled else {
            return result(
                status: .unknown,
                activation: activation,
                requiredName: contract.activationProviderName,
                evidenceID: contract.evidenceID,
                level: .declared,
                contractMatched: true
            )
        }
        guard featureEnabled else {
            return result(
                status: .unsupported,
                activation: activation,
                requiredName: contract.activationProviderName,
                evidenceID: contract.evidenceID,
                level: .declared,
                contractMatched: true
            )
        }
        return result(
            status: input.remoteCompactionEventObserved
                ? .verified : .requested,
            activation: activation,
            requiredName: contract.activationProviderName,
            evidenceID: contract.evidenceID,
            level: input.remoteCompactionEventObserved
                ? .response : .declared,
            contractMatched: true
        )
    }

    private func result(
        status: ProviderCapabilityStatus,
        activation: RemoteCompactionActivation,
        requiredName: String?,
        evidenceID: String?,
        level: ProviderProbeEvidenceLevel,
        contractMatched: Bool
    ) -> CodexRemoteCompactionProbeAssessment {
        CodexRemoteCompactionProbeAssessment(
            capability: ProviderRemoteCompactionCapability(
                status: status,
                activation: activation,
                requiredUpstreamName: requiredName,
                evidenceID: evidenceID
            ),
            evidenceLevel: level,
            localAutoCompactCountsAsRemoteEvidence: false,
            contractMatched: contractMatched
        )
    }
}

struct SyntheticImageProbeFixture: Equatable, Sendable {
    let mimeType: String
    let pixelWidth: Int
    let pixelHeight: Int
    let data: Data
    let sha256: String
    let prompt: String
    let containsUserData: Bool

    static let onePixelPNG: SyntheticImageProbeFixture = {
        let data = Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        return SyntheticImageProbeFixture(
            mimeType: "image/png",
            pixelWidth: 1,
            pixelHeight: 1,
            data: data,
            sha256:
                ProviderCapabilityProbeReceiptFactory.sha256(data),
            prompt: "Describe the synthetic pixel in one word.",
            containsUserData: false
        )
    }()
}
