// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// LTP-130: the live switch path proves the specified-model probe only. The
/// `/models` directory is a separate discovery, so an all-passed probe record
/// on that path would manufacture a model-list pass. Keeping the narrower
/// record here also keeps it out of the large legacy
/// `RelayDirectorySecurity.swift`; the existing `load`/`save` writer is
/// reused and no new writer is introduced.
extension RelayProbeScheduleStore {
    @discardableResult
    func recordSpecifiedModelProbeSuccess(
        entryID: String,
        completedAt: Date = Date()
    ) throws -> Bool {
        guard let schedule = try load(),
              let task = schedule.tasks.first(
                  where: { $0.entryID == entryID }
              ) else {
            return false
        }
        // A task already in its six-hour failure retry carries at least one
        // unresolved dimension that this narrow probe never retested. The
        // generic recorder would read the all-`unverified` result as
        // recovery, clear the failure count and move the retry to the
        // 24-hour partial interval. Keep that failure evidence and the
        // existing retry deadline; only the attempt time is refreshed. A
        // task without unresolved failures still records normally below.
        if task.consecutiveFailures > 0 {
            let tasks = schedule.tasks.map { candidate in
                guard candidate.entryID == task.entryID,
                      candidate.verifierTaskID == task.verifierTaskID else {
                    return candidate
                }
                return ScheduledRelayProbe(
                    id: candidate.id,
                    entryID: candidate.entryID,
                    verifierTaskID: candidate.verifierTaskID,
                    nextDueAt: candidate.nextDueAt,
                    lastAttemptAt: completedAt,
                    consecutiveFailures: candidate.consecutiveFailures,
                    authenticatedVerificationPending:
                        candidate.authenticatedVerificationPending
                )
            }
            try save(
                RelayProbeScheduleState(
                    schemaVersion: schedule.schemaVersion,
                    generatedAt: completedAt,
                    tasks: tasks
                )
            )
            return true
        }
        let result = RelayProbeRunResult(
            entryID: entryID,
            verifierTaskID: task.verifierTaskID,
            completedAt: completedAt,
            documentation: .unverified,
            tls: .unverified,
            modelList: .unverified,
            minimalRequest: .passed,
            failureSummarySHA256: nil
        )
        try save(
            RelayProbeScheduler.recording(
                result,
                in: schedule
            )
        )
        return true
    }
}
