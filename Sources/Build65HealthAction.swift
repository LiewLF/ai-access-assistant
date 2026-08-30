// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation

/// Build 65 warning contract: every user-visible warning either has a real
/// handling action or is hidden from the beginner surface (kept in advanced
/// diagnostics). Severity, impact, action and plain-language summary come
/// from one decision; dismissals are bound to an evidence fingerprint.
///
/// This file is read-model and action-contract only. The copy action calls
/// the existing ManagedModelCatalogStore; nothing here writes an external
/// catalog file or switches provider/model/effort/tier/endpoint/token.

enum Build65WarningSeverity: String, Codable, CaseIterable, Sendable {
    case informational
    case warning
    case blocking
}

enum Build65WarningImpact: String, Codable, CaseIterable, Sendable {
    case none
    case futureSwitch
    case currentOperation
    case currentRuntime
}

enum Build65WarningActionKind: String, Codable, CaseIterable, Sendable {
    case none
    case recheck
    case openManagedCatalog
    case copyAsManaged
    case keepCurrent
    case exportDiagnostic
    case viewTechnicalDetail
    case cancel
}

struct Build65WarningAction: Codable, Equatable, Sendable {
    let severity: Build65WarningSeverity
    let impact: Build65WarningImpact
    let actionKind: Build65WarningActionKind
    let actionTitle: String
    let plainLanguageSummary: String
    let evidenceFingerprint: String?

    /// Beginner surface: only actionable/blocking warnings are shown; an
    /// informational item collapses to the "非阻断信息" count.
    var beginnerVisible: Bool {
        severity != .informational
    }

    var dismissable: Bool {
        impact == .none || impact == .futureSwitch
    }
}

enum Build65CatalogFailureCode: String, Codable, CaseIterable, Sendable {
    case catalogMissing = "catalog_missing"
    case catalogExternalUnverified = "catalog_external_unverified"
    case catalogHashMismatch = "catalog_hash_mismatch"
    case catalogProviderMismatch = "catalog_provider_mismatch"
    case catalogContractMismatch = "catalog_contract_mismatch"
    case catalogSchemaUnsupported = "catalog_schema_unsupported"
    case catalogModelMissing = "catalog_model_missing"
    case catalogUnsafePath = "catalog_unsafe_path"
    case catalogPermissionDenied = "catalog_permission_denied"
    case catalogRecheckUnavailable = "catalog_recheck_unavailable"
}

struct Build65CatalogFailurePresentation:
    Codable, Equatable, Sendable {
    let code: String
    let message: String
    let blocking: Bool
    let recommendedAction: Build65WarningActionKind
    let retryable: Bool

    static func from(_ code: Build65CatalogFailureCode) -> Self {
        switch code {
        case .catalogMissing:
            return .init(
                code: code.rawValue,
                message: "模型目录路径尚未生效。",
                blocking: false,
                recommendedAction: .recheck,
                retryable: true
            )
        case .catalogExternalUnverified:
            return .init(
                code: code.rawValue,
                message: "外部模型目录尚未完成核对。",
                blocking: false,
                recommendedAction: .copyAsManaged,
                retryable: true
            )
        case .catalogHashMismatch:
            return .init(
                code: code.rawValue,
                message: "模型目录内容已变化，与受管副本不一致。",
                blocking: true,
                recommendedAction: .recheck,
                retryable: true
            )
        case .catalogProviderMismatch:
            return .init(
                code: code.rawValue,
                message: "模型目录绑定的 Provider 与当前配置不匹配。",
                blocking: true,
                recommendedAction: .recheck,
                retryable: true
            )
        case .catalogContractMismatch:
            return .init(
                code: code.rawValue,
                message: "模型目录与当前 Codex 版本合同不匹配。",
                blocking: true,
                recommendedAction: .recheck,
                retryable: true
            )
        case .catalogSchemaUnsupported:
            return .init(
                code: code.rawValue,
                message: "模型目录格式版本不受当前助手支持。",
                blocking: true,
                recommendedAction: .exportDiagnostic,
                retryable: false
            )
        case .catalogModelMissing:
            return .init(
                code: code.rawValue,
                message: "当前选中模型不在模型目录中，切换可能被阻止。",
                blocking: true,
                recommendedAction: .recheck,
                retryable: true
            )
        case .catalogUnsafePath:
            return .init(
                code: code.rawValue,
                message: "模型目录路径不安全，助手不会读取该位置。",
                blocking: true,
                recommendedAction: .exportDiagnostic,
                retryable: false
            )
        case .catalogPermissionDenied:
            return .init(
                code: code.rawValue,
                message: "模型目录权限不足，无法核对。",
                blocking: true,
                recommendedAction: .exportDiagnostic,
                retryable: true
            )
        case .catalogRecheckUnavailable:
            return .init(
                code: code.rawValue,
                message: "暂时无法重新核对模型目录，请稍后再试。",
                blocking: false,
                recommendedAction: .recheck,
                retryable: true
            )
        }
    }
}

