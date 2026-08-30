import Darwin
import CryptoKit
import Foundation

enum ManagedModelCatalogSourceKind:
    String, Codable, Sendable {
    case providerModelsEndpoint = "provider_models_endpoint"
    case userFile = "user_file"
    case userConfirmed = "user_confirmed"
    case codexRuntimeCatalog = "codex_runtime_catalog"
    case generatedFixture = "generated_fixture"
}

struct ManagedModelCatalogSource: Codable, Equatable, Sendable {
    let kind: ManagedModelCatalogSourceKind
    let locator: String?
    let evidenceID: String?
}

struct ManagedModelCatalogMetadata:
    Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let providerID: String
    let codexContractID: String
    let source: ManagedModelCatalogSource
    let generatedAt: Date
    let payloadSHA256: String
    let payloadBytes: Int
    let models: [ProviderModelCapability]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        providerID: String,
        codexContractID: String,
        source: ManagedModelCatalogSource,
        generatedAt: Date,
        payloadSHA256: String,
        payloadBytes: Int,
        models: [ProviderModelCapability]
    ) {
        self.schemaVersion = schemaVersion
        self.providerID = providerID
        self.codexContractID = codexContractID
        self.source = source
        self.generatedAt = generatedAt
        self.payloadSHA256 = payloadSHA256
        self.payloadBytes = payloadBytes
        self.models = models
    }
}

struct ManagedModelCatalogReceipt: Equatable, Sendable {
    let catalogURL: URL
    let metadataURL: URL
    let metadata: ManagedModelCatalogMetadata
}

enum ManagedModelCatalogExistingPathState: Equatable, Sendable {
    case absent
    case managed(ManagedModelCatalogReceipt)
    case managedInvalid(URL)
    case externalExisting(URL)
    case externalMissing(URL)
    case unsafe(String)
}

enum ManagedModelCatalogPathChoice:
    String, Codable, Equatable, Sendable {
    case continueExisting = "continue_existing"
    case copyAsManaged = "copy_as_managed"
    case cancel
}

struct ManagedModelCatalogPathProtection:
    Equatable, Sendable {
    let state: ManagedModelCatalogExistingPathState
    let allowedChoices: [ManagedModelCatalogPathChoice]
    let mayOverwriteExistingPath: Bool
}

enum ManagedModelCatalogStoreError:
    LocalizedError, Equatable {
    case invalidProviderID
    case invalidContractID
    case emptyPayload
    case payloadTooLarge
    case invalidPayload
    case emptyModels
    case duplicateModelID(String)
    case invalidModel(String)
    case unsafeRoot
    case unsafePath
    case unsafeFile
    case invalidPermissions
    case unsupportedSchema(Int)
    case metadataMismatch
    case payloadSizeMismatch(expected: Int, actual: Int)
    case modelMetadataMismatch
    case providerDirectoryMismatch
    case payloadHashMismatch
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidProviderID:
            return "模型目录Provider ID无效"
        case .invalidContractID:
            return "模型目录缺少Codex版本合同"
        case .emptyPayload:
            return "模型目录内容为空"
        case .payloadTooLarge:
            return "模型目录超过8 MB，已停止处理"
        case .invalidPayload:
            return "模型目录JSON格式无法识别"
        case .emptyModels:
            return "模型目录没有可识别模型"
        case let .duplicateModelID(model):
            return "模型目录重复定义模型：\(model)"
        case let .invalidModel(model):
            return "模型目录包含无效模型参数：\(model)"
        case .unsafeRoot:
            return "受管模型目录根路径不安全"
        case .unsafePath:
            return "model_catalog_json不是安全绝对路径"
        case .unsafeFile:
            return "模型目录文件不是安全普通文件"
        case .invalidPermissions:
            return "受管模型目录权限不符合0700/0600合同"
        case let .unsupportedSchema(version):
            return "模型目录元数据Schema \(version)不受支持"
        case .metadataMismatch:
            return "模型目录元数据与内容不一致"
        case let .payloadSizeMismatch(expected, actual):
            return "模型目录字节数不一致：元数据\(expected)，实际\(actual)"
        case .modelMetadataMismatch:
            return "模型目录提取结果与元数据不一致"
        case .providerDirectoryMismatch:
            return "模型目录Provider路径与元数据不一致"
        case .payloadHashMismatch:
            return "模型目录内容hash已变化"
        case let .writeFailed(stage):
            return "模型目录写入失败：\(stage)"
        }
    }
}

struct ManagedModelCatalogStore {
    static let maximumPayloadBytes = 8 * 1024 * 1024
    static let maximumMetadataBytes = 2 * 1024 * 1024
    static let maximumModels = 512
    static let maximumValuesPerModel = 64

