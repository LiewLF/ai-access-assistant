// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Foundation

enum LocalBetaIssueExportError: LocalizedError, Equatable {
    case explicitExportRequired
    case issueRecordRequired
    case invalidDocument
    case unsafeDestination
    case jsonDestinationRequired
    case documentTooLarge
    case atomicWriteFailed

    var errorDescription: String? {
        switch self {
        case .explicitExportRequired:
            return "只有你确认保存后才会导出这个问题"
        case .issueRecordRequired:
            return "只能导出一条“遇到问题”的本机Beta记录"
        case .invalidDocument:
            return "问题证据格式无效；未写入文件"
        case .unsafeDestination:
            return "只能导出到现有本机文件夹中的普通JSON文件"
        case .jsonDestinationRequired:
            return "问题证据必须使用.json扩展名"
        case .documentTooLarge:
            return "问题证据超过64 KB安全上限；未写入文件"
        case .atomicWriteFailed:
            return "原子写入失败；目标位置未留下半成品"
        }
    }
}

enum LocalBetaIssueReproductionAction:
    String, Codable, Equatable, Sendable {
    case firstUseFlow = "first_use_flow"
    case officialUsageRead = "official_usage_read"
    case officialRealTask = "official_real_task"
    case relayConnectionCheck = "relay_connection_check"
    case relayRealTask = "relay_real_task"
    case modeSwitch = "mode_switch"
    case recoveryFlow = "recovery_flow"
    case capabilityCompatibilityRead =
        "capability_compatibility_read"
    case continuityPreflight = "continuity_preflight"
    case sessionHistoryRead = "session_history_read"

    static func resolve(
        journey: LocalBetaAcceptanceJourney,
        failureStage: LocalBetaFailureStage
    ) -> LocalBetaIssueReproductionAction {
        switch journey {
        case .firstUse:
            return .firstUseFlow
        case .officialAccess:
            return failureStage == .realTask
                ? .officialRealTask : .officialUsageRead
        case .relayAccess:
            return failureStage == .realTask
                ? .relayRealTask : .relayConnectionCheck
        case .modeSwitch:
            return .modeSwitch
        case .recovery:
            return .recoveryFlow
        case .capabilityCompatibility:
            return .capabilityCompatibilityRead
        case .continuity:
            return .continuityPreflight
        case .sessionHistory:
            return .sessionHistoryRead
        }
    }

    var repeatInstruction: String {
        switch self {
        case .firstUseFlow:
            return "重新打开首次使用引导，并重复一次当前显示的主要动作。"
        case .officialUsageRead:
            return "重新读取官方额度状态；不要启动真实任务。"
        case .officialRealTask:
            return "仅在另行确认会消耗官方额度后，重复一次官方真实任务。"
        case .relayConnectionCheck:
            return "重复一次中转基础连接检查；不要自动切换当前接入。"
        case .relayRealTask:
            return "仅在另行确认可能产生中转费用后，重复一次中转真实任务。"
        case .modeSwitch:
            return "在明确确认后重复一次相同模式切换，并保留当前恢复出口。"
        case .recoveryFlow:
            return "从现有待恢复状态重复一次可恢复动作；不要跳过预检。"
        case .capabilityCompatibilityRead:
            return "重新运行一次只读能力核对；不要安装、禁用或修复第三方能力。"
        case .continuityPreflight:
            return "重新执行迁移设置预检；确认前不要写入目标设置。"
        case .sessionHistoryRead:
            return "重新打开历史会话，并重复一次相同只读筛选或查找动作。"
        }
    }

    var costBoundary: LocalBetaIssueCostBoundary {
        switch self {
        case .officialRealTask, .relayRealTask:
            return .separateConfirmationRequired
        default:
            return .readOnlyOrLocalOnly
        }
    }
}

enum LocalBetaIssueCostBoundary:
    String, Codable, Equatable, Sendable {
    case readOnlyOrLocalOnly = "read_only_or_local_only"
    case separateConfirmationRequired =
        "separate_confirmation_required"
}

enum LocalBetaIssueReproductionStepCode:
    String, Codable, Equatable, Sendable {
    case openTargetFeature = "open_target_feature"
    case preserveCurrentLocalState = "preserve_current_local_state"
    case repeatSelectedAction = "repeat_selected_action"
    case observeSameFailureStage = "observe_same_failure_stage"
    case retainRedactedPacket = "retain_redacted_packet"
}

struct LocalBetaIssueReproductionStep:
    Codable, Equatable, Sendable {
    let order: Int
    let code: LocalBetaIssueReproductionStepCode
    let instruction: String
}

struct LocalBetaIssueSnapshot: Codable, Equatable, Sendable {
    let recordedAt: Date
    let productVersion: String
    let productBuild: String
    let journey: LocalBetaAcceptanceJourney
    let outcome: LocalBetaAcceptanceOutcome
    let origin: LocalBetaAcceptanceRecordOrigin
    let signals: LocalBetaStructuredSignals

