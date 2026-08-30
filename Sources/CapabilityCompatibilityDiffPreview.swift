// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum CapabilityCompatibilityDiffChange:
    String, Codable, Equatable, Sendable {
    case unchanged
    case improved
    case regressed
    case changed

    var title: String {
        switch self {
        case .unchanged:
            return "未变化"
        case .improved:
            return "变好"
        case .regressed:
            return "需注意"
        case .changed:
            return "有变化"
        }
    }
}

enum CapabilityCompatibilityDiffBlocker: Error, Equatable, Sendable {
    case duplicateBefore(CapabilityCompatibilityKind)
    case duplicateAfter(CapabilityCompatibilityKind)
    case missingBefore(CapabilityCompatibilityKind)
    case missingAfter(CapabilityCompatibilityKind)

    var message: String {
        switch self {
        case .duplicateBefore(let kind):
            return "升级前基线包含重复的\(kind.rawValue)结论，无法安全比较。"
        case .duplicateAfter(let kind):
            return "升级后结果包含重复的\(kind.rawValue)结论，无法安全比较。"
        case .missingBefore(let kind):
            return "升级前基线缺少\(kind.rawValue)结论，无法安全比较。"
        case .missingAfter(let kind):
            return "升级后结果缺少\(kind.rawValue)结论，无法安全比较。"
        }
    }
}

struct CapabilityCompatibilityDiffItem:
    Identifiable, Equatable, Sendable {
    var id: String { kind.stableID }

    let kind: CapabilityCompatibilityKind
    let change: CapabilityCompatibilityDiffChange
    let before: CapabilityCompatibilityEvidenceItem
    let after: CapabilityCompatibilityEvidenceItem
}

struct CapabilityCompatibilityDiffPreview: Equatable, Sendable {
    let beforeGeneratedAt: Date
    let afterGeneratedAt: Date
    let items: [CapabilityCompatibilityDiffItem]
    let sideEffects: CapabilityCompatibilitySideEffects

    var improvedCount: Int { count(.improved) }
    var regressedCount: Int { count(.regressed) }
    var changedCount: Int { count(.changed) }
    var unchangedCount: Int { count(.unchanged) }

    var summary: String {
        "变好\(improvedCount)项 · 需注意\(regressedCount)项 · "
            + "其他变化\(changedCount)项 · 未变化\(unchangedCount)项"
    }

    private func count(
        _ change: CapabilityCompatibilityDiffChange
    ) -> Int {
        items.filter { $0.change == change }.count
    }
}

enum CapabilityCompatibilityDiffResult: Equatable, Sendable {
    case ready(CapabilityCompatibilityDiffPreview)
    case blocked(CapabilityCompatibilityDiffBlocker)
}

enum CapabilityCompatibilityDiffEvaluator {
    static func compare(
        before: CapabilityCompatibilityReport,
        after: CapabilityCompatibilityReport
    ) -> CapabilityCompatibilityDiffResult {
        let beforeIndex: [String:
            CapabilityCompatibilityEvidenceItem]
        switch index(before.items, phase: .before) {
        case .success(let value):
            beforeIndex = value
        case .failure(let blocker):
            return .blocked(blocker)
        }

        let afterIndex: [String:
            CapabilityCompatibilityEvidenceItem]
        switch index(after.items, phase: .after) {
        case .success(let value):
            afterIndex = value
        case .failure(let blocker):
            return .blocked(blocker)
        }

        var items: [CapabilityCompatibilityDiffItem] = []
        for kind in CapabilityCompatibilityKind.allCases {
            guard let beforeItem = beforeIndex[kind.stableID] else {
                return .blocked(.missingBefore(kind))
            }
            guard let afterItem = afterIndex[kind.stableID] else {
                return .blocked(.missingAfter(kind))
            }
            items.append(
                CapabilityCompatibilityDiffItem(
                    kind: kind,
                    change: classify(
                        before: beforeItem,
                        after: afterItem
                    ),
                    before: beforeItem,
                    after: afterItem
                )
            )
        }
        return .ready(
            CapabilityCompatibilityDiffPreview(
                beforeGeneratedAt: before.generatedAt,
                afterGeneratedAt: after.generatedAt,
                items: items,
                sideEffects: .none
            )
        )
    }

    private enum Phase {
        case before
        case after
    }

    private static func index(
        _ items: [CapabilityCompatibilityEvidenceItem],
        phase: Phase
    ) -> Result<
        [String:
            CapabilityCompatibilityEvidenceItem],
        CapabilityCompatibilityDiffBlocker
    > {
        var result: [String:
            CapabilityCompatibilityEvidenceItem] = [:]
        for item in items {
            guard result[item.kind.stableID] == nil else {
                return .failure(
                    phase == .before
                        ? .duplicateBefore(item.kind)
                        : .duplicateAfter(item.kind)
                )
            }
            result[item.kind.stableID] = item
        }
        return .success(result)
    }

    private static func classify(
        before: CapabilityCompatibilityEvidenceItem,
        after: CapabilityCompatibilityEvidenceItem
    ) -> CapabilityCompatibilityDiffChange {
        if sameEvidenceIgnoringObservationTime(before, after) {
            return .unchanged
        }

        if before.verdict != .compatible,
           after.verdict == .compatible {
            return .improved
        }
        if before.verdict == .compatible,
           after.verdict != .compatible {
            return .regressed
        }
        if before.verdict == .blocked,
           after.verdict != .blocked {
            return .improved
        }
        if before.verdict != .blocked,
           after.verdict == .blocked {
            return .regressed
        }
        guard before.verdict == after.verdict else {
            return .changed
        }

        let beforeFreshness = freshnessScore(before.freshness)
        let afterFreshness = freshnessScore(after.freshness)
        if afterFreshness > beforeFreshness {
            return .improved
        }
        if afterFreshness < beforeFreshness {
            return .regressed
        }
        return .changed
    }

    private static func sameEvidenceIgnoringObservationTime(
        _ before: CapabilityCompatibilityEvidenceItem,
        _ after: CapabilityCompatibilityEvidenceItem
    ) -> Bool {
        before.kind == after.kind
            && before.verdict == after.verdict
            && before.source == after.source
            && before.freshness == after.freshness
            && before.detail == after.detail
    }

    private static func freshnessScore(
        _ freshness: CapabilityCompatibilityFreshness
    ) -> Int {
        switch freshness {
        case .fresh, .versionBound:
            return 2
        case .stale:
            return 1
        case .unknown:
            return 0
        }
    }
}
