import AppKit
import Foundation

enum ConfigurationWizardStep: Int, CaseIterable, Identifiable {
    case sources = 1
    case fields = 2
    case agent = 3
    case method = 4
    case safety = 5

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .sources: return "添加资料"
        case .fields: return "核对字段"
        case .agent: return "桌面 Agent"
        case .method: return "配置方式"
        case .safety: return "执行与验证"
        }
    }
}

struct V011SessionListItem: Identifiable, Equatable {
    let id: String
    let title: String
    let originLabel: String
    let currentProvider: String
    let createdAt: Date?
    let updatedAt: Date?
    let workingDirectory: String
    let archived: Bool
}

@MainActor
final class ConfigWorkspaceModel:
    ObservableObject,
    ConfigWorkspaceSessionPreviewControllerDelegate,
    ConfigWorkspaceSessionRepairControllerDelegate,
    ConfigWorkspaceModeSwitchControllerDelegate,
    ConfigWorkspaceSimulationControllerDelegate,
    ConfigWorkspaceSourceAcquisitionControllerDelegate {
    @Published var wizardStep = ConfigurationWizardStep.sources
    @Published var selectedRelayID = RelayCatalog.customID
    @Published var configurationMethod = ConfigurationMethod.toolImport
    @Published var configurationTool = ConfigurationTool.codexPlusPlus
    @Published var selectedAccessRoute = AccessRouteKind.managed
    @Published var agent = DesktopAgent.codexDesktop
    @Published var providerName = ""
    @Published var baseURL = ""
    @Published var apiKey = ""
    @Published var modelName = ""
    @Published var modelNames: [String] = []
    @Published var newModelName = ""
    @Published var isFetchingModels = false
    @Published var modelFetchStatus = "可手动添加，也可从中转在线拉取"
    @Published var wireProtocol = RelayWireProtocol.responses
    @Published var contextWindow = ""
    @Published var autoCompactTokenLimit = ""
    @Published var remoteCompactionSetting =
        ProviderRemoteCompactionSetting.preserve
    @Published var reasoningEnabled = true
    @Published var reasoningEffort = ReasoningEffort.automatic
    @Published var supportsTextInput = true
    @Published var supportsImageInput = true
    @Published var serviceTierKind = ProviderServiceTierKind.inherit
    @Published var serviceTierCustomValue = ""
    @Published var fastModeSetting = ProviderOptionalBooleanSetting.preserve
    @Published var webSearchSetting = ProviderWebSearchSetting.preserve
    @Published var modelVerbositySetting = ProviderModelVerbositySetting.preserve
    @Published var responseStorageDisabledSetting =
        ProviderOptionalBooleanSetting.preserve
    @Published var providerCompatibilityName = ""
    @Published var confirmsLocalGateway = false
    @Published var documentURL = ""
    @Published var documentTitle = ""
    @Published var documentText = ""
    @Published var documentStatus = "尚未联网整理"
    @Published var isRefreshingDocument = false
    @Published var extracted = ExtractedRelayConfiguration.empty
    @Published var evidence: [FieldEvidence] = []
    @Published var preview: GeneratedConfiguration?
    @Published var confirmed = false
    @Published var errorMessage: String?
    @Published var exportURL: URL?
    @Published var pastedConfigurationText = ""
    @Published var configurationSources: [ConfigurationSourceRecord] = []
    @Published var unifiedResult: UnifiedConfigurationResult?
    @Published var conflictResolutions: [String: String] = [:]
    @Published var isReadingScreenshots = false
    @Published var screenshotStatus = "尚未导入截图"
    @Published var managedProfiles: [ManagedConfigurationProfile] = []
    @Published var activeSimulatedProfileID = "official"
    @Published var simulationStatus = "0.6.0 只做切换模拟；真实配置零写入"
    @Published var officialBaseline: OfficialBaseline?
    @Published var codexPlan: CodexConfigurationPlan?
    @Published var codexRuntimeMode = CodexRuntimeMode.official
    @Published var realSwitchStatus = "尚未读取或修改真实 Codex 配置"
    @Published var realSwitchPhase: RealSwitchPhase?
    @Published var isRealSwitchWorking = false
    @Published var confirmsOfficialMode = false
    @Published var confirmsCodexRestart = false
    @Published var confirmsWorkSaved = false
    @Published var confirmsRealWrite = false
    @Published var externalChangeDetected = false
    @Published var externalChangeSummary = ""
    @Published var savedRelayProfiles: [CodexRelayProfile] = []
    @Published var activeRelayProfileID: String?
    @Published var runtimeTruth: RuntimeTruth?
    @Published var runtimeTruthStatus = "尚未核对真实配置"
    @Published var codexDoctorStatus =
        "可选：使用Codex官方doctor --json核对；会只读配置并执行网络连通性检查"
    @Published var codexDoctorDiagnostic: CodexDoctorDiagnostic?
    @Published var codexDoctorComparison: CodexDoctorTruthComparison?
    @Published var codexDoctorGuidance: CodexDoctorActionableGuidance?
    @Published var codexDoctorBlocksManagedWrite = false
    @Published var confirmsCodexDoctorDiagnostic = false
    @Published var isRunningCodexDoctorDiagnostic = false
    @Published var bundledRecoveryStatus =
        "尚未检查认证辅助程序与恢复文档"
    @Published var bundledRecoveryAllowsManagedRelay = false
    @Published var governanceFixtureExportStatus =
        "可选：从用户手选TOML导出不含值的结构证据JSON"
    @Published var confirmsGovernanceFixtureExport = false
    @Published var runtimeDriftDetected = false
    @Published var runtimeDriftSummary = ""
    @Published var confirmsOfficialRecoveryTest = false
    @Published var exitManagementStatus = "退出托管前必须切回官方并完成真实官方请求"
    @Published var configurationHealth: ConfigurationHealthReport?
    @Published var existingProviderDisplayName = ""
    @Published var existingProviderImportReport: ExistingProviderImportReport?
    @Published var officialCandidates: [OfficialOverlayCandidate] = []
    @Published var selectedOfficialCandidateID: String?
    @Published var officialCandidateStatus = "尚未生成官方候选"
    @Published var legacyBackupRiskReport: LegacyBackupRiskReport?
    @Published var legacyBackupRiskStatus = "尚未扫描旧Provider备份"
    @Published var confirmsEncryptLegacyBackups = false
    @Published var officialBaselineTrust =
        OfficialBaselineTrust.missing
    @Published var unverifiedLegacyRelayProfileIDs: [String] = []
    @Published var sessionSyncAuthorized = false
    @Published var sessionSyncPreview: SessionSyncPreview?
    @Published var sessionSyncStatus = "尚未扫描历史会话"
    @Published var sessionSyncPhase:
        SessionSyncPhase?
    @Published var isSessionSyncScanning = false
    @Published var isSessionSyncWorking = false
    @Published var hasPendingSessionRecovery = false
    @Published var credentialBridgeState =
        CredentialBridgeState.helperMissing
    @Published var v011LiveState: LiveCodexState?
    @Published var v011RuntimeStatus = "正在读取Codex当前状态"
    @Published var v011OperationStatus = "尚未开始"
    @Published var isV011RuntimeRefreshing = false
    @Published var isV011SwitchWorking = false
    @Published var isV011AddingRelay = false
    @Published var v011HasPendingRecovery = false
    @Published var v011SessionRows: [V011SessionListItem] = []
    @Published var v011SessionTotal = 0
    @Published var v011SessionVisibleCount: Int?
    @Published var v011SessionHasMore = false
    @Published var isV011SessionLoading = false
    @Published var isV011SessionWorking = false
    @Published var v011SessionStatus = "尚未读取历史会话"
    private var importedProviderID: String?
    private var importedDirectoryEntryID: String?
    private var externalAdoptionExpectedConfigHash: String?
    private var selectedLegacyBackupDirectory: URL?
    private let dependencies: ConfigWorkspaceDependencies
    private let manualHandoffService =
        ConfigWorkspaceManualHandoffService()
    private let governanceFixtureExportController =
        ConfigWorkspaceGovernanceFixtureExportController()
    let v011Collaborator: V011WorkspaceCollaborator
    private lazy var sessionPreviewController =
        ConfigWorkspaceSessionPreviewController(
            delegate: self
        )
    private lazy var sessionRepairController =
        ConfigWorkspaceSessionRepairController(
            codexHomeURL: codexHomeURL,
            controlRootURL: controlRoot,
            keyProvider: dependencies.vaultKeyProvider,
            delegate: self
        )
    private lazy var modeSwitchController =
        ConfigWorkspaceModeSwitchController(
            delegate: self
        )
    private lazy var simulationController =
        ConfigWorkspaceSimulationController(
            delegate: self
        )
    private lazy var runtimeMonitorController =
        ConfigWorkspaceRuntimeMonitorController(
            stateStore: realStateStore,
            truthService: runtimeTruthService
        )
    private lazy var sourceAcquisitionController =
        ConfigWorkspaceSourceAcquisitionController(
            delegate: self
        )

    init(
        dependencies: ConfigWorkspaceDependencies = .live
    ) {
        self.dependencies = dependencies
        v011Collaborator = V011WorkspaceCollaborator(
            dependencies: dependencies
        )
        applySelectedRelayPreset()
        applyAgentDefaults()
        bundledRecoveryStatus =
            "0.11已停用旧凭据组件和环境变量方案"
        bundledRecoveryAllowsManagedRelay = false
        credentialBridgeState = .helperMissing
    }

    var selectedRelay: RelayProvider? { RelayCatalog.provider(id: selectedRelayID) }

    var availableAccessRoutes: [AccessRouteKind] { AccessRouteCatalog.available(for: agent) }

    var codexHomeURL: URL {
        v011Collaborator.codexHomeURL
    }

    private var controlRoot: URL {
        v011Collaborator.controlRoot
    }

    private var realAdapter: CodexConfigurationAdapter {
        CodexConfigurationAdapter(
            codexHome: codexHomeURL,
            vault: SecureProfileVault(
                rootURL: controlRoot.appendingPathComponent(
                    "ProfileVault",
                    isDirectory: true
                ),
                keyProvider: dependencies.vaultKeyProvider
            )
        )
    }

    private var realStateStore: CodexStateStore {
        v011Collaborator.stateStore
    }

    private var realEngine: CodexSwitchEngine {
        CodexSwitchEngine(adapter: realAdapter, stateStore: realStateStore)
    }

    private var sessionSyncEngine: SessionSyncEngine {
        SessionSyncEngine(
            codexHomeURL: codexHomeURL,
            controlRootURL: controlRoot,
            keyProvider: dependencies.vaultKeyProvider
        )
    }

    private var sessionPolicyService:
        ConfigWorkspaceSessionPolicyService {
        ConfigWorkspaceSessionPolicyService(
            stateStore: realStateStore,
            journalStore: sessionSyncEngine.journalStore
        )
    }

    private var runtimeTruthService:
        ConfigWorkspaceRuntimeTruthService {
        ConfigWorkspaceRuntimeTruthService(
            codexHomeURL: codexHomeURL,
            controlRootURL: controlRoot
        )
    }

    private var officialCandidateService:
        ConfigWorkspaceOfficialCandidateService {
        ConfigWorkspaceOfficialCandidateService(
            codexHomeURL: codexHomeURL,
            adapter: realAdapter,
            stateStore: realStateStore
        )
    }

    private var legacyBackupService:
        ConfigWorkspaceLegacyBackupService {
        ConfigWorkspaceLegacyBackupService(
            vaultRoot: controlRoot.appendingPathComponent(
                "LegacyBackupVault",
                isDirectory: true
            )
        )
    }

    private var existingProviderService:
        ConfigWorkspaceExistingProviderService {
        ConfigWorkspaceExistingProviderService(
            adapter: realAdapter,
            engine: realEngine
        )
    }

    private var sessionRecoveryFiles:
        [SessionAdditionalRecoveryFile] {
        [
            SessionAdditionalRecoveryFile(
                url: realAdapter.configURL,
                label: "Codex配置"
            ),
            SessionAdditionalRecoveryFile(
                url: realAdapter.authURL,
                label: "Codex认证"
            ),
            SessionAdditionalRecoveryFile(
                url: realStateStore.fileURL,
                label: "助手状态"
            ),
        ]
    }

    var manager: AdapterTarget {
        switch selectedAccessRoute {
        case .codexPlusPlus: return .codexPlusPlus
        case .ccSwitch: return .ccSwitch
        case .managed, .manual: return .manual
        }
    }

    var legacyManager: AdapterTarget {
        switch configurationMethod {
        case .toolImport: return configurationTool.adapterTarget
        case .builtIn: return agent == .cherryStudio ? .cherryStudio : .manual
        case .managed, .guidance: return .manual
        }
    }

    var compatibility: CompatibilityRecord {
        CompatibilityCatalog.record(
            relayID: selectedRelayID,
            manager: manager,
            method: selectedAccessRoute == .managed ? .managed : (selectedAccessRoute == .manual ? .guidance : .toolImport),
            tool: selectedAccessRoute == .codexPlusPlus ? .codexPlusPlus : (selectedAccessRoute == .ccSwitch ? .ccSwitch : nil),
            agent: agent
        )
    }

    var safetyPolicy: SafetyPolicy { SafetyPolicies.policy(manager: manager, agent: agent) }

    var allowsManagedWrite: Bool {
        guard let runtimeTruth else { return false }
        return runtimeTruth.allowsManagedWrite
            && runtimeTruth.runtimeMode == codexRuntimeMode
            && !runtimeDriftDetected
            && !codexDoctorBlocksManagedWrite
            && !activeRelayIsUnverified
    }

    var activeRelayIsUnverified: Bool {
        guard let activeRelayProfileID else {
            return false
        }
        return unverifiedLegacyRelayProfileIDs
            .contains(activeRelayProfileID)
    }

    var safetyAudit: SafetyAuditResult {
        safetyPolicy.evaluate(proposedWrites: ["~/Desktop/AI接入助手导出"])
    }

    var unresolvedConflicts: [ConfigurationFieldConflict] { unifiedResult?.conflicts ?? [] }

    var sourceWarnings: [String] { unifiedResult?.warnings ?? [] }

    var recognizedFieldRows: [(String, String)] {
        [
            ("供应商", providerName.isEmpty ? "未填写" : providerName),
            ("Base URL", baseURL.isEmpty ? "未填写" : baseURL),
            ("协议", wireProtocol.rawValue),
            ("模型", modelNames.isEmpty ? "未填写" : modelNames.joined(separator: "、")),
            ("上下文", contextWindow.isEmpty ? "未填写（可选）" : contextWindow),
            ("自动压缩阈值", autoCompactTokenLimit.isEmpty ? "未填写（可选）" : autoCompactTokenLimit),
            ("推理", reasoningEnabled ? "开启" : "关闭"),
            ("思考强度", reasoningEffort.rawValue),
            ("文本输入", supportsTextInput ? "支持" : "不支持"),
            ("图片输入", supportsImageInput ? "支持" : "不支持"),
        ]
    }

    var canContinueFromSources: Bool { !configurationSources.isEmpty }

    var canContinueFromFields: Bool { unresolvedConflicts.isEmpty && missingFields.isEmpty }

    var isLocalGateway: Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    var draft: ConfigDraft {
        ConfigDraft(
            manager: manager,
            method: selectedAccessRoute == .managed ? .managed : (selectedAccessRoute == .manual ? .guidance : .toolImport),
            tool: selectedAccessRoute == .codexPlusPlus ? .codexPlusPlus : (selectedAccessRoute == .ccSwitch ? .ccSwitch : nil),
            agent: agent,
            relayID: selectedRelayID,
            providerName: providerName,
            baseURL: baseURL,
            apiKey: apiKey,
            model: modelName,
            models: modelNames.isEmpty ? [modelName].filter { !$0.isEmpty } : modelNames,
            wireProtocol: wireProtocol,
            capabilities: ModelCapabilityProfile(
                contextWindow: Int(contextWindow.replacingOccurrences(of: "_", with: "")),
                autoCompactTokenLimit: Int(autoCompactTokenLimit.replacingOccurrences(of: "_", with: "")),
                reasoningEnabled: reasoningEnabled,
                reasoningEffort: reasoningEffort,
                supportsTextInput: supportsTextInput,
                supportsImageInput: supportsImageInput,
                serviceTier: configuredServiceTierValue,
                fastMode: fastModeSetting.value,
                webSearch: webSearchSetting.configuredValue,
                modelVerbosity: modelVerbositySetting.configuredValue,
                disableResponseStorage:
                    responseStorageDisabledSetting.value,
                upstreamName: normalizedProviderCompatibilityName
            ),
            evidence: evidence
        )
    }

    var capabilityConfigurationDraft:
        ProviderCapabilityConfigurationDraft {
        ProviderCapabilityConfigurationDraft(
            serviceTierKind: serviceTierKind,
            serviceTierProviderValue: serviceTierCustomValue,
            fastMode: fastModeSetting,
            webSearch: webSearchSetting,
            modelVerbosity: modelVerbositySetting,
            responseStorageDisabled:
                responseStorageDisabledSetting,
            remoteCompaction: remoteCompactionSetting,
            upstreamName: providerCompatibilityName
        )
    }

    var codexRelayProfile: CodexRelayProfile {
        let importedID = importedProviderID
        let resolvedProviderID = importedID
            ?? (selectedRelayID == RelayCatalog.customID
                ? PreservingTOMLEditor.providerIdentifier(providerName)
                : selectedRelayID)
        let resolvedModels = modelNames.isEmpty
            ? [modelName].filter { !$0.isEmpty }
            : modelNames
        let context = Int(
            contextWindow.replacingOccurrences(of: "_", with: "")
        )
        let compact = Int(
            autoCompactTokenLimit.replacingOccurrences(of: "_", with: "")
        )
        let capability = capabilityConfigurationDraft.makeProfile(
            providerID: resolvedProviderID,
            displayName: providerName,
            baseURL: baseURL,
            models: resolvedModels,
            defaultModel: modelName,
            contextWindow: context,
            localAutoCompactLimit: compact,
            reasoningEffort: capabilityReasoningEffort,
            supportsTextInput: supportsTextInput,
            supportsImageInput: supportsImageInput
        )
        return CodexRelayProfile(
            id: resolvedProviderID,
            providerID: importedID,
            name: providerName,
            baseURL: baseURL,
            wireProtocol: wireProtocol,
            models: resolvedModels,
            defaultModel: modelName,
            contextWindow: context,
            autoCompactTokenLimit: compact,
            reasoningEffort: reasoningEffort,
            localGatewayConfirmed: isLocalGateway ? confirmsLocalGateway : nil,
            catalogEntryID: importedDirectoryEntryID,
            capabilityProfile: capability
        )
    }

    var capabilityConfigurationSummary: [String] {
        codexRelayProfile.capabilityProfile?.configurationSummary ?? []
    }

    var missingFields: [String] {
        var fields: [String] = []
        if providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields.append("供应商") }
        if !CodexPlusPlusAdapter.isAllowedBaseURL(baseURL) { fields.append("Base URL") }
        if modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields.append("模型") }
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields.append("API Key") }
        if isLocalGateway, !confirmsLocalGateway { fields.append("本地网关确认") }
        if serviceTierKind == .providerSpecific,
           serviceTierCustomValue.trimmingCharacters(
            in: .whitespacesAndNewlines
           ).isEmpty {
            fields.append("自定义速度档")
        }
        return fields
    }

    var extractedSummary: [String] {
        var values: [String] = []
        if let name = extracted.providerName { values.append("供应商：\(name)") }
        if let url = extracted.baseURL { values.append("Base URL：\(url)") }
        if !extracted.protocols.isEmpty { values.append("协议：\(extracted.protocols.map(\.rawValue).joined(separator: "、"))") }
        if !extracted.models.isEmpty { values.append("模型：\(extracted.models.joined(separator: "、"))") }
        if let value = extracted.capabilities.contextWindow { values.append("上下文：\(value)") }
        if let value = extracted.capabilities.autoCompactTokenLimit { values.append("自动压缩：\(value)") }
        if let value = extracted.capabilities.reasoningEffort { values.append("思考强度：\(value.rawValue)") }
        if let value = extracted.capabilities.supportsImageInput { values.append("图片输入：\(value ? "支持" : "不支持")") }
        if let value = extracted.capabilities.serviceTier { values.append("速度档：\(value)") }
        if let value = extracted.capabilities.fastMode { values.append("Fast开关：\(value ? "开启" : "关闭")") }
        if let value = extracted.capabilities.webSearch { values.append("Web Search：\(value)") }
        if let value = extracted.capabilities.modelVerbosity { values.append("回答详略：\(value)") }
        if let value = extracted.capabilities.disableResponseStorage { values.append("禁用响应存储：\(value ? "开启" : "关闭")") }
        if let value = extracted.capabilities.upstreamName { values.append("Provider兼容名称：\(value)") }
        return values
    }

    var configuredServiceTierValue: String? {
        switch serviceTierKind {
        case .inherit, .followCodex:
            return nil
        case .standard:
            return "standard"
        case .fast:
            return "fast"
        case .flex:
            return "flex"
        case .providerSpecific:
            let value = serviceTierCustomValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return value.isEmpty ? nil : value
        }
    }

    var normalizedProviderCompatibilityName: String? {
        let value = providerCompatibilityName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        switch remoteCompactionSetting {
        case .preserve:
            return value.isEmpty ? nil : value
        case .enabled:
            return "OpenAI"
        case .disabled:
            guard value.caseInsensitiveCompare("OpenAI")
                    == .orderedSame else {
                return value.isEmpty ? nil : value
            }
            return nil
        }
    }

    private var capabilityReasoningEffort: String? {
        switch reasoningEffort {
        case .automatic: return nil
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh: return "xhigh"
        case .max: return "max"
        case .ultra: return "ultra"
        }
    }

    private func resetCapabilityConfiguration() {
        serviceTierKind = .inherit
        serviceTierCustomValue = ""
        fastModeSetting = .preserve
        webSearchSetting = .preserve
        modelVerbositySetting = .preserve
        responseStorageDisabledSetting = .preserve
        remoteCompactionSetting = .preserve
        providerCompatibilityName = ""
    }

    private func applyCapabilityConfiguration(
        from profile: CodexRelayProfile
    ) {
        guard let capability = profile.capabilityProfile else {
            resetCapabilityConfiguration()
            return
        }
        serviceTierKind = capability.serviceTier.requested.kind
        serviceTierCustomValue =
            capability.serviceTier.requested.providerValue ?? ""
        fastModeSetting = ProviderOptionalBooleanSetting(
            value: capability.fastModeEnabled
        )
        webSearchSetting = ProviderWebSearchSetting(
            configuredValue: capability.webSearch.configuredValue
        )
        modelVerbositySetting = ProviderModelVerbositySetting(
            configuredValue: capability.modelVerbosity
        )
        responseStorageDisabledSetting =
            ProviderOptionalBooleanSetting(
                value: capability.responseStorageDisabled
            )
        remoteCompactionSetting =
            ProviderRemoteCompactionSetting(
                capability: capability.remoteCompaction
            )
        providerCompatibilityName = capability.upstreamName ?? ""
        supportsTextInput = capability.textInput != .unsupported
        let defaultModelSupportsImage = capability.models.first {
            $0.modelID == capability.defaultModel
        }?.inputModalities.contains("image") == true
        switch capability.imageInput {
        case .requested, .verified:
            supportsImageInput = true
        case .unsupported:
            supportsImageInput = false
        case .unknown, .degraded:
            supportsImageInput = defaultModelSupportsImage
        }
    }

    func selectRelay(_ relayID: String) {
        selectedRelayID = relayID
        importedProviderID = nil
        importedDirectoryEntryID = nil
        providerName = ""
        baseURL = ""
        apiKey = ""
        confirmsLocalGateway = false
        modelName = ""
        modelNames = []
        documentURL = ""
        documentTitle = ""
        documentText = ""
        documentStatus = "尚未联网整理"
        extracted = .empty
        resetCapabilityConfiguration()
        evidence.removeAll { $0.status != .userConfirmed }
        configurationSources.removeAll { $0.kind == .verifiedPreset || $0.kind == .remoteDocument }
        conflictResolutions.removeAll()
        if relayID != RelayCatalog.customID { applySelectedRelayPreset() }
        invalidatePreview()
    }

    func importDirectoryEntry(_ entry: ProviderCatalogEntryV2) {
        selectRelay(RelayCatalog.customID)
        importedDirectoryEntryID = entry.id
        providerName = entry.serviceName
        documentURL = entry.documentationURL.absoluteString
        baseURL = entry.baseURLPattern ?? ""
        modelNames = entry.models
        modelName = entry.models.first ?? ""
        contextWindow = entry.contextWindow.map(String.init) ?? contextWindow
        supportsImageInput = entry.supportsImageInput ?? supportsImageInput
        if entry.protocols.contains("responses") {
            wireProtocol = .responses
        } else if entry.protocols.contains("chat_completions")
                    || entry.protocols.contains("chat") {
            wireProtocol = .chatCompletions
        } else if entry.protocols.contains("anthropic_messages")
                    || entry.protocols.contains("anthropic") {
            wireProtocol = .anthropicMessages
        }
        let source = "签名中转目录；核验者 \(entry.verification.verifierID)"
        evidence = [
            FieldEvidence(field: "供应商", value: entry.serviceName, source: source, status: .verified),
        ]
        if let baseURLPattern = entry.baseURLPattern {
            evidence.append(
                FieldEvidence(
                    field: "Base URL",
                    value: baseURLPattern,
                    source: entry.documentationURL.absoluteString,
                    status: .verified
                )
            )
        }
        entry.protocols.forEach {
            evidence.append(
                FieldEvidence(
                    field: "协议",
                    value: $0,
                    source: entry.documentationURL.absoluteString,
                    status: .verified
                )
            )
        }
        let sourceText = """
        供应商：\(entry.serviceName)
        Base URL：\(entry.baseURLPattern ?? "未提供")
        协议：\(entry.protocols.joined(separator: "、"))
        模型：\(entry.models.joined(separator: "、"))
        上下文：\(entry.contextWindow.map(String.init) ?? "未提供")
        图片输入：\(entry.supportsImageInput.map { $0 ? "支持" : "不支持" } ?? "未提供")
        """
        configurationSources = [
            ConfigurationSourceEngine.sanitizedSource(
                kind: .verifiedPreset,
                title: "\(entry.serviceName) 签名目录记录",
                text: sourceText,
                location: entry.documentationURL.absoluteString
            ),
        ]
        rebuildUnifiedResult(applyValues: true)
        wizardStep = .fields
        invalidatePreview()
    }

    func selectAccessRoute(_ route: AccessRouteKind) {
        selectedAccessRoute = route
        switch route {
        case .managed:
            configurationMethod = .managed
        case .codexPlusPlus:
            configurationMethod = .toolImport
            configurationTool = .codexPlusPlus
        case .ccSwitch:
            configurationMethod = .toolImport
            configurationTool = .ccSwitch
        case .manual:
            configurationMethod = .guidance
        }
        codexPlan = nil
        externalChangeDetected = false
        invalidatePreview()
    }

    func loadRealControlState() {
        do {
            let state = try realStateStore.load()
            officialBaseline = state.baseline
            officialBaselineTrust =
                state.officialBaselineTrust
            savedRelayProfiles = state.relayProfiles
            activeRelayProfileID =
                state.activeRelayID
            unverifiedLegacyRelayProfileIDs =
                state.unverifiedLegacyRelayProfileIDs
            codexRuntimeMode = state.currentMode
            sessionSyncAuthorized =
                state.sessionSyncAuthorized
            if let activeID = state.activeRelayID,
               let profile = state.relayProfiles.first(where: { $0.id == activeID }) {
                selectedRelayID = profile.id
                providerName = profile.name
                baseURL = profile.baseURL
                wireProtocol = profile.wireProtocol
                modelNames = profile.models
                modelName = profile.defaultModel
                contextWindow = profile.contextWindow.map(String.init) ?? ""
                autoCompactTokenLimit = profile.autoCompactTokenLimit.map(String.init) ?? ""
                reasoningEffort = profile.reasoningEffort
                confirmsLocalGateway = profile.localGatewayConfirmed == true
                applyCapabilityConfiguration(from: profile)
            }
            if let transaction = state.lastTransaction {
                realSwitchPhase = transaction.phase
                realSwitchStatus = transaction.message
                if transaction.phase != .committed, transaction.phase != .rolledBack {
                    errorMessage = "发现未完成切换事务。不要继续配置；进入第5步恢复官方基线。"
                }
            }
            hasPendingSessionRecovery =
                (try? sessionPolicyService
                    .hasPendingRecovery()) == true
            refreshRuntimeTruth()
            refreshExistingProviderMigrationState(
                state
            )
            refreshOfficialCandidates()
            refreshCredentialBridgeState()
        } catch {
            realSwitchStatus = "助手控制状态无法读取：\(error.localizedDescription)"
            runtimeTruthStatus = "助手记录无法读取，已阻止自动写入"
        }
    }

    func refreshOfficialCandidates() {
        do {
            let snapshot = try officialCandidateService.load()
            officialCandidates = snapshot.candidates
            selectedOfficialCandidateID =
                snapshot.selectedCandidateID
            officialCandidateStatus =
                "已生成\(snapshot.candidates.count)个候选；没有真实官方请求证据的候选不会标为已验证。"
        } catch {
            officialCandidates = []
            officialCandidateStatus = "官方候选生成失败：\(error.localizedDescription)"
        }
    }

    func confirmOfficialRequestSuccess() {
        refreshRuntimeTruth()
        guard confirmsOfficialRecoveryTest,
              codexRuntimeMode == .official,
              runtimeTruth?.runtimeMode == .official,
              runtimeTruth?.allowsManagedWrite == true,
              let processIdentifier =
                  runtimeTruth?.process.processIdentifier else {
            errorMessage = "官方验证未记录：必须由当前运行的官方Codex完成真实请求，并勾选确认。"
            return
        }
        do {
            let overlay = try realEngine.confirmOfficialValidation(
                evidence: OfficialValidationEvidence(
                    method: .userConfirmedInteractiveRequest,
                    observedAt: Date(),
                    codexProcessIdentifier: processIdentifier,
                    responseSucceeded: true
                )
            )
            refreshOfficialCandidates()
            officialCandidateStatus =
                "官方覆盖层已验证：\(overlay.lastVerifiedAt?.formatted() ?? "时间未知")；只记录结果，不保存请求正文。"
            exitManagementStatus = "官方真实请求证据已记录；满足其他退出条件后可退出托管"
            errorMessage = nil
        } catch {
            errorMessage = "官方验证记录失败：\(error.localizedDescription)"
        }
    }

    func scanLegacyBackupDirectory(_ directory: URL) {
        do {
            let report = try legacyBackupService.scan(
                directory: directory
            )
            selectedLegacyBackupDirectory = directory.standardizedFileURL
            legacyBackupRiskReport = report
            if report.plaintextRiskRemains {
                legacyBackupRiskStatus =
                    "扫描\(report.scannedFileCount)个文件，发现\(report.riskFileCount)个疑似明文风险；未显示正文，原文件未改动。"
            } else {
                legacyBackupRiskStatus =
                    "扫描\(report.scannedFileCount)个文件，未发现已知明文凭据模式。"
            }
            confirmsEncryptLegacyBackups = false
            errorMessage = nil
        } catch {
            legacyBackupRiskReport = nil
            selectedLegacyBackupDirectory = nil
            legacyBackupRiskStatus = "旧备份扫描失败：\(error.localizedDescription)"
        }
    }

    func archiveLegacyBackups() {
        guard confirmsEncryptLegacyBackups,
              let directory = selectedLegacyBackupDirectory else {
            errorMessage = "先选择旧备份目录并确认创建加密归档"
            return
        }
        do {
            let result = try legacyBackupService.archive(
                directory: directory
            )
            legacyBackupRiskReport = result.report
            legacyBackupRiskStatus =
                "已加密归档\(result.receipt.archivedFileCount)个风险文件；原明文备份仍保留，删除或移入废纸篓必须另行确认。"
            confirmsEncryptLegacyBackups = false
            errorMessage = nil
        } catch {
            errorMessage = "旧备份加密归档失败：\(error.localizedDescription)"
        }
    }

    func importOfficialBackupCandidate(_ url: URL) {
        do {
            let candidate = try officialCandidateService
                .importBackup(from: url)
            officialCandidates.removeAll { $0.id == candidate.id }
            officialCandidates.append(candidate)
            officialCandidateStatus = "已加入备份候选\(url.lastPathComponent)；仅比较和提取Provider覆盖，不整份恢复。"
            errorMessage = nil
        } catch {
            errorMessage = "备份候选无法读取：\(error.localizedDescription)"
        }
    }

    func selectOfficialCandidate(_ candidate: OfficialOverlayCandidate) {
        guard candidate.state == .candidate || candidate.state == .verified else {
            errorMessage = "该候选证据不足，不能选为官方覆盖层"
            return
        }
        do {
            try officialCandidateService.select(candidate)
            officialBaselineTrust = .candidate
            selectedOfficialCandidateID = candidate.id
            officialCandidateStatus = "已选择“\(candidate.displayName)”作为官方候选；真实官方请求成功前仍是候选状态。"
            errorMessage = nil
        } catch {
            errorMessage = "官方候选保存失败：\(error.localizedDescription)"
        }
    }

    func refreshRuntimeTruth() {
        switch runtimeMonitorController.refresh() {
        case let .observed(snapshot):
            applyRuntimeObservation(snapshot)
            if snapshot.acceptsManagedState {
                clearAcceptedRuntimeDrift()
            }
            runtimeTruthStatus = snapshot.status(
                recordedRuntimeMode: codexRuntimeMode,
                activeRelayIsUnverified:
                    activeRelayIsUnverified,
                allowsManagedWrite: allowsManagedWrite,
                doctorBlockingReasons:
                    codexDoctorComparison?
                        .blockingReasons ?? []
            )
        case let .failed(state, message):
            if let state {
                synchronizeControlState(state)
            }
            runtimeTruth = nil
            runtimeTruthStatus =
                "真实配置无法安全解析：" + message
        }
    }

    func refreshBundledRecoveryHealth() {
        bundledRecoveryStatus =
            "0.11已停用旧凭据组件；中转使用本机Codex配置中的持久认证"
        bundledRecoveryAllowsManagedRelay = false
        credentialBridgeState = .helperMissing
    }

    func refreshCredentialBridgeState() {
        credentialBridgeState = .helperMissing
    }

    func exportGovernanceStructureFixture() {
        guard confirmsGovernanceFixtureExport else {
            errorMessage = "先确认允许本次只读所选TOML并导出脱敏结构"
            return
        }
        defer {
            confirmsGovernanceFixtureExport = false
        }
        switch governanceFixtureExportController.export() {
        case .cancelled:
            return
        case let .exported(status):
            governanceFixtureExportStatus = status
            errorMessage = nil
        case let .failed(message):
            errorMessage = message
        }
    }

    func monitorRuntimeTruth() {
        guard !isRealSwitchWorking else { return }
        switch runtimeMonitorController.monitor() {
        case let .observed(snapshot):
            applyRuntimeObservation(snapshot)
            runtimeTruthStatus = snapshot.status(
                recordedRuntimeMode: codexRuntimeMode,
                activeRelayIsUnverified:
                    activeRelayIsUnverified,
                allowsManagedWrite: allowsManagedWrite,
                doctorBlockingReasons:
                    codexDoctorComparison?
                        .blockingReasons ?? []
            )
            if snapshot.acceptsManagedState {
                clearAcceptedRuntimeDrift()
                return
            }
            guard let report = snapshot.driftReport else {
                return
            }
            if !report.configurationChanged {
                realSwitchStatus = "Codex进程状态已更新；配置轨道未变化"
                return
            }
            runtimeDriftDetected = true
            runtimeDriftSummary = report.summary
            externalChangeDetected = report.configurationChanged
            externalChangeSummary = report.summary
            realSwitchStatus = "持续监控发现外部变化；已暂停托管写入，请核对后处理"
        case let .failed(state, message):
            if let state {
                synchronizeControlState(state)
            }
            runtimeTruth = nil
            runtimeTruthStatus =
                "持续监控无法安全读取真实配置："
                + message
            runtimeDriftDetected = true
            runtimeDriftSummary = runtimeTruthStatus
        }
    }

    private func applyRuntimeObservation(
        _ snapshot: ConfigWorkspaceRuntimeMonitorSnapshot
    ) {
        synchronizeControlState(snapshot.state)
        runtimeTruth = snapshot.truth
        refreshCodexDoctorComparison(with: snapshot.truth)
    }

    func synchronizeControlState(
        _ state: CodexStateStore.State
    ) {
        officialBaseline = state.baseline
        officialBaselineTrust =
            state.officialBaselineTrust
        savedRelayProfiles = state.relayProfiles
        activeRelayProfileID = state.activeRelayID
        unverifiedLegacyRelayProfileIDs =
            state.unverifiedLegacyRelayProfileIDs
        codexRuntimeMode = state.currentMode
        sessionSyncAuthorized =
            state.sessionSyncAuthorized
    }

    func setSessionSyncAuthorization(_ allowed: Bool) {
        do {
            try sessionPolicyService
                .setAuthorization(allowed)
            sessionSyncAuthorized = allowed
            sessionSyncStatus = allowed
                ? "切换时将自动保持全部历史会话可见"
                : "自动保持历史会话可见已关闭"
            errorMessage = nil
        } catch {
            sessionSyncAuthorized = false
            errorMessage =
                "历史会话授权无法保存："
                + error.localizedDescription
        }
    }

    func refreshSessionSyncPreview(
        force: Bool = false
    ) {
        do {
            if let pending = try sessionPolicyService
                .pendingTransaction() {
                cancelSessionSyncPreviewScan(
                    updateStatus: false
                )
                hasPendingSessionRecovery = true
                sessionSyncPreview = nil
                sessionSyncStatus =
                    "发现未完成事务（"
                    + pending.phase.rawValue
                    + "）；恢复前禁止继续切换"
                return
            }
            hasPendingSessionRecovery = false
        } catch {
            cancelSessionSyncPreviewScan(
                updateStatus: false
            )
            sessionSyncPreview = nil
            sessionSyncStatus =
                "历史会话扫描未通过："
                + error.localizedDescription
            return
        }

        if !force {
            if isSessionSyncScanning {
                return
            }
            if sessionPreviewController.hasFreshResult(
                hasPreview: sessionSyncPreview != nil
            ) {
                return
            }
        }

        let target: ConfigWorkspaceSessionTarget
        do {
            target = try currentSessionTarget()
        } catch {
            cancelSessionSyncPreviewScan(
                updateStatus: false
            )
            sessionSyncPreview = nil
            sessionSyncStatus =
                "历史会话扫描未通过："
                + error.localizedDescription
            return
        }

        cancelSessionSyncPreviewScan(
            updateStatus: false
        )
        let engine = sessionSyncEngine
        let recoveryFiles =
            sessionRecoveryFiles
        let trustSourceOrigin =
            codexRuntimeMode != .external
        let previewOperation =
            dependencies.sessionPreviewOperation
        isSessionSyncScanning = true
        sessionSyncStatus =
            "正在后台扫描历史会话；可继续使用其他页面"

        sessionPreviewController.scan(
            ConfigWorkspaceSessionPreviewRequest(
                engine: engine,
                providerID: target.providerID,
                profileID: target.profileID,
                trustSourceOrigin: trustSourceOrigin,
                recoveryFiles: recoveryFiles,
                operation: previewOperation
            )
        )
    }

    func cancelSessionSyncPreviewScan() {
        cancelSessionSyncPreviewScan(
            updateStatus: true
        )
    }

    private func cancelSessionSyncPreviewScan(
        updateStatus: Bool
    ) {
        guard sessionPreviewController.isRunning
                || isSessionSyncScanning
        else { return }
        sessionPreviewController.cancel()
        isSessionSyncScanning = false
        if updateStatus {
            sessionSyncStatus =
                sessionSyncPreview == nil
                    ? "历史会话扫描已暂停"
                    : "历史会话扫描已暂停；显示上次结果"
        }
    }

    func configWorkspaceSessionPreviewDidFinish(
        _ outcome: SessionPreviewScanOutcome
    ) {
        isSessionSyncScanning = false
        switch outcome {
        case let .preview(preview):
            sessionSyncPreview = preview
            let repair = preview.needsRepair
                ? "需要修复"
                : "当前已一致"
            sessionSyncStatus =
                "共\(preview.uniqueThreadCount)个；"
                + "当前可见\(preview.currentlyVisibleThreadCount)个；"
                + repair
                + (
                    preview.blockers.isEmpty
                        ? ""
                        : "；"
                            + preview.blockers
                                .joined(
                                    separator: "；"
                                )
                )
        case let .failed(message):
            sessionSyncPreview = nil
            sessionSyncStatus =
                "历史会话扫描未通过："
                + message
        case .cancelled:
            sessionSyncStatus =
                sessionSyncPreview == nil
                    ? "历史会话扫描已暂停"
                    : "历史会话扫描已暂停；显示上次结果"
        }
    }

    func repairSessionsToCurrentMode() {
        guard !isSessionSyncWorking else {
            errorMessage =
                "历史会话正在处理，请等待当前步骤完成"
            return
        }
        guard sessionSyncAuthorized else {
            errorMessage =
                "请先勾选“切换时自动保持全部历史会话可见”"
            return
        }
        guard confirmsWorkSaved else {
            errorMessage =
                "请先勾选“我确认当前Codex工作已保存”，再开始修复"
            return
        }
        let application = CodexApplicationController()
        let workDecision = CodexWorkSafetyGate.evaluate(
            isRunning: application.isRunning,
            userConfirmedSavedWork: confirmsWorkSaved
        )
        guard workDecision.allowsQuit else {
            errorMessage = workDecision.message
            return
        }
        isSessionSyncWorking = true
        sessionSyncPhase = .preflight
        sessionSyncStatus =
            "正在核对当前模式和会话修复条件"
        errorMessage = nil
        sessionRepairController.repair(
            application: application,
            resolveTarget: {
                let target =
                    try self.currentSessionTarget()
                return ConfigWorkspaceSessionRepairTarget(
                    providerID: target.providerID,
                    profileID: target.profileID
                )
            },
            additionalRecoveryFiles: sessionRecoveryFiles
        )
    }

    func restoreLastSessionRepair() {
        guard !isSessionSyncWorking else { return }
        let application = CodexApplicationController()
        let workDecision = CodexWorkSafetyGate.evaluate(
            isRunning: application.isRunning,
            userConfirmedSavedWork: confirmsWorkSaved
        )
        guard workDecision.allowsQuit else {
            errorMessage = workDecision.message
            return
        }
        isSessionSyncWorking = true
        sessionSyncStatus =
            "正在准备恢复上次历史会话修复"
        sessionRepairController.restoreLatest(
            application: application
        )
    }

    func recoverPendingSessionTransaction() {
        guard !isSessionSyncWorking else { return }
        let application = CodexApplicationController()
        let workDecision = CodexWorkSafetyGate.evaluate(
            isRunning: application.isRunning,
            userConfirmedSavedWork: confirmsWorkSaved
        )
        guard workDecision.allowsQuit else {
            errorMessage = workDecision.message
            return
        }
        isSessionSyncWorking = true
        sessionSyncStatus =
            "正在准备恢复未完成事务"
        sessionRepairController.recoverPending(
            application: application
        )
    }

    func configWorkspaceSessionRepairDidReportStatus(
        _ status: String
    ) {
        sessionSyncStatus = status
    }

    func configWorkspaceSessionRepairDidReportProgress(
        phase: SessionSyncPhase,
        status: String
    ) {
        sessionSyncPhase = phase
        sessionSyncStatus = status
    }

    func configWorkspaceSessionRepairDidFinish(
        _ result: ConfigWorkspaceSessionRepairResult
    ) {
        switch result {
        case .repaired:
            sessionSyncStatus =
                "历史会话已修复；Codex原生侧栏应显示全部会话"
            hasPendingSessionRecovery = false
            errorMessage = nil
            refreshSessionSyncPreview(force: true)
        case let .failed(message, hasPendingRecovery):
            sessionSyncStatus =
                "历史会话修复失败，已恢复"
            errorMessage = message
            hasPendingSessionRecovery = hasPendingRecovery
        }
        isSessionSyncWorking = false
    }

    func configWorkspaceSessionRestoreDidFinish(
        _ result: ConfigWorkspaceSessionRestoreResult
    ) {
        switch result {
        case .restored:
            sessionSyncStatus =
                "已恢复上次历史会话修复并重开Codex"
            errorMessage = nil
            refreshSessionSyncPreview(force: true)
        case let .failed(message):
            errorMessage =
                "恢复上次会话修复失败：" + message
        }
        isSessionSyncWorking = false
    }

    func configWorkspacePendingSessionRecoveryDidFinish(
        _ result:
            ConfigWorkspacePendingSessionRecoveryResult
    ) {
        switch result {
        case let .recovered(count):
            hasPendingSessionRecovery = false
            sessionSyncStatus =
                "已恢复\(count)个未完成事务"
            errorMessage = nil
            refreshSessionSyncPreview(force: true)
        case let .failed(message):
            hasPendingSessionRecovery = true
            errorMessage =
                "未完成事务恢复失败：" + message
        }
        isSessionSyncWorking = false
    }

    func sessionOpenBlockReason(
        _ session: SessionSyncListItem
    ) -> String? {
        do {
            let target = try currentSessionTarget()
            return try ConfigWorkspaceSessionOpenSafetyService(
                configURL: codexHomeURL
                    .appendingPathComponent("config.toml")
            ).blockReason(
                sessionProvider: session.observedProvider,
                currentProvider: target.providerID,
                runtimeTruth: runtimeTruth
            )
        } catch {
            return "无法安全核对当前Provider，请先重新扫描并修复到当前模式"
        }
    }

    private func currentSessionTarget() throws ->
        ConfigWorkspaceSessionTarget {
        try sessionPolicyService.currentTarget()
    }

    private func clearAcceptedRuntimeDrift() {
        runtimeDriftDetected = false
        runtimeDriftSummary = ""
        externalChangeDetected = false
        externalChangeSummary = ""
    }

    func dismissRuntimeDrift() {
        runtimeDriftDetected = false
        runtimeDriftSummary = ""
        externalChangeDetected = false
        externalChangeSummary = ""
        realSwitchStatus = "已确认暂不处理；当前观察设为新基线，后续变化仍会提示"
    }

    func refreshConfigurationHealth(
        expectedProviderID: String? = nil,
        expectedCodexContractID: String? = nil,
        expectedProfileID: String? = nil,
        expectedCapabilityProfileSHA256: String? = nil,
        providerProbeReceipts:
            [ProviderCapabilityProbeReceipt] = []
    ) {
        refreshRuntimeTruth()
        do {
            configurationHealth = try
                ConfigWorkspaceConfigurationHealthService(
                    codexHomeURL: codexHomeURL,
                    controlRootURL: controlRoot,
                    adapter: realAdapter,
                    stateStore: realStateStore
                ).evaluate(
                    ConfigWorkspaceConfigurationHealthRequest(
                        runtimeTruth: runtimeTruth,
                        expectedAgentVersion:
                            runtimeTruthService
                                .installedCodexVersion(),
                        expectedProviderID:
                            expectedProviderID,
                        expectedCodexContractID:
                            expectedCodexContractID,
                        expectedProfileID:
                            expectedProfileID,
                        expectedCapabilityProfileSHA256:
                            expectedCapabilityProfileSHA256,
                        providerProbeReceipts:
                            providerProbeReceipts
                    )
                )
            errorMessage = nil
        } catch {
            configurationHealth = ConfigurationHealthEvaluator.evaluate(
                configText: "",
                runtimeTruth: runtimeTruth,
                lastTransaction: nil
            )
            errorMessage = "配置体检无法读取助手状态：\(error.localizedDescription)"
        }
    }

    func establishOfficialBaseline() {
        guard agent == .codexDesktop else {
            errorMessage = "当前只开放 Codex Desktop 真实接入"
            return
        }
        guard confirmsOfficialMode, confirmsRealWrite else {
            errorMessage = "先确认当前确实是可用的官方模式，并授权建立加密基线"
            return
        }
        refreshRuntimeTruth()
        guard runtimeTruth?.runtimeMode == .official,
              runtimeTruth?.allowsManagedWrite == true else {
            errorMessage = "真实配置不是已确认的官方状态：\(runtimeTruthStatus)"
            return
        }
        do {
            let baseline = try realEngine.createOfficialBaseline()
            officialBaseline = baseline
            codexRuntimeMode = .official
            realSwitchStatus = "官方候选基线已加密保存；完成官方真实请求后才能标记为已验证"
            errorMessage = nil
        } catch {
            errorMessage = "建立官方基线失败：\(error.localizedDescription)"
        }
    }

    func importExistingProviderReadOnly() {
        do {
            let adoption = try existingProviderService
                .adoptReadOnly(
                    displayName: existingProviderDisplayName
                )
            let result = adoption.imported
            existingProviderImportReport = result.report
            codexPlan = adoption.plan
            codexRuntimeMode = .relay
            selectedRelayID = result.profile.id
            importedProviderID = result.profile.providerID
            providerName = result.profile.name
            baseURL = result.profile.baseURL
            wireProtocol = result.profile.wireProtocol
            modelNames = result.profile.models
            modelName = result.profile.defaultModel
            contextWindow = result.profile.contextWindow.map(String.init) ?? ""
            autoCompactTokenLimit = result.profile.autoCompactTokenLimit.map(String.init) ?? ""
            reasoningEffort = result.profile.reasoningEffort
            savedRelayProfiles = (try? realStateStore.load().relayProfiles) ?? []
            refreshRuntimeTruth()
            runtimeDriftDetected = false
            runtimeDriftSummary = ""
            realSwitchStatus =
                "已只读接管 \(result.profile.name)；config.toml字节未变。"
                + (
                    result.report
                        .legacyBearerFieldPresent
                        ? "进入执行页后，可在统一恢复点保护下一次性迁移现有认证。"
                        : "认证来源仍需核对后再执行真实验证。"
                )
            errorMessage = nil
        } catch {
            errorMessage = "现有Provider只读接管失败：\(error.localizedDescription)"
        }
    }

    private func refreshExistingProviderMigrationState(
        _ state: CodexStateStore.State
    ) {
        do {
            guard let migration = try existingProviderService
                .migration(for: state) else { return }
            existingProviderImportReport = migration.report
            codexPlan = migration.plan
            realSwitchStatus =
                migration.usesLegacyBearer
                ? "当前中转仍使用旧明文认证；进入执行页可在统一恢复点保护下一次性迁移"
                : "当前中转仍依赖环境变量；请在安全输入框填写Key后完成持久凭据迁移"
        } catch {
            realSwitchStatus =
                "当前中转认证尚未完成持久化接管："
                + error.localizedDescription
        }
    }

    func prepareCodexExecution() {
        guard officialBaseline != nil else {
            errorMessage = "先建立官方配置基线"
            return
        }
        refreshRuntimeTruth()
        guard allowsManagedWrite else {
            errorMessage = "真实状态核对未通过：\(runtimeTruthStatus)"
            return
        }
        do {
            codexPlan = try realEngine.prepareRelay(profile: codexRelayProfile)
            realSwitchStatus = selectedAccessRoute == .manual
                ? "手动配置块已生成；保存后点击检查"
                : "配置差异已生成；等待最终确认"
            errorMessage = nil
        } catch {
            if error is CodexControlError {
                selectedAccessRoute = .manual
                codexPlan = try? PreservingTOMLEditor.plan(original: "", profile: codexRelayProfile)
                realSwitchStatus = "自动写入已阻止，已转手动修复路径"
                errorMessage = "现有config.toml无法安全自动处理：\(error.localizedDescription)。请按手动步骤修复后再检查。"
            } else {
                codexPlan = nil
                errorMessage = "无法生成安全配置计划：\(error.localizedDescription)"
            }
        }
    }

    func copyManualConfiguration() {
        guard let block = codexPlan?.manualBlock else { return }
        manualHandoffService.copyManualConfiguration(block)
        realSwitchStatus = "配置块已复制；API Key不在剪贴板内容中"
    }

    func openCodexConfiguration() {
        if let status = manualHandoffService.openConfiguration(
            at: realAdapter.configURL
        ) {
            realSwitchStatus = status
        }
    }

    func openExternalTool() {
        guard officialBaseline != nil, codexPlan != nil else {
            errorMessage = "先建立官方基线并生成配置差异"
            return
        }
        do {
            guard let status = try manualHandoffService
                .openExternalTool(
                    route: selectedAccessRoute,
                    relayID: selectedRelayID,
                    draft: draft
                ) else {
                return
            }
            realSwitchStatus = status
            errorMessage = nil
        } catch {
            errorMessage = "无法打开配置工具：\(error.localizedDescription)"
        }
    }

    func inspectExternalChange() {
        guard let baseline = officialBaseline else {
            errorMessage = "没有官方基线"
            return
        }
        do {
            let inspection = try existingProviderService
                .inspectChange(from: baseline)
            externalChangeDetected = inspection.detected
            if externalChangeDetected { codexRuntimeMode = .external }
            externalChangeSummary = "config.toml：\(inspection.configChanged ? "已改变" : "未改变")；auth.json：\(inspection.authChanged ? "已改变，将恢复官方认证" : "未改变")"
            realSwitchStatus = externalChangeDetected ? "已发现外部工具写入，请选择处理方式" : "没有发现外部工具写入"
            errorMessage = nil
        } catch {
            errorMessage = "外部改动检查失败：\(error.localizedDescription)"
        }
    }

    func handleExternalDrift(_ choice: ExternalDriftChoice) {
        switch choice {
        case .saveRelay:
            prepareAndSaveExternalRelay()
        case .restoreKnown:
            restoreOfficialMode()
        case .cancel:
            dismissRuntimeDrift()
        }
    }

    private func prepareAndSaveExternalRelay() {
        do {
            let result: ExistingProviderImportResult
            let plan: CodexConfigurationPlan
            switch try existingProviderService
                .prepareExternalRelay(
                    displayName: existingProviderDisplayName,
                    enteredAPIKey: apiKey,
                    allowsLegacyBearerRemoval: confirmsRealWrite
                ) {
            case .missingCredential:
                errorMessage = "已识别当前中转配置，但缺少中转Key。请在安全输入框填写Key后重试；尚未写入任何文件。"
                return
            case .requiresLegacyBearerAuthorization:
                errorMessage = "当前配置含旧Bearer字段。必须先授权白名单事务，才能在真实验证和回滚保护下删除。"
                return
            case let .ready(imported, preparedPlan):
                result = imported
                plan = preparedPlan
            }
            selectedRelayID = result.profile.id
            importedProviderID = result.profile.providerID
            providerName = result.profile.name
            baseURL = result.profile.baseURL
            wireProtocol = result.profile.wireProtocol
            modelNames = result.profile.models
            modelName = result.profile.defaultModel
            contextWindow = result.profile.contextWindow.map(String.init) ?? ""
            autoCompactTokenLimit = result.profile.autoCompactTokenLimit.map(String.init) ?? ""
            reasoningEffort = result.profile.reasoningEffort
            codexPlan = plan
            existingProviderImportReport = result.report
            externalAdoptionExpectedConfigHash = result.report.configHashBefore
            executeRealRelaySwitch(normalizeExternalTool: true)
        } catch {
            errorMessage = "当前外部配置无法安全收编：\(error.localizedDescription)"
        }
    }

    func executeRealRelaySwitch(normalizeExternalTool: Bool = false) {
        guard !isRealSwitchWorking else { return }
        refreshBundledRecoveryHealth()
        guard bundledRecoveryAllowsManagedRelay else {
            errorMessage = bundledRecoveryStatus
            return
        }
        let application = CodexApplicationController()
        let workDecision = CodexWorkSafetyGate.evaluate(
            isRunning: application.isRunning,
            userConfirmedSavedWork: confirmsWorkSaved
        )
        guard officialBaseline != nil, confirmsCodexRestart,
              workDecision.allowsQuit, confirmsRealWrite,
              sessionSyncAuthorized else {
            errorMessage = "先确认允许关闭重开、工作已保存、授权白名单配置事务，并开启历史会话自动保持。\(workDecision.message)"
            return
        }
        refreshRuntimeTruth()
        let relayProfile = codexRelayProfile
        let manualConfigurationReady =
            selectedAccessRoute == .manual
                && codexRuntimeMode == .official
                && ((try? realAdapter.manualConfigurationMatches(
                    relayProfile
                )) == true)
        guard normalizeExternalTool || allowsManagedWrite
                || manualConfigurationReady else {
            errorMessage =
                "真实状态核对未通过：\(runtimeTruthStatus)"
            return
        }
        guard let plan = codexPlan else {
            errorMessage = "先生成配置差异"
            return
        }
        let normalizesExistingProvider =
            normalizeExternalTool
            || (
                existingProviderImportReport?.providerID
                    == (
                        relayProfile.providerID
                            ?? PreservingTOMLEditor
                                .providerIdentifier(
                                    relayProfile.id
                                )
                    )
                && existingProviderImportReport?
                    .legacyBearerFieldPresent == true
                && externalAdoptionExpectedConfigHash == nil
            )
        isRealSwitchWorking = true
        errorMessage = nil
        let request = ConfigWorkspaceRelaySwitchRequest(
            accessRoute: selectedAccessRoute,
            runtimeMode: codexRuntimeMode,
            profile: relayProfile,
            providerName: providerName,
            plan: plan,
            normalizesExistingProvider:
                normalizesExistingProvider,
            existingProviderImportReport:
                existingProviderImportReport,
            externalAdoptionExpectedConfigHash:
                externalAdoptionExpectedConfigHash,
            officialBaseline: officialBaseline,
            enteredAPIKey: apiKey,
            additionalRecoveryFiles:
                sessionRecoveryFiles,
            savedRelayProfiles: savedRelayProfiles
        )
        modeSwitchController.switchRelay(
            request: request,
            application: application,
            adapter: realAdapter,
            stateStore: realStateStore,
            switchEngine: realEngine,
            sessionEngine: sessionSyncEngine
        )
    }

    func restoreOfficialMode() {
        let application = CodexApplicationController()
        let workDecision = CodexWorkSafetyGate.evaluate(
            isRunning: application.isRunning,
            userConfirmedSavedWork: confirmsWorkSaved
        )
        guard !isRealSwitchWorking, officialBaseline != nil,
              confirmsCodexRestart, workDecision.allowsQuit,
              sessionSyncAuthorized else {
            errorMessage = "先确认允许关闭重开、工作已保存、官方基线存在，并开启历史会话自动保持。\(workDecision.message)"
            return
        }
        isRealSwitchWorking = true
        let request = ConfigWorkspaceOfficialRestoreRequest(
            runtimeMode: codexRuntimeMode,
            additionalRecoveryFiles: sessionRecoveryFiles
        )
        modeSwitchController.restoreOfficial(
            request: request,
            application: application,
            stateStore: realStateStore,
            switchEngine: realEngine,
            sessionEngine: sessionSyncEngine
        )
    }

    func configWorkspaceModeSwitchDidReceive(
        _ event: ConfigWorkspaceRelaySwitchEvent
    ) {
        switch event {
        case let .phase(phase):
            realSwitchPhase = phase
        case let .status(status):
            realSwitchStatus = status
        }
    }

    func configWorkspaceModeSwitchDidFinish(
        _ outcome: ConfigWorkspaceModeSwitchOutcome
    ) {
        codexRuntimeMode = outcome.runtimeMode
        if case let .set(value) = outcome.officialBaseline {
            officialBaseline = value
        }
        if case let .set(value) = outcome.savedRelayProfiles {
            savedRelayProfiles = value
        }
        if case let .set(value) =
            outcome.existingProviderImportReport {
            existingProviderImportReport = value
        }
        if case let .set(value) =
            outcome.hasPendingSessionRecovery {
            hasPendingSessionRecovery = value
        }
        realSwitchPhase = outcome.phase
        realSwitchStatus = outcome.status
        errorMessage = outcome.errorMessage
        if outcome.clearsRuntimeDrift {
            externalChangeDetected = false
            runtimeDriftDetected = false
            runtimeDriftSummary = ""
        }
        if outcome.refreshesRuntimeTruth {
            refreshRuntimeTruth()
        }
        if outcome.refreshesCredentialBridge {
            refreshCredentialBridgeState()
        }
        if outcome.refreshesSessionPreview {
            refreshSessionSyncPreview(force: true)
        }
    }

    func configWorkspaceOfficialRestoreDidReportStatus(
        _ status: String
    ) {
        realSwitchStatus = status
    }

    func configWorkspaceModeSwitchDidBecomeIdle(
        resetRelayInput: Bool
    ) {
        isRealSwitchWorking = false
        guard resetRelayInput else { return }
        externalAdoptionExpectedConfigHash = nil
        apiKey = ""
    }

    func exitManagement() {
        refreshRuntimeTruth()
        guard codexRuntimeMode == .official,
              runtimeTruth?.runtimeMode == .official,
              runtimeTruth?.allowsManagedWrite == true,
              confirmsOfficialRecoveryTest else {
            errorMessage = "退出托管已阻止：先切回官方、重新核对状态，并确认官方真实请求成功"
            return
        }
        let result = ConfigWorkspaceManagementExitService(
            adapter: realAdapter,
            controlRoot: controlRoot
        ).execute(relayProfiles: savedRelayProfiles)
        switch result {
        case .exited:
            officialBaseline = nil
            savedRelayProfiles = []
            codexPlan = nil
            exitManagementStatus = "托管数据、助手Keychain项和加密快照已移除；官方配置与auth.json未修改"
            realSwitchStatus = exitManagementStatus
            errorMessage = nil
        case let .blocked(message):
            errorMessage = message
        case let .failed(message):
            errorMessage = "退出托管未完成：\(message)"
        }
    }

    func selectSavedRelayProfile(_ profile: CodexRelayProfile) {
        guard !unverifiedLegacyRelayProfileIDs
                .contains(profile.id) else {
            errorMessage =
                "这是升级前保存的未验证旧档；请重新导入真实配置或核对后另存，当前不会参与切换"
            return
        }
        selectedRelayID = profile.id
        importedProviderID = profile.providerID
        providerName = profile.name
        baseURL = profile.baseURL
        wireProtocol = profile.wireProtocol
        modelNames = profile.models
        modelName = profile.defaultModel
        contextWindow = profile.contextWindow.map(String.init) ?? ""
        autoCompactTokenLimit = profile.autoCompactTokenLimit.map(String.init) ?? ""
        reasoningEffort = profile.reasoningEffort
        confirmsLocalGateway = profile.localGatewayConfirmed == true
        applyCapabilityConfiguration(from: profile)
        selectedAccessRoute = .managed
        do {
            codexPlan = try realEngine.prepareRelay(profile: profile)
            realSwitchStatus = "已选择保存的中转配置档：\(profile.name)"
            errorMessage = nil
        } catch {
            errorMessage = "无法准备保存的配置档：\(error.localizedDescription)"
        }
    }

    func observeCodexApplicationLaunch(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              application.bundleIdentifier == CodexApplicationController.bundleIdentifier else {
            return
        }
        refreshRuntimeTruth()
        refreshCredentialBridgeState()
        if runtimeTruth?.runtimeMode == .relay,
           codexRuntimeMode != .relay {
            _ = reconcileKnownRelayFromDisk()
        }
        if codexRuntimeMode == .relay,
           credentialBridgeState == .ready {
            realSwitchStatus =
                "Codex已从普通入口启动；持久凭据桥可用"
        }
        refreshSessionSyncPreview()
    }

    private func reconcileKnownRelayFromDisk() -> Bool {
        switch ConfigWorkspaceKnownRelayReconciliationService(
            adapter: realAdapter,
            stateStore: realStateStore,
            engine: realEngine
        ).reconcile() {
        case let .reconciled(state):
            synchronizeControlState(state)
            refreshRuntimeTruth()
            return true
        case .unmatched:
            realSwitchStatus =
                "真实配置是中转，但无法唯一匹配已保存配置档"
            return false
        case let .failed(message):
            errorMessage =
                "中转轨道记录纠正失败：" + message
            return false
        }
    }

    func applySelectedRelayPreset() {
        guard let relay = selectedRelay else { return }
        providerName = relay.name
        documentURL = relay.documentationURL
        if let base = relay.defaultBaseURL { baseURL = base }
        if let first = relay.verifiedProtocols.first { wireProtocol = first }
        let source = "预设目录；核验日期 \(relay.lastVerified)"
        evidence.removeAll { ["供应商", "Base URL", "协议"].contains($0.field) && $0.status == .verified }
        evidence.append(FieldEvidence(field: "供应商", value: relay.name, source: source, status: .verified))
        if let base = relay.defaultBaseURL {
            evidence.append(FieldEvidence(field: "Base URL", value: base, source: relay.documentationURL, status: .verified))
        }
        for item in relay.verifiedProtocols {
            evidence.append(FieldEvidence(field: "协议", value: item.rawValue, source: relay.documentationURL, status: .verified))
        }
        let presetText = """
        供应商：\(relay.name)
        \(relay.defaultBaseURL.map { "Base URL：\($0)" } ?? "")
        \(relay.verifiedProtocols.map { "协议：\($0.rawValue)" }.joined(separator: "\n"))
        """
        configurationSources.removeAll { $0.kind == .verifiedPreset }
        configurationSources.append(ConfigurationSourceEngine.sanitizedSource(
            kind: .verifiedPreset,
            title: "\(relay.name) 已核验预设",
            text: presetText,
            location: relay.documentationURL
        ))
        rebuildUnifiedResult(applyValues: true)
    }

    func applyAgentDefaults() {
        let defaults = agent.userConfirmedDefaults
        contextWindow = defaults.contextWindow.map(String.init) ?? ""
        autoCompactTokenLimit = defaults.autoCompactTokenLimit.map(String.init) ?? ""
        reasoningEnabled = defaults.reasoningEnabled ?? true
        reasoningEffort = defaults.reasoningEffort ?? .automatic
        supportsTextInput = defaults.supportsTextInput ?? true
        supportsImageInput = defaults.supportsImageInput ?? true
        evidence.removeAll { $0.status == .userConfirmed }
        if let value = defaults.contextWindow {
            evidence.append(FieldEvidence(field: "上下文", value: String(value), source: "用户 2026-07-18 确认的 \(agent.rawValue) 参数", status: .userConfirmed))
        }
        if let value = defaults.autoCompactTokenLimit {
            evidence.append(FieldEvidence(field: "自动压缩阈值", value: String(value), source: "用户 2026-07-18 确认的 \(agent.rawValue) 参数", status: .userConfirmed))
        }
        if defaults.contextWindow == nil {
            evidence.append(FieldEvidence(field: "上下文", value: "由具体模型决定", source: "目标桌面端不固定模型能力", status: .unknown))
        }
        evidence.append(FieldEvidence(field: "文本输入", value: supportsTextInput ? "支持" : "不支持", source: "目标 Agent 能力", status: .userConfirmed))
        evidence.append(FieldEvidence(field: "图片输入", value: supportsImageInput ? "支持" : "不支持", source: "目标 Agent 能力", status: .userConfirmed))
        invalidatePreview()
    }

    func invalidatePreview() {
        preview = nil
        confirmed = false
        exportURL = nil
        errorMessage = nil
    }

    func refreshDocument() {
        isRefreshingDocument = true
        documentStatus = "正在读取并整理全文"
        errorMessage = nil
        sourceAcquisitionController.acquireDocument(
            urlString: documentURL
        )
    }

    func applyExtractedConfiguration() {
        if let value = extracted.providerName { providerName = value }
        if let value = extracted.baseURL { baseURL = value }
        if let value = extracted.protocols.first { wireProtocol = value }
        if !extracted.models.isEmpty {
            for value in extracted.models where !modelNames.contains(value) { modelNames.append(value) }
            if modelName.isEmpty, let value = extracted.models.first { modelName = value }
        }
        if let value = extracted.capabilities.contextWindow { contextWindow = String(value) }
        if let value = extracted.capabilities.autoCompactTokenLimit { autoCompactTokenLimit = String(value) }
        if let value = extracted.capabilities.reasoningEnabled { reasoningEnabled = value }
        if let value = extracted.capabilities.reasoningEffort { reasoningEffort = value }
        if let value = extracted.capabilities.supportsTextInput { supportsTextInput = value }
        if let value = extracted.capabilities.supportsImageInput { supportsImageInput = value }
        if let value = extracted.capabilities.serviceTier {
            switch value {
            case "fast":
                serviceTierKind = .fast
                serviceTierCustomValue = ""
            case "standard":
                serviceTierKind = .standard
                serviceTierCustomValue = ""
            case "flex":
                serviceTierKind = .flex
                serviceTierCustomValue = ""
            default:
                serviceTierKind = .providerSpecific
                serviceTierCustomValue = value
            }
        }
        if let value = extracted.capabilities.fastMode {
            fastModeSetting = ProviderOptionalBooleanSetting(value: value)
        }
        if let value = extracted.capabilities.webSearch {
            webSearchSetting = ProviderWebSearchSetting(configuredValue: value)
        }
        if let value = extracted.capabilities.modelVerbosity {
            modelVerbositySetting = ProviderModelVerbositySetting(
                configuredValue: value
            )
        }
        if let value = extracted.capabilities.disableResponseStorage {
            responseStorageDisabledSetting =
                ProviderOptionalBooleanSetting(value: value)
        }
        if let value = extracted.capabilities.upstreamName {
            providerCompatibilityName = value
        }
        evidence.removeAll { $0.status == .extracted }
        evidence.append(contentsOf: extracted.evidence)
        invalidatePreview()
    }

    func addPastedSource() {
        let value = pastedConfigurationText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            errorMessage = "先粘贴中转配置文字"
            return
        }
        configurationSources.removeAll { $0.kind == .pastedText }
        configurationSources.append(ConfigurationSourceEngine.sanitizedSource(
            kind: .pastedText,
            title: "用户粘贴文字",
            text: value,
            location: "粘贴文字"
        ))
        rebuildUnifiedResult(applyValues: true)
        errorMessage = nil
    }

    func addModel() {
        let value = newModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if !modelNames.contains(value) { modelNames.append(value) }
        if modelName.isEmpty { modelName = value }
        newModelName = ""
        // A successful manual addition supersedes a prior /models warning.
        modelFetchStatus = "已手动添加模型：\(value)"
        if errorMessage == ModelCatalogError.emptyModels.localizedDescription {
            errorMessage = nil
        }
        recordManualField("模型", value: value)
        invalidatePreview()
    }

    func removeModel(_ value: String) {
        modelNames.removeAll { $0 == value }
        if modelName == value { modelName = modelNames.first ?? "" }
        invalidatePreview()
    }

    func selectDefaultModel(_ value: String) {
        modelName = value
        recordManualField("默认模型", value: value)
        invalidatePreview()
    }

    func fetchModels() {
        isFetchingModels = true
        modelFetchStatus = "正在安全读取模型列表"
        errorMessage = nil
        sourceAcquisitionController.acquireModels(
            baseURL: baseURL,
            apiKey: apiKey,
            wireProtocol: wireProtocol,
            confirmedLocalGateway: confirmsLocalGateway
        )
    }

    func recordManualField(_ field: String, value: String) {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        evidence.removeAll { $0.field == field && $0.status == .userConfirmed }
        guard !cleaned.isEmpty else { return }
        evidence.append(FieldEvidence(field: field, value: cleaned, source: "用户手动填写", status: .userConfirmed))
    }

    func addScreenshots(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isReadingScreenshots = true
        screenshotStatus = "正在本机识别 \(urls.count) 张截图"
        errorMessage = nil
        sourceAcquisitionController.acquireScreenshots(urls)
    }

    func setScreenshotKind(sourceID: UUID, kind: ScreenshotConfigurationKind) {
        guard let index = configurationSources.firstIndex(where: { $0.id == sourceID }) else { return }
        configurationSources[index].screenshotKind = kind
        configurationSources[index].kind = kind == .currentSettings
            ? .currentSettingsScreenshot
            : .relayScreenshot
        rebuildUnifiedResult(applyValues: true)
    }

    func removeSource(_ id: UUID) {
        configurationSources.removeAll { $0.id == id }
        rebuildUnifiedResult(applyValues: true)
    }

    func resolveConflict(field: String, value: String) {
        conflictResolutions[field] = value
        rebuildUnifiedResult(applyValues: true)
    }

    func rebuildUnifiedResult(applyValues: Bool) {
        let result = ConfigurationSourceEngine.merge(configurationSources, resolutions: conflictResolutions)
        unifiedResult = result
        extracted = result.extracted
        evidence = result.extracted.evidence
        if applyValues { applyExtractedConfiguration() }
    }

    func createSimulatedProfiles() {
        simulationController.createProfiles(
            ConfigWorkspaceSimulationRequest(
                providerName: providerName,
                baseURL: baseURL,
                modelName: modelName,
                relayID: selectedRelayID,
                agent: agent
            )
        )
    }

    func simulateSwitch(to profileID: String) {
        simulationController.switchProfile(
            to: profileID,
            compatibility: compatibility
        )
    }

    func configWorkspaceSimulationDidFinish(
        _ outcome: ConfigWorkspaceSimulationOutcome
    ) {
        switch outcome {
        case let .profilesCreated(
            profiles,
            activeProfileID,
            status
        ):
            managedProfiles = profiles
            self.activeSimulatedProfileID = activeProfileID
            simulationStatus = status
        case let .switched(activeProfileID, status):
            self.activeSimulatedProfileID = activeProfileID
            simulationStatus = status
        case let .failed(status):
            simulationStatus = status
        }
    }

    func generatePreview() {
        errorMessage = nil
        exportURL = nil
        confirmed = false
        do {
            preview = try ConfigWorkspaceArtifactService.generate(
                draft: draft,
                manager: manager,
                compatibility: compatibility,
                safetyAudit: safetyAudit
            )
        } catch {
            preview = nil
            errorMessage = error.localizedDescription
        }
    }

    func exportConfirmedConfiguration() {
        guard confirmed, let preview else {
            errorMessage = "先预览并勾选确认"
            return
        }
        guard safetyAudit.allowed else {
            errorMessage = "安全检查阻止导出：\(safetyAudit.reasons.joined(separator: "；"))"
            return
        }
        do {
            exportURL = try ConfigWorkspaceArtifactService
                .export(preview)
        } catch {
            errorMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    func goNext() {
        guard let next = ConfigurationWizardStep(rawValue: wizardStep.rawValue + 1) else { return }
        wizardStep = next
    }

    func goBack() {
        guard let previous = ConfigurationWizardStep(rawValue: wizardStep.rawValue - 1) else { return }
        wizardStep = previous
    }
}