/// Read-only local recheck of the model catalog: path identity, payload
/// hash, models and contract fields computed from disk + config. Never calls
/// a remote endpoint and never writes anything.
struct Build65CatalogInspection: Codable, Equatable, Sendable {
    let catalogPathPresent: Bool
    let catalogPathIdentity: String?
    let managed: Bool
    let payloadSHA256: String?
    let providerID: String?
    let codexContractID: String?
    let schemaVersion: Int?
    let modelIDs: [String]
    let selectedModelPresent: Bool
    let failureCode: Build65CatalogFailureCode?
    let externalSourceUnchanged: Bool

    var redactedEvidence: String {
        [
            "catalogPathPresent=\(catalogPathPresent)",
            "managed=\(managed)",
            "payloadSHA256=\(payloadSHA256?.prefix(12) ?? "nil")",
            "provider=\(providerID ?? "nil")",
            "contract=\(codexContractID?.prefix(8) ?? "nil")",
            "schema=\(schemaVersion.map(String.init) ?? "nil")",
            "models=\(modelIDs.count)",
            "selectedModelPresent=\(selectedModelPresent)",
            "failure=\(failureCode?.rawValue ?? "none")",
        ].joined(separator: " ")
    }
}

/// Runtime context passed from configuration health into the resolution UI.
/// It contains only the current catalog identity fields; the UI still reads
/// the external payload through the existing V011AccessModel writer path.
struct Build65CatalogResolutionContext:
    Codable, Equatable, Sendable {
    let profileID: String?
    let catalogPath: String?
    let providerID: String?
    let codexContractID: String?
    let selectedModelID: String?
}

/// User-confirmed copy request. The request is data-only; production writes
/// remain inside V011AccessModel.importManagedModelCatalog.
struct Build65CatalogCopyRequest: Equatable, Sendable {
    let sourceURL: URL
    let payloadSHA256: String?
    let profileID: String?
    let providerID: String?
    let codexContractID: String?
    let selectedModelID: String?
}

