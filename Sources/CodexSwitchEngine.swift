import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

final class CodexSwitchEngine {
    private let adapter: CodexConfigurationAdapter
    private let stateStore: CodexStateStore
    private let transactionLock: ProviderTransactionLock

    init(
        adapter: CodexConfigurationAdapter,
        stateStore: CodexStateStore,
        transactionLock: ProviderTransactionLock? = nil
    ) {
        self.adapter = adapter
        self.stateStore = stateStore
        self.transactionLock = transactionLock ?? ProviderTransactionLock(
            fileURL: stateStore.fileURL.deletingLastPathComponent()
                .appendingPathComponent("provider-switch.lock")
        )
    }

    func createOfficialBaseline() throws -> OfficialBaseline {
        var state = try stateStore.load()
        let baseline = try adapter.createBaseline()
        let overlay = try adapter.createOfficialOverlay()
        state.baseline = baseline
        state.officialBaselineTrust = .candidate
        state.officialOverlay = overlay
        state.currentMode = .official
        state.activeRelayID = nil
        try stateStore.save(state)
        return baseline
    }

    func confirmOfficialValidation(
        evidence: OfficialValidationEvidence
    ) throws -> OfficialOverlay {
        guard evidence.responseSucceeded,
              evidence.codexProcessIdentifier != nil else {
            throw CodexControlError.officialValidationEvidenceMissing
        }
        let configText = String(
            decoding: try adapter.currentConfigData() ?? Data(),
            as: UTF8.self
        )
        let document = try TOMLSemanticEngine.parse(configText)
        let provider = document.rootString("model_provider")
        guard provider == nil || provider == "openai" else {
            throw CodexControlError.externalDrift
        }
        var state = try stateStore.load()
        guard state.currentMode == .official,
              var overlay = state.officialOverlay else {
            throw CodexControlError.baselineMissing
        }
        overlay.state = .verified
        overlay.lastVerifiedAt = evidence.observedAt
        overlay.lastVerificationMethod = evidence.method.rawValue
        overlay.lastVerifiedProcessIdentifier =
            evidence.codexProcessIdentifier
        state.officialOverlay = overlay
        state.officialBaselineTrust = .verified
        try stateStore.save(state)
        return overlay
    }

    func prepareRelay(profile: CodexRelayProfile) throws -> CodexConfigurationPlan {
        try adapter.buildPlan(profile: profile)
    }

    func prepareImportedRelay(
        _ result: ExistingProviderImportResult,
        allowLegacyBearerRemoval: Bool = false
    ) throws -> CodexConfigurationPlan {
        guard result.report.targetConfigurationUnchanged,
              try adapter.currentConfigHash() == result.report.configHashBefore else {
            throw CodexControlError.externalDrift
        }
        return try adapter.buildPlan(
            profile: result.profile,
            allowLegacyBearerRemoval: allowLegacyBearerRemoval
        )
    }

    func createRecoveryPoint() throws -> CodexSwitchRecoveryPoint {
        CodexSwitchRecoveryPoint(
            configData: try adapter.currentConfigData(),
            configHash: try adapter.currentConfigHash(),
            authHash: try adapter.currentAuthHash(),
            state: try stateStore.load()
        )
    }

    func recordReadOnlyImportedRelay(
        _ result: ExistingProviderImportResult
    ) throws {
        guard result.report.targetConfigurationUnchanged,
              try adapter.currentConfigHash() == result.report.configHashBefore else {
            throw CodexControlError.externalDrift
        }
        var state = try stateStore.load()
        let previousMode = state.currentMode
        state.relayProfiles.removeAll { $0.id == result.profile.id }
        state.relayProfiles.append(result.profile)
        state.unverifiedLegacyRelayProfileIDs.removeAll {
            $0 == result.profile.id
        }
        state.currentMode = .relay
        state.activeRelayID = result.profile.id
        state.lastTransaction = RealSwitchTransaction(
            id: UUID().uuidString,
            fromMode: previousMode,
            toMode: .relay,
            phase: .committed,
            startedAt: Date(),
            completedAt: Date(),
            message: "已只读接管现有Provider；目标配置零写入，认证尚未迁移",
            beforeConfigHash: result.report.configHashBefore,
            afterConfigHash: result.report.configHashAfter
        )
        try stateStore.save(state)
    }

