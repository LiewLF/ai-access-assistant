import Darwin
import Foundation

enum FableSwitchError: LocalizedError, Equatable {
    case invalidProfile(String)
    case invalidConfiguration(String)
    case unsupportedVersion
    case sourceChanged
    case unmanagedProvider(String)
    case officialRootOverlayUnavailable
    case credentialUnavailable
    case unsafeConfigFile
    case atomicWriteFailed(Int32)
    case managedRecoveryConflict
    case verificationFailedAndRolledBack
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case let .invalidProfile(reason):
            return "中转资料无效：\(reason)"
        case let .invalidConfiguration(reason):
            return "Codex配置无法安全处理：\(reason)"
        case .unsupportedVersion:
            return "当前Codex版本未通过兼容验证，只允许查看，不允许切换"
        case .sourceChanged:
            return "Codex配置已被其他程序修改，本次切换未执行"
        case let .unmanagedProvider(providerID):
            return "当前中转“\(providerID)”尚未由AI接入助手接管。请先选择“接管并保持现状”，再切换模式"
        case .officialRootOverlayUnavailable:
            return "尚未保存可信的官方模型设置。为避免用中转值覆盖官方设置，本次不会切换；请先用原来的方式切回官方，再由AI接入助手建立恢复信息"
        case .credentialUnavailable:
            return "未找到该中转的本机凭据，请重新输入API Key"
        case .unsafeConfigFile:
            return "Codex配置文件不是安全的普通文件，本次切换未执行"
        case .atomicWriteFailed:
            return "Codex配置无法安全写入，本次切换未完成"
        case .managedRecoveryConflict:
            return "本事务管理的Codex设置已被改成第三个值，已停止自动恢复"
        case .verificationFailedAndRolledBack:
            return "目标模式验证失败，已恢复切换前配置"
        case .rollbackFailed:
            return "目标模式验证失败，自动恢复也未完成；请使用恢复入口"
        }
    }
}

struct CodexVersionIdentity: Equatable {
    let appVersion: String
    let appBuild: String
    let cliVersion: String
}

struct CodexVersionContract: Equatable {
    struct Entry: Equatable {
        let schemaID: String
        let appVersion: String
        let appBuild: String
        let cliVersion: String

        func matches(_ identity: CodexVersionIdentity) -> Bool {
            identity.appVersion == appVersion
                && identity.appBuild == appBuild
                && identity.cliVersion == cliVersion
        }
    }

    static let verified = CodexVersionContract(
        entries: [
            Entry(
                schemaID: "fable-codex-26.715.31925-5551-cli-0.145.0-alpha.18-v1",
                appVersion: "26.715.31925",
                appBuild: "5551",
                cliVersion: "0.145.0-alpha.18"
            ),
            Entry(
                schemaID: "fable-codex-26.715.52143-5591-cli-0.145.0-alpha.18-v1",
                appVersion: "26.715.52143",
                appBuild: "5591",
                cliVersion: "0.145.0-alpha.18"
            ),
        ]
    )

    /// A stable managed-field schema family. A version may use this entry only
    /// after the signed bundled CLI passes the isolated compatibility probe.
    static let dynamicManagedSchemaID =
        "fable-codex-managed-provider-schema-v1"

    let entries: [Entry]

    /// Kept for old fixtures that exercise the first verified contract.
    var schemaID: String {
        entries[0].schemaID
    }

    func schemaID(
        for identity: CodexVersionIdentity
    ) -> String? {
        entry(for: identity)?.schemaID
    }

    func entry(
        for identity: CodexVersionIdentity
    ) -> Entry? {
        entries.first(where: { $0.matches(identity) })
    }

    func supports(_ identity: CodexVersionIdentity) -> Bool {
        schemaID(for: identity) != nil
    }

    static func compatibleSchemaIDs(
        for schemaID: String
    ) -> Set<String> {
        let bundled = Set(verified.entries.map(\.schemaID))
        let family = bundled.union([dynamicManagedSchemaID])
        return family.contains(schemaID) ? family : [schemaID]
    }
}

struct CodexServiceTierResolution: Equatable {
    let configuredValue: String
    let emittedValue: String?
}

enum CodexServiceTierContract {
    static func resolve(
        configuredValue: String,
        schemaID: String
    ) -> CodexServiceTierResolution? {
        guard CodexVersionContract.compatibleSchemaIDs(
            for: schemaID
        ).contains(
            CodexVersionContract.dynamicManagedSchemaID
        ) else {
            return nil
        }
        let normalized = configuredValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }
        let emittedValue: String?
        switch normalized {
        case "fast", "priority":
            emittedValue = schemaID
                == CodexVersionContract.dynamicManagedSchemaID
                ? "fast" : "priority"
        case "standard", "default", "auto", "flex":
            emittedValue = normalized
        default:
            emittedValue = nil
        }
        return CodexServiceTierResolution(
            configuredValue: configuredValue,
            emittedValue: emittedValue
        )
    }
}

enum FableVersionSupport: Equatable {
    case verified(schemaID: String)
    case readOnly

    var allowsWrites: Bool {
        if case .verified = self { return true }
        return false
    }
}

enum FableConfigurationMode: Equatable {
    case official
    case relay(providerID: String)
}

private enum FableTOMLValueRenderer {
    static func quoted(_ value: String) -> String {
        var output = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: output += "\\b"
            case 0x09: output += "\\t"
            case 0x0A: output += "\\n"
            case 0x0C: output += "\\f"
            case 0x0D: output += "\\r"
            case 0x22: output += "\\\""
            case 0x5C: output += "\\\\"
            default: output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
        return output
    }
}

enum FableManagedScalar: Codable, Equatable {
    case string(String)
    case integer(Int)
    case bool(Bool)

    var rendered: String {
        switch self {
        case let .string(value):
            return FableTOMLValueRenderer.quoted(value)
        case let .integer(value):
            return String(value)
        case let .bool(value):
            return value ? "true" : "false"
        }
    }
}

struct FableManagedValue: Codable, Equatable {
    let isPresent: Bool
    let value: FableManagedScalar?

    static let missing = FableManagedValue(
        isPresent: false,
        value: nil
    )

    static func present(
        _ value: FableManagedScalar
    ) -> FableManagedValue {
        FableManagedValue(isPresent: true, value: value)
    }

    var isStructurallyValid: Bool {
        isPresent == (value != nil)
    }
}

enum FableFieldIntent<Value: Equatable>: Equatable {
    case preserve
    case remove
    case set(Value)

    var isPreserved: Bool {
        if case .preserve = self { return true }
        return false
    }
}

struct FableProviderSnapshot: Equatable {
    let providerID: String
    let displayName: String?
    let baseURL: String?
    let wireAPI: String?
    let requiresOpenAIAuth: Bool?
    let hasBearerToken: Bool
    let envKey: String?
    let hasEnvKey: Bool
    let hasCommandAuth: Bool
    let supportsWebSockets: Bool?
    let supportsStandaloneWebSearch: Bool?
}

struct LiveCodexState: Equatable {
    let codexHome: URL
    let configURL: URL
    let version: CodexVersionIdentity
    let versionSupport: FableVersionSupport
    let mode: FableConfigurationMode
    let model: String?
    let contextWindow: Int?
    let autoCompactTokenLimit: Int?
    let reasoningEffort: String?
    let modelVerbosity: String?
    let serviceTier: String?
    let modelCatalogJSON: String?
    let webSearch: String?
    let disableResponseStorage: Bool?
    let fastMode: Bool?
    let provider: FableProviderSnapshot?
    let configHash: String
}

/// The exact managed root values observed while Codex is genuinely on the
/// official route. Optional values alone are not enough for recovery because
/// an empty string is different from a missing key, so presence is stored
/// explicitly. This record never contains provider credentials.
struct FableOfficialRootOverlay: Codable, Equatable {
    static let capabilityRootKeys = [
        "model_verbosity",
        "service_tier",
        "model_catalog_json",
        "web_search",
        "disable_response_storage",
    ]

    let hasModel: Bool
    let model: String?
    let hasContextWindow: Bool
    let contextWindow: Int?
    let hasAutoCompactTokenLimit: Bool
    let autoCompactTokenLimit: Int?
    let hasReasoningEffort: Bool
    let reasoningEffort: String?
    let capabilityRootValues: [String: FableManagedValue]?
    let featuresFastMode: FableManagedValue?

    init(
        model: String?,
        contextWindow: Int?,
        autoCompactTokenLimit: Int?,
        reasoningEffort: String?,
        capabilityRootValues:
            [String: FableManagedValue]? = nil,
        featuresFastMode: FableManagedValue? = nil
    ) {
        hasModel = model != nil
        self.model = model
        hasContextWindow = contextWindow != nil
        self.contextWindow = contextWindow
        hasAutoCompactTokenLimit =
            autoCompactTokenLimit != nil
        self.autoCompactTokenLimit =
            autoCompactTokenLimit
        hasReasoningEffort = reasoningEffort != nil
        self.reasoningEffort = reasoningEffort
        self.capabilityRootValues = capabilityRootValues
        self.featuresFastMode = featuresFastMode
    }

    fileprivate init(
        document: TOMLSemanticDocument
    ) throws {
        func has(_ key: String) -> Bool {
            document.leaves[
                TOMLSemanticEngine.path([key])
            ] != nil
        }

        hasModel = has("model")
        model = document.rootString("model")
        hasContextWindow = has("model_context_window")
        contextWindow = document.rootInteger(
            "model_context_window"
        )
        hasAutoCompactTokenLimit = has(
            "model_auto_compact_token_limit"
        )
        autoCompactTokenLimit = document.rootInteger(
            "model_auto_compact_token_limit"
        )
        hasReasoningEffort = has(
            "model_reasoning_effort"
        )
        reasoningEffort = document.rootString(
            "model_reasoning_effort"
        )
        capabilityRootValues = Dictionary(
            uniqueKeysWithValues: Self.capabilityRootKeys.map { key in
                let present = has(key)
                let value: FableManagedScalar?
                if key == "disable_response_storage" {
                    value = document.boolean(at: [key]).map {
                        .bool($0)
                    }
                } else {
                    value = document.rootString(key).map {
                        .string($0)
                    }
                }
                return (
                    key,
                    FableManagedValue(
                        isPresent: present,
                        value: value
                    )
                )
            }
        )
        let fastPath = ["features", "fast_mode"]
        let hasFastMode = document.leaves[
            TOMLSemanticEngine.path(fastPath)
        ] != nil
        featuresFastMode = FableManagedValue(
            isPresent: hasFastMode,
            value: document.boolean(at: fastPath).map {
                .bool($0)
            }
        )
        guard isStructurallyValid else {
            throw FableSwitchError.invalidConfiguration(
                "官方模型字段类型无法安全保存"
            )
        }
    }

