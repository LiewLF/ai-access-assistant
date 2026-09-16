import Foundation

/// Keeps native account observations current after the user first reads resources.
/// CPA already owns its own maintenance loop; failed reads wait for manual recovery.
enum V013OfficialUsageSampling {
    static func isDue(
        snapshot: V011OfficialUsageSnapshot?,
        canRefresh: Bool,
        collectingCPA: Bool,
        failedAt: Date?,
        now: Date
    ) -> Bool {
        guard canRefresh, !collectingCPA, failedAt == nil,
              let snapshot, snapshot.accountScopeSHA256 != nil else { return false }
        return now.timeIntervalSince(snapshot.observedAt) >= 60
    }
}