    func reconcileKnownRelay(profileID: String) throws -> CodexRelayProfile {
        var state = try stateStore.load()
        guard let profile = state.relayProfiles.first(where: {
            $0.id == profileID
        }),
        try adapter.manualConfigurationMatches(profile) else {
            throw CodexControlError.externalDrift
        }
        let before = try adapter.currentConfigHash()
        let authBefore = try adapter.currentAuthHash()
        let previousMode = state.currentMode
        state.currentMode = .relay
        state.activeRelayID = profile.id
        if !state.credentialBridgeProfileIDs
            .contains(profile.id) {
            state.credentialBridgeProfileIDs.append(
                profile.id
            )
        }
        state.lastTransaction = RealSwitchTransaction(
            id: UUID().uuidString,
            fromMode: previousMode,
            toMode: .relay,
            phase: .committed,
            startedAt: Date(),
            completedAt: Date(),
            message: "真实配置精确匹配已保存中转档；已零写入纠正助手轨道记录",
            beforeConfigHash: before,
            afterConfigHash: before
        )
        guard try adapter.currentConfigHash() == before,
              try adapter.currentAuthHash() == authBefore else {
            throw CodexControlError.atomicWriteFailed
        }
        try stateStore.save(state)
        return profile
    }

    func restoreRecoveryPoint(
        _ recoveryPoint: CodexSwitchRecoveryPoint
    ) throws -> RealSwitchTransaction {
        let currentHash = try adapter.currentConfigHash()
        try adapter.restoreConfigData(
            recoveryPoint.configData,
            expectedCurrentHash: currentHash
        )
        guard try adapter.currentAuthHash() == recoveryPoint.authHash else {
            throw CodexControlError.atomicWriteFailed
        }
        var restoredState = recoveryPoint.state
        let transaction = RealSwitchTransaction(
            id: UUID().uuidString,
            fromMode: (try? stateStore.load().currentMode) ?? .external,
            toMode: recoveryPoint.state.currentMode,
            phase: .rolledBack,
            startedAt: Date(),
            completedAt: Date(),
            message: "已恢复切换前配置档和助手状态；auth.json保持不变",
            beforeConfigHash: currentHash,
            afterConfigHash: try adapter.currentConfigHash()
        )
        restoredState.lastTransaction = transaction
        try stateStore.save(restoredState)
        return transaction
    }

