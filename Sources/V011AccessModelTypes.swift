// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum V011RuntimeFreshness: Equatable {
    case fresh
    case stale
    case notRunning
    case unknown
}

enum V011CodexRuntimeObservation: Equatable, Sendable {
    case notRunning
    case running(earliestLaunchDate: Date)
    case runningUnknown
}

enum V011AccessError: LocalizedError, Equatable {
    case responsesRequired
    case apiKeyRequired
    case currentRelayMissing
    case currentRelayIncomplete
    case currentRelayCredentialMissing
    case currentRelayUsesLegacyAuthentication
    case currentRelaySnapshotMismatch
    case duplicateProvider
    case invalidCapabilityProfile

    var errorDescription: String? {
        switch self {
        case .responsesRequired:
            return "当前Codex版本只支持已经验证的Responses协议"
        case .apiKeyRequired:
            return "请先填写中转API Key"
        case .currentRelayMissing:
            return "当前Codex没有检测到可接管的中转"
        case .currentRelayIncomplete:
            return "当前中转缺少接口地址或模型，暂时不能无损接管"
        case .currentRelayCredentialMissing:
            return "当前中转没有可迁移的本机密钥，请在安全输入框重新填写"
        case .currentRelayUsesLegacyAuthentication:
            return "当前中转仍使用旧认证方式，不能在“不改现状”的前提下接管。本次没有保存密钥或修改设置；请先用原来的配置工具切回官方，再回来添加这个中转"
        case .currentRelaySnapshotMismatch:
            return "当前中转含有无法无损保存的扩展能力；本次未接管，Codex设置未改变"
        case .duplicateProvider:
            return "已有同名但地址不同的中转，请换一个名称后再添加"
        case .invalidCapabilityProfile:
            return "能力配置无效；请核对速度档、上下文和自动压缩阈值"
        }
    }
}

enum V011SavedRelayPreflightError:
    LocalizedError, Equatable {
    case profileChanged
    case credentialUnavailable

    var errorDescription: String? {
        switch self {
        case .profileChanged:
            return "中转资料在检测前后不一致；请重新读取后再检测"
        case .credentialUnavailable:
            return "中转密钥不可用；未发送检测请求"
        }
    }
}

enum V011SavedRelayPreflightOutcome:
    String, Equatable {
    case checking
    case passed
    case failed
}

struct V011SavedRelayPreflightResult: Equatable {
    let profile: CodexRelayProfile
    let outcome: V011SavedRelayPreflightOutcome
    let checkedAt: Date?
    let detail: String
}

enum V011ProviderCapabilityProbeRunError:
    LocalizedError, Equatable {
    case currentRelayRequired
    case currentContractRequired
    case unsupportedProbe
    case configurationRequired(String)
    case credentialMissing
    case stateChanged
    case invalidEndpoint

    var errorDescription: String? {
        switch self {
        case .currentRelayRequired:
            return "先切换到要验证的中转；可选探针只验证当前真实轨"
        case .currentContractRequired:
            return "当前Codex版本合同尚未绑定；请先验证当前连接"
        case .unsupportedProbe:
            return "该能力没有安全的通用真实探针合同"
        case let .configurationRequired(name):
            return "先在扩展能力中配置\(name)，保存应用后再验证"
        case .credentialMissing:
            return "当前中转凭据不可用；未发送探针请求"
        case .stateChanged:
            return "探针期间当前轨或能力档已变化；回执未保存"
        case .invalidEndpoint:
            return "当前中转Responses地址无效；未发送探针请求"
        }
    }
}

struct V011ProviderCapabilityProbeObservation:
    Sendable {
    let kind: ProviderCapabilityProbeKind
    let status: ProviderCapabilityStatus
    let stage: ProviderProbeStageObservation
    let evidenceLevel: ProviderProbeEvidenceLevel
    let responseStructureSHA256: String?
    let evidenceComponents: [String]
    let requestCount: Int
}

enum V011RefreshReason: String, Hashable, Sendable {
    case initial
    case manual
    case codexApplicationLifecycle
    case sceneActive
}

struct V011RefreshObservation: Equatable, Sendable {
    let reasons: [V011RefreshReason]
    let durationMilliseconds: Double
    let requestCount: Int
    let executionCount: Int
    let coalescedRequestCount: Int
}

struct V011RefreshGate: Sendable {
    enum RequestDecision: Equatable, Sendable {
        case schedule
        case coalesced
    }

    private(set) var requestCount = 0
    private(set) var executionCount = 0
    private(set) var coalescedRequestCount = 0
    private(set) var isExecuting = false
    private var pendingReasons: Set<V011RefreshReason> = []

    mutating func request(
        _ reason: V011RefreshReason
    ) -> RequestDecision {
        requestCount += 1
        if isExecuting || !pendingReasons.isEmpty {
            coalescedRequestCount += 1
        }
        pendingReasons.insert(reason)
        return isExecuting ? .coalesced : .schedule
    }

    mutating func begin() -> [V011RefreshReason]? {
        guard !isExecuting, !pendingReasons.isEmpty else {
            return nil
        }
        isExecuting = true
        executionCount += 1
        let reasons = pendingReasons.sorted {
            $0.rawValue < $1.rawValue
        }
        pendingReasons.removeAll(keepingCapacity: true)
        return reasons
    }

    mutating func complete() -> Bool {
        isExecuting = false
        return !pendingReasons.isEmpty
    }
}
