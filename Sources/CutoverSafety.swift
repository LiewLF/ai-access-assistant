import Foundation

enum FableCutoverState: String, Codable, CaseIterable {
    case candidate
    case active
    case lastKnownGood
}

enum FableCutoverImpactLevel: String, Codable, CaseIterable {
    case l0
    case l1
    case l2
    case l3

    var displayName: String {
        switch self {
        case .l0: return "L0 · 说明/证据"
        case .l1: return "L1 · 同轨热更新"
        case .l2: return "L2 · 同轨快速重开"
        case .l3: return "L3 · 真实切轨"
        }
    }
}

enum FableCutoverCheckID: String, Codable, CaseIterable {
    case semanticParse
    case versionContract
    case providerResponses
    case credentialPresence
    case coreResponses
    case baselineCAS
    case unmanagedPreservation
    case singleWriter
}

enum FableCutoverCheckResult: String, Codable {
    case passed
    case failed
    case unverified
    case notApplicable
}

struct FableCutoverCheck: Codable, Equatable {
    let id: FableCutoverCheckID
    let result: FableCutoverCheckResult
    let detail: String

    init(
        id: FableCutoverCheckID,
        result: FableCutoverCheckResult,
        detail: String
    ) {
        self.id = id
        self.result = result
        self.detail = detail
    }
}

struct FableCutoverCandidate: Codable, Equatable {
    let profileID: String?
    let providerID: String
    let modelID: String?
    let baselineGenerationHash: String
    let proposedConfigHash: String
    let semanticDiffPaths: [String]
    let capabilityContract: String
    let credentialReferencePresent: Bool
    let coreChecks: [FableCutoverCheck]
    let optionalChecks: [FableCutoverCheck]
    let impactLevel: FableCutoverImpactLevel
    let createdAt: Date

    var state: FableCutoverState { .candidate }

    var optionalFailures: [FableCutoverCheck] {
        optionalChecks.filter { $0.result == .failed }
    }
}

enum FableCutoverPreflightDecision: Equatable {
    case ready
    case blocked(reasons: [String])

    var allowsLiveWrite: Bool {
        if case .ready = self { return true }
        return false
    }
}

enum FableCutoverSafetyError: LocalizedError, Equatable {
    case preflightBlocked([String])
    case promotionEvidenceMissing

    var errorDescription: String? {
        switch self {
        case let .preflightBlocked(reasons):
            return "候选配置未通过写前检查："
                + reasons.joined(separator: "；")
        case .promotionEvidenceMissing:
            return "缺少事务、CAS或核心运行时验证证据，不能晋升为当前配置"
        }
    }
}

enum FableCutoverSafetyPolicy {
    private static let requiredChecks = Set(
        FableCutoverCheckID.allCases
    )