enum Build65CatalogInspector {
    static func inspect(
        catalogPath: String?,
        store: ManagedModelCatalogStore,
        configProviderID: String?,
        configContractID: String?,
        selectedModelID: String?
    ) -> Build65CatalogInspection {
        guard let catalogPath,
              !catalogPath.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty else {
            return Build65CatalogInspection(
                catalogPathPresent: false,
                catalogPathIdentity: nil,
                managed: false,
                payloadSHA256: nil,
                providerID: nil,
                codexContractID: nil,
                schemaVersion: nil,
                modelIDs: [],
                selectedModelPresent: false,
                failureCode: .catalogMissing,
                externalSourceUnchanged: true
            )
        }
        let normalized = URL(
            fileURLWithPath: catalogPath
        ).standardizedFileURL
        let pathIdentity = Self.pathIdentity(normalized.path)
        let trimmed = catalogPath.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmed.hasPrefix("/"),
              trimmed.utf8.count <= Int(PATH_MAX) else {
            return Build65CatalogInspection(
                catalogPathPresent: true,
                catalogPathIdentity: pathIdentity,
                managed: false,
                payloadSHA256: nil,
                providerID: nil,
                codexContractID: nil,
                schemaVersion: nil,
                modelIDs: [],
                selectedModelPresent: false,
                failureCode: .catalogUnsafePath,
                externalSourceUnchanged: true
            )
        }
        switch store.existingPathState(trimmed) {
        case .managed(let receipt):
            let metadata = receipt.metadata
            let selectedPresent = metadata.models.contains {
                $0.modelID == selectedModelID
            }
            if let configProviderID,
               metadata.providerID != configProviderID {
                return inspection(
                    pathIdentity,
                    managed: true,
                    failure: .catalogProviderMismatch,
                    selectedPresent: selectedPresent,
                    models: metadata.models.map(\.modelID),
                    provider: metadata.providerID,
                    contract: metadata.codexContractID,
                    schema: metadata.schemaVersion,
                    payloadHash: metadata.payloadSHA256
                )
            }
            if let configContractID,
               metadata.codexContractID != configContractID {
                return inspection(
                    pathIdentity,
                    managed: true,
                    failure: .catalogContractMismatch,
                    selectedPresent: selectedPresent,
                    models: metadata.models.map(\.modelID),
                    provider: metadata.providerID,
                    contract: metadata.codexContractID,
                    schema: metadata.schemaVersion,
                    payloadHash: metadata.payloadSHA256
                )
            }
            if metadata.schemaVersion
                != ManagedModelCatalogMetadata.currentSchemaVersion {
                return inspection(
                    pathIdentity,
                    managed: true,
                    failure: .catalogSchemaUnsupported,
                    selectedPresent: selectedPresent,
                    models: metadata.models.map(\.modelID),
                    provider: metadata.providerID,
                    contract: metadata.codexContractID,
                    schema: metadata.schemaVersion,
                    payloadHash: metadata.payloadSHA256
                )
            }
            if selectedModelID != nil,
               !selectedPresent {
                return inspection(
                    pathIdentity,
                    managed: true,
                    failure: .catalogModelMissing,
                    selectedPresent: false,
                    models: metadata.models.map(\.modelID),
                    provider: metadata.providerID,
                    contract: metadata.codexContractID,
                    schema: metadata.schemaVersion,
                    payloadHash: metadata.payloadSHA256
                )
            }
            return inspection(
                pathIdentity,
                managed: true,
                failure: nil,
                selectedPresent: selectedPresent,
                models: metadata.models.map(\.modelID),
                provider: metadata.providerID,
                contract: metadata.codexContractID,
                schema: metadata.schemaVersion,
                payloadHash: metadata.payloadSHA256
            )
        case .managedInvalid:
            return inspection(
                pathIdentity,
                managed: true,
                failure: .catalogHashMismatch,
                selectedPresent: false,
                models: []
            )
        case .externalExisting(let url):
            return inspectExternal(
                url,
                pathIdentity,
                store: store,
                selectedModelID: selectedModelID
            )
        case .externalMissing:
            return inspection(
                pathIdentity,
                managed: false,
                failure: .catalogExternalUnverified,
                selectedPresent: false,
                models: []
            )
        case .unsafe:
            return inspection(
                pathIdentity,
                managed: false,
                failure: .catalogUnsafePath,
                selectedPresent: false,
                models: []
            )
        case .absent:
            return inspection(
                pathIdentity,
                managed: false,
                failure: .catalogMissing,
                selectedPresent: false,
                models: []
            )
        }
    }

    private static func inspectExternal(
        _ url: URL,
        _ pathIdentity: String,
        store: ManagedModelCatalogStore,
        selectedModelID: String?
    ) -> Build65CatalogInspection {
        let before: Data
        do {
            before = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            return inspection(
                pathIdentity,
                managed: false,
                failure: .catalogPermissionDenied,
                selectedPresent: false,
                models: [],
                externalSourceUnchanged: false
            )
        }
        let payloadHash = Self.sha256(before)
        let models: [String]
        let failure: Build65CatalogFailureCode?
        if let parsed = try? store.parseModels(before) {
            models = parsed.map(\.modelID)
            if let selectedModelID,
               !parsed.contains(where: {
                   $0.modelID == selectedModelID
               }) {
                failure = .catalogModelMissing
            } else {
                failure = nil
            }
        } else {
            models = []
            failure = .catalogExternalUnverified
        }
        // Recheck is read-only: the source bytes must be untouched.
        guard let after = try? Data(
            contentsOf: url,
            options: .mappedIfSafe
        ), after == before else {
            return inspection(
                pathIdentity,
                managed: false,
                failure: .catalogRecheckUnavailable,
                selectedPresent: false,
                models: models,
                payloadHash: payloadHash,
                externalSourceUnchanged: false
            )
        }
        return Build65CatalogInspection(
            catalogPathPresent: true,
            catalogPathIdentity: pathIdentity,
            managed: false,
            payloadSHA256: payloadHash,
            providerID: nil,
            codexContractID: nil,
            schemaVersion: nil,
            modelIDs: models,
            selectedModelPresent: models.contains(selectedModelID ?? ""),
            failureCode: failure,
            externalSourceUnchanged: true
        )
    }