    enum CodingKeys: String, CodingKey {
        case recordedAt = "recorded_at"
        case productVersion = "product_version"
        case productBuild = "product_build"
        case journey
        case outcome
        case origin
        case signals
    }
}

struct LocalBetaIssueReproductionPlan:
    Codable, Equatable, Sendable {
    let action: LocalBetaIssueReproductionAction
    let targetJourney: LocalBetaAcceptanceJourney
    let expectedOutcome: LocalBetaAcceptanceOutcome
    let observedOutcome: LocalBetaAcceptanceOutcome
    let observedFailureStage: LocalBetaFailureStage
    let costBoundary: LocalBetaIssueCostBoundary
    let steps: [LocalBetaIssueReproductionStep]

    enum CodingKeys: String, CodingKey {
        case action
        case targetJourney = "target_journey"
        case expectedOutcome = "expected_outcome"
        case observedOutcome = "observed_outcome"
        case observedFailureStage = "observed_failure_stage"
        case costBoundary = "cost_boundary"
        case steps
    }

    static func make(
        journey: LocalBetaAcceptanceJourney,
        failureStage: LocalBetaFailureStage
    ) -> LocalBetaIssueReproductionPlan {
        let action = LocalBetaIssueReproductionAction.resolve(
            journey: journey,
            failureStage: failureStage
        )
        return LocalBetaIssueReproductionPlan(
            action: action,
            targetJourney: journey,
            expectedOutcome: .passed,
            observedOutcome: .needsAttention,
            observedFailureStage: failureStage,
            costBoundary: action.costBoundary,
            steps: [
                LocalBetaIssueReproductionStep(
                    order: 1,
                    code: .openTargetFeature,
                    instruction:
                        "打开AI接入助手，进入“\(journey.displayName)”对应页面。"
                ),
                LocalBetaIssueReproductionStep(
                    order: 2,
                    code: .preserveCurrentLocalState,
                    instruction:
                        "保持当前本机状态；不要补充内容正文、凭据或本机位置。"
                ),
                LocalBetaIssueReproductionStep(
                    order: 3,
                    code: .repeatSelectedAction,
                    instruction: action.repeatInstruction
                ),
                LocalBetaIssueReproductionStep(
                    order: 4,
                    code: .observeSameFailureStage,
                    instruction:
                        "观察是否再次停在“\(failureStage.displayName)”并得到“遇到问题”。"
                ),
                LocalBetaIssueReproductionStep(
                    order: 5,
                    code: .retainRedactedPacket,
                    instruction:
                        "保留本脱敏文件；不要另行添加敏感说明，文件不会自动上传。"
                ),
            ]
        )
    }
}

enum LocalBetaIssueContentProfile:
    String, Codable, Equatable, Sendable {
    case fixedCodesAndStepsOnly =
        "fixed_codes_and_fixed_steps_only"
}

enum LocalBetaIssueDeliveryMode:
    String, Codable, Equatable, Sendable {
    case localFileOnly = "local_file_only"
}

struct LocalBetaIssuePrivacyBoundary:
    Codable, Equatable, Sendable {
    let contentProfile: LocalBetaIssueContentProfile
    let deliveryMode: LocalBetaIssueDeliveryMode
    let userContentIncluded: Bool
    let secretsIncluded: Bool
    let addressesIncluded: Bool
    let pathsIncluded: Bool
    let deviceIdentifiersIncluded: Bool
    let backgroundCollection: Bool
    let automaticSharing: Bool

    static let redactedLocalFile = LocalBetaIssuePrivacyBoundary(
        contentProfile: .fixedCodesAndStepsOnly,
        deliveryMode: .localFileOnly,
        userContentIncluded: false,
        secretsIncluded: false,
        addressesIncluded: false,
        pathsIncluded: false,
        deviceIdentifiersIncluded: false,
        backgroundCollection: false,
        automaticSharing: false
    )

    enum CodingKeys: String, CodingKey {
        case contentProfile = "content_profile"
        case deliveryMode = "delivery_mode"
        case userContentIncluded = "user_content_included"
        case secretsIncluded = "secrets_included"
        case addressesIncluded = "addresses_included"
        case pathsIncluded = "paths_included"
        case deviceIdentifiersIncluded =
            "device_identifiers_included"
        case backgroundCollection = "background_collection"
        case automaticSharing = "automatic_sharing"
    }
}

