import Foundation

/// Pricing identity returned for one completed, dedicated exec thread. It is
/// separate from requested/rollout settings and never changes their history.
struct V012OfficialRequestPricingEvidence: Codable, Equatable, Sendable {
    let threadIDHash: String
    let accountScopeSHA256: String
    let observedAt: Date
    let model: String
    let serviceTier: String
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64

    func matches(_ turn: V012CompletedTurnUsage) -> Bool {
        turn.providerID.caseInsensitiveCompare("openai") == .orderedSame
            && threadIDHash == turn.sourceThreadIDHash
            && threadIDHash.count == 64
            && threadIDHash.allSatisfy { $0.isHexDigit && !$0.isUppercase }
            && accountScopeSHA256.count == 64
            && accountScopeSHA256.allSatisfy { $0.isHexDigit && !$0.isUppercase }
            && observedAt >= turn.completedAt
            && inputTokens == turn.inputTokens
            && cachedInputTokens == turn.cachedInputTokens
            && outputTokens == turn.outputTokens
            && V012ModelTokenRate.safeText(model, maximumBytes: 128)
            && model != "unknown"
            && V013OfficialPricingSnapshot.normalizedTier(serviceTier) != nil
    }
}

enum V012OfficialUsageCollection {
    static func enrich(
        _ turn: V012CompletedTurnUsage,
        snapshot: V011OfficialUsageSnapshot?
    ) -> V012CompletedTurnUsage {
        guard let snapshot, snapshot.isStructurallyValid,
              let scope = snapshot.accountScopeSHA256,
              let thread = snapshot.tokenUsage?.threadUsage,
              let hash = thread.sourceThreadIDHash,
              hash == turn.sourceThreadIDHash,
              thread.groups.count == 1,
              let group = thread.groups.first,
              let model = group.model,
              let tier = V013OfficialPricingSnapshot.normalizedTier(group.speed),
              let input = group.inputTokens,
              let cached = group.cachedInputTokens,
              let output = group.outputTokens,
              group.totalTokens == turn.modelProcessedTokens else { return turn }
        let evidence = V012OfficialRequestPricingEvidence(
            threadIDHash: hash, accountScopeSHA256: scope, observedAt: snapshot.observedAt,
            model: model, serviceTier: tier,
            inputTokens: input, cachedInputTokens: cached, outputTokens: output)
        guard evidence.matches(turn) else { return turn }
        var result = turn
        result.officialRequestPricing = evidence
        return result
    }

    /// A reread of the rollout must not discard matching evidence already
    /// collected from the official thread endpoint or the exec result.
    static func retainingEvidence(
        _ scanned: V012CompletedTurnUsage, _ saved: V012CompletedTurnUsage
    ) -> V012CompletedTurnUsage {
        guard scanned.id == saved.id, scanned.model == saved.model,
              scanned.providerID == saved.providerID,
              abs(scanned.completedAt.timeIntervalSince(saved.completedAt)) <= 1,
              scanned.inputTokens == saved.inputTokens,
              scanned.cachedInputTokens == saved.cachedInputTokens,
              scanned.outputTokens == saved.outputTokens else { return scanned }
        var result = scanned
        result.sourceThreadIDHash = result.sourceThreadIDHash ?? saved.sourceThreadIDHash
        result.sourceThreadID = result.sourceThreadID ?? saved.sourceThreadID
        result.officialRequestPricing = result.officialRequestPricing ?? saved.officialRequestPricing
        if result.officialRequestPricing?.matches(result) == false {
            result.officialRequestPricing = nil
        }
        return result
    }

    static func hydrate(_ record: inout V013UsageLedgerRecord, from turn: V012CompletedTurnUsage) {
        guard record.id == turn.id, record.model == turn.model,
              record.providerID == turn.providerID,
              record.inputTokens == turn.inputTokens,
              record.cachedInputTokens == turn.cachedInputTokens,
              record.outputTokens == turn.outputTokens,
              abs(record.completedAt.timeIntervalSince(turn.completedAt)) <= 1,
              turn.officialRequestPricing.map({
                  !record.identityBoundAtCompletion || $0.accountScopeSHA256 == record.accountScopeSHA256
              }) != false else { return }
        record.completedUsage = record.completedUsage.map {
            retainingEvidence($0, turn)
        } ?? turn
    }
}

extension V012CompletedTurnUsage {
    var pricingModel: String {
        guard let evidence = officialRequestPricing, evidence.matches(self) else { return model }
        return evidence.model
    }

    var pricingServiceTier: String? {
        guard let evidence = officialRequestPricing, evidence.matches(self) else { return serviceTier }
        return evidence.serviceTier
    }
}
