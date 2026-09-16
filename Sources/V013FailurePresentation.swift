// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum V013FailurePrimaryAction: String, Equatable, Sendable {
    case reviewRelayProfile
    case reviewQuota
    case reviewDNSAndAddress
    case reviewTLSAndProxy
    case checkNetwork
    case retryLater
    case refreshState
    case openCodexLogin
    case updateAssistant
    case reviewToolPermission
    case reviewResponsesCompatibility
    case restartAssistant
    case openAdvancedDiagnostics

    var title: String {
        switch self {
        case .reviewRelayProfile:
            return "检查中转资料"
        case .reviewQuota:
            return "检查余额或套餐"
        case .reviewDNSAndAddress:
            return "检查地址与DNS"
        case .reviewTLSAndProxy:
            return "检查TLS与代理"
        case .checkNetwork:
            return "检查网络或代理"
        case .retryLater:
            return "稍后再检测"
        case .refreshState:
            return "重新读取当前状态"
        case .openCodexLogin:
            return "打开Codex登录"
        case .updateAssistant:
            return "更新助手后重试"
        case .reviewToolPermission:
            return "检查Codex工具权限"
        case .reviewResponsesCompatibility:
            return "检查Responses兼容性"
        case .restartAssistant:
            return "重开助手"
        case .openAdvancedDiagnostics:
            return "查看高级诊断"
        }
    }
}

struct V013FailurePresentation: Equatable, Sendable {
    let conclusion: String
    let explanation: String
    let primaryAction: V013FailurePrimaryAction
    let evidence: [String]