struct LocalBetaIssueExportDocument:
    Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let marker =
        "AI_ACCESS_ASSISTANT_LOCAL_BETA_ISSUE_V1"
    static let maximumDocumentBytes = 64 * 1024

    let schemaVersion: Int
    let documentMarker: String
    let exportedAt: Date
    let issue: LocalBetaIssueSnapshot
    let reproduction: LocalBetaIssueReproductionPlan
    let privacy: LocalBetaIssuePrivacyBoundary

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case documentMarker = "marker"
        case exportedAt = "exported_at"
        case issue
        case reproduction
        case privacy
    }

    func encodedData() throws -> Data {
        guard isValid else {
            throw LocalBetaIssueExportError.invalidDocument
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard !data.isEmpty else {
            throw LocalBetaIssueExportError.invalidDocument
        }
        guard data.count <= Self.maximumDocumentBytes else {
            throw LocalBetaIssueExportError.documentTooLarge
        }
        return data
    }

    private var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              documentMarker == Self.marker,
              issue.outcome == .needsAttention,
              issue.origin == .userAction,
              issue.signals.failureStage != .none,
              isSafeVersion(issue.productVersion),
              isSafeBuild(issue.productBuild),
              privacy == .redactedLocalFile else {
            return false
        }
        return reproduction == .make(
            journey: issue.journey,
            failureStage: issue.signals.failureStage
        )
    }

    private func isSafeVersion(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9]+(?:\.[0-9]+){1,3}$"#,
            options: .regularExpression
        ) != nil
    }

    private func isSafeBuild(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9]{1,7}$"#,
            options: .regularExpression
        ) != nil
    }
}

enum LocalBetaIssueExportBuilder {
    static func make(
        record: LocalBetaAcceptanceRecord,
        exportedAt: Date = Date()
    ) throws -> LocalBetaIssueExportDocument {
        guard record.outcome == .needsAttention,
              record.origin == .userAction else {
            throw LocalBetaIssueExportError.issueRecordRequired
        }
        let failureStage = record.signals.failureStage == .none
            ? LocalBetaFailureStage.fallback(for: record.journey)
            : record.signals.failureStage
        let signals = LocalBetaStructuredSignals(
            crash: record.signals.crash,
            failureStage: failureStage,
            recoveryResult: record.signals.recoveryResult,
            performanceBoundary: record.signals.performanceBoundary
        )
        let document = LocalBetaIssueExportDocument(
            schemaVersion:
                LocalBetaIssueExportDocument.currentSchemaVersion,
            documentMarker: LocalBetaIssueExportDocument.marker,
            exportedAt: normalized(exportedAt),
            issue: LocalBetaIssueSnapshot(
                recordedAt: normalized(record.recordedAt),
                productVersion: record.productVersion,
                productBuild: record.productBuild,
                journey: record.journey,
                outcome: record.outcome,
                origin: record.origin,
                signals: signals
            ),
            reproduction: .make(
                journey: record.journey,
                failureStage: failureStage
            ),
            privacy: .redactedLocalFile
        )
        _ = try document.encodedData()
        return document
    }

    private static func normalized(_ date: Date) -> Date {
        Date(
            timeIntervalSince1970:
                date.timeIntervalSince1970.rounded(.down)
        )
    }
}

enum LocalBetaIssueAtomicExporter {
    static func write(
        _ document: LocalBetaIssueExportDocument,
        to destinationURL: URL,
        userConfirmed: Bool,
        fileManager: FileManager = .default,
        makeUUID: () -> UUID = UUID.init
    ) throws {
        guard userConfirmed else {
            throw LocalBetaIssueExportError.explicitExportRequired
        }
        guard destinationURL.isFileURL else {
            throw LocalBetaIssueExportError.unsafeDestination
        }
        guard destinationURL.pathExtension.lowercased() == "json" else {
            throw LocalBetaIssueExportError.jsonDestinationRequired
        }

        let destination = destinationURL.standardizedFileURL
        let parent = destination.deletingLastPathComponent()
        let parentAttributes: [FileAttributeKey: Any]
        do {
            parentAttributes = try fileManager.attributesOfItem(
                atPath: parent.path
            )
        } catch {
            throw LocalBetaIssueExportError.unsafeDestination
        }
        guard parentAttributes[.type] as? FileAttributeType
                == .typeDirectory else {
            throw LocalBetaIssueExportError.unsafeDestination
        }
        if let destinationAttributes = try? fileManager
            .attributesOfItem(atPath: destination.path),
           let type = destinationAttributes[.type]
            as? FileAttributeType,
           type == .typeDirectory || type == .typeSymbolicLink {
            throw LocalBetaIssueExportError.unsafeDestination
        }

        let data = try document.encodedData()
        let temporary = parent.appendingPathComponent(
            ".ai-access-beta-\(makeUUID().uuidString).tmp",
            isDirectory: false
        )
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw LocalBetaIssueExportError.atomicWriteFailed
        }
        defer { try? fileManager.removeItem(at: temporary) }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporary.path
            )
        } catch {
            throw LocalBetaIssueExportError.atomicWriteFailed
        }
        guard Darwin.rename(
            temporary.path,
            destination.path
        ) == 0 else {
            throw LocalBetaIssueExportError.atomicWriteFailed
        }
    }
}