    let rootURL: URL
    private let fileManager: FileManager
    private let writer: ManagedModelCatalogAtomicWriter
    private let revisionID: () -> String

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        writer: ManagedModelCatalogAtomicWriter =
            ManagedModelCatalogAtomicWriter(),
        revisionID: @escaping () -> String = {
            UUID().uuidString.lowercased()
        }
    ) {
        self.rootURL = URL(
            fileURLWithPath:
                rootURL.standardizedFileURL.path,
            isDirectory: true
        )
        self.fileManager = fileManager
        self.writer = writer
        self.revisionID = revisionID
    }

    func save(
        providerID: String,
        payload: Data,
        codexContractID: String,
        source: ManagedModelCatalogSource,
        generatedAt: Date = Date()
    ) throws -> ManagedModelCatalogReceipt {
        let provider = try validatedProviderID(providerID)
        let contract = codexContractID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !contract.isEmpty,
              contract.utf8.count <= 512,
              !containsControlCharacter(contract) else {
            throw ManagedModelCatalogStoreError.invalidContractID
        }
        let models = try parseModels(payload)
        let payloadHash = Self.sha256(payload)
        let metadata = ManagedModelCatalogMetadata(
            providerID: provider,
            codexContractID: contract,
            source: source,
            generatedAt: generatedAt,
            payloadSHA256: payloadHash,
            payloadBytes: payload.count,
            models: models
        )
        let metadataData = try encode(metadata)

        try ensureRoot()
        let providerDirectory = rootURL.appendingPathComponent(
            providerDirectoryName(provider),
            isDirectory: true
        )
        try ensurePrivateDirectory(providerDirectory)
        let revision = try validatedRevisionID(revisionID())
        let revisionDirectory = providerDirectory
            .appendingPathComponent(
                "revision-\(revision)",
                isDirectory: true
            )
        guard !fileManager.fileExists(
            atPath: revisionDirectory.path
        ) else {
            throw ManagedModelCatalogStoreError
                .writeFailed("revision_exists")
        }
        try ensurePrivateDirectory(revisionDirectory)
        let catalogURL = revisionDirectory.appendingPathComponent(
            "catalog.json",
            isDirectory: false
        )
        let metadataURL = revisionDirectory.appendingPathComponent(
            "catalog.metadata.json",
            isDirectory: false
        )
        do {
            try writer.write(payload, to: catalogURL)
        } catch {
            throw ManagedModelCatalogStoreError
                .writeFailed("catalog")
        }
        do {
            try writer.write(metadataData, to: metadataURL)
        } catch {
            throw ManagedModelCatalogStoreError
                .writeFailed("metadata")
        }
        return try load(catalogURL: catalogURL)
    }

    func copyAsManaged(
        from externalURL: URL,
        providerID: String,
        codexContractID: String,
        source: ManagedModelCatalogSource,
        generatedAt: Date = Date()
    ) throws -> ManagedModelCatalogReceipt {
        let url = externalURL.standardizedFileURL
        guard url.path.hasPrefix("/"),
              !isInsideManagedRoot(url) else {
            throw ManagedModelCatalogStoreError.unsafePath
        }
        try requireSafeRegularFile(url)
        let data = try boundedData(
            at: url,
            maximumBytes: Self.maximumPayloadBytes
        )
        return try save(
            providerID: providerID,
            payload: data,
            codexContractID: codexContractID,
            source: source,
            generatedAt: generatedAt
        )
    }

    func load(
        catalogURL: URL
    ) throws -> ManagedModelCatalogReceipt {
        let catalog = catalogURL.standardizedFileURL
        guard isInsideManagedRoot(catalog),
              catalog.lastPathComponent == "catalog.json" else {
            throw ManagedModelCatalogStoreError.unsafePath
        }
        let revisionDirectory = catalog
            .deletingLastPathComponent()
        let providerDirectory = revisionDirectory
            .deletingLastPathComponent()
        try requirePrivateDirectory(rootURL)
        try requirePrivateDirectory(providerDirectory)
        try requirePrivateDirectory(revisionDirectory)
        try requireSafeRegularFile(catalog)
        let metadataURL = revisionDirectory.appendingPathComponent(
            "catalog.metadata.json",
            isDirectory: false
        )
        try requireSafeRegularFile(metadataURL)
        try requirePermissions(catalog, expected: 0o600)
        try requirePermissions(metadataURL, expected: 0o600)
        let payload = try boundedData(
            at: catalog,
            maximumBytes: Self.maximumPayloadBytes
        )
        let metadataData = try boundedData(
            at: metadataURL,
            maximumBytes: Self.maximumMetadataBytes
        )
        let metadata: ManagedModelCatalogMetadata
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            metadata = try decoder.decode(
                ManagedModelCatalogMetadata.self,
                from: metadataData
            )
        } catch {
            throw ManagedModelCatalogStoreError.invalidPayload
        }
        guard metadata.schemaVersion
                == ManagedModelCatalogMetadata
                    .currentSchemaVersion else {
            throw ManagedModelCatalogStoreError.unsupportedSchema(
                metadata.schemaVersion
            )
        }
        guard metadata.payloadBytes == payload.count else {
            throw ManagedModelCatalogStoreError.payloadSizeMismatch(
                expected: metadata.payloadBytes,
                actual: payload.count
            )
        }
        guard metadata.payloadSHA256
                == Self.sha256(payload) else {
            throw ManagedModelCatalogStoreError.payloadHashMismatch
        }
        let parsedModels = try parseModels(payload)
        guard parsedModels == metadata.models else {
            throw ManagedModelCatalogStoreError
                .modelMetadataMismatch
        }
        guard providerDirectory.lastPathComponent
                == providerDirectoryName(metadata.providerID) else {
            throw ManagedModelCatalogStoreError
                .providerDirectoryMismatch
        }
        return ManagedModelCatalogReceipt(
            catalogURL: catalog,
            metadataURL: metadataURL,
            metadata: metadata
        )
    }

    func protection(
        for existingPath: String?
    ) -> ManagedModelCatalogPathProtection {
        let state = existingPathState(existingPath)
        let choices: [ManagedModelCatalogPathChoice]
        switch state {
        case .externalExisting:
            choices = [
                .continueExisting,
                .copyAsManaged,
                .cancel,
            ]
        case .managed:
            choices = [.continueExisting, .cancel]
        case .absent:
            choices = [.copyAsManaged, .cancel]
        case .managedInvalid, .externalMissing, .unsafe:
            choices = [.cancel]
        }
        return ManagedModelCatalogPathProtection(
            state: state,
            allowedChoices: choices,
            mayOverwriteExistingPath: false
        )
    }

    func existingPathState(
        _ path: String?
    ) -> ManagedModelCatalogExistingPathState {
        guard let path else { return .absent }
        let trimmed = path.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty,
              trimmed.hasPrefix("/"),
              trimmed.utf8.count <= Int(PATH_MAX),
              !containsControlCharacter(trimmed) else {
            return .unsafe("invalid_absolute_path")
        }
        let url = URL(fileURLWithPath: trimmed)
            .standardizedFileURL
        if isInsideManagedRoot(url) {
            do {
                return .managed(try load(catalogURL: url))
            } catch {
                return .managedInvalid(url)
            }
        }
        guard fileManager.fileExists(atPath: url.path) else {
            return .externalMissing(url)
        }
        do {
            try requireSafeRegularFile(url)
            return .externalExisting(url)
        } catch {
            return .unsafe("external_file_not_regular")
        }
    }

    func parseModels(
        _ payload: Data
    ) throws -> [ProviderModelCapability] {
        guard !payload.isEmpty else {
            throw ManagedModelCatalogStoreError.emptyPayload
        }
        guard payload.count <= Self.maximumPayloadBytes else {
            throw ManagedModelCatalogStoreError.payloadTooLarge
        }
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(
                JSONValue.self,
                from: payload
            )
        } catch {
            throw ManagedModelCatalogStoreError.invalidPayload
        }
        guard case let .object(object) = root,
              let rawModels = array(
                  object["models"] ?? object["data"]
              ),
              !rawModels.isEmpty,
              rawModels.count <= Self.maximumModels else {
            throw ManagedModelCatalogStoreError.invalidPayload
        }
        var seen = Set<String>()
        var models: [ProviderModelCapability] = []
        for raw in rawModels {
            guard case let .object(model) = raw,
                  let modelID = firstString(
                      model,
                      keys: ["slug", "id", "model", "name"]
                  ),
                  isSafeMetadataString(
                      modelID,
                      maximumUTF8Count: 512
                  ) else {
                throw ManagedModelCatalogStoreError.invalidPayload
            }
            guard seen.insert(modelID).inserted else {
                throw ManagedModelCatalogStoreError
                    .duplicateModelID(modelID)
            }
            let context = firstInteger(
                model,
                keys: ["context_window", "contextWindow"]
            )
            let compact = firstInteger(
                model,
                keys: [
                    "auto_compact_token_limit",
                    "model_auto_compact_token_limit",
                    "autoCompactTokenLimit",
                ]
            )
            if let context, context <= 0 {
                throw ManagedModelCatalogStoreError
                    .invalidModel(modelID)
            }
            if let compact,
               compact <= 0
                || context == nil
                || compact >= context! {
                throw ManagedModelCatalogStoreError
                    .invalidModel(modelID)
            }
            let serviceTiers = uniqueStrings(
                values(
                    model,
                    keys: [
                        "service_tiers",
                        "serviceTiers",
                        "additional_speed_tiers",
                        "additionalSpeedTiers",
                    ],
                    objectKeys: [
                        "id", "value", "tier", "name",
                    ]
                )
            )
            let reasoningEfforts = uniqueStrings(
                values(
                    model,
                    keys: [
                        "reasoning_efforts",
                        "reasoningEfforts",
                        "supported_reasoning_levels",
                        "supportedReasoningLevels",
                    ],
                    objectKeys: [
                        "id",
                        "value",
                        "effort",
                        "reasoning_effort",
                    ]
                )
            )
            let inputModalities = uniqueStrings(
                values(
                    model,
                    keys: [
                        "input_modalities",
                        "inputModalities",
                    ],
                    objectKeys: ["type", "id", "value"]
                )
            )
            let defaultServiceTier = firstString(
                model,
                keys: [
                    "default_service_tier",
                    "defaultServiceTier",
                ]
            )
            let boundedValues = [
                serviceTiers,
                reasoningEfforts,
                inputModalities,
            ]
            let defaultServiceTierIsValid =
                defaultServiceTier == nil
                || isSafeMetadataString(
                    defaultServiceTier!,
                    maximumUTF8Count: 256
                )
            guard boundedValues.allSatisfy({ values in
                values.count <= Self.maximumValuesPerModel
                    && values.allSatisfy {
                        isSafeMetadataString(
                            $0,
                            maximumUTF8Count: 256
                        )
                    }
            }),
            defaultServiceTierIsValid else {
                throw ManagedModelCatalogStoreError
                    .invalidModel(modelID)
            }
            models.append(
                ProviderModelCapability(
                    modelID: modelID,
                    contextWindow: context,
                    localAutoCompactLimit: compact,
                    serviceTiers: serviceTiers,
                    defaultServiceTier:
                        defaultServiceTier,
                    reasoningEfforts:
                        reasoningEfforts,
                    inputModalities: inputModalities
                )
            )
        }
        guard !models.isEmpty else {
            throw ManagedModelCatalogStoreError.emptyModels
        }
        return models
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(value)
        } catch {
            throw ManagedModelCatalogStoreError.invalidPayload
        }
    }

    private func validatedProviderID(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 512,
              !containsControlCharacter(trimmed) else {
            throw ManagedModelCatalogStoreError.invalidProviderID
        }
        return trimmed
    }

    private func validatedRevisionID(_ value: String) throws -> String {
        let normalized = value.lowercased()
        guard !normalized.isEmpty,
              normalized.utf8.count <= 128,
              normalized.utf8.allSatisfy({ byte in
                  (48...57).contains(byte)
                      || (97...122).contains(byte)
                      || byte == 45
              }) else {
            throw ManagedModelCatalogStoreError
                .writeFailed("revision_id")
        }
        return normalized
    }

    private func providerDirectoryName(_ providerID: String) -> String {
        let digest = Self.sha256(
            Data(providerID.utf8)
        )
        return "provider-\(digest.prefix(32))"
    }

    private func ensureRoot() throws {
        do {
            try ensurePrivateDirectory(rootURL)
        } catch let error as ManagedModelCatalogStoreError {
            throw error
        } catch {
            throw ManagedModelCatalogStoreError.unsafeRoot
        }
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else {
                throw ManagedModelCatalogStoreError.unsafeRoot
            }
        } else {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        guard chmod(url.path, mode_t(0o700)) == 0 else {
            throw ManagedModelCatalogStoreError.invalidPermissions
        }
        try requirePermissions(url, expected: 0o700)
    }

    private func requirePrivateDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw ManagedModelCatalogStoreError.unsafeRoot
        }
        try requirePermissions(url, expected: 0o700)
    }

    private func requireSafeRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw ManagedModelCatalogStoreError.unsafeFile
        }
    }

    private func requirePermissions(
        _ url: URL,
        expected: Int
    ) throws {
        let attributes = try fileManager.attributesOfItem(
            atPath: url.path
        )
        guard let permissions = attributes[.posixPermissions]
                as? NSNumber,
              permissions.intValue & 0o777 == expected else {
            throw ManagedModelCatalogStoreError.invalidPermissions
        }
    }

    private func boundedData(
        at url: URL,
        maximumBytes: Int
    ) throws -> Data {
        let attributes = try fileManager.attributesOfItem(
            atPath: url.path
        )
        guard let size = attributes[.size] as? NSNumber,
              size.intValue > 0,
              size.intValue <= maximumBytes else {
            throw sizeIsTooLarge(attributes)
                ? ManagedModelCatalogStoreError.payloadTooLarge
                : ManagedModelCatalogStoreError.emptyPayload
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func sizeIsTooLarge(
        _ attributes: [FileAttributeKey: Any]
    ) -> Bool {
        (attributes[.size] as? NSNumber)?.intValue ?? 0
            > Self.maximumPayloadBytes
    }

    private func isInsideManagedRoot(_ url: URL) -> Bool {
        let rootPath = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath + "/")
    }

    private func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        })
    }

    private func isSafeMetadataString(
        _ value: String,
        maximumUTF8Count: Int
    ) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumUTF8Count
            && !containsControlCharacter(value)
    }

    private func array(_ value: JSONValue?) -> [JSONValue]? {
        guard case let .array(values)? = value else { return nil }
        return values
    }

    private func firstString(
        _ object: [String: JSONValue],
        keys: [String]
    ) -> String? {
        for key in keys {
            guard case let .string(value)? = object[key] else {
                continue
            }
            let trimmed = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private func firstInteger(
        _ object: [String: JSONValue],
        keys: [String]
    ) -> Int? {
        for key in keys {
            switch object[key] {
            case let .integer(value):
                guard value >= Int64(Int.min),
                      value <= Int64(Int.max) else { return nil }
                return Int(value)
            case let .number(value):
                guard value.isFinite,
                      value.rounded() == value,
                      value >= Double(Int.min),
                      value <= Double(Int.max) else { return nil }
                return Int(value)
            default:
                continue
            }
        }
        return nil
    }

    private func values(
        _ object: [String: JSONValue],
        keys: [String],
        objectKeys: [String]
    ) -> [String] {
        for key in keys {
            guard case let .array(items)? = object[key] else {
                continue
            }
            return items.compactMap { item in
                switch item {
                case let .string(value):
                    let trimmed = value.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    return trimmed.isEmpty ? nil : trimmed
                case let .object(itemObject):
                    return firstString(
                        itemObject,
                        keys: objectKeys
                    )
                default:
                    return nil
                }
            }
        }
        return []
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

struct ManagedModelCatalogAtomicWriter {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func write(_ data: Data, to url: URL) throws {
        guard !fileManager.fileExists(atPath: url.path) else {
            throw ManagedModelCatalogStoreError
                .writeFailed("target_exists")
        }
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".ai-access-model-catalog-\(UUID().uuidString).tmp"
        )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw ManagedModelCatalogStoreError
                .writeFailed("open_\(errno)")
        }
        var removeTemporary = true
        defer {
            _ = close(descriptor)
            if removeTemporary {
                _ = unlink(temporary.path)
            }
        }
        try writeAll(data, descriptor: descriptor)
        guard fchmod(descriptor, mode_t(0o600)) == 0,
              fsync(descriptor) == 0 else {
            throw ManagedModelCatalogStoreError
                .writeFailed("sync_\(errno)")
        }
        guard !fileManager.fileExists(atPath: url.path),
              link(temporary.path, url.path) == 0 else {
            throw ManagedModelCatalogStoreError
                .writeFailed("publish_\(errno)")
        }
        guard unlink(temporary.path) == 0 else {
            throw ManagedModelCatalogStoreError
                .writeFailed("unlink_\(errno)")
        }
        removeTemporary = false
        guard chmod(url.path, mode_t(0o600)) == 0 else {
            throw ManagedModelCatalogStoreError
                .writeFailed("chmod_\(errno)")
        }
        try synchronizeDirectory(directory)
    }

    private func writeAll(
        _ data: Data,
        descriptor: Int32
    ) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ManagedModelCatalogStoreError
                        .writeFailed("write_\(errno)")
                }
                guard count > 0 else {
                    throw ManagedModelCatalogStoreError
                        .writeFailed("write_\(EIO)")
                }
                offset += count
            }
        }
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = open(
            directory.path,
            O_RDONLY | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ManagedModelCatalogStoreError
                .writeFailed("directory_open_\(errno)")
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw ManagedModelCatalogStoreError
                .writeFailed("directory_sync_\(errno)")
        }
    }
}
