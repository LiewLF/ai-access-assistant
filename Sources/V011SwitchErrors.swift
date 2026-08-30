// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import CryptoKit
import Foundation

enum V011SwitchError: LocalizedError {
    case pendingRecovery
    case pendingSessionRecovery(prewrite: Bool)
    case invalidRecoveryJournal
    case concurrentConfigurationChange
    case currentRelayChanged
    case recoveryDecisionRequired
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .pendingRecovery:
            return "发现上次未完成的切换，请先点“一键恢复”"
        case let .pendingSessionRecovery(prewrite):
            if prewrite {
                return "发现未完成的历史会话准备操作，已在写入前停止；请先打开修复工具处理历史会话"
            }
            return "发现未完成的历史会话恢复记录，已在写入前停止；请先打开修复工具恢复历史会话"
        case .invalidRecoveryJournal:
            return "恢复记录无法安全读取，已停止继续切换"
        case .concurrentConfigurationChange:
            return "切换期间Codex设置被其他程序改动，已停止自动恢复"
        case .currentRelayChanged:
            return "当前中转设置已被其他工具改变，请先重新接管并核对现状"
        case .recoveryDecisionRequired:
            return "当前Codex设置与操作前和旧目标都不同，已停止自动恢复；请先核对并选择保留当前模式或恢复到操作前"
        case let .rollbackFailed(message):
            return "自动恢复未完成：\(message)"
        }
    }
}

enum V011AcceptedCurrentFaultPoint: Equatable, Sendable {
    case afterAcceptedStateWrite
    case afterAcceptedJournalWrite
    case beforeExclusiveArchiveRename
}

struct V011AcceptedJournalCommitIndeterminate:
    LocalizedError {
    let detail: String

    var errorDescription: String? { detail }
}

enum V011RecoveryErrorText {
    static func safeDetail(_ error: Error) -> String {
        if let clientError = error as? SessionCoreClientError,
           case let .commandFailed(_, code, message) = clientError {
            return sessionCoreDetail(
                code: code,
                fallback: message
            )
        }
        return safeDetail(error.localizedDescription)
    }

    static func safeDetail(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let patterns: [(String, String)] = [
            (
                #"(?i)[\"']?\b(proxy-authorization|authorization)\b[\"']?\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|(?:[a-z][a-z0-9_-]*\s+)?[^\s,;]+)"#,
                "$1=[已隐藏]"
            ),
            (
                #"(?i)\bbearer\s+[^\s,;]+"#,
                "Bearer [已隐藏]"
            ),
            (
                #"(?i)(experimental_bearer_token|api[ _-]?key|authorization|bearer|token)\s*[:=]\s*(\"[^\"]*\"|'[^']*'|[^\s;,]+)"#,
                "$1=[已隐藏]"
            ),
            (#"(?i)\bsk-[A-Za-z0-9_-]{8,}\b"#, "[已隐藏]")
        ]
        for (pattern, replacement) in patterns {
            guard let expression = try? NSRegularExpression(
                pattern: pattern
            ) else { continue }
            let range = NSRange(
                text.startIndex..<text.endIndex,
                in: text
            )
            text = expression.stringByReplacingMatches(
                in: text,
                range: range,
                withTemplate: replacement
            )
        }
        text = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return "恢复组件没有返回可识别的原因"
        }
        let lowered = text.lowercased()
        if lowered.contains("changed after session transaction")
            || lowered.contains("refusing destructive rollback") {
            return "检测到切换后新增或变更的历史会话。恢复已暂停，避免覆盖这些会话；请使用新版再次恢复，新版会先保护新增会话。"
        }
        if lowered.contains("concurrent_sqlite_change") {
            return sessionCoreDetail(
                code: "concurrent_sqlite_change",
                fallback: text
            )
        }
        if lowered.contains("concurrent_rollout_change") {
            return sessionCoreDetail(
                code: "concurrent_rollout_change",
                fallback: text
            )
        }
        if lowered.contains("rollback_compensation_failed") {
            return sessionCoreDetail(
                code: "rollback_compensation_failed",
                fallback: text
            )
        }
        if lowered.contains("recovery journal exceeds")
            || lowered.contains("journal_too_large") {
            return "历史会话记录超过安全处理范围。当前设置未覆盖；请只处理设置、不处理历史会话，或打开修复工具查看详情。"
        }
        if lowered.contains("invalid recovery journal")
            || lowered.contains("invalid_journal")
            || lowered.contains("journal unavailable")
            || lowered.contains("journal_unavailable") {
            return "历史会话记录无法安全读取。当前设置未覆盖；请只处理设置、不处理历史会话，或打开修复工具查看详情。"
        }
        return String(text.prefix(360))
    }

    private static func sessionCoreDetail(
        code: String,
        fallback: String
    ) -> String {
        switch code {
        case "concurrent_sqlite_change",
             "concurrent_rollout_change":
            return "历史会话出现了不能自动合并的修改。为避免覆盖，恢复已暂停；请完全退出Codex后再次恢复，仍失败时打开修复工具。"
        case "rollback_compensation_failed":
            return "历史会话恢复中途失败，自动补偿也没有完成。请不要继续切换，完全退出Codex后再次恢复。"
        case "transaction_locked",
             "transaction_lock_unavailable":
            return "Codex仍在使用历史会话。请保存工作并完全退出Codex，等待几秒后再次恢复。"
        case "sqlite_error":
            return "历史会话索引处理失败。请完全退出Codex后再次恢复；仍失败时打开修复工具，助手不会覆盖现有会话。"
        case "unsupported_sqlite_schema":
            return "当前Codex的历史会话格式尚未通过兼容验证。已停止修改；请打开修复工具查看支持状态。"
        case "rollback_verification_failed",
             "rollback_failed":
            return "历史会话恢复后核对未通过。已停止后续写入；请再次恢复，仍失败时打开修复工具。"
        default:
            return safeDetail(fallback)
        }
    }
}

struct V011ForwardCompletionError: LocalizedError {
    let stage: V011RecoveryFailureStage
    let reason: String
    let nextAction: String

    var errorDescription: String? {
        "\(stage.displayName)未通过：\(reason)。下一步：\(nextAction)"
    }
}
