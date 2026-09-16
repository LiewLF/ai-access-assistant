import Foundation

/// Reuse Codex's own rollout and the existing reader before the probe sandbox is
/// removed. A JSON exec turn total alone cannot establish request pricing tiers.
enum V012VerifiedExecUsage {
    static func read(
        codexHome: URL,
        expected: V012CompletedTurnUsage
    ) -> V012CompletedTurnUsage? {
        let sessions = codexHome.appendingPathComponent("sessions")
        guard let files = FileManager.default.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var visited = 0
        for case let url as URL in files {
            visited += 1
            guard visited <= 128 else { return nil }
            guard url.pathExtension == "jsonl",
                  let properties = try? url.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey,
                  ]),
                  properties.isRegularFile == true,
                  properties.isSymbolicLink != true,
                  let result = try? V012RolloutUsageReader().read(
                    at: url, fallbackProviderID: expected.providerID
                  ),
                  !result.overflowed, !result.sourceChangedDuringRead,
                  result.turns.count == 1,
                  let turn = result.turns.first,
                  turn.inputTokens == expected.inputTokens,
                  turn.cachedInputTokens == expected.cachedInputTokens,
                  turn.outputTokens == expected.outputTokens,
                  turn.model == expected.model,
                  turn.providerID == expected.providerID else { continue }
            let calls = turn.calls.map { call in
                V012UpstreamTokenUsage(observedAt: call.observedAt,
                    inputTokens: call.inputTokens, cachedInputTokens: call.cachedInputTokens,
                    cacheWriteInputTokens: call.cacheWriteInputTokens
                        ?? (expected.cacheWriteInputTokens == 0 ? 0 : nil),
                    outputTokens: call.outputTokens,
                    reasoningOutputTokens: call.reasoningOutputTokens,
                    activeContextTokens: call.activeContextTokens,
                    rateLimit: call.rateLimit, creditBalance: call.creditBalance)
            }
            return V012CompletedTurnUsage(id: turn.id, startedAt: turn.startedAt,
                completedAt: turn.completedAt, durationMilliseconds: turn.durationMilliseconds,
                timeToFirstTokenMilliseconds: turn.timeToFirstTokenMilliseconds,
                model: turn.model, providerID: turn.providerID,
                serviceTier: turn.serviceTier ?? "unknown", calls: calls)
        }
        return nil
    }
}