    static func connection(
        _ observation: V011ConnectionHealthObservation?
    ) -> Self? {
        guard let observation,
              observation.outcome != .passed,
              let failureCode = observation.failureCode else {
            return nil
        }
        if failureCode != .probeFailed {
            return connectionFailureCode(
                failureCode,
                observation: observation
            )
        }
        guard let category = observation.failureCategory else {
            return make(
                conclusion: "当前连接没有通过",
                explanation: "连接检测未返回可安全分类的原因；保留当前设置，查看高级诊断。",
                action: .openAdvancedDiagnostics,
                evidence: connectionEvidence(observation)
            )
        }
        let status = observation.httpStatus.map {
            "（HTTP \($0)）"
        } ?? ""
        let isOfficial = observation.providerID == "openai"
        let service = isOfficial ? "官方" : "中转"
        switch category {
        case .authentication:
            return make(
                conclusion: "\(service)认证未通过",
                explanation: isOfficial
                    ? "基础请求认证未通过\(status)。请在Codex官方界面核对登录状态。"
                    : "认证未通过\(status)。检查API Key与对应中转资料。",
                action: isOfficial ? .openCodexLogin : .reviewRelayProfile,
                evidence: connectionEvidence(observation)
            )
        case .permission:
            return make(
                conclusion: "\(service)访问受限",
                explanation: isOfficial
                    ? "官方服务拒绝基础请求\(status)。需核对账号、模型或地区权限，不能据此断定登录失效。"
                    : "服务拒绝请求\(status)。可能是账号、模型或地区权限，不能据此断定API Key错误。",
                action: isOfficial ? .openAdvancedDiagnostics : .reviewRelayProfile,
                evidence: connectionEvidence(observation)
            )
        case .endpointOrModel:
            return make(
                conclusion: "\(service)地址或模型不可用",
                explanation: isOfficial
                    ? "官方基础请求的地址、协议或模型不可用\(status)。请查看诊断并核对Codex版本与模型。"
                    : "地址、协议路径或默认模型不可用\(status)。检查中转资料。",
                action: isOfficial ? .openAdvancedDiagnostics : .reviewRelayProfile,
                evidence: connectionEvidence(observation)
            )
        case .quotaExhausted:
            return make(
                conclusion: "\(service)额度不足",
                explanation: isOfficial
                    ? "官方基础请求报告额度不足\(status)。请核对套餐与额度，无需反复检测。"
                    : "账户余额或额度不足\(status)。无需反复检测或更换API Key。",
                action: .reviewQuota,
                evidence: connectionEvidence(observation)
            )
        case .rateLimited:
            return make(
                conclusion: "\(service)请求暂时受限",
                explanation: isOfficial
                    ? "基础请求过于频繁\(status)。可稍后再检测，无需先重新登录。"
                    : "请求过于频繁\(status)。无需先更换API Key。",
                action: .retryLater,
                evidence: connectionEvidence(observation)
            )
        case .upstreamUnavailable:
            return make(
                conclusion: "\(service)服务暂时异常",
                explanation: "\(service)服务暂时异常\(status)。助手不会自动切换接入。",
                action: .retryLater,
                evidence: connectionEvidence(observation)
            )
        case .networkNameResolutionFailed:
            return make(
                conclusion: "\(service)域名无法解析",
                explanation: isOfficial
                    ? "官方基础请求的域名无法解析。请检查DNS、网络或代理。"
                    : "域名无法解析。先核对中转地址；地址无误时检查DNS或网络。",
                action: isOfficial ? .checkNetwork : .reviewDNSAndAddress,
                evidence: connectionEvidence(observation)
            )
        case .networkSecureConnectionFailed:
            return make(
                conclusion: "\(service)安全连接未通过",
                explanation: "TLS或证书验证未通过。检查系统时间、代理或证书链；助手不会绕过证书验证。",
                action: .reviewTLSAndProxy,
                evidence: connectionEvidence(observation)
            )
        case .networkTimedOut:
            return make(
                conclusion: "\(service)基础连接检测超时",
                explanation: isOfficial
                    ? "上次检测未在等待时限内完成，可能涉及 Codex 启动或响应等待，不能据此判定网络故障；额度读取成功也不代表基础请求通过。"
                    : "上次检测未在等待时限内完成，可能涉及 Codex 启动或响应等待，不能据此判定服务或代理故障。",
                action: .retryLater,
                evidence: connectionEvidence(observation)
            )
        case .networkUnavailable:
            return make(
                conclusion: "\(service)网络未连通",
                explanation: "网络或代理连接未完成。核对连接后再检测。",
                action: .checkNetwork,
                evidence: connectionEvidence(observation)
            )
        case .invalidResponse:
            return make(
                conclusion: "\(service)响应格式不可用",
                explanation: "服务已响应，但本次协议的结果无法识别\(status)。",
                action: .reviewResponsesCompatibility,
                evidence: connectionEvidence(observation)
            )
        case .probeBudgetExhausted:
            // LTP-140: the probe's own 8 token budget, not account quota and
            // not a rate limit. The persisted text never claims the response
            // had no text; that detail stays in the immediate typed error.
            return make(
                conclusion: "\(service)响应未在探测预算内完成",
                explanation: "已收到响应，但它在本次探测的 8 token 预算内没有完成\(status)。这不代表账户额度、套餐或服务不可用；可在需要时重新检测。",
                action: .retryLater,
                evidence: connectionEvidence(observation)
            )
        case .probeCancelled:
            return make(
                conclusion: "\(service)验证已取消",
                explanation: "本次探测在完成前被取消\(status)。没有完成验证，也没有失败结论；这不代表服务不可用或额度不足，可在需要时重新检测。",
                action: .retryLater,
                evidence: connectionEvidence(observation)
            )
        case .probeRefused:
            return make(
                conclusion: "\(service)模型拒绝了探针请求",
                explanation: "模型对本次最小请求给出了明确拒绝\(status)。这是模型侧的决定，不能据此判断服务不可用或额度不足；可在需要时重新检测。",
                action: .retryLater,
                evidence: connectionEvidence(observation)
            )
        case .probeMissingCompletion:
            return make(
                conclusion: "\(service)响应缺少正常结束",
                explanation: "已收到响应，但没有可识别的正常结束标记\(status)。保留有限证据，未完成验证；这不代表服务不可用或额度不足。",
                action: .retryLater,
                evidence: connectionEvidence(observation)
            )
        case .probeNoVisibleText:
            // LTP-140: only the observed fact is persisted. Some wire
            // protocols can deliver a body without any completion marker,
            // so the card never claims the response ended normally.
            return make(
                conclusion: "\(service)响应没有可见文字",
                explanation: "本次探测收到的响应没有可见文字（可能只有推理或工具内容）\(status)。未完成验证；这不代表服务不可用或额度不足。",
                action: .retryLater,
                evidence: connectionEvidence(observation)
            )
        case .unknown:
            return make(
                conclusion: "当前连接没有通过",
                explanation: "失败原因未能安全分类；保留当前设置，查看高级诊断。",
                action: .openAdvancedDiagnostics,
                evidence: connectionEvidence(observation)
            )
        }
    }

