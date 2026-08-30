// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct CodexDoctorTruthComparison: Equatable {
    let matchesPersistentConfig: Bool
    let blockingReasons: [String]

    var summary: String {
        matchesPersistentConfig
            ? "Codex官方诊断与用户配置层一致。"
            : blockingReasons.joined(separator: "；")
    }
}

enum CodexDoctorTruthComparator {
    static func compare(
        diagnostic: CodexDoctorDiagnostic,
        runtimeTruth: RuntimeTruth
    ) -> CodexDoctorTruthComparison {
        var blockers: [String] = []
        if URL(fileURLWithPath: diagnostic.codexHome)
            .standardizedFileURL.path
            != URL(fileURLWithPath: runtimeTruth.persistent.codexHome)
                .standardizedFileURL.path {
            blockers.append("Codex官方诊断与助手读取的CODEX_HOME不一致")
        }
        let diagnosticProvider = normalizedProvider(
            diagnostic.providerID
        )
        let persistentProvider = normalizedProvider(
            runtimeTruth.persistent.selectedProviderID
        )
        if diagnosticProvider != persistentProvider {
            blockers.append(
                "Codex官方诊断Provider“\(diagnosticProvider)”与用户配置层“\(persistentProvider)”不一致"
            )
        }
        if let diagnosticModel = diagnostic.model,
           diagnosticModel != runtimeTruth.persistent.selectedModel {
            blockers.append(
                "Codex官方诊断模型与用户配置层不一致"
            )
        }
        if diagnostic.configStatus != "ok" {
            blockers.append("Codex官方诊断未确认配置加载成功")
        }
        return CodexDoctorTruthComparison(
            matchesPersistentConfig: blockers.isEmpty,
            blockingReasons: blockers
        )
    }

    private static func normalizedProvider(_ value: String?) -> String {
        guard let value, !value.isEmpty, value != "openai" else {
            return "openai"
        }
        return value
    }
}

enum CodexDoctorCheckStatus: String, Equatable, Sendable {
    case ok
    case warning
    case fail
    case skipped
    case unknown

    var userLabel: String {
        switch self {
        case .ok: return "通过"
        case .warning: return "需注意"
        case .fail: return "未通过"
        case .skipped: return "未执行"
        case .unknown: return "状态未知"
        }
    }
}

struct CodexDoctorCheckEvidence: Equatable, Sendable {
    let id: String
    let category: String?
    let status: CodexDoctorCheckStatus

    var safeSummary: String {
        "\(id)：\(status.userLabel)"
    }
}

enum CodexDoctorCheckEvidenceParser {
    private static let maximumChecks = 128
    private static let maximumIDLength = 160
    private static let maximumCategoryLength = 80

    static func parse(
        _ rawChecks: [String: Any]
    ) -> [CodexDoctorCheckEvidence] {
        rawChecks.keys.sorted().prefix(maximumChecks).compactMap { key in
            guard isSafeToken(key, maximumLength: maximumIDLength),
                  let rawCheck = rawChecks[key] as? [String: Any] else {
                return nil
            }
            let reportedID = rawCheck["id"] as? String ?? key
            guard reportedID == key,
                  isSafeToken(
                      reportedID,
                      maximumLength: maximumIDLength
                  ),
                  let rawStatus = rawCheck["status"] as? String else {
                return nil
            }
            let status = CodexDoctorCheckStatus(
                rawValue: rawStatus.lowercased()
            ) ?? .unknown
            let category = (rawCheck["category"] as? String).flatMap {
                isSafeToken(
                    $0,
                    maximumLength: maximumCategoryLength
                ) ? $0 : nil
            }
            return CodexDoctorCheckEvidence(
                id: reportedID,
                category: category,
                status: status
            )
        }
    }

    private static func isSafeToken(
        _ value: String,
        maximumLength: Int
    ) -> Bool {
        guard !value.isEmpty,
              value.count <= maximumLength else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "."
                || scalar == "_"
                || scalar == "-"
        }
    }
}

enum CodexDoctorReadinessState: String, Equatable, Sendable {
    case ready
    case limited
    case blocked
    case unknown
}

enum CodexDoctorPrimaryAction: String, Equatable, Sendable {
    case openCodex
    case openCodexLogin
    case refreshState
    case reviewConfiguration
    case checkNetwork
    case updateCodex
    case reviewEvidence

    var title: String {
        switch self {
        case .openCodex: return "打开Codex继续工作"
        case .openCodexLogin: return "打开Codex完成登录"
        case .refreshState: return "重新读取当前状态"
        case .reviewConfiguration: return "查看配置位置"
        case .checkNetwork: return "再次只读检查网络"
        case .updateCodex: return "打开Codex官方下载页"
        case .reviewEvidence: return "查看安全诊断依据"
        }
    }
}

struct CodexDoctorActionableGuidance: Equatable, Sendable {
    let state: CodexDoctorReadinessState
    let conclusion: String
    let explanation: String
    let primaryAction: CodexDoctorPrimaryAction
    let evidence: [String]

    var summary: String {
        "\(conclusion) \(explanation) 下一步：\(primaryAction.title)。"
    }
}

