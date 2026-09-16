// SPDX-License-Identifier: AGPL-3.0-only

enum V016AccessEvidenceLayerKind:
    String, Equatable, Hashable, Sendable {
    case basicHistory = "历史/基础检测"
    case currentAccess = "当前接入新鲜证据"
    case realTask = "真实任务闭环"
}

struct V016AccessEvidenceLayer: Equatable, Sendable {
    let kind: V016AccessEvidenceLayerKind
    let status: String
    let detail: String
}

extension V016AccessReadinessDecision {
    var evidenceLayers: [V016AccessEvidenceLayer] {
        V016AccessEvidenceLayerResolver.resolve(self)
    }
}

enum V016AccessEvidenceLayerResolver {
    static func resolve(
        _ decision: V016AccessReadinessDecision
    ) -> [V016AccessEvidenceLayer] {
        [
            basicLayer(decision),
            currentLayer(decision),
            realTaskLayer(decision),
        ]
    }

    private static func basicLayer(
        _ decision: V016AccessReadinessDecision
    ) -> V016AccessEvidenceLayer {
        let status: String
        switch decision.code {
        case .checkingBasicConnection:
            status = "检测中"
        case .basicConnectionFailed:
            status = "最近一次检测未通过"
        case .realTaskRequired, .checkingRealTask,
                .realTaskReady, .realTaskFailed:
            status = "当前基础连接已通过"
        case .runtimeChanged:
            status = decision.primaryAction == .verifyRealTask
                ? "当前基础连接已通过" : "旧证据已失效"
        case .doctorActionRequired:
            status = "Doctor不能代替连接检测"
        default:
            status = "仅作历史线索"
        }
        return V016AccessEvidenceLayer(
            kind: .basicHistory,
            status: status,
            detail: "“检测通过”只说明当次最小请求，不代表当前版本仍匹配，也不代表真实任务可用。"
        )
    }

    private static func currentLayer(
        _ decision: V016AccessReadinessDecision
    ) -> V016AccessEvidenceLayer {
        let status: String
        switch decision.code {
        case .routeUnknown, .currentStateReadRequired:
            status = "尚未读取"
        case .readingCurrentState:
            status = "读取中"
        case .checkingBasicConnection:
            status = "确认中"
        case .basicConnectionRequired:
            status = "缺少匹配当前接入的证据"
        case .basicConnectionFailed:
            status = "匹配当前接入的最近检测未通过"
        case .runtimeChanged:
            status = decision.primaryAction == .verifyRealTask
                ? "当前基础证据有效" : "旧版本证据已失效"
        case .realTaskRequired, .checkingRealTask,
                .realTaskReady, .realTaskFailed:
            status = "匹配当前配置和版本"
        case .codexNotInstalled:
            status = "Codex未安装"
        case .recoveryPending, .configurationBlocked,
                .compatibilityFailed, .doctorActionRequired:
            status = "先处理当前阻断"
        }
        return V016AccessEvidenceLayer(
            kind: .currentAccess,
            status: status,
            detail: decision.code == .basicConnectionFailed
                ? "失败记录已匹配当前接入、配置和有效期；该记录不包含Codex版本，不能证明当前版本已验证。"
                : "只有证据同时匹配当前接入、配置和 Codex 版本，才算当前新鲜证据。"
        )
    }

    private static func realTaskLayer(
        _ decision: V016AccessReadinessDecision
    ) -> V016AccessEvidenceLayer {
        let status: String
        switch decision.code {
        case .checkingRealTask:
            status = "验证中"
        case .realTaskReady:
            status = "已通过"
        case .realTaskFailed:
            status = "未通过"
        case .runtimeChanged:
            status = "需重新验证"
        case .recoveryPending:
            status = "就绪状态已暂停；恢复后核对"
        case .currentStateReadRequired:
            status = "待核对验证记录"
        default:
            status = "未验证"
        }
        return V016AccessEvidenceLayer(
            kind: .realTask,
            status: status,
            detail: "需单独完成工具调用和续答；基础连接或 Doctor 通过不能替代。"
        )
    }
}
