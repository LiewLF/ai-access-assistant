// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum V011HistoryMutationUpdate {
    case presentation(
        status: String,
        current: Int?,
        total: Int?
    )
    case restoreCompletedState(
        pointer: V011HistoryRecoveryPointer?,
        pending: SessionCorePendingJournal?
    )
    case restoreFailed(String)
}

enum V011HistoryMutationCompletion {
    case externalImport(
        V011ExternalSessionImportOutcome,
        provider: String?
    )
    case repair(
        V011HistoryRepairOutcome,
        provider: String
    )
    case restore(
        V011HistoryRestoreOutcome,
        operationKey: String,
        provider: String?
    )
}

@MainActor
protocol V011HistoryMutationControllerDelegate: AnyObject {
    func historyMutationDidUpdate(
        _ update: V011HistoryMutationUpdate
    )
    func historyMutationDidComplete(
        _ completion: V011HistoryMutationCompletion
    ) async
}

/// Owns History mutation task lifetime and service-event ordering. Durable
/// import/repair/restore transactions remain in their existing services;
/// HistoryModel remains the sole Published-state owner.
@MainActor
final class V011HistoryMutationController {
    private let dependencies: V011HistoryDependencies
    private let recoveryRoot: URL
    private let ledgerRoot: URL
    private weak var delegate:
        (any V011HistoryMutationControllerDelegate)?
    private var task: Task<Void, Never>?
    private(set) var restoreInFlight = false

    init(
        dependencies: V011HistoryDependencies,
        recoveryRoot: URL,
        ledgerRoot: URL,
        delegate: any V011HistoryMutationControllerDelegate
    ) {
        self.dependencies = dependencies
        self.recoveryRoot = recoveryRoot
        self.ledgerRoot = ledgerRoot
        self.delegate = delegate
    }

    func importExternalSessions(
        sourceRoot: URL,
        normalizedSource: URL,
        expectedSessionCount: Int,
        provider: String?
    ) {
        let service = V011ExternalSessionImportService(
            dependencies: dependencies
        )
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            let outcome = await service.execute(
                sourceRoot: sourceRoot,
                normalizedSource: normalizedSource,
                expectedSessionCount: expectedSessionCount,
                event: { [weak self] event in
                    self?.publish(event)
                }
            )
            await delegate?.historyMutationDidComplete(
                .externalImport(outcome, provider: provider)
            )
        }
    }

    func repair(provider: String) {
        let service = V011HistoryRepairService(
            dependencies: dependencies,
            recoveryRoot: recoveryRoot,
            ledgerRoot: ledgerRoot
        )
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            let outcome = await service.execute(
                provider: provider,
                event: { [weak self] event in
                    self?.publish(event)
                }
            )
            await delegate?.historyMutationDidComplete(
                .repair(outcome, provider: provider)
            )
        }
    }

    func restore(
        snapshot: V011HistoryRecoverySnapshot,
        visibleTotal: Int?,
        total: Int,
        operationKey: String,
        provider: String?
    ) {
        restoreInFlight = true
        let service = V011HistoryRestoreService(
            dependencies: dependencies,
            recoveryRoot: recoveryRoot
        )
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                restoreInFlight = false
                task = nil
            }
            let outcome = await service.execute(
                expectedPointerHash: snapshot.pointerHash,
                visibleTotal: visibleTotal,
                total: total,
                event: { [weak self] event in
                    self?.publish(event)
                }
            )
            await delegate?.historyMutationDidComplete(
                .restore(
                    outcome,
                    operationKey: operationKey,
                    provider: provider
                )
            )
        }
    }

    private func publish(
        _ event: V011ExternalSessionImportEvent
    ) {
        switch event {
        case .importing:
            delegate?.historyMutationDidUpdate(
                .presentation(
                    status: "正在导入外部会话",
                    current: nil,
                    total: nil
                )
            )
        case let .progress(current, total):
            delegate?.historyMutationDidUpdate(
                .presentation(
                    status: "正在导入外部会话 \(current)/\(total)",
                    current: current,
                    total: total
                )
            )
        case .relaunching:
            delegate?.historyMutationDidUpdate(
                .presentation(
                    status: "外部会话已导入，正在重新打开Codex",
                    current: nil,
                    total: nil
                )
            )
        }
    }

    private func publish(_ event: V011HistoryRepairEvent) {
        let update: V011HistoryMutationUpdate
        switch event {
        case .reconciling:
            update = .presentation(
                status: "正在核对并整理历史会话",
                current: nil,
                total: nil
            )
        case .capturingOrigins:
            update = .presentation(
                status: "正在记录历史会话最初来源",
                current: nil,
                total: nil
            )
        case let .progress(current, total):
            update = .presentation(
                status: "正在整理历史会话 \(current)/\(total)",
                current: current,
                total: total
            )
        case .relaunching:
            update = .presentation(
                status: "历史会话已整理，正在重新打开Codex",
                current: nil,
                total: nil
            )
        }
        delegate?.historyMutationDidUpdate(update)
    }

    private func publish(_ event: V011HistoryRestoreEvent) {
        switch event {
        case .restoring:
            delegate?.historyMutationDidUpdate(
                .presentation(
                    status: "正在恢复上次历史会话操作",
                    current: nil,
                    total: nil
                )
            )
        case let .completedStateObserved(pointer, pending):
            delegate?.historyMutationDidUpdate(
                .restoreCompletedState(
                    pointer: pointer,
                    pending: pending
                )
            )
        case let .failed(message):
            delegate?.historyMutationDidUpdate(
                .restoreFailed(message)
            )
        }
    }
}