enum CodexDoctorActionableProjector {
    private static let criticalChecks: [
        (id: String, action: CodexDoctorPrimaryAction,
         conclusion: String)
    ] = [
        (
            "config.load",
            .reviewConfiguration,
            "Codex配置没有加载成功"
        ),
        (
            "auth.credentials",
            .openCodexLogin,
            "Codex官方登录未就绪"
        ),
        (
            "installation",
            .updateCodex,
            "Codex安装需要处理"
        ),
        (
            "network.provider_reachability",
            .checkNetwork,
            "Codex服务网络没有连通"
        ),
        (
            "network.websocket_reachability",
            .checkNetwork,
            "Codex任务连接没有连通"
        ),
    ]

    static func project(
        diagnostic: CodexDoctorDiagnostic,
        comparison: CodexDoctorTruthComparison?
    ) -> CodexDoctorActionableGuidance {
        if let comparison,
           !comparison.matchesPersistentConfig {
            return guidance(
                state: .limited,
                conclusion: "诊断结果与当前设置不一致",
                explanation:
                    "旧结果不会用于修改设置；现有Codex不会被自动切换。",
                action: .refreshState,
                checks: diagnostic.checks
            )
        }
        if let failure = criticalCheck(
            in: diagnostic.checks,
            status: .fail
        ) {
            return guidance(
                state: .blocked,
                conclusion: failure.conclusion,
                explanation:
                    "只停止受影响的接入步骤；助手没有修改当前设置。",
                action: failure.action,
                checks: diagnostic.checks
            )
        }
        if diagnostic.checks.contains(where: {
            $0.id == "state.paths"
                && $0.status == .fail
        }) {
            return guidance(
                state: .blocked,
                conclusion: "Codex本机状态数据库完整性检查失败",
                explanation:
                    "只停止依赖该状态库的操作；助手不会移动、删除或重建数据库。",
                action: .reviewEvidence,
                checks: diagnostic.checks
            )
        }
        if let warning = criticalCheck(
            in: diagnostic.checks,
            status: .warning
        ) {
            return guidance(
                state: .limited,
                conclusion: warning.conclusion,
                explanation:
                    "检查给出提示，先处理这一项，再判断是否需要重试。",
                action: warning.action,
                checks: diagnostic.checks
            )
        }
        if diagnostic.checks.contains(where: {
            $0.status == .fail || $0.status == .unknown
        }) {
            return guidance(
                state: .unknown,
                conclusion: "Codex诊断有未识别问题",
                explanation:
                    "不能据此断定Codex不可用；先查看安全诊断依据。",
                action: .reviewEvidence,
                checks: diagnostic.checks
            )
        }
        if diagnostic.checks.contains(where: {
            $0.id == "runtime.search"
                && $0.status == .warning
        }) {
            return guidance(
                state: .limited,
                conclusion: "Codex文件搜索工具未就绪",
                explanation:
                    "官方诊断无法验证文件搜索工具；助手不会自动安装软件。",
                action: .updateCodex,
                checks: diagnostic.checks
            )
        }
        if diagnostic.checks.contains(where: {
            $0.id == "state.rollout_db_parity"
                && $0.status == .warning
        }) {
            return guidance(
                state: .limited,
                conclusion: "Codex历史索引与会话文件不一致",
                explanation:
                    "只显示官方安全诊断依据；助手不会自动修复、删除或重建历史索引。",
                action: .reviewEvidence,
                checks: diagnostic.checks
            )
        }
        if diagnostic.checks.contains(where: {
            $0.status == .warning || $0.status == .skipped
        }) {
            return guidance(
                state: .limited,
                conclusion: "Codex没有报告基础阻断",
                explanation:
                    "可以继续现有工作；部分环境或扩展检查仍需注意。",
                action: .reviewEvidence,
                checks: diagnostic.checks
            )
        }
        guard !diagnostic.checks.isEmpty else {
            return guidance(
                state: .unknown,
                conclusion: "Codex诊断结果不足",
                explanation:
                    "没有可安全采用的分项结果，当前设置保持不变。",
                action: .reviewEvidence,
                checks: []
            )
        }
        return guidance(
            state: .ready,
            conclusion: "Codex基础环境可以继续使用",
            explanation:
                "官方诊断未发现阻断；真实任务能力仍以单独验证为准。",
            action: .openCodex,
            checks: diagnostic.checks
        )
    }

    private static func criticalCheck(
        in checks: [CodexDoctorCheckEvidence],
        status: CodexDoctorCheckStatus
    ) -> (
        action: CodexDoctorPrimaryAction,
        conclusion: String
    )? {
        for critical in criticalChecks
            where checks.contains(where: {
                $0.id == critical.id && $0.status == status
            }) {
            return (critical.action, critical.conclusion)
        }
        return nil
    }

    private static func guidance(
        state: CodexDoctorReadinessState,
        conclusion: String,
        explanation: String,
        action: CodexDoctorPrimaryAction,
        checks: [CodexDoctorCheckEvidence]
    ) -> CodexDoctorActionableGuidance {
        let nonPassing = checks.filter { $0.status != .ok }
        let evidence = nonPassing.isEmpty
            ? ["官方分项检查：\(checks.count)项，未发现阻断"]
            : Array(nonPassing.prefix(8).map(\.safeSummary))
        return CodexDoctorActionableGuidance(
            state: state,
            conclusion: conclusion,
            explanation: explanation,
            primaryAction: action,
            evidence: evidence
        )
    }
}