    static func officialUsage(_ error: Error) -> Self {
        guard let usageError = error as? V011OfficialUsageError else {
            return make(
                conclusion: "官方额度未读取",
                explanation: "检查Codex安装、登录与网络后再读取。",
                action: .openAdvancedDiagnostics,
                evidence: [
                    "阶段：官方额度",
                    "类别：unknown",
                ]
            )
        }
        let conclusion: String
        let explanation: String
        let action: V013FailurePrimaryAction
        let category: String
        switch usageError {
        case .testingBlocked:
            conclusion = "测试环境禁止读取官方额度"
            explanation = "当前环境不会访问真实官方账户。"
            action = .openAdvancedDiagnostics
            category = "testing-blocked"
        case .unsupportedVersion:
            conclusion = "当前Codex版本不支持安全读取额度"
            explanation = "助手保持只读，不猜测或绕过官方接口。"
            action = .updateAssistant
            category = "unsupported-version"
        case .appServerUnavailable:
            conclusion = "Codex官方额度服务暂时不可用"
            explanation = "当前设置未变化，可稍后重新读取。"
            action = .retryLater
            category = "app-server-unavailable"
        case .protocolMismatch:
            conclusion = "Codex官方额度接口已变化"
            explanation = "当前结果未采用，更新助手后再读取。"
            action = .updateAssistant
            category = "protocol-mismatch"
        case .chatGPTLoginRequired:
            conclusion = "Codex官方登录未完成"
            explanation = "先在Codex官方界面登录ChatGPT账号；助手不读取账号、密码或验证码。"
            action = .openCodexLogin
            category = "login-required"
        case .rateLimitsUnavailable:
            conclusion = "官方暂未返回额度窗口"
            explanation = "本次没有可显示的官方额度证据。"
            action = .retryLater
            category = "rate-limits-unavailable"
        case .unsafeEvidence:
            conclusion = "官方额度证据不完整"
            explanation = "本次结果未采用，避免显示错误额度。"
            action = .retryLater
            category = "unsafe-evidence"
        }
        return make(
            conclusion: conclusion,
            explanation: explanation,
            action: action,
            evidence: [
                "阶段：官方额度",
                "类别：\(category)",
            ]
        )
    }

    static func compatibility(
        _ evidence: CodexCompatibilityEvidence?
    ) -> Self? {
        guard let evidence,
              evidence.source == .blocked else {
            return nil
        }
        let check = safeEvidenceToken(
            evidence.failureCheck ?? "compatibility-not-verified"
        )
        let conclusion: String
        let explanation: String
        switch check {
        case "agent-loop-exec-protocol":
            conclusion = "当前Codex命令能力未通过验证"
            explanation = "助手未找到可安全启动真实任务闭环的CLI参数；保持只读。"
        default:
            conclusion = "当前Codex版本未通过兼容验证"
            explanation = "助手保持只读，不用未知参数改写Codex设置。"
        }
        return make(
            conclusion: conclusion,
            explanation: explanation,
            action: .updateAssistant,
            evidence: [
                "阶段：Codex兼容验证",
                "未通过项目：\(check)",
            ]
        )
    }

    static func agentLoop(
        _ stage: V011AgentLoopFailureStage,
        reason: V011AgentLoopFailureReason? = nil
    ) -> Self {
        if let reason {
            return make(conclusion: reason.userTitle, explanation: reason.userAction,
                        action: .openAdvancedDiagnostics,
                        evidence: ["阶段：真实任务", "失败位置：\(stage.rawValue)",
                                   "原因：\(reason.rawValue)"])
        }
        let explanation: String
        let action: V013FailurePrimaryAction
        switch stage {
        case .preparation:
            explanation = "隔离验证环境未建立；真实设置与历史会话未被使用。"
            action = .openAdvancedDiagnostics
        case .initialResponse:
            explanation = stage.userAction
            action = .openAdvancedDiagnostics
        case .toolCall:
            explanation = "当前模型或中转只完成普通回复，尚不能证明可完成Codex任务。"
            action = .reviewResponsesCompatibility
        case .toolExecution:
            explanation = "本机工具未完成；助手不会扩大权限或绕过审批。"
            action = .reviewToolPermission
        case .continuation:
            explanation = "工具结果未被正确续接；当前链路尚未形成完整任务闭环。"
            action = .reviewResponsesCompatibility
        case .finalResponse:
            explanation = "最终回复与验证合同不一致；当前链路返回不完整。"
            action = .reviewResponsesCompatibility
        case .configurationChanged:
            explanation = "验证期间Codex设置发生变化，本次证据已作废。重新读取当前状态；若再次变化，仅说明证据仍未稳定，不会停止进程、修改配置或自动重试。"
            action = .refreshState
        case .cleanup:
            explanation = "临时验证目录未能立即清理；过期目录仍由助手受控清理。"
            action = .restartAssistant
        }
        return make(
            conclusion: stageConclusion(stage),
            explanation: explanation,
            action: action,
            evidence: [
                "阶段：真实任务",
                "失败位置：\(stage.rawValue)",
            ]
        )
    }

