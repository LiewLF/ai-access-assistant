// SPDX-License-Identifier: AGPL-3.0-only

import Combine
import Foundation

@MainActor
final class V011HistoryModel:
    ObservableObject,
    V011HistoryListControllerDelegate,
    V011HistorySearchControllerDelegate,
    V011HistoryWorkspaceControllerDelegate,
    V011SessionVaultExportControllerDelegate,
    V011HistoryRecoveryRefreshControllerDelegate,
    V011HistoryRecoveryCleanupControllerDelegate,
    V011HistoryMutationControllerDelegate {
    enum Operation: Equatable {
        case repair
        case restore
        case externalImport
        case sessionVaultExport
    }

    @Published private(set) var rows: [V011SessionRow] = []
    @Published private(set) var total = 0
    @Published private(set) var visibleTotal: Int?
    @Published private(set) var hasMore = false
    @Published private(set) var isLoading = false
    @Published private(set) var searchRows: [V011SessionRow] = []
    @Published private(set) var searchQuery = ""
    @Published private(set) var searchTotal = 0
    @Published private(set) var searchHasMore = false
    @Published private(set) var isSearching = false
    @Published private(set) var searchStatus = "尚未搜索本地历史"
    @Published private(set) var searchError: String?
    @Published private(set) var workspaceRows: [V011WorkspaceRow] = []
    @Published private(set) var workspaceTotal = 0
    @Published private(set) var workspaceHasMore = false
    @Published private(set) var isLoadingWorkspaces = false
    @Published private(set) var workspaceStatus = "尚未读取工作区总览"
    @Published private(set) var workspaceError: String?
    @Published private(set) var favoriteWorkspacePaths: Set<String> = []
    @Published private(set) var workspaceLabels: [String: String] = [:]
    @Published private(set) var workspacePreferenceError: String?
    @Published private(set) var operation: Operation?
    @Published private(set) var progressCurrent = 0
    @Published private(set) var progressTotal = 0
    @Published private(set) var hasLastRecoveryPoint = false
    @Published private(set) var hasInterruptedOperation = false
    @Published private(set) var status = "尚未读取历史会话"
    @Published private(set) var errorMessage: String?
    @Published private(set) var externalImportPreview:
        V011ExternalSessionImportPreview?
    @Published private(set) var isInspectingExternalImport = false
    @Published private(set) var externalImportStatus =
        "尚未预检外部会话"
    @Published private(set) var externalImportError: String?
    @Published private(set) var sessionVaultStatus =
        "尚未导出会话保险箱"
    @Published private(set) var sessionVaultError: String?

    /// Build 65 single immutable recovery snapshot. Counts, pointer/journal
    /// state, operation state, warning visibility, next action and failure
    /// code all come from this one generation; the UI must not combine async
    /// flags to infer "unfinished".
    @Published private(set) var recovery: V011HistoryRecoverySnapshot

    private let dependencies: V011HistoryDependencies
    private lazy var listController = V011HistoryListController(
        dependencies: dependencies,
        ledgerRoot: ledgerRoot,
        delegate: self
    )
    private lazy var searchController = V011HistorySearchController(
        dependencies: dependencies,
        delegate: self
    )
    private lazy var workspaceController =
        V011HistoryWorkspaceController(
            dependencies: dependencies,
            delegate: self
        )
    private lazy var sessionVaultController =
        V011SessionVaultExportController(
            codexHome: dependencies.codexHome,
            delegate: self
        )
    private lazy var recoveryRefreshController =
        V011HistoryRecoveryRefreshController(
            dependencies: dependencies,
            recoveryRoot: recoveryRoot,
            delegate: self
        )
    private lazy var recoveryCleanupController =
        V011HistoryRecoveryCleanupController(
            delegate: self
        )
    private lazy var mutationController =
        V011HistoryMutationController(
            dependencies: dependencies,
            recoveryRoot: recoveryRoot,
            ledgerRoot: ledgerRoot,
            delegate: self
        )
    private var externalImportSourcePath: String?
    private var interruptedOperation:
        SessionCorePendingJournal?

    // Recovery reconciliation state (Build 65). Pointer/journal facts are
    // re-read before every restore; the snapshot is republished after every
    // durable change and after every count refresh.
    private var recoveryGeneration = 0
    private var historyIndexVersion = 1
    private var lastPointerRecord: V011HistoryRecoveryPointer?
    private var pointerReadFailed = false
    private var lastPending: SessionCorePendingJournal?
    private var journalIdentityMismatch = false
    private var journalCorruptOnDisk = false
    private var lastJournalState:
        Build65RecoveryJournalState = .absent
    private var lastJournalURL: URL?
    private var lastPointerHash: String?
    private var lastJournalHash: String?
    private var restoreAttempt = 0
    private var consecutiveRestoreFailures = 0
    private var restoreFailedOnce = false
    private var lastSuccessfulOperationID: String?
    private var recoveryObservationFailure:
        Build65HistoryRecoveryFailureCode?

    init(
        dependencies: V011HistoryDependencies = .live
    ) {
        let favorites = V011WorkspacePreferenceStore.load(
            at: dependencies.controlRoot
        )
        self.dependencies = dependencies
        self.favoriteWorkspacePaths = favorites.paths
        self.workspaceLabels = favorites.labels
        self.workspacePreferenceError = favorites.error
        self.recovery = V011HistoryRecoverySnapshot(
            generation: 0,
            totalCount: 0,
            visibleCount: 0,
            pointerState: .absent,
            journalState: .absent,
            operationState: .idle,
            warningVisibility: .hidden,
            nextAction: Build65RecoveryNextAction.none
        )
    }

    var isWorking: Bool {
        operation != nil || recoveryCleanupController.isRunning
    }
    var recentRows: [V011SessionRow] { V013UsageWindowHistoryReader.orderByRecentActivity(rows) }

    func readUsageWindowHistory(
        windowStart: Date
    ) async throws -> V013UsageWindowHistoryResult {
        let value = dependencies
        return try await V013UsageWindowHistoryReader().read(
            windowStart: windowStart
        ) { limit, offset in
            try await value.sessionCore.listAll(
                codexHome: value.codexHome,
                limit: limit,
                offset: offset,
                provider: nil
            )
        }
    }

    var recoveryNeedsAttention: Bool {
        switch recovery.warningVisibility {
        case .actionable, .blocking:
            return true
        case .hidden, .informational:
            break
        }
        switch recovery.operationState {
        case .running, .recoverable, .failed, .safeMode:
            return true
        case .idle, .completed:
            return false
        }
    }

    var orderedWorkspaceRows: [V011WorkspaceRow] {
        workspaceRows.sorted { lhs, rhs in
            let lhsFavorite = favoriteWorkspacePaths.contains(
                lhs.path
            )
            let rhsFavorite = favoriteWorkspacePaths.contains(
                rhs.path
            )
            if lhsFavorite != rhsFavorite {
                return lhsFavorite
            }
            let lhsDate = lhs.latestUpdatedAt ?? .distantPast
            let rhsDate = rhs.latestUpdatedAt ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.path < rhs.path
        }
    }

    func isWorkspaceFavorite(_ path: String) -> Bool {
        guard let normalized = V011WorkspacePreferenceStore
            .normalizedPath(path) else {
            return false
        }
        return favoriteWorkspacePaths.contains(normalized)
    }

    func workspaceLabel(for path: String) -> String? {
        guard let normalized = V011WorkspacePreferenceStore
            .normalizedPath(path) else {
            return nil
        }
        return workspaceLabels[normalized]
    }

    func clearWorkspacePreferenceError() {
        workspacePreferenceError = nil
    }

    func reloadWorkspacePreferences() {
        let favorites = V011WorkspacePreferenceStore.load(
            at: dependencies.controlRoot
        )
        favoriteWorkspacePaths = favorites.paths
        workspaceLabels = favorites.labels
        workspacePreferenceError = favorites.error
    }

    @discardableResult
    func setWorkspaceLabel(
        _ label: String?,
        for path: String
    ) -> Bool {
        guard let normalizedPath = V011WorkspacePreferenceStore
            .normalizedPath(path) else {
            workspacePreferenceError = "工作区路径无效，名称未保存"
            return false
        }
        guard favoriteWorkspacePaths.contains(normalizedPath) else {
            workspacePreferenceError = "请先收藏工作区，再设置名称"
            return false
        }
        let normalizedLabel: String?
        if let label,
           !label.trimmingCharacters(
               in: .whitespacesAndNewlines
           ).isEmpty {
            guard let valid = V011WorkspacePreferenceStore
                .normalizedLabel(label) else {
                workspacePreferenceError =
                    "工作区名称最多40个字符，且不能包含控制字符"
                return false
            }
            normalizedLabel = valid
        } else {
            normalizedLabel = nil
        }
        var candidateLabels = workspaceLabels
        if let normalizedLabel {
            candidateLabels[normalizedPath] = normalizedLabel
        } else {
            candidateLabels.removeValue(forKey: normalizedPath)
        }
        do {
            try V011WorkspacePreferenceStore.persist(
                favoriteWorkspacePaths,
                labels: candidateLabels,
                at: dependencies.controlRoot
            )
            workspaceLabels = candidateLabels
            workspacePreferenceError = nil
            return true
        } catch {
            workspacePreferenceError =
                "工作区名称未保存：\(error.localizedDescription)"
            return false
        }
    }

    func toggleWorkspaceFavorite(_ path: String) {
        guard let normalized = V011WorkspacePreferenceStore
            .normalizedPath(path) else {
            workspacePreferenceError = "工作区路径无效，收藏未保存"
            return
        }
        var candidate = favoriteWorkspacePaths
        var candidateLabels = workspaceLabels
        if candidate.contains(normalized) {
            candidate.remove(normalized)
            candidateLabels.removeValue(forKey: normalized)
        } else {
            guard candidate.count < 20 else {
                workspacePreferenceError = "最多收藏20个工作区"
                return
            }
            candidate.insert(normalized)
        }
        do {
            try V011WorkspacePreferenceStore.persist(
                candidate,
                labels: candidateLabels,
                at: dependencies.controlRoot
            )
            favoriteWorkspacePaths = candidate
            workspaceLabels = candidateLabels
            if !candidate.contains(normalized) {
                workspaceRows.removeAll {
                    $0.path == normalized && !$0.isIndexed
                }
            }
            workspacePreferenceError = nil
        } catch {
            workspacePreferenceError =
                "工作区收藏未保存：\(error.localizedDescription)"
        }
    }

    var hasCommittedExternalImportRecoveryPoint: Bool {
        lastPointerRecord?.kind == .externalImport
            && lastPointerRecord?.phase == .committed
            && recovery.pointerState == .committed
            && recovery.journalState == .materialized
            && recovery.operationState == .recoverable
            && recovery.nextAction == .restore
    }

    var canCleanupRecoveryRecord: Bool {
        (recovery.operationState == .completed
            && recovery.nextAction == .archiveStaleRecord)
            || hasCommittedExternalImportRecoveryPoint
    }

    var recoveryActionableText: String {
        if hasCommittedExternalImportRecoveryPoint {
            return "外部会话已导入。可恢复撤回本次导入，或整理恢复记录并保留导入结果。"
        }
        return "上次操作在完成前中断。恢复只会撤回那一次历史会话操作，不会影响操作前已有的会话。"
    }

    var recoveryInformationalText: String {
        if lastPointerRecord?.kind == .externalImport {
            return "外部会话已导入；恢复记录可在确认无误后整理。"
        }
        return recovery.nextAction == .archiveStaleRecord
            ? "会话已全部可见，但留有一条旧完成记录。当前使用不受影响。"
            : "上次历史会话操作已完成，\(recovery.visibleCount) 个会话均可见。"
    }

    /// Build 68 zero-write readiness + impact plan. This reads only current
    /// snapshot and filesystem metadata; existing repair/restore/cleanup
    /// methods remain the only writers.
    func makeRecoveryPlan(
        operation requestedOperation: B68RecoveryOperation
    ) throws -> B68RecoveryPlanBundle {
        try V011HistoryRecoveryPlanService.make(
            operation: requestedOperation,
            context: recoveryPlanContext
        )
    }

    func validateRecoveryPlan(
        _ plan: RecoveryOperationPlan
    ) -> B68RecoveryExecutionDecision {
        V011HistoryRecoveryPlanService.validate(
            plan,
            context: recoveryPlanContext
        )
    }

    private var recoveryPlanContext:
        V011HistoryRecoveryPlanContext {
        V011HistoryRecoveryPlanContext(
            snapshot: recovery,
            pointerKind: lastPointerRecord?.kind,
            provider: listController.currentProvider ?? "unknown",
            codexHome: dependencies.codexHome,
            controlRoot: dependencies.controlRoot,
            isWorking: isWorking
        )
    }

    func loadFirstPage(
        provider: String?,
        force: Bool = false
    ) {
        let normalized = Self.normalizedProvider(provider)
        listController.loadFirstPage(
            provider: normalized,
            force: force,
            isLoading: isLoading
        )
    }

    func loadMore() {
        guard hasMore,
              !isLoading else { return }
        listController.loadMore(
            offset: rows.count
        )
    }

    func loadWorkspaceOverview(force: Bool = false) {
        workspaceController.loadFirstPage(
            force: force,
            isLoading: isLoadingWorkspaces,
            favoritePaths: favoriteWorkspacePaths
        )
    }

    func loadMoreWorkspaces() {
        guard workspaceHasMore,
              !isLoadingWorkspaces else { return }
        workspaceController.loadMore(
            existingRows: workspaceRows
        )
    }

    func cancelWorkspaceListing() {
        workspaceController.cancel()
    }

    func searchMetadata(
        _ query: String,
        provider: String?
    ) {
        let normalizedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedQuery.isEmpty else {
            clearSearch()
            return
        }
        searchQuery = normalizedQuery
        searchController.searchMetadata(
            query: normalizedQuery,
            provider: Self.normalizedProvider(provider),
            recentRows: rows
        )
    }

    func searchWorkspace(
        _ path: String,
        provider: String?
    ) {
        let normalizedPath = path.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedPath.isEmpty else {
            clearSearch()
            return
        }
        searchQuery = normalizedPath
        searchController.searchWorkspace(
            path: normalizedPath,
            provider: Self.normalizedProvider(provider),
            recentRows: rows
        )
    }

    func loadMoreSearch() {
        guard searchHasMore,
              !isSearching,
              !searchQuery.isEmpty else { return }
        searchController.loadMore(
            offset: searchRows.count,
            existingRows: searchRows,
            recentRows: rows
        )
    }

    func clearSearch() {
        searchController.clear()
    }

    func historySearchDidClear() {
        isSearching = false
        searchRows = []
        searchQuery = ""
        searchTotal = 0
        searchHasMore = false
        searchStatus = "尚未搜索本地历史"
        searchError = nil
    }

    func preflightExternalSessionImport(
        at sourceRoot: URL
    ) async {
        guard !isInspectingExternalImport else { return }
        isInspectingExternalImport = true
        externalImportPreview = nil
        externalImportSourcePath = nil
        externalImportError = nil
        externalImportStatus = "正在只读核对外部会话"
        defer { isInspectingExternalImport = false }
        do {
            let result = try await
                V011ExternalSessionImportPreflightService(
                    dependencies: dependencies
                ).inspect(sourceRoot: sourceRoot)
            externalImportPreview = result.preview
            externalImportSourcePath =
                result.normalizedSourcePath
            externalImportStatus =
                "只读预检完成：候选 \(result.preview.importableSessionCount) 个，阻止 \(result.preview.issues.count) 个"
        } catch is CancellationError {
            externalImportSourcePath = nil
            externalImportStatus = "外部会话预检已取消"
        } catch {
            externalImportSourcePath = nil
            externalImportError = error.localizedDescription
            externalImportStatus = "外部会话预检未完成"
        }
    }

    func exportSessionVault(
        to destination: URL
    ) {
        guard operation == nil else { return }
        operation = .sessionVaultExport
        status = "正在导出会话保险箱"
        sessionVaultStatus = "正在复制并校验会话文件"
        sessionVaultError = nil
        errorMessage = nil
        sessionVaultController.export(to: destination)
    }

    func sessionVaultDidExport(
        _ summary: SessionVaultExportSummary
    ) {
        let size = ByteCountFormatter.string(
            fromByteCount: summary.totalBytes,
            countStyle: .file
        )
        sessionVaultStatus =
            "已导出 \(summary.fileCount) 个会话文件（活跃 \(summary.activeFileCount)，归档 \(summary.archivedFileCount)，\(size)）"
        status = "会话保险箱已导出并通过SHA-256校验"
        sessionVaultError = nil
    }

    func sessionVaultExportDidCancel() {
        sessionVaultStatus = "会话保险箱导出已取消"
    }

    func sessionVaultExportDidFail(_ error: Error) {
        sessionVaultStatus = "会话保险箱未导出"
        sessionVaultError = error.localizedDescription
    }

    func sessionVaultExportDidBecomeIdle() {
        operation = nil
        progressCurrent = 0
        progressTotal = 0
    }

    func importExternalSessions(
        at sourceRoot: URL
    ) {
        guard operation == nil else { return }
        guard !hasInterruptedOperation else {
            externalImportError =
                "请先恢复上次未完成的历史会话操作"
            return
        }
        let normalizedSource = sourceRoot
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard let preview = externalImportPreview,
              preview.readyForImport,
              externalImportSourcePath == normalizedSource.path else {
            externalImportError =
                "外部会话目录或预检结果已变化，请重新预检"
            return
        }

        operation = .externalImport
        progressCurrent = 0
        progressTotal = preview.importableSessionCount
        status = "正在准备导入外部会话"
        errorMessage = nil
        externalImportError = nil
        let provider = listController.currentProvider
        mutationController.importExternalSessions(
            sourceRoot: sourceRoot,
            normalizedSource: normalizedSource,
            expectedSessionCount:
                preview.importableSessionCount,
            provider: provider
        )
    }

    /// Leaving the page only cancels the read-only list process. A repair or
    /// rollback has transaction semantics and must finish or roll back.
    func cancelListing() {
        listController.cancel()
        isLoading = false
        clearSearch()
        if rows.isEmpty, !isWorking {
            status = "历史会话读取已暂停"
        }
    }

    /// Read-only reconciliation. Never archives or deletes live records here:
    /// archiving belongs to the user-confirmed restore transaction or the
    /// explicit "整理旧记录" cleanup action, both CAS-guarded.
    func refreshRecoveryAvailability() {
        recoveryRefreshController.refresh()
    }

    func historyRecoveryRefreshDidLoad(
        _ observation: V011HistoryRecoveryObservation
    ) {
        recoveryObservationFailure =
            applyRecoveryObservation(observation)
        publishRecovery()
    }

    func historyRecoveryRefreshDidFail(_ error: Error) {
        lastPending = nil
        journalIdentityMismatch = false
        journalCorruptOnDisk = true
        lastJournalState = .corrupt
        lastJournalURL = nil
        lastJournalHash = nil
        recoveryObservationFailure =
            error is SessionCoreClientError
            && (error as? SessionCoreClientError)
                == .invalidJournalRoot
            ? .journalCorrupt
            : .sessionCoreUnavailable
        errorMessage = error.localizedDescription
        publishRecovery()
    }

    @discardableResult
    private func applyRecoveryObservation(
        _ observation: V011HistoryRecoveryObservation
    ) -> Build65HistoryRecoveryFailureCode? {
        lastPointerRecord = observation.pointerRecord
        pointerReadFailed = observation.pointerReadFailed
        lastPending = observation.pending
        if observation.pointerReadFailed {
            journalIdentityMismatch = false
            journalCorruptOnDisk = false
            errorMessage = observation.pointerErrorMessage
            return .pointerUnreadable
        }
        applyJournalReconciliation(
            V011HistoryRecoveryReconciler.reconcileJournal(
                pointer: observation.pointerRecord,
                pending: observation.pending,
                recoveryRoot: recoveryRoot,
                currentJournalURL: lastJournalURL
            )
        )
        return nil
    }

    private func applyJournalReconciliation(
        _ state: V011HistoryJournalReconciliation
    ) {
        lastPending = state.pending
        journalIdentityMismatch = state.identityMismatch
        journalCorruptOnDisk = state.corruptOnDisk
        lastJournalState = state.state
        lastJournalURL = state.url
        lastJournalHash = state.hash
    }

    private func reconcileCompletedState(
        pointer: V011HistoryRecoveryPointer?,
        pending: SessionCorePendingJournal?
    ) {
        lastPointerRecord = pointer
        pointerReadFailed = false
        applyJournalReconciliation(
            V011HistoryRecoveryReconciler.reconcileJournal(
                pointer: pointer,
                pending: pending,
                recoveryRoot: recoveryRoot,
                currentJournalURL: lastJournalURL
            )
        )
    }

    /// "整理旧记录" accepts a completed external import or archives a stale
    /// completed repair: CAS-archive the exact pointer and its journal
    /// directory. Both stay recoverable in Archive; no session body is
    /// touched.
    func cleanupStaleRecoveryRecord() {
        guard canCleanupRecoveryRecord,
              !recoveryCleanupController.isRunning else {
            return
        }
        guard let expectedPointer = lastPointerRecord,
              let expectedPointerHash = lastPointerHash else {
            errorMessage = "恢复记录缺少完整指纹，已停止整理。"
            publishRecovery()
            return
        }
        recoveryCleanupController.cleanup(
            V011HistoryRecoveryCleanupRequest(
                pointerURL: recoveryPointerURL,
                pointer: expectedPointer,
                expectedPointerHash: expectedPointerHash,
                journal: lastJournalURL,
                expectedJournalHash: lastJournalHash
            )
        )
    }

    func historyRecoveryCleanupDidArchive() {
        lastPointerRecord = nil
        pointerReadFailed = false
        lastPointerHash = nil
        lastJournalState = .absent
        lastJournalURL = nil
        lastJournalHash = nil
        errorMessage = nil
        publishRecovery()
    }

    func historyRecoveryCleanupDidFail(_ message: String) {
        errorMessage = message
        refreshRecoveryAvailability()
        publishRecovery()
    }

    private func publishRecovery() {
        let projection = V011HistoryRecoveryReconciler.project(
            V011HistoryRecoveryProjectionInput(
                currentGeneration: recoveryGeneration,
                totalCount: total,
                visibleCount: visibleTotal,
                indexVersion: historyIndexVersion,
                pointerRecord: lastPointerRecord,
                pointerReadFailed: pointerReadFailed,
                pending: lastPending,
                journalIdentityMismatch:
                    journalIdentityMismatch,
                journalCorruptOnDisk: journalCorruptOnDisk,
                journalState: lastJournalState,
                journalHash: lastJournalHash,
                restoreAttempt: restoreAttempt,
                consecutiveRestoreFailures:
                    consecutiveRestoreFailures,
                restoreFailedOnce: restoreFailedOnce,
                lastSuccessfulOperationID:
                    lastSuccessfulOperationID,
                observationFailure:
                    recoveryObservationFailure
            ),
            pointerURL: recoveryPointerURL
        )
        recoveryGeneration = projection.generation
        lastPointerHash = projection.pointerHash
        recovery = projection.snapshot
        hasInterruptedOperation =
            projection.hasInterruptedOperation
        hasLastRecoveryPoint = projection.hasLastRecoveryPoint
    }

    func repairToCurrentMode(provider: String?) {
        guard operation == nil else { return }
        guard !hasInterruptedOperation else {
            errorMessage = "请先恢复上次未完成的历史会话操作"
            return
        }
        guard let target = Self.normalizedProvider(provider) else {
            errorMessage = "还在确认当前模式，请稍后再试"
            return
        }

        operation = .repair
        progressCurrent = 0
        progressTotal = 0
        status = "正在准备找回历史会话"
        errorMessage = nil
        mutationController.repair(provider: target)
    }

    /// Single-flight, idempotent, CAS-guarded restore. Order is fixed:
    /// single-flight check -> operation key -> re-read pointer/journal ->
    /// reconcile -> SessionCore only when provably actionable -> durable
    /// result -> CAS archive pointer -> re-read -> recount -> publish -> only
    /// then clear the warning. Never auto-retries corrupt/mismatch records.
    func restoreLastOperation() {
        guard operation == nil else { return }
        let snapshot = recovery
        guard snapshot.operationState == .recoverable
                || (snapshot.operationState == .failed
                    && consecutiveRestoreFailures < 2),
              let operationKey = snapshot.operationKey,
              !operationKey.isEmpty else {
            if snapshot.operationState == .safeMode
                || (snapshot.operationState == .failed
                    && consecutiveRestoreFailures >= 2) {
                // Read-only safe mode: keep the existing diagnostic message,
                // do not re-enter SessionCore and do not loop.
                status = "恢复记录无法安全核对。助手已停止自动重试，当前会话保持不变。"
                return
            }
            if snapshot.operationState != .running {
                errorMessage = "没有可恢复的历史会话操作"
            }
            return
        }
        guard !mutationController.restoreInFlight else {
            return
        }
        restoreAttempt += 1
        operation = .restore
        progressCurrent = 0
        progressTotal = 0
        status = "正在核对恢复记录…"
        errorMessage = nil
        let provider = listController.currentProvider
        mutationController.restore(
            snapshot: snapshot,
            visibleTotal: visibleTotal,
            total: total,
            operationKey: operationKey,
            provider: provider
        )
    }

    func historyMutationDidUpdate(
        _ update: V011HistoryMutationUpdate
    ) {
        switch update {
        case let .presentation(status, current, total):
            self.status = status
            if let current {
                progressCurrent = current
            }
            if let total {
                progressTotal = total
            }
        case let .restoreCompletedState(pointer, pending):
            reconcileCompletedState(
                pointer: pointer,
                pending: pending
            )
        case let .restoreFailed(message):
            consecutiveRestoreFailures += 1
            restoreFailedOnce = true
            status = "恢复尚未完成"
            errorMessage = message
            operation = nil
            publishRecovery()
        }
    }

    func historyMutationDidComplete(
        _ completion: V011HistoryMutationCompletion
    ) async {
        switch completion {
        case let .externalImport(outcome, provider):
            await applyExternalImportCompletion(
                outcome,
                provider: provider
            )
        case let .repair(outcome, provider):
            await applyRepairCompletion(
                outcome,
                provider: provider
            )
        case let .restore(outcome, operationKey, provider):
            await applyRestoreCompletion(
                outcome,
                operationKey: operationKey,
                provider: provider
            )
        }
    }

    private func applyExternalImportCompletion(
        _ outcome: V011ExternalSessionImportOutcome,
        provider: String?
    ) async {
        switch outcome {
        case let .success(summary):
            externalImportPreview = nil
            externalImportSourcePath = nil
            externalImportStatus =
                "已导入 \(summary.importedSessions) 个外部会话"
            status = externalImportStatus
            errorMessage = nil
            externalImportError = nil
            interruptedOperation = nil
            lastSuccessfulOperationID = summary.transactionID
            consecutiveRestoreFailures = 0
            restoreFailedOnce = false
            operation = nil
            progressCurrent = 0
            progressTotal = 0
            _ = await refreshRecoveryAndRecount(
                provider: provider
            )
        case let .failure(failure):
            status = failure.recoveryMessage == nil
                ? "导入未完成，已恢复原状态"
                : "导入未完成，需要继续恢复"
            externalImportError = [
                failure.primaryMessage,
                failure.recoveryMessage,
            ]
            .compactMap { $0 }
            .joined(separator: "；")
            errorMessage = externalImportError
            operation = nil
            progressCurrent = 0
            progressTotal = 0
            refreshRecoveryAvailability()
        }
    }

    private func applyRepairCompletion(
        _ outcome: V011HistoryRepairOutcome,
        provider: String
    ) async {
        switch outcome {
        case let .success(summary):
            status = summary.noChanges
                ? "全部历史会话已经可见"
                : "已让全部历史会话在当前模式可见"
            errorMessage = nil
            interruptedOperation = nil
            progressCurrent = 0
            progressTotal = 0
            _ = await refreshRecoveryAndRecount(
                provider: provider
            )
            operation = nil
        case let .failure(failure):
            status = failure.recoveryMessage == nil
                ? "操作未完成，已恢复原状态"
                : "操作未完成，需要继续恢复"
            errorMessage = [
                failure.primaryMessage,
                failure.recoveryMessage,
            ]
            .compactMap { $0 }
            .joined(separator: "；")
            operation = nil
            progressCurrent = 0
            progressTotal = 0
            refreshRecoveryAvailability()
        }
    }

    private func applyRestoreCompletion(
        _ outcome: V011HistoryRestoreOutcome,
        operationKey: String,
        provider: String?
    ) async {
        switch outcome {
        case .completedWithoutRollback:
            // Pointer was archived; next publish must not reuse stale state.
            lastPointerRecord = nil
            lastPointerHash = nil
            lastSuccessfulOperationID = operationKey
            consecutiveRestoreFailures = 0
            restoreFailedOnce = false
            status = "上次历史会话操作已完成"
            errorMessage = nil
            operation = nil
            _ = await refreshRecoveryAndRecount(
                provider: provider
            )
        case .restored:
            interruptedOperation = nil
            lastSuccessfulOperationID = operationKey
            consecutiveRestoreFailures = 0
            restoreFailedOnce = false
            status = "已恢复上次历史会话操作"
            errorMessage = nil
            operation = nil
            _ = await refreshRecoveryAndRecount(
                provider: provider
            )
        case .failed:
            refreshRecoveryAvailability()
        }
    }

    func continuationPacket(
        for session: V011SessionRow
    ) async throws -> SessionContinuationPacket {
        try await V011HistoryContinuationService(
            codexHome: dependencies.codexHome
        )
            .packet(
                rolloutPath: session.rolloutPath,
                threadID: session.id
            )
    }

    /// Durable recovery completion path: invalidate stale observations,
    /// reconcile once, recount once, then publish one coherent snapshot.
    private func refreshRecoveryAndRecount(
        provider: String?
    ) async -> Bool {
        let token = recoveryRefreshController
            .beginExclusiveRefresh()
        do {
            guard let observation = try await
                recoveryRefreshController.read(for: token) else {
                return false
            }
            recoveryObservationFailure = applyRecoveryObservation(
                observation
            )
        } catch is CancellationError {
            return false
        } catch {
            guard recoveryRefreshController.isCurrent(token) else {
                return false
            }
            recoveryObservationFailure =
                error is SessionCoreClientError
                && (error as? SessionCoreClientError)
                    == .invalidJournalRoot
                ? .journalCorrupt
                : .sessionCoreUnavailable
            lastPending = nil
            journalIdentityMismatch = false
            journalCorruptOnDisk = true
            lastJournalState = .corrupt
            lastJournalURL = nil
            lastJournalHash = nil
            errorMessage = error.localizedDescription
        }
        guard recoveryRefreshController.isCurrent(token) else {
            return false
        }
        let task = listController.recount(provider: provider)
        await task.value
        guard recoveryRefreshController.isCurrent(token) else {
            return false
        }
        guard listController.lastError == nil,
              visibleTotal != nil else {
            errorMessage = "历史会话数量暂时无法刷新，原恢复提示保留。"
            return false
        }
        publishRecovery()
        return true
    }

    func historyListWillLoad(
        offset: Int,
        replacing: Bool
    ) {
        isLoading = true
        status = offset == 0
            ? "正在读取首批50个历史会话"
            : "正在读取更多历史会话"
        errorMessage = nil
        if replacing {
            rows = []
            total = 0
            visibleTotal = nil
            hasMore = false
        }
    }

    func historyListDidLoad(
        page: SessionCoreSessionPage,
        ledger: V011SessionOriginLedgerPayload,
        ledgerWarning: String?,
        replacing: Bool,
        publishRecoveryAtEnd: Bool
    ) {
        let newRows = page.sessions.map {
            V011SessionRow(
                session: $0,
                origin: ledger.records[$0.id]
            )
        }
        if replacing {
            rows = V015BoundedPageMerger.replacing(
                newRows,
                limit: V015PerformanceBudgetCatalog
                    .maximumVisibleHistoryRows
            )
        } else {
            rows = V015BoundedPageMerger.appending(
                existing: rows,
                incoming: newRows,
                limit: V015PerformanceBudgetCatalog
                    .maximumVisibleHistoryRows,
                id: \.id
            )
        }
        total = page.total
        visibleTotal = page.visibleTotal
        hasMore = page.hasMore
            && rows.count
                < V015PerformanceBudgetCatalog
                    .maximumVisibleHistoryRows
        status = "共\(page.total)个会话"
            + (
                page.visibleTotal.map {
                    "，当前可见\($0)个"
                } ?? ""
            )
        errorMessage = ledgerWarning
        historyIndexVersion += 1
        if publishRecoveryAtEnd {
            publishRecovery()
        }
    }

    func historyListDidCancel() {
        if rows.isEmpty {
            status = "历史会话读取已暂停"
        }
    }

    func historyListDidFail(_ error: Error) {
        status = "历史会话读取未完成"
        errorMessage = error.localizedDescription
    }

    func historyListDidBecomeIdle() {
        isLoading = false
    }

    func historySearchDidBegin(
        offset: Int,
        replacing: Bool
    ) {
        isSearching = true
        searchError = nil
        searchStatus = offset == 0
            ? "正在检索本地会话元数据"
            : "正在读取更多检索结果"
        if replacing {
            searchRows = []
            searchTotal = 0
            searchHasMore = false
        }
    }

    func historySearchDidLoad(
        rows: [V011SessionRow],
        total: Int,
        hasMore: Bool,
        workspaceScoped: Bool
    ) {
        searchRows = rows
        searchTotal = total
        searchHasMore = hasMore
        if workspaceScoped {
            searchStatus = total == 0
                ? "此工作区没有本地会话"
                : "此工作区共\(total)个本地会话"
        } else {
            searchStatus = total == 0
                ? "没有匹配的本地会话"
                : "找到\(total)个本地会话"
        }
    }

    func historySearchDidFail(_ error: Error) {
        searchStatus = "本地历史检索未完成"
        searchError = error.localizedDescription
    }

    func historySearchDidBecomeIdle() {
        isSearching = false
    }

    func historyWorkspaceDidBegin(
        offset: Int,
        replacing: Bool
    ) {
        isLoadingWorkspaces = true
        workspaceError = nil
        workspaceStatus = offset == 0
            ? "正在读取工作区总览"
            : "正在读取更多工作区"
        if replacing {
            workspaceRows = []
            workspaceTotal = 0
            workspaceHasMore = false
        }
    }

    func historyWorkspaceDidLoad(
        rows: [V011WorkspaceRow],
        total: Int,
        hasMore: Bool,
        favoriteLookupError: Error?
    ) {
        workspaceRows = rows
        workspaceTotal = total
        workspaceHasMore = hasMore
        workspaceError = favoriteLookupError.map {
            "收藏工作区详情暂未读取："
                + $0.localizedDescription
        }
        workspaceStatus = total == 0
            ? "本地历史没有工作目录元数据"
            : "共\(total)个工作区"
    }

    func historyWorkspaceDidFail(_ error: Error) {
        workspaceStatus = "工作区总览读取未完成"
        workspaceError = error.localizedDescription
    }

    func historyWorkspaceDidBecomeIdle() {
        isLoadingWorkspaces = false
    }

    func historyWorkspaceDidCancel() {
        isLoadingWorkspaces = false
        if workspaceRows.isEmpty {
            workspaceStatus = "工作区总览读取已暂停"
        }
    }

    private var recoveryRoot: URL {
        dependencies.controlRoot
            .appendingPathComponent(
                "SessionCoreRecovery",
                isDirectory: true
            )
    }

    private var recoveryPointerURL: URL {
        recoveryRoot.appendingPathComponent(
            "last-repair.json"
        )
    }

    private var ledgerRoot: URL {
        dependencies.controlRoot
            .appendingPathComponent(
                "SessionOriginLedger",
                isDirectory: true
            )
    }

    nonisolated private static func normalizedProvider(
        _ provider: String?
    ) -> String? {
        let trimmed = provider?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

}