    var isStructurallyValid: Bool {
        hasModel == (model != nil)
            && hasContextWindow
                == (contextWindow != nil)
            && hasAutoCompactTokenLimit
                == (autoCompactTokenLimit != nil)
            && hasReasoningEffort
                == (reasoningEffort != nil)
            && capabilitySnapshotIsValid
    }

    var hasCompleteCapabilitySnapshot: Bool {
        guard let capabilityRootValues,
              Set(capabilityRootValues.keys)
                == Set(Self.capabilityRootKeys),
              let featuresFastMode else {
            return false
        }
        return capabilityRootValues.values.allSatisfy(
            \.isStructurallyValid
        ) && featuresFastMode.isStructurallyValid
    }

    private var capabilitySnapshotIsValid: Bool {
        guard capabilityRootValues != nil
                || featuresFastMode != nil else {
            return true
        }
        guard hasCompleteCapabilitySnapshot,
              let capabilityRootValues,
              let featuresFastMode else {
            return false
        }
        for (key, managed) in capabilityRootValues {
            guard let value = managed.value else {
                if managed.isPresent { return false }
                continue
            }
            switch (key, value) {
            case ("disable_response_storage", .bool),
                 ("model_verbosity", .string),
                 ("service_tier", .string),
                 ("model_catalog_json", .string),
                 ("web_search", .string):
                break
            default:
                return false
            }
        }
        if let value = featuresFastMode.value,
           case .bool = value {
            return true
        }
        return !featuresFastMode.isPresent
    }
}

struct RelayProfile: Equatable {
    let id: String
    let providerID: String
    let displayName: String
    let baseURL: String
    let model: String
    let contextWindow: Int?
    let autoCompactTokenLimit: Int?
    let reasoningEffort: String
    let credentialReference: String
    let requiresOpenAIAuth: Bool
    let upstreamName: String?
    let modelVerbosity: FableFieldIntent<String>
    let serviceTier: FableFieldIntent<String>
    let modelCatalogJSON: FableFieldIntent<String>
    let webSearch: FableFieldIntent<String>
    let disableResponseStorage: FableFieldIntent<Bool>
    let fastMode: FableFieldIntent<Bool>
    let supportsWebSockets: FableFieldIntent<Bool>
    let supportsStandaloneWebSearch: FableFieldIntent<Bool>

    init(
        id: String,
        providerID: String,
        displayName: String,
        baseURL: String,
        model: String,
        contextWindow: Int?,
        autoCompactTokenLimit: Int?,
        reasoningEffort: String,
        credentialReference: String,
        requiresOpenAIAuth: Bool = true,
        upstreamName: String? = nil,
        modelVerbosity: FableFieldIntent<String> = .preserve,
        serviceTier: FableFieldIntent<String> = .preserve,
        modelCatalogJSON: FableFieldIntent<String> = .preserve,
        webSearch: FableFieldIntent<String> = .preserve,
        disableResponseStorage:
            FableFieldIntent<Bool> = .preserve,
        fastMode: FableFieldIntent<Bool> = .preserve,
        supportsWebSockets:
            FableFieldIntent<Bool> = .preserve,
        supportsStandaloneWebSearch:
            FableFieldIntent<Bool> = .preserve
    ) {
        self.id = id
        self.providerID = providerID
        self.displayName = displayName
        self.baseURL = baseURL
        self.model = model
        self.contextWindow = contextWindow
        self.autoCompactTokenLimit = autoCompactTokenLimit
        self.reasoningEffort = reasoningEffort
        self.credentialReference = credentialReference
        self.requiresOpenAIAuth = requiresOpenAIAuth
        self.upstreamName = upstreamName
        self.modelVerbosity = modelVerbosity
        self.serviceTier = serviceTier
        self.modelCatalogJSON = modelCatalogJSON
        self.webSearch = webSearch
        self.disableResponseStorage = disableResponseStorage
        self.fastMode = fastMode
        self.supportsWebSockets = supportsWebSockets
        self.supportsStandaloneWebSearch =
            supportsStandaloneWebSearch
    }

    var providerConfigurationName: String {
        upstreamName ?? displayName
    }

    var managesCapabilityFields: Bool {
        !modelVerbosity.isPreserved
            || !serviceTier.isPreserved
            || !modelCatalogJSON.isPreserved
            || !webSearch.isPreserved
            || !disableResponseStorage.isPreserved
            || !fastMode.isPreserved
            || !supportsWebSockets.isPreserved
            || !supportsStandaloneWebSearch.isPreserved
    }
}

enum FableSwitchDestination: Equatable {
    case official
    case relay(RelayProfile)
}

struct FableManagedChange: Equatable {
    let field: String
    let action: String
}

struct SwitchPlan: Equatable, CustomStringConvertible {
    let sourceHash: String
    let sourceExisted: Bool
    let sourceMode: FableConfigurationMode
    let destination: FableSwitchDestination
    let managedSourceProviderID: String?
    let credentialScrubProviderIDs: Set<String>
    let officialRootOverlay:
        FableOfficialRootOverlay?
    let versionContractID: String
    let changes: [FableManagedChange]

    var description: String {
        let target: String
        switch destination {
        case .official:
            target = "官方"
        case let .relay(profile):
            target = "中转：\(profile.displayName)"
        }
        return "切换目标=\(target)；变更项=\(changes.map(\.field).joined(separator: ","))；密钥=执行时从本机凭据库读取"
    }
}

enum FableSwitchLogStage: String, Equatable {
    case preflight
    case stopWriters
    case write
    case launch
    case verify
    case rollback
    case committed
}

struct FableSwitchLogEvent: Equatable {
    let stage: FableSwitchLogStage
    let message: String
}

/// In-memory only. This value must never be encoded or logged because
/// `originalData` can contain the active relay credential.
struct FablePreparedConfiguration {
    let configURL: URL
    let originalData: Data?
    let originalHash: String
    let originalExisted: Bool
    let proposedData: Data
    let proposedHash: String
}

/// In-memory only. This value must never be encoded or logged because
/// `originalData` can contain the active relay credential.
struct FableAppliedConfiguration {
    let configURL: URL
    let originalData: Data?
    let originalHash: String
    let writtenHash: String
}

/// In-memory only. `recoveredData` can contain relay credentials and must
/// never be encoded or logged.
struct FablePreparedRecoveryConfiguration {
    let configURL: URL
    let expectedCurrentHash: String?
    let expectedCurrentExisted: Bool
    let recoveredData: Data?
    let requiresWrite: Bool
}

protocol FableCredentialStore {
    func store(_ secret: String, reference: String) throws
    func secret(reference: String) throws -> String?
    func delete(reference: String) throws
}

protocol FableProcessController {
    func stopConfigurationWriters() throws
    func relaunchCodex() throws
}

protocol FableRuntimeVerifier {
    func verifyOfficial() throws
    func verifyRelay(_ profile: RelayProfile) throws
}

struct FableAtomicConfigWriter {
    private let fileManager: FileManager
    private let postRenameFaultHook: (URL) throws -> Void

    init(
        fileManager: FileManager = .default,
        postRenameFaultHook: @escaping (URL) throws -> Void = { _ in }
    ) {
        self.fileManager = fileManager
        self.postRenameFaultHook = postRenameFaultHook
    }

    func write(
        _ data: Data,
        to url: URL,
        expectedCurrentHash: String?
    ) throws {
        try validateTarget(url)
        try verifyCurrentHash(url, expected: expectedCurrentHash)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".ai-access-fable-\(UUID().uuidString).tmp"
        )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw FableSwitchError.atomicWriteFailed(errno)
        }
        var shouldRemoveTemporary = true
        defer {
            _ = close(descriptor)
            if shouldRemoveTemporary {
                try? fileManager.removeItem(at: temporary)
            }
        }
        do {
            try writeAll(data, descriptor: descriptor)
            guard fchmod(descriptor, mode_t(0o600)) == 0,
                  fsync(descriptor) == 0 else {
                throw FableSwitchError.atomicWriteFailed(errno)
            }
            try verifyCurrentHash(url, expected: expectedCurrentHash)
            guard rename(temporary.path, url.path) == 0 else {
                throw FableSwitchError.atomicWriteFailed(errno)
            }
            shouldRemoveTemporary = false
            try postRenameFaultHook(url)
            guard chmod(url.path, mode_t(0o600)) == 0 else {
                throw FableSwitchError.atomicWriteFailed(errno)
            }
            try synchronizeDirectory(url.deletingLastPathComponent())
        } catch let error as FableSwitchError {
            throw error
        } catch {
            throw FableSwitchError.atomicWriteFailed(errno)
        }
    }

    func restore(
        _ data: Data?,
        to url: URL,
        expectedCurrentHash: String?
    ) throws {
        if let data {
            try write(data, to: url, expectedCurrentHash: expectedCurrentHash)
            return
        }
        try verifyCurrentHash(url, expected: expectedCurrentHash)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
            try synchronizeDirectory(url.deletingLastPathComponent())
        }
    }

    private func validateTarget(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw FableSwitchError.unsafeConfigFile
        }
    }

    private func verifyCurrentHash(
        _ url: URL,
        expected: String?
    ) throws {
        let actual: String?
        if fileManager.fileExists(atPath: url.path) {
            actual = TOMLSemanticEngine.sha256(try Data(contentsOf: url))
        } else {
            actual = nil
        }
        guard actual == expected else {
            throw FableSwitchError.sourceChanged
        }
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
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
                    throw FableSwitchError.atomicWriteFailed(errno)
                }
                guard count > 0 else {
                    throw FableSwitchError.atomicWriteFailed(EIO)
                }
                offset += count
            }
        }
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw FableSwitchError.atomicWriteFailed(errno)
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw FableSwitchError.atomicWriteFailed(errno)
        }
    }
}

