import Foundation

struct V011UserReadinessEvidenceSnapshot {
    let officialUsage: V011OfficialUsageSnapshot?
    let officialUsageLoadFailed: Bool
    let savedRelayReceipts:
        [String: V011SavedRelayReadinessReceipt]
}

struct V011UserReadinessCoordinator: @unchecked Sendable {
    private let rootURL: URL
    private let writer: FableAtomicConfigWriter
    private let officialUsageReader:
        any V011OfficialUsageReading
    private let savedRelayVerifier:
        any V011SavedRelayReadinessVerifying
    private let credentialStore: any FableCredentialStore
    private let now: @Sendable () -> Date

    init(dependencies: V011AccessDependencies) {
        rootURL = dependencies.controlRoot
            .appendingPathComponent("V011", isDirectory: true)
            .appendingPathComponent(
                "UserReadiness",
                isDirectory: true
            )
        writer = dependencies.atomicWriter
        officialUsageReader = dependencies.officialUsageReader
        savedRelayVerifier =
            dependencies.savedRelayReadinessVerifier
        credentialStore = dependencies.credentialStore
        now = dependencies.now
    }

    func loadEvidence() -> V011UserReadinessEvidenceSnapshot {
        let officialUsage: V011OfficialUsageSnapshot?
        let officialUsageLoadFailed: Bool
        do {
            officialUsage = try officialUsageStore.load()
            officialUsageLoadFailed = false
        } catch {
            officialUsage = nil
            officialUsageLoadFailed = true
        }
        let savedRelayReceipts:
            [String: V011SavedRelayReadinessReceipt]
        do {
            savedRelayReceipts = try savedRelayStore.load()
        } catch {
            savedRelayReceipts = [:]
        }
        return V011UserReadinessEvidenceSnapshot(
            officialUsage: officialUsage,
            officialUsageLoadFailed: officialUsageLoadFailed,
            savedRelayReceipts: savedRelayReceipts
        )
    }

    func refreshOfficialUsage(
        threadID: String?
    ) throws -> V011OfficialUsageSnapshot {
        let snapshot: V011OfficialUsageSnapshot
        if let threadID {
            snapshot = try officialUsageReader.read(
                threadID: threadID
            )
        } else {
            snapshot = try officialUsageReader.read()
        }
        try officialUsageStore.commit(snapshot)
        return snapshot
    }

    func verifySavedRelayReadiness(
        _ profile: CodexRelayProfile
    ) throws -> (
        receipt: V011SavedRelayReadinessReceipt,
        matches: Bool
    ) {
        guard let secret = try credentialStore.secret(
            reference: profile.v011CredentialReference
        ), !secret.isEmpty else {
            throw FableSwitchError.credentialUnavailable
        }
        let receipt = try savedRelayVerifier.verify(
            profile: profile,
            secret: secret,
            userConsented: true
        )
        return (
            receipt,
            savedRelayVerifier.receiptMatchesCurrent(
                receipt,
                profile: profile,
                now: now()
            )
        )
    }

    func commitSavedRelayReadiness(
        _ receipts: [String: V011SavedRelayReadinessReceipt]
    ) throws {
        try savedRelayStore.commit(receipts)
    }

    static func state(
        for profile: CodexRelayProfile,
        verifyingProfileID: String?,
        errors: [String: String],
        receipts: [String: V011SavedRelayReadinessReceipt],
        matches: [String: Bool],
        now: Date
    ) -> V011SavedRelayReadinessState {
        if verifyingProfileID == profile.id {
            return .verifying
        }
        if errors[profile.id] != nil {
            return .failed
        }
        guard let receipt = receipts[profile.id] else {
            return .unverified
        }
        guard receipt.profileFingerprint
                == V011SavedRelayReadinessReceipt
                    .fingerprint(profile) else {
            return .expired
        }
        if receipt.agentLoop.outcome == .failed {
            return .failed
        }
        guard receipt.expiresAt > now else {
            return .expired
        }
        return matches[profile.id] == true
            ? .usable : .expired
    }

    static func status(
        for profile: CodexRelayProfile,
        state: V011SavedRelayReadinessState,
        errors: [String: String],
        receipts: [String: V011SavedRelayReadinessReceipt]
    ) -> String {
        switch state {
        case .verifying:
            return "正在隔离验证真实任务；不会切换当前接入"
        case .usable:
            guard let receipt = receipts[profile.id] else {
                return "真实任务可用"
            }
            return "真实任务可用 · 证据到期 \(receipt.expiresAt.formatted(date: .omitted, time: .shortened))"
        case .expired:
            return "真实任务证据已过期或中转资料已变化"
        case .failed:
            if let error = errors[profile.id] {
                return "真实任务未通过：\(error)"
            }
            if let stage = receipts[
                profile.id
            ]?.agentLoop.failureStage {
                return "真实任务未通过：\(V013FailurePresentation.agentLoop(stage).conclusion)"
            }
            return "真实任务未通过"
        case .unverified:
            return "未验证真实工具调用；基础请求通过不代表能完成任务"
        }
    }

    static func safeError(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return "验证未完成；请检查Codex安装、登录、网络和额度"
    }

    private var officialUsageStore:
        V011OfficialUsageSnapshotStore {
        V011OfficialUsageSnapshotStore(
            fileURL: rootURL.appendingPathComponent(
                "official-usage.json",
                isDirectory: false
            ),
            writer: writer
        )
    }

    private var savedRelayStore:
        V011SavedRelayReadinessStore {
        V011SavedRelayReadinessStore(
            fileURL: rootURL.appendingPathComponent(
                "saved-relay-readiness.json",
                isDirectory: false
            ),
            writer: writer
        )
    }
}
