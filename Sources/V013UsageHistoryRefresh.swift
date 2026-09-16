// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Combine

/// Keeps the history fetch and usage scan in one refresh lifecycle.
@MainActor
final class V013UsageHistoryRefresh: ObservableObject {
    @Published private(set) var isLoadingHistory = false
    private var task: Task<Void, Never>?
    private var sourceSnapshot: V011OfficialUsageSnapshot?
    private let now: () -> Date

    init(now: @escaping () -> Date = { Date() }) { self.now = now }

    func refresh(
        model: V012UsageTruthModel, recentRows: [V011SessionRow],
        snapshot: V011OfficialUsageSnapshot?, profiles: [CodexRelayProfile],
        readHistory: @escaping (Date) async throws -> V013UsageWindowHistoryResult
    ) {
        task?.cancel()
        model.cancelRefresh()
        guard let reset = snapshot?.windows.first(where: {
            $0.durationMinutes == 10_080
        })?.resetsAt else {
            isLoadingHistory = false
            sourceSnapshot = nil
            model.refresh(rows: [], historyCoverage: .loading,
                officialSnapshot: snapshot, profiles: profiles)
            model.refresh(rows: recentRows, historyCoverage: .unknown,
                officialSnapshot: snapshot, profiles: profiles)
            return
        }
        let retain = model.usagePresentation?.local != nil
            && Self.canRetain(previous: sourceSnapshot, next: snapshot, now: now())
        if !retain {
            model.refresh(rows: [], historyCoverage: .loading,
                officialSnapshot: snapshot, profiles: profiles)
        }
        isLoadingHistory = true
        task = Task { [weak self] in
            do {
                let result = try await readHistory(reset.addingTimeInterval(-604_800))
                guard let self, !Task.isCancelled else { return }
                self.isLoadingHistory = false
                self.sourceSnapshot = snapshot
                model.refresh(rows: result.rows, historyCoverage: result.coverage,
                    officialSnapshot: snapshot, profiles: profiles)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isLoadingHistory = false
                self.sourceSnapshot = nil
                model.historyReadFailed(officialSnapshot: snapshot)
            }
        }
    }

    func cancel(model: V012UsageTruthModel) {
        task?.cancel()
        task = nil
        isLoadingHistory = false
        model.cancelRefresh()
    }

    static func canRetain(previous: V011OfficialUsageSnapshot?,
                          next: V011OfficialUsageSnapshot?, now: Date) -> Bool {
        guard let previous, let next, previous.isFresh(at: now), next.isFresh(at: now),
              let account = previous.accountScopeSHA256,
              next.accountScopeSHA256 == account,
              previous.planType == next.planType,
              next.observedAt >= previous.observedAt,
              let reset = previous.windows.first(where: {
                  $0.durationMinutes == 10_080
              })?.resetsAt,
              reset > now,
              next.windows.first(where: { $0.durationMinutes == 10_080 })?.resetsAt == reset
        else { return false }
        return true
    }
}

extension V013UsagePresentation {
    static func readFailure(previous: Self?) -> Self {
        .init(strict: .init(estimate: nil,
            reason: "本机请求读取失败；请刷新官方资源重试",
            observationCount: previous?.strict.observationCount ?? 0,
            percentageTransitionCount: previous?.strict.percentageTransitionCount ?? 0,
            usableIntervalSampleCount: 0,
            officialUsedPercent: previous?.strict.officialUsedPercent,
            supplemental: .empty), local: previous?.local, apiReference: nil)
    }
}
