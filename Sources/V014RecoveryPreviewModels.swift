import Foundation

struct V014RecoveryRepairPreview: Equatable, Identifiable, Sendable {
    let fingerprint: String
    let switchCount: Int
    let adoptionCount: Int
    let deletionCount: Int
    let protectsNewSessions: Bool
    var operationImpacts: [V014RecoveryOperationImpact] = []

    var id: String { fingerprint }

    var totalCount: Int {
        switchCount + adoptionCount + deletionCount
    }

    var operationSummary: String {
        var parts: [String] = []
        if switchCount > 0 {
            parts.append("接入切换 \(switchCount) 项")
        }
        if adoptionCount > 0 {
            parts.append("中转接管 \(adoptionCount) 项")
        }
        if deletionCount > 0 {
            parts.append("中转删除 \(deletionCount) 项")
        }
        return parts.isEmpty
            ? "没有可修复的已有恢复点"
            : parts.joined(separator: "、")
    }
}

/// Safe object-level facts from journals, without paths, identifiers or values.
struct V014RecoveryOperationImpact: Equatable, Sendable {
    let title: String
    let direction: String
    let affected: [String]
    let preserved: String
    let limitation: String
}

enum V014RecoveryRepairError: LocalizedError, Equatable {
    case previewChanged

    var errorDescription: String? {
        switch self {
        case .previewChanged:
            return "修复预览已经变化；未执行任何修复，请重新读取后确认"
        }
    }
}

struct V014RecoveryFieldPreview: Equatable, Sendable {
    let fields: [String]
    let undisplayedFieldCount: Int
    let isAvailable: Bool

    static let unavailable = Self(fields: [], undisplayedFieldCount: 0, isAvailable: false)
}