struct FableSwitchCore {
    let codexHome: URL
    let versionContract: CodexVersionContract
    let resolvedContractEntry: CodexVersionContract.Entry?
    let credentialStore: any FableCredentialStore
    let processController: any FableProcessController
    let runtimeVerifier: any FableRuntimeVerifier
    let atomicWriter: FableAtomicConfigWriter
    let managedProviderIDs: Set<String>
    let logger: (FableSwitchLogEvent) -> Void

    init(
        codexHome: URL,
        versionContract: CodexVersionContract = .verified,
        resolvedContractEntry:
            CodexVersionContract.Entry? = nil,
        credentialStore: any FableCredentialStore,
        processController: any FableProcessController,
        runtimeVerifier: any FableRuntimeVerifier,
        atomicWriter: FableAtomicConfigWriter = FableAtomicConfigWriter(),
        managedProviderIDs: Set<String> = [],
        logger: @escaping (FableSwitchLogEvent) -> Void = { _ in }
    ) {
        self.codexHome = codexHome.standardizedFileURL
        self.versionContract = versionContract
        self.resolvedContractEntry = resolvedContractEntry
        self.credentialStore = credentialStore
        self.processController = processController
        self.runtimeVerifier = runtimeVerifier
        self.atomicWriter = atomicWriter
        self.managedProviderIDs = managedProviderIDs
        self.logger = logger
    }

    func inspect(version: CodexVersionIdentity) throws -> LiveCodexState {
        let configURL = codexHome.appendingPathComponent("config.toml")
        let data = try currentData(configURL)
        let text = String(decoding: data ?? Data(), as: UTF8.self)
        let document: TOMLSemanticDocument
        do {
            document = try TOMLSemanticEngine.parse(text)
        } catch {
            throw FableSwitchError.invalidConfiguration("TOML语法检查未通过")
        }
        let selectedProvider = document.rootString("model_provider")
        let mode: FableConfigurationMode
        let provider: FableProviderSnapshot?
        if selectedProvider == nil || selectedProvider == "openai" {
            mode = .official
            provider = nil
        } else if let selectedProvider {
            mode = .relay(providerID: selectedProvider)
            let bearerToken = document.string(
                at: [
                    "model_providers", selectedProvider,
                    "experimental_bearer_token",
                ]
            )
            let authPath = [
                "model_providers", selectedProvider, "auth",
            ]
            let envKeyPath = [
                "model_providers", selectedProvider, "env_key",
            ]
            provider = FableProviderSnapshot(
                providerID: selectedProvider,
                displayName: document.string(
                    at: ["model_providers", selectedProvider, "name"]
                ),
                baseURL: document.string(
                    at: ["model_providers", selectedProvider, "base_url"]
                ),
                wireAPI: document.string(
                    at: ["model_providers", selectedProvider, "wire_api"]
                ),
                requiresOpenAIAuth: bool(
                    document,
                    at: [
                        "model_providers", selectedProvider,
                        "requires_openai_auth",
                    ]
                ),
                hasBearerToken: bearerToken?
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    .isEmpty == false,
                envKey: document.string(
                    at: [
                        "model_providers", selectedProvider,
                        "env_key",
                    ]
                ),
                hasEnvKey: document.leaves.keys
                    .contains { encodedPath in
                        TOMLSemanticEngine.decodePath(
                            encodedPath
                        ).starts(with: envKeyPath)
                    },
                hasCommandAuth: document.leaves.keys
                    .contains { encodedPath in
                        TOMLSemanticEngine.decodePath(
                            encodedPath
                        ).starts(with: authPath)
                    },
                supportsWebSockets: document.boolean(at: [
                    "model_providers", selectedProvider,
                    "supports_websockets",
                ]),
                supportsStandaloneWebSearch: document.boolean(at: [
                    "model_providers", selectedProvider,
                    "supports_standalone_web_search",
                ])
            )
        } else {
            mode = .official
            provider = nil
        }
        let support: FableVersionSupport
        if let schemaID = resolvedSchemaID(for: version) {
            support = .verified(schemaID: schemaID)
        } else {
            support = .readOnly
        }
        return LiveCodexState(
            codexHome: codexHome,
            configURL: configURL,
            version: version,
            versionSupport: support,
            mode: mode,
            model: document.rootString("model"),
            contextWindow: document.rootInteger("model_context_window"),
            autoCompactTokenLimit: document.rootInteger(
                "model_auto_compact_token_limit"
            ),
            reasoningEffort: document.rootString("model_reasoning_effort"),
            modelVerbosity: document.rootString("model_verbosity"),
            serviceTier: document.rootString("service_tier"),
            modelCatalogJSON: document.rootString("model_catalog_json"),
            webSearch: document.rootString("web_search"),
            disableResponseStorage: document.boolean(at: [
                "disable_response_storage",
            ]),
            fastMode: document.boolean(at: [
                "features", "fast_mode",
            ]),
            provider: provider,
            configHash: TOMLSemanticEngine.sha256(data ?? Data())
        )
    }

    func captureOfficialRootOverlay(
        version: CodexVersionIdentity,
        expectedConfigHash: String? = nil
    ) throws -> FableOfficialRootOverlay {
        guard resolvedSchemaID(for: version) != nil else {
            throw FableSwitchError.unsupportedVersion
        }
        let configURL = codexHome.appendingPathComponent(
            "config.toml"
        )
        let data = try currentData(configURL)
        let actualHash = TOMLSemanticEngine.sha256(
            data ?? Data()
        )
        if let expectedConfigHash,
           expectedConfigHash != actualHash {
            throw FableSwitchError.sourceChanged
        }
        let document: TOMLSemanticDocument
        do {
            document = try TOMLSemanticEngine.parse(
                String(
                    decoding: data ?? Data(),
                    as: UTF8.self
                )
            )
        } catch {
            throw FableSwitchError.invalidConfiguration(
                "TOML语法检查未通过"
            )
        }
        let selectedProvider = document.rootString(
            "model_provider"
        )
        guard selectedProvider == nil
                || selectedProvider == "openai" else {
            throw FableSwitchError
                .officialRootOverlayUnavailable
        }
        return try FableOfficialRootOverlay(
            document: document
        )
    }

    func makePlan(
        destination: FableSwitchDestination,
        version: CodexVersionIdentity,
        officialRootOverlay:
            FableOfficialRootOverlay? = nil
    ) throws -> SwitchPlan {
        let state = try inspect(version: version)
        guard state.versionSupport.allowsWrites else {
            throw FableSwitchError.unsupportedVersion
        }
        let observedSourceProviderID: String?
        if case let .relay(providerID) = state.mode {
            observedSourceProviderID = providerID
        } else {
            observedSourceProviderID = nil
        }
        let sourceProviderID = observedSourceProviderID.flatMap {
            managedProviderIDs.contains($0) ? $0 : nil
        }
        if let observedSourceProviderID,
           sourceProviderID == nil {
            throw FableSwitchError.unmanagedProvider(
                observedSourceProviderID
            )
        }
        var changes: [FableManagedChange]
        let plannedOfficialRootOverlay:
            FableOfficialRootOverlay?
        let credentialScrubProviderIDs:
            Set<String>
        switch destination {
        case .official:
            switch state.mode {
            case .official:
                plannedOfficialRootOverlay =
                    try officialRootOverlay
                        ?? captureOfficialRootOverlay(
                            version: version,
                            expectedConfigHash:
                                state.configHash
                        )
            case .relay:
                guard let officialRootOverlay,
                      officialRootOverlay
                        .isStructurallyValid else {
                    throw FableSwitchError
                        .officialRootOverlayUnavailable
                }
                plannedOfficialRootOverlay =
                    officialRootOverlay
            }
            credentialScrubProviderIDs =
                managedProviderIDs
            changes = [
                FableManagedChange(
                    field: "model_provider",
                    action: "移除中转选择"
                ),
                FableManagedChange(
                    field: "model/context/compact/reasoning",
                    action: "恢复官方原值或移除原本不存在的字段"
                ),
                FableManagedChange(
                    field: "model_providers.<受管中转>.认证",
                    action: "去激活并移除中转密钥"
                ),
            ]
        case let .relay(profile):
            try validate(profile)
            plannedOfficialRootOverlay = nil
            credentialScrubProviderIDs =
                managedProviderIDs.subtracting(
                    [profile.providerID]
                )
            changes = [
                FableManagedChange(field: "model", action: "设置目标模型"),
                FableManagedChange(
                    field: "model_provider",
                    action: "选择目标中转"
                ),
                FableManagedChange(
                    field: "model_context_window",
                    action: "设置上下文"
                ),
                FableManagedChange(
                    field: "model_auto_compact_token_limit",
                    action: "设置压缩阈值"
                ),
                FableManagedChange(
                    field: "model_reasoning_effort",
                    action: "设置思考强度"
                ),
                FableManagedChange(
                    field: "model_providers.<目标中转>",
                    action: "写入Responses接入参数"
                ),
            ]
            if profile.managesCapabilityFields {
                changes.append(
                    FableManagedChange(
                        field: "Fast/Web Search/隐私/模型目录",
                        action: "按目标轨证据执行叶子级设置"
                    )
                )
            }
        }
        guard let versionContractID =
            resolvedSchemaID(for: version) else {
            throw FableSwitchError.unsupportedVersion
        }
        return SwitchPlan(
            sourceHash: state.configHash,
            sourceExisted: FileManager.default.fileExists(
                atPath: state.configURL.path
            ),
            sourceMode: state.mode,
            destination: destination,
            managedSourceProviderID: sourceProviderID,
            credentialScrubProviderIDs:
                credentialScrubProviderIDs,
            officialRootOverlay:
                plannedOfficialRootOverlay,
            versionContractID: versionContractID,
            changes: changes
        )
    }