    func applyRelay(
        profile: CodexRelayProfile,
        expectedCurrentHash: String?,
        configurationPlan: CodexConfigurationPlan? = nil,
        failAt: RealSwitchPhase? = nil
    ) throws -> RealSwitchTransaction {
        let transactionID = UUID().uuidString
        try transactionLock.acquire(
            transactionID: transactionID,
            expectedConfigHash: expectedCurrentHash
        )
        defer { transactionLock.release() }
        var state = try stateStore.load()
        guard state.baseline != nil, var officialOverlay = state.officialOverlay else {
            throw CodexControlError.baselineMissing
        }
        let currentHash = try adapter.currentConfigHash()
        if expectedCurrentHash != nil, currentHash != expectedCurrentHash { throw CodexControlError.externalDrift }
        let recoveryData = try adapter.currentConfigData()
        let authenticationHash = try adapter.currentAuthHash()
        var didWrite = false
        var transaction = RealSwitchTransaction(
            id: transactionID,
            fromMode: state.currentMode,
            toMode: .relay,
            phase: .preflight,
            startedAt: Date(),
            completedAt: nil,
            message: "切换进行中",
            beforeConfigHash: currentHash,
            afterConfigHash: nil
        )
        state.lastTransaction = transaction
        try stateStore.save(state)
        do {
            if failAt == .preflight { throw CodexControlError.injectedFailure(.preflight) }
            transaction.phase = .snapshot
            state.lastTransaction = transaction
            try stateStore.save(state)
            if failAt == .snapshot { throw CodexControlError.injectedFailure(.snapshot) }
            let plan = try configurationPlan
                ?? adapter.buildPlan(profile: profile)
            if let configurationPlan {
                let currentText = String(
                    decoding:
                        try adapter.currentConfigData()
                            ?? Data(),
                    as: UTF8.self
                )
                guard configurationPlan.original
                        == currentText else {
                    throw CodexControlError.externalDrift
                }
            }
            transaction.phase = .write
            state.lastTransaction = transaction
            try stateStore.save(state)
            if failAt == .write { throw CodexControlError.injectedFailure(.write) }
            try adapter.apply(plan, expectedCurrentHash: currentHash)
            didWrite = true
            transaction.afterConfigHash = try adapter.currentConfigHash()
            transaction.phase = .launch
            state.lastTransaction = transaction
            try stateStore.save(state)
            if failAt == .launch { throw CodexControlError.injectedFailure(.launch) }
            transaction.phase = .validate
            state.lastTransaction = transaction
            try stateStore.save(state)
            if failAt == .validate { throw CodexControlError.injectedFailure(.validate) }
            state.relayProfiles.removeAll { $0.id == profile.id }
            state.relayProfiles.append(profile)
            state.unverifiedLegacyRelayProfileIDs.removeAll {
                $0 == profile.id
            }
            if !state.credentialBridgeProfileIDs
                .contains(profile.id) {
                state.credentialBridgeProfileIDs
                    .append(profile.id)
            }
            if let providerID = profile.providerID ?? Optional(PreservingTOMLEditor.providerIdentifier(profile.id)),
               providerID.hasPrefix("ai_access_"),
               !officialOverlay.managedProviderIDs.contains(providerID) {
                officialOverlay.managedProviderIDs.append(providerID)
            }
            state.officialOverlay = officialOverlay
            state.currentMode = .relay
            state.activeRelayID = profile.id
            transaction.phase = .validate
            transaction.message = "配置写入完成；等待真实连接验证"
            state.lastTransaction = transaction
            try stateStore.save(state)
            return transaction
        } catch {
            if didWrite {
                try? adapter.restoreConfigData(
                    recoveryData,
                    expectedCurrentHash: try? adapter.currentConfigHash()
                )
            }
            let authUnchanged = (try? adapter.currentAuthHash()) == authenticationHash
            state.currentMode = transaction.fromMode
            transaction.phase = .rolledBack
            transaction.completedAt = Date()
            transaction.message = authUnchanged
                ? error.localizedDescription
                : "认证文件发生外部变化；配置已回滚，认证未被助手覆盖"
            state.lastTransaction = transaction
            try? stateStore.save(state)
            throw error
        }
    }

    func adoptManualRelay(
        profile: CodexRelayProfile
    ) throws -> RealSwitchTransaction {
        let transactionID = UUID().uuidString
        try transactionLock.acquire(
            transactionID: transactionID,
            expectedConfigHash: try adapter.currentConfigHash()
        )
        defer { transactionLock.release() }
        guard try adapter.manualConfigurationMatches(profile) else {
            throw CodexControlError.manualConfigurationMismatch
        }
        var state = try stateStore.load()
        guard state.baseline != nil, var officialOverlay = state.officialOverlay else {
            throw CodexControlError.baselineMissing
        }
        let authBefore = try adapter.currentAuthHash()
        let providerID = profile.providerID
            ?? PreservingTOMLEditor.providerIdentifier(profile.id)
        if providerID.hasPrefix("ai_access_"),
           !officialOverlay.managedProviderIDs.contains(providerID) {
            officialOverlay.managedProviderIDs.append(providerID)
        }
        state.officialOverlay = officialOverlay
        state.relayProfiles.removeAll { $0.id == profile.id }
        state.relayProfiles.append(profile)
        state.unverifiedLegacyRelayProfileIDs.removeAll {
            $0 == profile.id
        }
        if !state.credentialBridgeProfileIDs
            .contains(profile.id) {
            state.credentialBridgeProfileIDs.append(
                profile.id
            )
        }
        state.currentMode = .relay
        state.activeRelayID = profile.id
        let transaction = RealSwitchTransaction(
            id: transactionID,
            fromMode: .official,
            toMode: .relay,
            phase: .validate,
            startedAt: Date(),
            completedAt: nil,
            message: "手动配置已精确匹配；助手零写入收编，等待真实连接验证",
            beforeConfigHash: try adapter.currentConfigHash(),
            afterConfigHash: try adapter.currentConfigHash()
        )
        guard try adapter.currentAuthHash() == authBefore else {
            throw CodexControlError.atomicWriteFailed
        }
        state.lastTransaction = transaction
        try stateStore.save(state)
        return transaction
    }