    private static func inspection(
        _ pathIdentity: String,
        managed: Bool,
        failure: Build65CatalogFailureCode?,
        selectedPresent: Bool,
        models: [String],
        provider: String? = nil,
        contract: String? = nil,
        schema: Int? = nil,
        payloadHash: String? = nil,
        externalSourceUnchanged: Bool = true
    ) -> Build65CatalogInspection {
        Build65CatalogInspection(
            catalogPathPresent: true,
            catalogPathIdentity: pathIdentity,
            managed: managed,
            payloadSHA256: payloadHash,
            providerID: provider,
            codexContractID: contract,
            schemaVersion: schema,
            modelIDs: models,
            selectedModelPresent: selectedPresent,
            failureCode: failure,
            externalSourceUnchanged: externalSourceUnchanged
        )
    }

    static func pathIdentity(_ path: String) -> String {
        let digest = Self.sha256(Data(path.utf8))
        return String(digest.prefix(16))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

/// Maps a configuration-health catalog item plus local inspection to one
/// warning action with severity/impact/plain-language summary. A catalog item
/// with no verified receipt but no current impact resolves informational
/// (hidden from the beginner surface); real problems resolve to the dialog.
enum Build65HealthActionResolver {
    static func resolveCatalog(
        itemState: ConfigurationHealthState,
        inspection: Build65CatalogInspection,
        connectionHealthy: Bool
    ) -> Build65WarningAction {
        if itemState == .notEnabled {
            return Build65WarningAction(
                severity: .informational,
                impact: .none,
                actionKind: .none,
                actionTitle: "",
                plainLanguageSummary: "未设置受管模型目录，功能未启用。",
                evidenceFingerprint: inspection.payloadSHA256
            )
        }
        guard let failure = inspection.failureCode else {
            // Catalog verifies locally; the remaining question is only the
            // verified receipt.
            return Build65WarningAction(
                severity: .informational,
                impact: .none,
                actionKind: .recheck,
                actionTitle: "重新核对目录",
                plainLanguageSummary:
                    connectionHealthy
                    ? "模型目录可用，当前使用不受影响。"
                    : "模型目录内容正常，连接状态需另行核对。",
                evidenceFingerprint: inspection.payloadSHA256
            )
        }
        let presentation = Build65CatalogFailurePresentation
            .from(failure)
        let impact: Build65WarningImpact
        switch failure {
        case .catalogMissing,
             .catalogExternalUnverified:
            impact = .futureSwitch
        case .catalogHashMismatch,
             .catalogModelMissing,
             .catalogUnsafePath,
             .catalogPermissionDenied:
            impact = .currentOperation
        case .catalogProviderMismatch,
             .catalogContractMismatch,
             .catalogSchemaUnsupported:
            impact = .futureSwitch
        case .catalogRecheckUnavailable:
            impact = .none
        }
        return Build65WarningAction(
            severity: presentation.blocking
                ? .blocking : .warning,
            impact: impact,
            actionKind: presentation.recommendedAction,
            actionTitle: presentation.recommendedAction == .recheck
                ? "重新核对目录"
                : (presentation.recommendedAction == .copyAsManaged
                    ? "复制为受管目录" : "查看技术详情"),
            plainLanguageSummary: presentation.message,
            evidenceFingerprint: inspection.payloadSHA256
        )
    }

    /// Source-level resolution window content when no live catalog context is
    /// available in the view. Best-effort failure-code mapping from the item
    /// detail; runtime context (payload hash, path identity, contract) is
    /// filled by the ConfigWorkspace integration and stays UNVERIFIED until
    /// installed-runtime replay.
    static func catalogResolution(
        item: ConfigurationHealthItem,
        semanticHash: String?
    ) -> (action: Build65WarningAction, dialog: Build65ManagedCatalogDialog) {
        let code: Build65CatalogFailureCode
        if item.state == .warning {
            code = item.detail.contains("尚未完成当前合同验证")
                ? .catalogExternalUnverified
                : .catalogRecheckUnavailable
        } else {
            let detail = item.detail
            if detail.contains("已变化")
                || detail.contains("hash") {
                code = .catalogHashMismatch
            } else if detail.contains("Provider")
                || detail.contains("不匹配") {
                code = .catalogProviderMismatch
            } else if detail.contains("合同") {
                code = .catalogContractMismatch
            } else if detail.contains("模型") {
                code = .catalogModelMissing
            } else if detail.contains("权限") {
                code = .catalogPermissionDenied
            } else {
                code = .catalogExternalUnverified
            }
        }
        let presentation = Build65CatalogFailurePresentation
            .from(code)
        let action = Build65WarningAction(
            severity: presentation.blocking
                ? .blocking : .warning,
            impact: presentation.blocking
                ? .currentOperation : .futureSwitch,
            actionKind: presentation.recommendedAction,
            actionTitle: presentation.recommendedAction == .recheck
                ? "重新核对目录"
                : (presentation.recommendedAction == .copyAsManaged
                    ? "复制为受管目录" : "查看技术详情"),
            plainLanguageSummary: presentation.message,
            evidenceFingerprint: semanticHash
        )
        let dialog = Build65ManagedCatalogDialog.build(
            action: action,
            inspection: Build65CatalogInspection(
                catalogPathPresent: true,
                catalogPathIdentity: nil,
                managed: false,
                payloadSHA256: nil,
                providerID: nil,
                codexContractID: nil,
                schemaVersion: nil,
                modelIDs: [],
                selectedModelPresent: true,
                failureCode: code,
                externalSourceUnchanged: true
            )
        )
        return (action, dialog)
    }

    /// Reverse audit: every warning/blocked configuration-health item has an
    /// action or is hidden from the beginner surface.
    static func resolveGeneric(
        item: ConfigurationHealthItem
    ) -> Build65WarningAction {
        switch item.state {
        case .passed, .notEnabled:
            return Build65WarningAction(
                severity: .informational,
                impact: .none,
                actionKind: .none,
                actionTitle: "",
                plainLanguageSummary: "\(item.title) 正常或未启用。",
                evidenceFingerprint: nil
            )
        case .unverified:
            return Build65WarningAction(
                severity: .informational,
                impact: .none,
                actionKind: .recheck,
                actionTitle: "重新核对",
                plainLanguageSummary: "\(item.title) 尚未验证，不影响当前使用。",
                evidenceFingerprint: nil
            )
        case .warning:
            return Build65WarningAction(
                severity: .warning,
                impact: .futureSwitch,
                actionKind: .recheck,
                actionTitle: "重新核对",
                plainLanguageSummary: item.detail,
                evidenceFingerprint: nil
            )
        case .blocked:
            return Build65WarningAction(
                severity: .blocking,
                impact: .currentOperation,
                actionKind: .exportDiagnostic,
                actionTitle: "查看技术详情",
                plainLanguageSummary: item.detail,
                evidenceFingerprint: nil
            )
        }
    }
}

/// Dismissal bound to evidence: any fingerprint change makes the old
/// dismissal invalid and the prompt reappears.
struct Build65CatalogDismissalFingerprint:
    Codable, Equatable, Sendable {
    let profileID: String?
    let providerID: String?
    let catalogPathIdentity: String?
    let catalogPayloadHash: String?
    let contractID: String?
    let schemaVersion: Int?
    let selectedModelID: String?
    let configurationSemanticHash: String?

    var isComplete: Bool {
        profileID?.isEmpty == false
            && providerID?.isEmpty == false
            && catalogPathIdentity?.isEmpty == false
            && catalogPayloadHash?.isEmpty == false
            && contractID?.isEmpty == false
            && selectedModelID?.isEmpty == false
            && configurationSemanticHash?.isEmpty == false
    }
}

struct Build65CatalogDismissal: Codable, Equatable, Sendable {
    let fingerprint: Build65CatalogDismissalFingerprint
    let dismissedAt: Date
}

enum Build65CatalogDismissalStoreError: Error, Equatable {
    case staleHash
    case invalidData
}

/// App-owned dismissal state (0600). Never writes the external catalog, the
/// configuration or any session data.
struct Build65CatalogDismissalStore {
    let url: URL
    private let fileManager: FileManager
    private static let processLock = NSLock()

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url.standardizedFileURL
        self.fileManager = fileManager
    }

    func read() throws -> Build65CatalogDismissal? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw Build65CatalogDismissalStoreError.invalidData
        }
        let data = try Data(contentsOf: url)
        guard let dismissal = try? JSONDecoder().decode(
            Build65CatalogDismissal.self,
            from: data
        ) else {
            throw Build65CatalogDismissalStoreError.invalidData
        }
        return dismissal
    }

    func isDismissed(
        _ fingerprint: Build65CatalogDismissalFingerprint
    ) -> Bool {
        guard let dismissal = try? read() else { return false }
        return dismissal.fingerprint == fingerprint
    }

    func dismiss(
        _ fingerprint: Build65CatalogDismissalFingerprint
    ) throws {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        if let existing = try? read(),
           existing.fingerprint == fingerprint {
            // Same evidence already dismissed: idempotent no-op.
            return
        }
        // Different evidence replaces the old dismissal: the prompt
        // reappears for changed evidence and a new dismissal binds to it.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            Build65CatalogDismissal(
                fingerprint: fingerprint,
                dismissedAt: Date()
            )
        )
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(
                ".b65-catalog-dismissal-\(UUID().uuidString).tmp"
            )
        try data.write(to: temporary, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporary.path
        )
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(
                url,
                withItemAt: temporary
            )
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }

    func clear() throws {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }
}