    func prepareConfiguration(
        _ plan: SwitchPlan,
        version: CodexVersionIdentity
    ) throws -> FablePreparedConfiguration {
        guard let versionContractID =
                resolvedSchemaID(for: version),
              plan.versionContractID == versionContractID else {
            throw FableSwitchError.unsupportedVersion
        }
        logger(.init(stage: .preflight, message: "开始核对实时Codex配置"))
        let configURL = codexHome.appendingPathComponent("config.toml")
        let originalData = try currentData(configURL)
        let currentHash = TOMLSemanticEngine.sha256(originalData ?? Data())
        guard currentHash == plan.sourceHash,
              (originalData != nil) == plan.sourceExisted else {
            throw FableSwitchError.sourceChanged
        }
        let original = String(decoding: originalData ?? Data(), as: UTF8.self)
        let proposed: String
        switch plan.destination {
        case .official:
            guard let officialRootOverlay =
                    plan.officialRootOverlay,
                  officialRootOverlay
                    .isStructurallyValid else {
                throw FableSwitchError
                    .officialRootOverlayUnavailable
            }
            proposed = try FableTOMLEditor.official(
                original: original,
                officialRootOverlay:
                    officialRootOverlay,
                credentialScrubProviderIDs:
                    plan.credentialScrubProviderIDs
            )
        case let .relay(profile):
            let secret: String
            do {
                guard let stored = try credentialStore.secret(
                    reference: profile.credentialReference
                ), !stored.isEmpty else {
                    throw FableSwitchError.credentialUnavailable
                }
                secret = stored
            } catch let error as FableSwitchError {
                throw error
            } catch {
                throw FableSwitchError.credentialUnavailable
            }
            proposed = try FableTOMLEditor.relay(
                original: original,
                profile: profile,
                secret: secret,
                credentialScrubProviderIDs:
                    plan.credentialScrubProviderIDs
            )
        }
        let proposedData = Data(proposed.utf8)
        return FablePreparedConfiguration(
            configURL: configURL,
            originalData: originalData,
            originalHash: currentHash,
            originalExisted: originalData != nil,
            proposedData: proposedData,
            proposedHash: TOMLSemanticEngine.sha256(proposedData)
        )
    }

    @discardableResult
    func applyPreparedConfiguration(
        _ prepared: FablePreparedConfiguration
    ) throws -> FableAppliedConfiguration {
        logger(.init(stage: .write, message: "正在原子写入受管配置"))
        do {
            try atomicWriter.write(
                prepared.proposedData,
                to: prepared.configURL,
                expectedCurrentHash:
                    prepared.originalExisted
                        ? prepared.originalHash : nil
            )
        } catch let error as FableSwitchError {
            guard case .atomicWriteFailed = error else {
                throw error
            }
            try compensateAtomicWriteFailure(
                error,
                originalData: prepared.originalData,
                proposedHash: prepared.proposedHash,
                at: prepared.configURL
            )
        }
        return FableAppliedConfiguration(
            configURL: prepared.configURL,
            originalData: prepared.originalData,
            originalHash: prepared.originalHash,
            writtenHash: prepared.proposedHash
        )
    }

    private func compensateAtomicWriteFailure(
        _ error: FableSwitchError,
        originalData: Data?,
        proposedHash: String,
        at url: URL
    ) throws -> Never {
        let current: Data?
        do {
            current = try currentData(url)
        } catch {
            throw error
        }
        guard let current,
              TOMLSemanticEngine.sha256(current) == proposedHash else {
            throw error
        }
        do {
            try atomicWriter.restore(
                originalData,
                to: url,
                expectedCurrentHash: proposedHash
            )
        } catch {
            throw FableSwitchError.rollbackFailed
        }
        throw error
    }

    @discardableResult
    func applyConfiguration(
        _ plan: SwitchPlan,
        version: CodexVersionIdentity
    ) throws -> FableAppliedConfiguration {
        try applyPreparedConfiguration(
            prepareConfiguration(plan, version: version)
        )
    }

    func restoreConfiguration(
        _ applied: FableAppliedConfiguration
    ) throws {
        let current = try currentData(applied.configURL)
        guard TOMLSemanticEngine.sha256(current ?? Data())
                == applied.writtenHash else {
            throw FableSwitchError.sourceChanged
        }
        try atomicWriter.restore(
            applied.originalData,
            to: applied.configURL,
            expectedCurrentHash: applied.writtenHash
        )
    }

    func prepareRecoveryConfiguration(
        sourceData: Data?,
        targetData: Data
    ) throws -> FablePreparedRecoveryConfiguration {
        let configURL = codexHome.appendingPathComponent(
            "config.toml"
        )
        let current = try currentData(configURL)
        let expectedCurrentHash = current.map(
            TOMLSemanticEngine.sha256
        )

        if current == sourceData {
            return FablePreparedRecoveryConfiguration(
                configURL: configURL,
                expectedCurrentHash: expectedCurrentHash,
                expectedCurrentExisted: current != nil,
                recoveredData: current,
                requiresWrite: false
            )
        }
        if current == targetData {
            return FablePreparedRecoveryConfiguration(
                configURL: configURL,
                expectedCurrentHash: expectedCurrentHash,
                expectedCurrentExisted: true,
                recoveredData: sourceData,
                requiresWrite: sourceData != targetData
            )
        }

        let recovered = try FableTOMLEditor.recover(
            source: String(
                decoding: sourceData ?? Data(),
                as: UTF8.self
            ),
            target: String(decoding: targetData, as: UTF8.self),
            current: String(
                decoding: current ?? Data(),
                as: UTF8.self
            ),
            managedProviderIDs: managedProviderIDs
        )
        let recoveredData = current == nil && recovered.isEmpty
            ? nil : Data(recovered.utf8)
        return FablePreparedRecoveryConfiguration(
            configURL: configURL,
            expectedCurrentHash: expectedCurrentHash,
            expectedCurrentExisted: current != nil,
            recoveredData: recoveredData,
            requiresWrite: recoveredData != current
        )
    }

    func applyPreparedRecoveryConfiguration(
        _ prepared: FablePreparedRecoveryConfiguration
    ) throws {
        if prepared.requiresWrite {
            try atomicWriter.restore(
                prepared.recoveredData,
                to: prepared.configURL,
                expectedCurrentHash:
                    prepared.expectedCurrentHash
            )
            return
        }
        let current = try currentData(prepared.configURL)
        guard (current != nil)
                == prepared.expectedCurrentExisted,
              current.map(TOMLSemanticEngine.sha256)
                == prepared.expectedCurrentHash else {
            throw FableSwitchError.sourceChanged
        }
    }

    @discardableResult
    func execute(
        _ plan: SwitchPlan,
        version: CodexVersionIdentity
    ) throws -> LiveCodexState {
        logger(.init(stage: .stopWriters, message: "正在关闭配置写入程序"))
        try processController.stopConfigurationWriters()
        var applied: FableAppliedConfiguration?
        do {
            applied = try applyConfiguration(
                plan,
                version: version
            )
            logger(.init(stage: .launch, message: "正在重新打开Codex"))
            try processController.relaunchCodex()
            logger(.init(stage: .verify, message: "正在验证目标模式"))
            switch plan.destination {
            case .official:
                try runtimeVerifier.verifyOfficial()
            case let .relay(profile):
                try runtimeVerifier.verifyRelay(profile)
            }
            logger(.init(stage: .committed, message: "切换和验证完成"))
            return try inspect(version: version)
        } catch {
            guard let applied else { throw error }
            logger(.init(stage: .rollback, message: "验证未通过，正在恢复切换前配置"))
            do {
                try processController.stopConfigurationWriters()
                try restoreConfiguration(applied)
                try processController.relaunchCodex()
                throw FableSwitchError.verificationFailedAndRolledBack
            } catch FableSwitchError.verificationFailedAndRolledBack {
                throw FableSwitchError.verificationFailedAndRolledBack
            } catch {
                throw FableSwitchError.rollbackFailed
            }
        }
    }

    private func resolvedSchemaID(
        for version: CodexVersionIdentity
    ) -> String? {
        if let resolvedContractEntry,
           resolvedContractEntry.matches(version) {
            return resolvedContractEntry.schemaID
        }
        return versionContract.schemaID(for: version)
    }