    func completeRelayValidation(message: String) throws -> RealSwitchTransaction {
        var state = try stateStore.load()
        guard var transaction = state.lastTransaction, state.currentMode == .relay else {
            throw CodexControlError.externalDrift
        }
        transaction.phase = .committed
        transaction.completedAt = Date()
        transaction.message = message
        state.lastTransaction = transaction
        try stateStore.save(state)
        return transaction
    }

    func validateOfficialRestoreTarget() throws {
        let state = try stateStore.load()
        guard let baseline = state.baseline else {
            throw CodexControlError.baselineMissing
        }
        guard state.officialBaselineTrust
                != .legacyCandidate else {
            throw CodexControlError
                .officialBaselineUnverified
        }
        if let overlay = state.officialOverlay {
            let activeProviderID = state.activeRelayID.flatMap { relayID in
                state.relayProfiles.first(where: { $0.id == relayID })?
                    .providerID
                    ?? PreservingTOMLEditor.providerIdentifier(relayID)
            }
            var removable = Set(
                overlay.managedProviderIDs.filter {
                    $0.hasPrefix("ai_access_")
                }
            )
            if let activeProviderID,
               activeProviderID.hasPrefix("ai_access_") {
                removable.insert(activeProviderID)
            }
            let plan = try adapter.buildOfficialPlan(
                overlay: overlay,
                removingProviderIDs: removable
            )
            try adapter.requireOfficialConfiguration(
                Data(plan.proposed.utf8)
            )
        } else {
            try adapter.requireOfficialConfiguration(
                try adapter.baselineConfigData(baseline)
            )
        }
    }

    func restoreOfficial() throws -> RealSwitchTransaction {
        let transactionID = UUID().uuidString
        try transactionLock.acquire(
            transactionID: transactionID,
            expectedConfigHash: try adapter.currentConfigHash()
        )
        defer { transactionLock.release() }
        var state = try stateStore.load()
        guard let baseline = state.baseline else { throw CodexControlError.baselineMissing }
        try validateOfficialRestoreTarget()
        let before = try adapter.currentConfigHash()
        let recoveryData = try adapter.currentConfigData()
        let authBefore = try adapter.currentAuthHash()
        if let overlay = state.officialOverlay {
            let activeProviderID = state.activeRelayID.flatMap { relayID in
                state.relayProfiles.first(where: { $0.id == relayID })?.providerID
                    ?? PreservingTOMLEditor.providerIdentifier(relayID)
            }
            var removable = Set(overlay.managedProviderIDs.filter { $0.hasPrefix("ai_access_") })
            if let activeProviderID, activeProviderID.hasPrefix("ai_access_") {
                removable.insert(activeProviderID)
            }
            let plan = try adapter.buildOfficialPlan(
                overlay: overlay,
                removingProviderIDs: removable
            )
            try adapter.apply(plan, expectedCurrentHash: before)
        } else {
            // 0.7.x状态迁移：仅旧状态缺少覆盖层时使用完整灾难恢复快照。
            try adapter.restore(baseline)
        }
        do {
            try adapter.requireOfficialConfiguration(
                try adapter.currentConfigData()
            )
        } catch {
            try? adapter.restoreConfigData(
                recoveryData,
                expectedCurrentHash: try? adapter.currentConfigHash()
            )
            throw error
        }
        guard try adapter.currentAuthHash() == authBefore else {
            throw CodexControlError.atomicWriteFailed
        }
        let transaction = RealSwitchTransaction(
            id: transactionID,
            fromMode: state.currentMode,
            toMode: .official,
            phase: .committed,
            startedAt: Date(),
            completedAt: Date(),
            message: "已切到官方覆盖层；MCP、项目设置和官方认证保持当前内容",
            beforeConfigHash: before,
            afterConfigHash: try adapter.currentConfigHash()
        )
        state.currentMode = .official
        state.activeRelayID = nil
        state.lastTransaction = transaction
        try stateStore.save(state)
        return transaction
    }
}
