// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct ConfigWorkspaceSessionRepairTarget {
    let providerID: String
    let profileID: String
}

enum ConfigWorkspaceSessionRepairResult {
    case repaired
    case failed(
        message: String,
        hasPendingRecovery: Bool
    )
}

enum ConfigWorkspaceSessionRestoreResult {
    case restored
    case failed(message: String)
}

enum ConfigWorkspacePendingSessionRecoveryResult {
    case recovered(count: Int)
    case failed(message: String)
}

/// Owns SessionSync transaction ordering, Codex lifecycle coordination, and
/// repair compensation. ConfigWorkspaceModel keeps user authorization, saved-
/// work gates, progress projection, and final UI state.
@MainActor
struct ConfigWorkspaceSessionRepairService {
    let engine: SessionSyncEngine
    let application: CodexApplicationController

    func repair(
        resolveTarget:
            () throws -> ConfigWorkspaceSessionRepairTarget,
        additionalRecoveryFiles:
            [SessionAdditionalRecoveryFile],
        reportStatus: (String) -> Void
    ) async -> ConfigWorkspaceSessionRepairResult {
        let engine = self.engine
        let application = self.application
        var transactionID: String?
        do {
            let target = try resolveTarget()
            if application.isRunning {
                reportStatus("正在正常关闭Codex")
                try await application.requestQuit()
            }
            reportStatus("正在重新扫描并核对全部会话")
            let preview = try await Task.detached(
                priority: .userInitiated
            ) {
                try engine.preview(
                    targetProvider: target.providerID,
                    targetProfileID: target.profileID,
                    sourceProfileID: nil,
                    trustSourceOrigin: false,
                    additionalRecoveryFiles:
                        additionalRecoveryFiles
                )
            }.value
            guard preview.canApply else {
                throw SessionSyncError.planBlocked(
                    preview.blockers.map {
                        $0 + "。"
                            + Self.repairSuggestion(
                                for: $0
                            )
                    }
                )
            }
            let prepared = try await Task.detached(
                priority: .userInitiated
            ) {
                try engine.prepare(preview)
            }.value
            transactionID = prepared.id
            let applied = try await Task.detached(
                priority: .userInitiated
            ) {
                try engine.apply(
                    transactionID: prepared.id
                )
            }.value
            guard applied.phase == .readyToCommit else {
                throw SessionSyncError
                    .invalidTransactionPhase(
                        applied.phase
                    )
            }
            reportStatus(
                "会话与索引已同步，正在重开Codex"
            )
            try await application.launch()
            _ = try await Task.detached(
                priority: .userInitiated
            ) {
                try engine.commit(
                    transactionID: prepared.id,
                    message:
                        "历史会话已修复到当前模式并重开Codex"
                )
            }.value
            return .repaired
        } catch {
            if application.isRunning,
               transactionID != nil {
                try? await application.requestQuit()
            }
            if let transactionID,
               let transaction = try? engine
                .journalStore.load(
                    transactionID
                ),
               transaction.phase != .rolledBack,
               transaction.phase != .manualRecovery {
                _ = try? await Task.detached(
                    priority: .userInitiated
                ) {
                    try engine.rollback(
                        transactionID: transactionID,
                        reason:
                            error.localizedDescription
                    )
                }.value
            }
            if !application.isRunning {
                try? await application.launch()
            }
            return .failed(
                message: error.localizedDescription,
                hasPendingRecovery:
                    (try? engine.journalStore
                        .pending().isEmpty) == false
            )
        }
    }

    func restoreLatest()
        async -> ConfigWorkspaceSessionRestoreResult {
        let engine = self.engine
        let application = self.application
        do {
            if application.isRunning {
                try await application.requestQuit()
            }
            _ = try await Task.detached(
                priority: .userInitiated
            ) {
                try engine.restoreLatestCommitted()
            }.value
            try await application.launch()
            return .restored
        } catch {
            if !application.isRunning {
                try? await application.launch()
            }
            return .failed(
                message: error.localizedDescription
            )
        }
    }

    func recoverPending()
        async -> ConfigWorkspacePendingSessionRecoveryResult {
        let engine = self.engine
        let application = self.application
        do {
            if application.isRunning {
                try await application.requestQuit()
            }
            let restored = try await Task.detached(
                priority: .userInitiated
            ) {
                try engine.recoverPendingTransactions()
            }.value
            try await application.launch()
            return .recovered(count: restored.count)
        } catch {
            if !application.isRunning {
                try? await application.launch()
            }
            return .failed(
                message: error.localizedDescription
            )
        }
    }

    private static func repairSuggestion(
        for blocker: String
    ) -> String {
        if blocker.contains("不同Thread ID") {
            return "这些Thread没有父子、派生或会话关系证据，已保护性跳过；请在“查看技术详情”定位文件"
        }
        if blocker.contains("数据库")
            && blocker.contains("占用") {
            return "请先退出Codex和其他配置工具后重试"
        }
        if blocker.contains("没有对应数据库记录") {
            return "请先正常打开并退出一次Codex，让原生索引完成落盘后重试"
        }
        if blocker.contains("来源账本") {
            return "请先使用“一键恢复”恢复上次事务"
        }
        return "请查看下方红字的具体文件和原因后重试"
    }
}