    private func currentData(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw FableSwitchError.unsafeConfigFile
        }
        return try Data(contentsOf: url)
    }

    private func validate(_ profile: RelayProfile) throws {
        let nonEmptyValues = [
            profile.id,
            profile.providerID,
            profile.displayName,
            profile.model,
            profile.credentialReference,
        ]
        guard nonEmptyValues.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.utf8.count <= 256
                && !$0.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                })
        }) else {
            throw FableSwitchError.invalidProfile("名称、模型或凭据引用为空")
        }
        if let upstreamName = profile.upstreamName {
            guard Self.isSafeProfileText(
                    upstreamName,
                    maximumUTF8Count: 256
                  ) else {
                throw FableSwitchError.invalidProfile(
                    "Provider兼容名称不合法"
                )
            }
        }
        guard let components = URLComponents(string: profile.baseURL),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw FableSwitchError.invalidProfile("Base URL必须是无账号、查询参数和片段的HTTPS地址")
        }
        let efforts = Set(["low", "medium", "high", "xhigh", "max", "ultra"])
        guard efforts.contains(profile.reasoningEffort) else {
            throw FableSwitchError.invalidProfile("上下文、压缩阈值或思考强度不合法")
        }
        if let contextWindow = profile.contextWindow,
           contextWindow <= 0 {
            throw FableSwitchError.invalidProfile("上下文、压缩阈值或思考强度不合法")
        }
        if let autoCompactTokenLimit =
                profile.autoCompactTokenLimit {
            guard let contextWindow = profile.contextWindow,
                  autoCompactTokenLimit > 0,
                  autoCompactTokenLimit < contextWindow else {
                throw FableSwitchError.invalidProfile("上下文、压缩阈值或思考强度不合法")
            }
        }
        try Self.validateStringIntent(
            profile.modelVerbosity,
            field: "model_verbosity",
            allowed: ["low", "medium", "high"]
        )
        try Self.validateStringIntent(
            profile.webSearch,
            field: "web_search",
            allowed: ["disabled", "cached", "live"]
        )
        if case let .set(value) = profile.serviceTier {
            let allowedScalars = CharacterSet(
                charactersIn:
                    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
            )
            guard Self.isSafeProfileText(
                    value,
                    maximumUTF8Count: 64
                  ),
                  value.unicodeScalars.allSatisfy({
                      allowedScalars.contains($0)
                  }) else {
                throw FableSwitchError.invalidProfile(
                    "service_tier不合法"
                )
            }
        }
        if case let .set(value) = profile.modelCatalogJSON {
            guard Self.isSafeProfileText(
                    value,
                    maximumUTF8Count: 4_096
                  ),
                  NSString(string: value).isAbsolutePath else {
                throw FableSwitchError.invalidProfile(
                    "model_catalog_json必须是安全绝对路径"
                )
            }
        }
    }

    private static func validateStringIntent(
        _ intent: FableFieldIntent<String>,
        field: String,
        allowed: Set<String>
    ) throws {
        guard case let .set(value) = intent else { return }
        guard isSafeProfileText(
                value,
                maximumUTF8Count: 256
              ),
              allowed.contains(value.lowercased()) else {
            throw FableSwitchError.invalidProfile(
                "\(field)不合法"
            )
        }
    }

    private static func isSafeProfileText(
        _ value: String,
        maximumUTF8Count: Int
    ) -> Bool {
        !value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
            && value.utf8.count <= maximumUTF8Count
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    private func bool(
        _ document: TOMLSemanticDocument,
        at components: [String]
    ) -> Bool? {
        let path = TOMLSemanticEngine.path(components)
        guard let value = document.leaves[path] else { return nil }
        if value == "bool:true" { return true }
        if value == "bool:false" { return false }
        return nil
    }
}

private enum FableTOMLEditor {
    private struct PhysicalLine: Equatable {
        var body: String
        var ending: String
    }

    private struct TableHeader {
        let index: Int
        let path: [String]
    }

    private static let relayRootValuesOrder = [
        "model",
        "model_provider",
        "model_reasoning_effort",
        "model_verbosity",
        "model_context_window",
        "model_auto_compact_token_limit",
        "service_tier",
        "model_catalog_json",
        "web_search",
        "disable_response_storage",
    ]
    private static let providerValuesOrder = [
        "name",
        "wire_api",
        "requires_openai_auth",
        "base_url",
        "supports_websockets",
        "supports_standalone_web_search",
        "experimental_bearer_token",
    ]

    private static let recoveryProviderFields = Set([
        "name",
        "base_url",
        "wire_api",
        "requires_openai_auth",
        "supports_websockets",
        "supports_standalone_web_search",
        "experimental_bearer_token",
        "env_key",
        "auth",
    ])

    static func recover(
        source: String,
        target: String,
        current: String,
        managedProviderIDs: Set<String>
    ) throws -> String {
        let sourceDocument = try parse(source)
        let targetDocument = try parse(target)
        let currentDocument = try parse(current)
        let transactionChanges = TOMLSemanticEngine.diff(
            before: sourceDocument,
            after: targetDocument
        )
        var units = Set<[String]>()
        for change in transactionChanges {
            let path = TOMLSemanticEngine.decodePath(
                change.path
            )
            if let unit = recoveryUnit(
                for: path,
                managedProviderIDs: managedProviderIDs
            ) {
                units.insert(unit)
                continue
            }
            guard isManagedStructuralMarker(
                path,
                managedProviderIDs: managedProviderIDs
            ) else {
                throw FableSwitchError.invalidConfiguration(
                    "恢复快照包含非切轨字段变化"
                )
            }
        }

        let orderedUnits = units.sorted {
            $0.joined(separator: "\u{0}")
                < $1.joined(separator: "\u{0}")
        }
        var unitsToRestore: [[String]] = []
        for unit in orderedUnits {
            let sourceValues = semanticSubtree(
                sourceDocument,
                prefix: unit
            )
            let targetValues = semanticSubtree(
                targetDocument,
                prefix: unit
            )
            let currentValues = semanticSubtree(
                currentDocument,
                prefix: unit
            )
            if currentValues == sourceValues {
                continue
            }
            guard currentValues == targetValues else {
                throw FableSwitchError
                    .managedRecoveryConflict
            }
            unitsToRestore.append(unit)
        }

        var lines = splitPhysicalLines(current)
        for unit in unitsToRestore {
            lines = try restoringRecoveryUnit(
                unit,
                source: sourceDocument,
                lines: lines
            )
        }
        let output = render(lines)
        let outputDocument = try parse(output)
        for unit in units {
            guard semanticSubtree(
                    outputDocument,
                    prefix: unit
                  ) == semanticSubtree(
                    sourceDocument,
                    prefix: unit
                  ) else {
                throw FableSwitchError.invalidConfiguration(
                    "恢复后的受管字段核对未通过"
                )
            }
        }
        let outputChanges = TOMLSemanticEngine.diff(
            before: currentDocument,
            after: outputDocument
        )
        guard outputChanges.allSatisfy({ change in
            recoveryOutputChangeIsAllowed(
                TOMLSemanticEngine.decodePath(change.path),
                units: units
            )
        }) else {
            throw FableSwitchError.invalidConfiguration(
                "恢复过程触及了非受管字段"
            )
        }
        return output
    }

    private static func recoveryUnit(
        for path: [String],
        managedProviderIDs: Set<String>
    ) -> [String]? {
        guard let first = path.first else { return nil }
        if relayRootValuesOrder.contains(first) {
            return [first]
        }
        if path.starts(with: ["features", "fast_mode"]) {
            return ["features", "fast_mode"]
        }
        guard path.count >= 3,
              first == "model_providers",
              managedProviderIDs.contains(path[1]),
              recoveryProviderFields.contains(path[2]) else {
            return nil
        }
        return Array(path.prefix(3))
    }

    private static func isManagedStructuralMarker(
        _ path: [String],
        managedProviderIDs: Set<String>
    ) -> Bool {
        guard path.last == "<empty-table>"
                || path.last == "<empty-array>" else {
            return false
        }
        if path == ["features", "<empty-table>"] {
            return true
        }
        return path.count >= 3
            && path[0] == "model_providers"
            && managedProviderIDs.contains(path[1])
    }

    private static func semanticSubtree(
        _ document: TOMLSemanticDocument,
        prefix: [String]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for (encodedPath, value) in document.leaves {
            let path = TOMLSemanticEngine.decodePath(
                encodedPath
            )
            guard path.starts(with: prefix) else { continue }
            let relative = Array(path.dropFirst(prefix.count))
            result[TOMLSemanticEngine.path(relative)] = value
        }
        return result
    }

    private static func restoringRecoveryUnit(
        _ unit: [String],
        source: TOMLSemanticDocument,
        lines: [PhysicalLine]
    ) throws -> [PhysicalLine] {
        let value = try renderedRecoveryValue(
            source,
            prefix: unit
        )
        if unit.count == 1 {
            let key = unit[0]
            return try rewriteRoot(
                lines,
                desired: value.map { [key: $0] } ?? [:],
                removing: value == nil ? [key] : []
            )
        }
        if unit == ["features", "fast_mode"] {
            return try rewriteLeaf(
                lines,
                tablePath: ["features"],
                key: "fast_mode",
                value: value
            )
        }
        guard unit.count == 3,
              unit[0] == "model_providers" else {
            throw FableSwitchError.invalidConfiguration(
                "恢复单元路径无效"
            )
        }
        var updated = lines
        if unit[2] == "auth" {
            updated = try removingProviderAuthTable(
                updated,
                providerID: unit[1]
            )
        }
        return try rewriteLeaf(
            updated,
            tablePath: ["model_providers", unit[1]],
            key: unit[2],
            value: value
        )
    }

    private static func renderedRecoveryValue(
        _ document: TOMLSemanticDocument,
        prefix: [String]
    ) throws -> String? {
        let entries = semanticSubtree(
            document,
            prefix: prefix
        ).map { encodedPath, value in
            (
                TOMLSemanticEngine.decodePath(encodedPath),
                value
            )
        }
        guard !entries.isEmpty else { return nil }
        return try renderSemanticEntries(entries)
    }

    private static func renderSemanticEntries(
        _ entries: [([String], String)]
    ) throws -> String {
        if let exact = entries.first(where: { $0.0.isEmpty }) {
            guard entries.count == 1 else {
                throw FableSwitchError.invalidConfiguration(
                    "恢复值同时包含标量和子项"
                )
            }
            return try renderCanonicalScalar(exact.1)
        }
        if entries.count == 1,
           entries[0].0 == ["<empty-array>"] {
            return "[]"
        }
        if entries.count == 1,
           entries[0].0 == ["<empty-table>"] {
            return "{}"
        }
        let grouped = Dictionary(grouping: entries) {
            $0.0[0]
        }
        let indexed = grouped.keys.compactMap {
            arrayIndex($0).map { ($0, $0) }
        }
        if indexed.count == grouped.count {
            let values = try grouped.keys.sorted {
                arrayIndex($0)! < arrayIndex($1)!
            }.map { key in
                try renderSemanticEntries(
                    grouped[key]!.map {
                        (Array($0.0.dropFirst()), $0.1)
                    }
                )
            }
            return "[\(values.joined(separator: ", "))]"
        }
        guard indexed.isEmpty else {
            throw FableSwitchError.invalidConfiguration(
                "恢复值的数组结构无效"
            )
        }
        let fields = try grouped.keys.sorted().map { key in
            let value = try renderSemanticEntries(
                grouped[key]!.map {
                    (Array($0.0.dropFirst()), $0.1)
                }
            )
            return "\(quotedKey(key)) = \(value)"
        }
        return "{ \(fields.joined(separator: ", ")) }"
    }