    static func evaluate(
        _ candidate: FableCutoverCandidate
    ) -> FableCutoverPreflightDecision {
        var reasons: [String] = []
        if candidate.providerID.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {
            reasons.append("Provider标识为空")
        }
        if let profileID = candidate.profileID,
           profileID.trimmingCharacters(
               in: .whitespacesAndNewlines
           ).isEmpty {
            reasons.append("Profile标识为空")
        }
        if let modelID = candidate.modelID,
           modelID.trimmingCharacters(
               in: .whitespacesAndNewlines
           ).isEmpty {
            reasons.append("模型标识为空")
        }
        if !isSHA256(candidate.baselineGenerationHash) {
            reasons.append("基线generation/hash无效")
        }
        if !isSHA256(candidate.proposedConfigHash) {
            reasons.append("候选配置hash无效")
        }
        var checks: [FableCutoverCheckID: FableCutoverCheck] = [:]
        var duplicateCheckIDs = Set<FableCutoverCheckID>()
        for check in candidate.coreChecks {
            if checks[check.id] != nil {
                duplicateCheckIDs.insert(check.id)
            }
            checks[check.id] = check
        }
        if !duplicateCheckIDs.isEmpty {
            reasons.append(
                "核心检查ID重复："
                    + duplicateCheckIDs.map(\.rawValue)
                        .sorted().joined(separator: ",")
            )
        }
        let missing = requiredChecks.subtracting(checks.keys)
        if !missing.isEmpty {
            reasons.append(
                "缺少核心检查：\(missing.map(\.rawValue).sorted().joined(separator: ","))"
            )
        }
        for id in requiredChecks.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let check = checks[id] else { continue }
            let officialNotApplicable =
                candidate.providerID == "openai"
                && check.result == .notApplicable
                && [
                    FableCutoverCheckID.providerResponses,
                    .credentialPresence,
                    .coreResponses,
                ].contains(id)
            guard check.result == .passed
                    || officialNotApplicable else {
                reasons.append(
                    id.rawValue + "：" + check.detail
                )
                continue
            }
        }
        if candidate.providerID != "openai",
           !candidate.credentialReferencePresent {
            reasons.append("凭据引用不存在")
        }
        if reasons.isEmpty {
            return .ready
        }
        return .blocked(reasons: Array(Set(reasons)).sorted())
    }

    static func requireReady(
        _ candidate: FableCutoverCandidate
    ) throws {
        let decision = evaluate(candidate)
        guard case let .blocked(reasons) = decision else { return }
        throw FableCutoverSafetyError.preflightBlocked(reasons)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.allSatisfy {
                $0.isHexDigit && !$0.isUppercase
            }
    }
}

struct FableCutoverPromotionEvidence: Equatable {
    let transactionApplied: Bool
    let casMatched: Bool
    let runtimeCoreVerified: Bool
}

struct FableCutoverConfigurationRecord: Codable, Equatable {
    let state: FableCutoverState
    let profileID: String?
    let providerID: String
    let modelID: String?
    let configHash: String
    let capabilityContract: String
    let transactionID: String
    let coreVerifiedAt: Date
    let optionalCapabilityDifferences: [String]

    var isSafeRecord: Bool {
        state != .candidate
            && !providerID.isEmpty
            && configHash.count == 64
            && configHash.allSatisfy {
                $0.isHexDigit && !$0.isUppercase
            }
            && !capabilityContract.isEmpty
            && !transactionID.isEmpty
    }
}

enum FableCutoverPromotionPolicy {
    static func promote(
        providerID: String,
        profileID: String?,
        modelID: String?,
        configHash: String,
        capabilityContract: String,
        transactionID: String,
        optionalCapabilityDifferences: [String] = [],
        evidence: FableCutoverPromotionEvidence,
        now: Date = Date()
    ) throws -> (
        active: FableCutoverConfigurationRecord,
        lastKnownGood: FableCutoverConfigurationRecord
    ) {
        guard evidence.transactionApplied,
              evidence.casMatched,
              evidence.runtimeCoreVerified,
              isSHA256(configHash),
              !providerID.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              !capabilityContract.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              !transactionID.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty else {
            throw FableCutoverSafetyError.promotionEvidenceMissing
        }
        let active = FableCutoverConfigurationRecord(
            state: .active,
            profileID: profileID,
            providerID: providerID,
            modelID: modelID,
            configHash: configHash,
            capabilityContract: capabilityContract,
            transactionID: transactionID,
            coreVerifiedAt: now,
            optionalCapabilityDifferences:
                optionalCapabilityDifferences.sorted()
        )
        let lkg = FableCutoverConfigurationRecord(
            state: .lastKnownGood,
            profileID: profileID,
            providerID: providerID,
            modelID: modelID,
            configHash: configHash,
            capabilityContract: capabilityContract,
            transactionID: transactionID,
            coreVerifiedAt: now,
            optionalCapabilityDifferences:
                optionalCapabilityDifferences.sorted()
        )
        return (active, lkg)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.allSatisfy {
                $0.isHexDigit && !$0.isUppercase
            }
    }
}