    private static func stageConclusion(
        _ stage: V011AgentLoopFailureStage
    ) -> String {
        switch stage {
        case .preparation:
            return "隔离验证环境未建立"
        case .initialResponse:
            return stage.userTitle
        case .toolCall:
            return "模型没有发起本机工具调用"
        case .toolExecution:
            return "本机工具没有完成"
        case .continuation:
            return "工具完成后模型没有继续"
        case .finalResponse:
            return "任务最终回复未通过验证"
        case .configurationChanged:
            return "验证期间Codex设置发生变化"
        case .cleanup:
            return "临时验证目录未能立即清理"
        }
    }

    private static func connectionFailureCode(
        _ code: V011ConnectionHealthFailureCode,
        observation: V011ConnectionHealthObservation
    ) -> Self {
        let conclusion: String
        let explanation: String
        let action: V013FailurePrimaryAction
        switch code {
        case .savedProfileMissing:
            conclusion = "当前中转缺少匹配资料"
            explanation = "当前实时接入没有对应的已保存中转资料。"
            action = .reviewRelayProfile
        case .savedProfileMismatch:
            conclusion = "当前接入与保存资料不一致"
            explanation = "Provider、地址、模型或认证与保存资料不一致。"
            action = .reviewRelayProfile
        case .endpointHostUnavailable:
            conclusion = "当前中转地址无法识别"
            explanation = "地址未形成可验证的主机名。"
            action = .reviewRelayProfile
        case .configurationChangedDuringCheck:
            conclusion = "检测期间Codex设置发生变化"
            explanation = "本次结果已作废，先重新读取当前状态。"
            action = .refreshState
        case .sessionProviderDrift:
            conclusion = "历史任务保留其他接入标签"
            explanation = "这是历史标签差异，不代表当前请求路由或连接失败；可在高级诊断查看检测记录。"
            action = .openAdvancedDiagnostics
        case .receiptMismatch:
            conclusion = "连接证据与当前配置不一致"
            explanation = "旧证据未被采用，先重新读取当前状态。"
            action = .refreshState
        case .unavailable:
            conclusion = "连接检测未生成可用结果"
            explanation = "当前设置保持不变，查看高级诊断。"
            action = .openAdvancedDiagnostics
        case .probeFailed:
            conclusion = "当前连接没有通过"
            explanation = "失败原因未能安全分类。"
            action = .openAdvancedDiagnostics
        }
        return make(
            conclusion: conclusion,
            explanation: explanation,
            action: action,
            evidence: connectionEvidence(observation)
        )
    }

    private static func connectionEvidence(
        _ observation: V011ConnectionHealthObservation
    ) -> [String] {
        var result = ["阶段：基础连接"]
        if let category = observation.failureCategory {
            result.append("类别：\(category.rawValue)")
        } else if let code = observation.failureCode {
            result.append("类别：\(code.rawValue)")
        }
        if let status = observation.httpStatus,
           (100...599).contains(status) {
            result.append("HTTP：\(status)")
        }
        return result
    }

    private static func safeEvidenceToken(_ raw: String) -> String {
        let allowed = raw.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
                || $0 == "-" || $0 == "_"
        }
        let value = String(String.UnicodeScalarView(allowed))
        return String(value.prefix(80))
    }

    private static func make(
        conclusion: String,
        explanation: String,
        action: V013FailurePrimaryAction,
        evidence: [String]
    ) -> Self {
        Self(
            conclusion: conclusion,
            explanation: explanation,
            primaryAction: action,
            evidence: evidence
        )
    }
}