    private static func renderCanonicalScalar(
        _ value: String
    ) throws -> String {
        if value.hasPrefix("string:") {
            let payload = Data(
                value.dropFirst("string:".count).utf8
            )
            guard let decoded = try? JSONSerialization
                    .jsonObject(
                        with: payload,
                        options: [.fragmentsAllowed]
                    ) as? String else {
                throw FableSwitchError.invalidConfiguration(
                    "恢复字符串无法解码"
                )
            }
            return FableTOMLValueRenderer.quoted(decoded)
        }
        for prefix in ["integer:", "float:", "datetime:"]
            where value.hasPrefix(prefix) {
            return String(value.dropFirst(prefix.count))
        }
        if value == "bool:true" { return "true" }
        if value == "bool:false" { return "false" }
        throw FableSwitchError.invalidConfiguration(
            "恢复值类型不受支持"
        )
    }

    private static func arrayIndex(_ component: String) -> Int? {
        guard component.hasPrefix("["),
              component.hasSuffix("]") else { return nil }
        return Int(component.dropFirst().dropLast())
    }

    private static func recoveryOutputChangeIsAllowed(
        _ path: [String],
        units: Set<[String]>
    ) -> Bool {
        if units.contains(where: { path.starts(with: $0) }) {
            return true
        }
        if path == ["features", "<empty-table>"] {
            return units.contains(["features", "fast_mode"])
        }
        if path.count == 3,
           path[0] == "model_providers",
           path[2] == "<empty-table>" {
            return units.contains(where: {
                $0.count == 3
                    && $0[0] == "model_providers"
                    && $0[1] == path[1]
            })
        }
        return false
    }

    static func official(
        original: String,
        officialRootOverlay:
            FableOfficialRootOverlay,
        credentialScrubProviderIDs: Set<String>
    ) throws -> String {
        guard officialRootOverlay.isStructurallyValid else {
            throw FableSwitchError
                .officialRootOverlayUnavailable
        }
        _ = try parse(original)
        var lines = splitPhysicalLines(original)
        var desired: [String: String] = [:]
        var removing = Set(["model_provider"])
        if let model = officialRootOverlay.model {
            desired["model"] = quoted(model)
        } else {
            removing.insert("model")
        }
        if let reasoning =
            officialRootOverlay.reasoningEffort {
            desired["model_reasoning_effort"] =
                quoted(reasoning)
        } else {
            removing.insert("model_reasoning_effort")
        }
        if let context =
            officialRootOverlay.contextWindow {
            desired["model_context_window"] =
                String(context)
        } else {
            removing.insert("model_context_window")
        }
        if let compact = officialRootOverlay
            .autoCompactTokenLimit {
            desired[
                "model_auto_compact_token_limit"
            ] = String(compact)
        } else {
            removing.insert(
                "model_auto_compact_token_limit"
            )
        }
        if let capabilityRootValues =
            officialRootOverlay.capabilityRootValues {
            for key in FableOfficialRootOverlay.capabilityRootKeys {
                guard let managed = capabilityRootValues[key],
                      managed.isStructurallyValid else {
                    throw FableSwitchError
                        .officialRootOverlayUnavailable
                }
                if let value = managed.value {
                    desired[key] = value.rendered
                } else {
                    removing.insert(key)
                }
            }
        }
        lines = try rewriteRoot(
            lines,
            desired: desired,
            removing: removing
        )
        if let fastMode = officialRootOverlay.featuresFastMode {
            guard fastMode.isStructurallyValid else {
                throw FableSwitchError
                    .officialRootOverlayUnavailable
            }
            lines = try rewriteLeaf(
                lines,
                tablePath: ["features"],
                key: "fast_mode",
                value: fastMode.value?.rendered
            )
        }
        lines = try removingProviderCredentials(
            lines,
            providerIDs: credentialScrubProviderIDs
        )
        let output = render(lines)
        try validateSemanticChanges(
            before: original,
            after: output,
            allowedRootKeys: Set(relayRootValuesOrder),
            credentialScrubProviderIDs:
                credentialScrubProviderIDs,
            writableProviderID: nil,
            allowFastModeChange:
                officialRootOverlay.featuresFastMode != nil
        )
        return output
    }

    static func relay(
        original: String,
        profile: RelayProfile,
        secret: String,
        credentialScrubProviderIDs: Set<String>
    ) throws -> String {
        guard !secret.isEmpty,
              secret.utf8.count <= 16_384,
              !secret.unicodeScalars.contains(where: {
                  CharacterSet.newlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
              }) else {
            throw FableSwitchError.credentialUnavailable
        }
        _ = try parse(original)
        var lines = splitPhysicalLines(original)
        lines = try removingProviderCredentials(
            lines,
            providerIDs:
                credentialScrubProviderIDs
                    .subtracting([profile.providerID])
        )
        var rootValues = [
            "model": quoted(profile.model),
            "model_provider": quoted(profile.providerID),
            "model_reasoning_effort": quoted(profile.reasoningEffort),
        ]
        if let contextWindow = profile.contextWindow {
            rootValues["model_context_window"] =
                String(contextWindow)
        }
        if let autoCompactTokenLimit =
                profile.autoCompactTokenLimit {
            rootValues["model_auto_compact_token_limit"] =
                String(autoCompactTokenLimit)
        }
        var removingRootKeys = Set<String>()
        apply(
            profile.modelVerbosity,
            key: "model_verbosity",
            render: quoted,
            desired: &rootValues,
            removing: &removingRootKeys
        )
        apply(
            profile.serviceTier,
            key: "service_tier",
            render: quoted,
            desired: &rootValues,
            removing: &removingRootKeys
        )
        apply(
            profile.modelCatalogJSON,
            key: "model_catalog_json",
            render: quoted,
            desired: &rootValues,
            removing: &removingRootKeys
        )
        apply(
            profile.webSearch,
            key: "web_search",
            render: quoted,
            desired: &rootValues,
            removing: &removingRootKeys
        )
        apply(
            profile.disableResponseStorage,
            key: "disable_response_storage",
            render: { $0 ? "true" : "false" },
            desired: &rootValues,
            removing: &removingRootKeys
        )
        lines = try rewriteRoot(
            lines,
            desired: rootValues,
            removing: removingRootKeys
        )
        switch profile.fastMode {
        case .preserve:
            break
        case .remove:
            lines = try rewriteLeaf(
                lines,
                tablePath: ["features"],
                key: "fast_mode",
                value: nil
            )
        case let .set(value):
            lines = try rewriteLeaf(
                lines,
                tablePath: ["features"],
                key: "fast_mode",
                value: value ? "true" : "false"
            )
        }
        lines = try removingProviderCredentials(
            lines,
            providerIDs: [profile.providerID]
        )
        var providerValues = [
            "name": quoted(profile.providerConfigurationName),
            "wire_api": quoted("responses"),
            "requires_openai_auth":
                profile.requiresOpenAIAuth ? "true" : "false",
            "base_url": quoted(normalizedBaseURL(profile.baseURL)),
            "experimental_bearer_token": quoted(secret),
        ]
        var removingProviderFields = Set<String>()
        apply(
            profile.supportsWebSockets,
            key: "supports_websockets",
            render: { $0 ? "true" : "false" },
            desired: &providerValues,
            removing: &removingProviderFields
        )
        apply(
            profile.supportsStandaloneWebSearch,
            key: "supports_standalone_web_search",
            render: { $0 ? "true" : "false" },
            desired: &providerValues,
            removing: &removingProviderFields
        )
        lines = try upsertProvider(
            lines,
            providerID: profile.providerID,
            desired: providerValues,
            removing: removingProviderFields
        )
        let output = render(lines)
        try validateSemanticChanges(
            before: original,
            after: output,
            allowedRootKeys: Set(relayRootValuesOrder),
            credentialScrubProviderIDs:
                credentialScrubProviderIDs
                    .subtracting([profile.providerID]),
            writableProviderID: profile.providerID,
            allowFastModeChange:
                !profile.fastMode.isPreserved
        )
        return output
    }

    private static func rewriteRoot(
        _ input: [PhysicalLine],
        desired: [String: String],
        removing: Set<String>,
        orderedKeys: [String] = relayRootValuesOrder
    ) throws -> [PhysicalLine] {
        let normalizedKeys = Set(desired.keys).union(removing)
        var lines = removingRootMapShapes(
            input,
            keys: normalizedKeys
        )
        let firstTable = tableHeaders(lines).first?.index ?? lines.count
        var found = Set<String>()
        var removeIndexes = IndexSet()
        for index in 0..<firstTable {
            guard let assignment = assignment(in: lines[index].body),
                  assignment.path.count == 1 else { continue }
            let key = assignment.path[0]
            if removing.contains(key) {
                removeIndexes.insert(index)
                continue
            }
            guard let value = desired[key] else { continue }
            guard found.insert(key).inserted else {
                throw FableSwitchError.invalidConfiguration(
                    "顶层字段\(key)重复"
                )
            }
            lines[index].body = replacingValue(
                in: lines[index].body,
                equalsIndex: assignment.equalsIndex,
                with: value
            )
        }
        for index in removeIndexes.reversed() {
            lines.remove(at: index)
        }
        var insertion = tableHeaders(lines).first?.index ?? lines.count
        let newline = preferredLineEnding(lines)
        for key in orderedKeys
            where desired[key] != nil && !found.contains(key) {
            prepareInsertion(at: insertion, lines: &lines, newline: newline)
            lines.insert(
                PhysicalLine(
                    body: "\(key) = \(desired[key]!)",
                    ending: newline
                ),
                at: insertion
            )
            insertion += 1
        }
        try validateRootScalarShapes(
            lines,
            desired: desired,
            removing: removing
        )
        return lines
    }