/// Plain-language resolution window data model. Answers the six questions:
/// what this is, whether it affects now, why it is prompted, recommended
/// action, what it changes, and how to exit.
struct Build65ManagedCatalogDialog: Codable, Equatable, Sendable {
    let title: String
    let whatIsThis: String
    let affectsNow: String
    let whyPrompted: String
    let recommendedAction: Build65WarningActionKind
    let recommendedActionTitle: String
    let whatChanges: String
    let howToExit: String
    let actions: [Build65WarningActionKind]
    let failureCode: String?

    static func build(
        action: Build65WarningAction,
        inspection: Build65CatalogInspection
    ) -> Build65ManagedCatalogDialog {
        let failure = inspection.failureCode
        let presentation = failure.map(
            Build65CatalogFailurePresentation.from
        )
        let affectsNow: String
        switch action.impact {
        case .none:
            affectsNow = "不影响现在：当前连接和当前模型不受影响。"
        case .futureSwitch:
            affectsNow = "不影响当前使用，但下一次切换可能被目录合同阻止。"
        case .currentOperation:
            affectsNow = "影响当前操作：模型目录问题可能阻止切换或模型选择。"
        case .currentRuntime:
            affectsNow = "影响当前运行：当前模型或目录状态需要处理。"
        }
        let recommended: Build65WarningActionKind
        switch action.actionKind {
        case .recheck:
            recommended = .recheck
        case .copyAsManaged:
            recommended = .copyAsManaged
        case .exportDiagnostic:
            recommended = .exportDiagnostic
        case .keepCurrent, .openManagedCatalog:
            recommended = .openManagedCatalog
        case .none, .cancel, .viewTechnicalDetail:
            recommended = .viewTechnicalDetail
        }
        var actions: [Build65WarningActionKind] = [recommended]
        if action.dismissable,
           recommended != .keepCurrent {
            actions.append(.keepCurrent)
        }
        actions.append(.viewTechnicalDetail)
        actions.append(.cancel)
        return Build65ManagedCatalogDialog(
            title: "处理受管模型目录",
            whatIsThis:
                "模型目录用于核对当前中转允许选择哪些模型。",
            affectsNow: affectsNow,
            whyPrompted: presentation?.message
                ?? "目录内容已核对，状态需要确认。",
            recommendedAction: recommended,
            recommendedActionTitle: action.actionTitle,
            whatChanges:
                "只读重核对不写任何文件；复制为受管目录会创建助手自有副本，不会覆盖外部源文件。",
            howToExit:
                "取消或保留当前配置即可退出，不会自动切换 Provider、模型或服务档。",
            actions: actions,
            failureCode: failure?.rawValue
        )
    }
}