enum FableCutoverRecoveryAction: String, Codable, CaseIterable {
    case editCandidate
    case switchSavedRelay
    case switchOfficial
    case restorePreSwitchSnapshot
    case restoreLastKnownGood
    case minimalForwardRepair
    case exportDiagnostic
    case keepCurrentAndEndTransaction
    case safeRecoveryMode
    case openOfficialRecoveryGuide

    var displayName: String {
        switch self {
        case .editCandidate: return "编辑当前候选"
        case .switchSavedRelay: return "切换其他已保存中转"
        case .switchOfficial: return "切回官方"
        case .restorePreSwitchSnapshot: return "恢复切轨前快照"
        case .restoreLastKnownGood: return "恢复最近一次核心可用配置"
        case .minimalForwardRepair: return "执行最小前向修复"
        case .exportDiagnostic: return "导出脱敏诊断"
        case .keepCurrentAndEndTransaction: return "保留当前状态并结束旧事务"
        case .safeRecoveryMode: return "进入安全恢复模式"
        case .openOfficialRecoveryGuide: return "打开官方恢复指引"
        }
    }
}

struct FableCutoverFailureContext: Equatable {
    let pendingTransaction: Bool
    let evidenceConflict: Bool
    let candidateEditable: Bool
    let savedRelayCount: Int
    let officialExitAvailable: Bool
    let preSwitchSnapshotAvailable: Bool
    let lastKnownGoodAvailable: Bool
    let minimalForwardRepairSafe: Bool
    let diagnosticExportAvailable: Bool
}

struct FableCutoverRecoveryPlan: Equatable {
    let availableActions: [FableCutoverRecoveryAction]
    let preferredAction: FableCutoverRecoveryAction?

    var preventsPermanentLockout: Bool {
        availableActions.contains(.editCandidate)
            || availableActions.contains(.switchSavedRelay)
            || availableActions.contains(.switchOfficial)
            || availableActions.contains(.openOfficialRecoveryGuide)
            || availableActions.contains(.keepCurrentAndEndTransaction)
            || availableActions.contains(.safeRecoveryMode)
    }
}

enum FableCutoverRecoveryPolicy {
    static func plan(
        for context: FableCutoverFailureContext
    ) -> FableCutoverRecoveryPlan {
        var actions: [FableCutoverRecoveryAction] = []
        if context.candidateEditable {
            actions.append(.editCandidate)
        }
        if context.minimalForwardRepairSafe {
            actions.append(.minimalForwardRepair)
        }
        if context.preSwitchSnapshotAvailable {
            actions.append(.restorePreSwitchSnapshot)
        }
        if context.lastKnownGoodAvailable {
            actions.append(.restoreLastKnownGood)
        }
        if context.savedRelayCount > 0 {
            actions.append(.switchSavedRelay)
        }
        if context.officialExitAvailable {
            actions.append(.switchOfficial)
        } else {
            actions.append(.openOfficialRecoveryGuide)
        }
        if context.diagnosticExportAvailable {
            actions.append(.exportDiagnostic)
        }
        if context.pendingTransaction {
            actions.append(.keepCurrentAndEndTransaction)
        }
        if context.evidenceConflict {
            actions.append(.safeRecoveryMode)
        }
        let preferred = [
            FableCutoverRecoveryAction.minimalForwardRepair,
            .restorePreSwitchSnapshot,
            .restoreLastKnownGood,
            .switchOfficial,
            .switchSavedRelay,
            .keepCurrentAndEndTransaction,
            .openOfficialRecoveryGuide,
            .safeRecoveryMode,
            .editCandidate,
            .exportDiagnostic,
        ].first(where: { actions.contains($0) })
        return FableCutoverRecoveryPlan(
            availableActions: actions,
            preferredAction: preferred
        )
    }
}

enum FableCutoverImpactClassifier {
    static func classify(
        changesLiveConfiguration: Bool,
        changesRoute: Bool,
        clientSupportsHotUpdate: Bool
    ) -> FableCutoverImpactLevel {
        guard changesLiveConfiguration else { return .l0 }
        if !changesRoute, clientSupportsHotUpdate { return .l1 }
        if !changesRoute { return .l2 }
        return .l3
    }
}