    private static func removingRootMapShapes(
        _ input: [PhysicalLine],
        keys: Set<String>
    ) -> [PhysicalLine] {
        guard !keys.isEmpty else { return input }
        var lines = input
        let headers = tableHeaders(lines)
        var ranges: [Range<Int>] = []
        for (offset, header) in headers.enumerated() {
            guard let first = header.path.first,
                  keys.contains(first) else { continue }
            let end = offset + 1 < headers.count
                ? headers[offset + 1].index : lines.count
            ranges.append(header.index..<end)
        }
        for range in ranges.reversed() {
            lines.removeSubrange(range)
        }

        let firstTable = tableHeaders(lines).first?.index
            ?? lines.count
        var dottedAssignments = IndexSet()
        for index in 0..<firstTable {
            guard let field = assignment(in: lines[index].body),
                  field.path.count > 1,
                  let first = field.path.first,
                  keys.contains(first) else { continue }
            dottedAssignments.insert(index)
        }
        for index in dottedAssignments.reversed() {
            lines.remove(at: index)
        }
        return lines
    }

    private static func validateRootScalarShapes(
        _ lines: [PhysicalLine],
        desired: [String: String],
        removing: Set<String>
    ) throws {
        let document = try parse(render(lines))
        for key in Set(desired.keys).union(removing) {
            let encoded = TOMLSemanticEngine.path([key])
            let hasDescendant = document.leaves.keys.contains {
                let path = TOMLSemanticEngine.decodePath($0)
                return path.count > 1 && path.first == key
            }
            guard !hasDescendant else {
                throw FableSwitchError.invalidConfiguration(
                    "顶层字段\(key)必须是标量"
                )
            }
            if let value = desired[key] {
                let expected = try parse(
                    "\(key) = \(value)\n"
                )
                guard document.leaves[encoded]
                        == expected.leaves[encoded] else {
                    throw FableSwitchError.invalidConfiguration(
                        "顶层字段\(key)类型错误"
                    )
                }
            } else {
                guard document.leaves[encoded] == nil else {
                    throw FableSwitchError.invalidConfiguration(
                        "顶层字段\(key)未移除"
                    )
                }
            }
        }
    }

    private static func apply<Value: Equatable>(
        _ intent: FableFieldIntent<Value>,
        key: String,
        render: (Value) -> String,
        desired: inout [String: String],
        removing: inout Set<String>
    ) {
        switch intent {
        case .preserve:
            break
        case .remove:
            desired.removeValue(forKey: key)
            removing.insert(key)
        case let .set(value):
            removing.remove(key)
            desired[key] = render(value)
        }
    }

    private static func rewriteLeaf(
        _ input: [PhysicalLine],
        tablePath: [String],
        key: String,
        value: String?
    ) throws -> [PhysicalLine] {
        var lines = input
        let targetPath = tablePath + [key]
        var currentTablePath: [String] = []
        var matches: [Int] = []
        for index in lines.indices {
            let trimmed = lines[index].body.trimmingCharacters(
                in: .whitespaces
            )
            if trimmed.hasPrefix("[[") {
                currentTablePath = ["<array-table>"]
                continue
            }
            if let headerPath = Self.tablePath(
                in: lines[index].body
            ) {
                currentTablePath = headerPath
                continue
            }
            guard let field = assignment(
                in: lines[index].body
            ) else { continue }
            if currentTablePath + field.path == targetPath {
                matches.append(index)
            }
        }
        guard matches.count <= 1 else {
            throw FableSwitchError.invalidConfiguration(
                "字段\(targetPath.joined(separator: "."))重复"
            )
        }

        if let index = matches.first {
            if let value,
               let field = assignment(in: lines[index].body) {
                lines[index].body = replacingValue(
                    in: lines[index].body,
                    equalsIndex: field.equalsIndex,
                    with: value
                )
            } else {
                lines.remove(at: index)
                lines = removingEmptyTableHeader(
                    lines,
                    tablePath: tablePath
                )
            }
            return lines
        }
        guard let value else { return lines }

        let refreshedHeaders = tableHeaders(lines)
        if let offset = refreshedHeaders.firstIndex(where: {
            $0.path == tablePath
        }) {
            let end = offset + 1 < refreshedHeaders.count
                ? refreshedHeaders[offset + 1].index : lines.count
            let newline = preferredLineEnding(lines)
            prepareInsertion(at: end, lines: &lines, newline: newline)
            lines.insert(
                PhysicalLine(
                    body: "\(key) = \(value)",
                    ending: newline
                ),
                at: end
            )
            return lines
        }

        let newline = preferredLineEnding(lines)
        if !lines.isEmpty {
            if lines[lines.count - 1].ending.isEmpty {
                lines[lines.count - 1].ending = newline
            }
            if !lines[lines.count - 1].body.isEmpty {
                lines.append(
                    PhysicalLine(body: "", ending: newline)
                )
            }
        }
        lines.append(
            PhysicalLine(
                body: "[\(tablePath.joined(separator: "."))]",
                ending: newline
            )
        )
        lines.append(
            PhysicalLine(
                body: "\(key) = \(value)",
                ending: newline
            )
        )
        return lines
    }

    private static func removingEmptyTableHeader(
        _ input: [PhysicalLine],
        tablePath: [String]
    ) -> [PhysicalLine] {
        var lines = input
        let headers = tableHeaders(lines)
        guard let offset = headers.firstIndex(where: {
            $0.path == tablePath
        }) else { return lines }
        let header = headers[offset]
        let end = offset + 1 < headers.count
            ? headers[offset + 1].index : lines.count
        let hasAssignments = ((header.index + 1)..<end).contains {
            assignment(in: lines[$0].body) != nil
        }
        guard !hasAssignments else { return lines }
        lines.remove(at: header.index)
        return lines
    }

    private static func upsertProvider(
        _ input: [PhysicalLine],
        providerID: String,
        desired: [String: String],
        removing: Set<String>
    ) throws -> [PhysicalLine] {
        var lines = input
        let headers = tableHeaders(lines)
        guard let headerOffset = headers.firstIndex(where: {
            $0.path == ["model_providers", providerID]
        }) else {
            return appendingProvider(
                lines,
                providerID: providerID,
                desired: desired
            )
        }
        let header = headers[headerOffset]
        let end = headerOffset + 1 < headers.count
            ? headers[headerOffset + 1].index
            : lines.count
        var found = Set<String>()
        var removeIndexes = IndexSet()
        for index in (header.index + 1)..<end {
            guard let field = assignment(in: lines[index].body),
                  field.path.count == 1 else { continue }
            let key = field.path[0]
            if key == "env_key" || key == "auth"
                || removing.contains(key) {
                removeIndexes.insert(index)
                continue
            }
            guard let value = desired[key] else { continue }
            guard found.insert(key).inserted else {
                throw FableSwitchError.invalidConfiguration(
                    "Provider字段\(key)重复"
                )
            }
            lines[index].body = replacingValue(
                in: lines[index].body,
                equalsIndex: field.equalsIndex,
                with: value
            )
        }
        for index in removeIndexes.reversed() {
            lines.remove(at: index)
        }
        let refreshedHeaders = tableHeaders(lines)
        guard let refreshedOffset = refreshedHeaders.firstIndex(where: {
            $0.path == ["model_providers", providerID]
        }) else {
            throw FableSwitchError.invalidConfiguration("Provider表定位失败")
        }
        let refreshedEnd = refreshedOffset + 1 < refreshedHeaders.count
            ? refreshedHeaders[refreshedOffset + 1].index
            : lines.count
        let newline = preferredLineEnding(lines)
        var insertion = refreshedEnd
        for key in providerValuesOrder
            where desired[key] != nil && !found.contains(key) {
            prepareInsertion(at: insertion, lines: &lines, newline: newline)
            lines.insert(
                PhysicalLine(
                    body: "\(key) = \(desired[key]!)",
                    ending: newline
                ),
                at: insertion
            )
            insertion += 1
        }
        return lines
    }

    private static func appendingProvider(
        _ input: [PhysicalLine],
        providerID: String,
        desired: [String: String]
    ) -> [PhysicalLine] {
        var lines = input
        let newline = preferredLineEnding(lines)
        if !lines.isEmpty {
            if lines[lines.count - 1].ending.isEmpty {
                lines[lines.count - 1].ending = newline
            }
            if !lines[lines.count - 1].body.isEmpty {
                lines.append(PhysicalLine(body: "", ending: newline))
            }
        }
        lines.append(
            PhysicalLine(
                body: "[model_providers.\(quotedKey(providerID))]",
                ending: newline
            )
        )
        for key in providerValuesOrder {
            guard let value = desired[key] else { continue }
            lines.append(
                PhysicalLine(
                    body: "\(key) = \(value)",
                    ending: newline
                )
            )
        }
        return lines
    }

    private static func removingProviderSubtree(
        _ input: [PhysicalLine],
        providerID: String
    ) throws -> [PhysicalLine] {
        var lines = input
        let headers = tableHeaders(lines)
        var ranges: [Range<Int>] = []
        for (offset, header) in headers.enumerated() {
            guard header.path.starts(with: ["model_providers", providerID])
                    && header.path.count >= 2 else { continue }
            let end = offset + 1 < headers.count
                ? headers[offset + 1].index
                : lines.count
            ranges.append(header.index..<end)
        }
        for range in ranges.reversed() {
            lines.removeSubrange(range)
        }
        return lines
    }

    private static func removingProviderAuthTable(
        _ input: [PhysicalLine],
        providerID: String
    ) throws -> [PhysicalLine] {
        var lines = input
        let headers = tableHeaders(lines)
        var ranges: [Range<Int>] = []
        for (offset, header) in headers.enumerated() {
            guard header.path.starts(
                with: ["model_providers", providerID, "auth"]
            ) else { continue }
            let end = offset + 1 < headers.count
                ? headers[offset + 1].index
                : lines.count
            ranges.append(header.index..<end)
        }
        for range in ranges.reversed() {
            lines.removeSubrange(range)
        }
        return lines
    }

    /// Keep an inactive provider's non-secret and future fields intact while
    /// removing every supported authentication shape. This avoids deleting
    /// unknown extensions during official/relay round trips.
    private static func removingProviderCredentials(
        _ input: [PhysicalLine],
        providerIDs: Set<String>
    ) throws -> [PhysicalLine] {
        var lines = input
        for providerID in providerIDs.sorted() {
            lines = try removingProviderAuthTable(
                lines,
                providerID: providerID
            )
            let headers = tableHeaders(lines)
            guard let offset = headers.firstIndex(where: {
                $0.path == ["model_providers", providerID]
            }) else {
                continue
            }
            let header = headers[offset]
            let end = offset + 1 < headers.count
                ? headers[offset + 1].index
                : lines.count
            var removeIndexes = IndexSet()
            for index in (header.index + 1)..<end {
                guard let field = assignment(
                    in: lines[index].body
                ), let first = field.path.first else {
                    continue
                }
                if field.path.count == 1,
                   first == "experimental_bearer_token"
                    || first == "env_key" {
                    removeIndexes.insert(index)
                } else if first == "auth" {
                    removeIndexes.insert(index)
                }
            }
            for index in removeIndexes.reversed() {
                lines.remove(at: index)
            }
        }
        return lines
    }

    private static func validateSemanticChanges(
        before: String,
        after: String,
        allowedRootKeys: Set<String>,
        credentialScrubProviderIDs: Set<String>,
        writableProviderID: String?,
        allowFastModeChange: Bool
    ) throws {
        let beforeDocument = try parse(before)
        let afterDocument = try parse(after)
        let changes = TOMLSemanticEngine.diff(
            before: beforeDocument,
            after: afterDocument
        )
        let writableFields = Set([
            "name",
            "base_url",
            "wire_api",
            "requires_openai_auth",
            "supports_websockets",
            "supports_standalone_web_search",
            "experimental_bearer_token",
            "env_key",
            "auth",
        ])
        let blocked = changes.filter { change in
            let path = TOMLSemanticEngine.decodePath(change.path)
            if path.count == 1, allowedRootKeys.contains(path[0]) {
                return false
            }
            if path.count > 1,
               let first = path.first,
               allowedRootKeys.contains(first),
               change.kind == .missing {
                return false
            }
            if allowFastModeChange,
               (
                   path == ["features", "fast_mode"]
                    || path == ["features", "<empty-table>"]
               ) {
                return false
            }
            if path.count >= 3,
               path[0] == "model_providers",
               credentialScrubProviderIDs
                .contains(path[1]),
               Set([
                    "experimental_bearer_token",
                    "env_key",
                    "auth",
               ]).contains(path[2]) {
                return change.kind != .missing
            }
            if let writableProviderID,
               path.count >= 3,
               path[0] == "model_providers",
               path[1] == writableProviderID,
               writableFields.contains(path[2]) {
                if path[2] == "env_key" || path[2] == "auth" {
                    return change.kind != .missing
                }
                return false
            }
            return true
        }
        guard blocked.isEmpty else {
            throw FableSwitchError.invalidConfiguration(
                "检测到非切轨字段变化，原文件保持不动"
            )
        }
    }

    private static func parse(
        _ text: String
    ) throws -> TOMLSemanticDocument {
        do {
            return try TOMLSemanticEngine.parse(text)
        } catch let error as TOMLSemanticError {
            throw FableSwitchError.invalidConfiguration(
                error.localizedDescription
            )
        } catch {
            throw FableSwitchError.invalidConfiguration("TOML语法检查未通过")
        }
    }

    private static func splitPhysicalLines(_ text: String) -> [PhysicalLine] {
        guard !text.isEmpty else { return [] }
        var result: [PhysicalLine] = []
        let scalars = text.unicodeScalars
        var start = scalars.startIndex
        var index = start
        while index < scalars.endIndex {
            if scalars[index].value == 0x0A {
                var bodyEnd = index
                var ending = "\n"
                if bodyEnd > start {
                    let previous = scalars.index(
                        before: bodyEnd
                    )
                    if scalars[previous].value == 0x0D {
                        bodyEnd = previous
                        ending = "\r\n"
                    }
                }
                result.append(
                    PhysicalLine(
                        body: String(
                            scalars[start..<bodyEnd]
                        ),
                        ending: ending
                    )
                )
                index = scalars.index(after: index)
                start = index
            } else {
                index = scalars.index(after: index)
            }
        }
        if start < scalars.endIndex {
            result.append(
                PhysicalLine(
                    body: String(
                        scalars[start..<scalars.endIndex]
                    ),
                    ending: ""
                )
            )
        }
        return result
    }

    private static func render(_ lines: [PhysicalLine]) -> String {
        lines.map { $0.body + $0.ending }.joined()
    }

    private static func preferredLineEnding(
        _ lines: [PhysicalLine]
    ) -> String {
        lines.first(where: { !$0.ending.isEmpty })?.ending ?? "\n"
    }

    private static func prepareInsertion(
        at index: Int,
        lines: inout [PhysicalLine],
        newline: String
    ) {
        guard index == lines.count,
              !lines.isEmpty,
              lines[lines.count - 1].ending.isEmpty else { return }
        lines[lines.count - 1].ending = newline
    }

    private static func tableHeaders(
        _ lines: [PhysicalLine]
    ) -> [TableHeader] {
        lines.indices.compactMap { index in
            guard let path = tablePath(in: lines[index].body) else {
                return nil
            }
            return TableHeader(index: index, path: path)
        }
    }

    private static func tablePath(in line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["),
              !trimmed.hasPrefix("[[") else { return nil }
        var quote: Character?
        var escaped = false
        var closing: String.Index?
        var index = trimmed.index(after: trimmed.startIndex)
        while index < trimmed.endIndex {
            let character = trimmed[index]
            if escaped {
                escaped = false
            } else if character == "\\", quote == "\"" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "]" {
                closing = index
                break
            }
            index = trimmed.index(after: index)
        }
        guard let closing else { return nil }
        let remainder = trimmed[trimmed.index(after: closing)...]
            .trimmingCharacters(in: .whitespaces)
        guard remainder.isEmpty || remainder.hasPrefix("#") else {
            return nil
        }
        let body = String(
            trimmed[
                trimmed.index(after: trimmed.startIndex)..<closing
            ]
        )
        return dottedPath(body)
    }

    private struct Assignment {
        let path: [String]
        let equalsIndex: String.Index
    }

    private static func assignment(in line: String) -> Assignment? {
        let leading = line.drop(while: { $0 == " " || $0 == "\t" })
        guard !leading.isEmpty, leading.first != "#" else { return nil }
        var quote: Character?
        var escaped = false
        var index = leading.startIndex
        while index < leading.endIndex {
            let character = leading[index]
            if escaped {
                escaped = false
            } else if character == "\\", quote == "\"" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "=" {
                let key = String(leading[..<index])
                guard let path = dottedPath(key), !path.isEmpty else {
                    return nil
                }
                return Assignment(path: path, equalsIndex: index)
            }
            index = leading.index(after: index)
        }
        return nil
    }

    private static func dottedPath(_ source: String) -> [String]? {
        var result: [String] = []
        var token = ""
        var quote: Character?
        var escaped = false
        var wasQuoted = false

        func appendToken() -> Bool {
            let value = wasQuoted
                ? token
                : token.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return false }
            result.append(value)
            token = ""
            wasQuoted = false
            return true
        }

        for character in source {
            if escaped {
                switch character {
                case "\"", "\\": token.append(character)
                default: return nil
                }
                escaped = false
                continue
            }
            if let activeQuote = quote {
                if character == "\\", activeQuote == "\"" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                    wasQuoted = true
                } else {
                    token.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                guard token.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return nil
                }
                quote = character
            } else if character == "." {
                guard appendToken() else { return nil }
            } else {
                token.append(character)
            }
        }
        guard quote == nil, !escaped, appendToken() else { return nil }
        return result
    }

    private static func replacingValue(
        in line: String,
        equalsIndex: String.Index,
        with value: String
    ) -> String {
        let afterEquals = line.index(after: equalsIndex)
        var quote: Character?
        var escaped = false
        var squareDepth = 0
        var curlyDepth = 0
        var commentIndex: String.Index?
        var index = afterEquals
        while index < line.endIndex {
            let character = line[index]
            if escaped {
                escaped = false
            } else if character == "\\", quote == "\"" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else {
                switch character {
                case "\"", "'": quote = character
                case "[": squareDepth += 1
                case "]": squareDepth = max(0, squareDepth - 1)
                case "{": curlyDepth += 1
                case "}": curlyDepth = max(0, curlyDepth - 1)
                case "#" where squareDepth == 0 && curlyDepth == 0:
                    commentIndex = index
                default: break
                }
                if commentIndex != nil { break }
            }
            index = line.index(after: index)
        }
        let valueEnd = commentIndex ?? line.endIndex
        let oldValue = line[afterEquals..<valueEnd]
        let leadingWhitespace = oldValue.prefix {
            $0 == " " || $0 == "\t"
        }
        let trailingWhitespace = oldValue.reversed().prefix {
            $0 == " " || $0 == "\t"
        }.reversed()
        let suffix = commentIndex.map { String(line[$0...]) } ?? ""
        return String(line[..<afterEquals])
            + String(leadingWhitespace)
            + value
            + String(trailingWhitespace)
            + suffix
    }

    private static func quoted(_ value: String) -> String {
        FableTOMLValueRenderer.quoted(value)
    }

    private static func quotedKey(_ value: String) -> String {
        quoted(value)
    }

    private static func normalizedBaseURL(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.count > "https://".count, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}

/// Builds an in-memory relay configuration for an isolated verification
/// sandbox. It reuses the production semantic writer, scrubs credentials for
/// every non-target provider, and never writes the live configuration.
enum FableIsolatedRelayConfigurationBuilder {
    static func build(
        original: String,
        profile: RelayProfile,
        secret: String
    ) throws -> String {
        let document = try TOMLSemanticEngine.parse(original)
        return try FableTOMLEditor.relay(
            original: original,
            profile: profile,
            secret: secret,
            credentialScrubProviderIDs: Set(document.providerIDs)
        )
    }
}
