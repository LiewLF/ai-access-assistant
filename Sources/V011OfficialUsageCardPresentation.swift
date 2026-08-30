import Foundation

struct V011OfficialUsageCardPresentation: Equatable, Sendable {
    let isFresh: Bool
    let freshnessText: String?
    let planText: String
    let weeklyUsageText: String
    let resetText: String

    static func make(
        snapshot: V011OfficialUsageSnapshot?,
        now: Date
    ) -> Self {
        guard let snapshot else {
            return Self(
                isFresh: false,
                freshnessText: nil,
                planText: "未读取",
                weeklyUsageText: "未读取",
                resetText: "未读取"
            )
        }
        let fresh = snapshot.isFresh(at: now)
        let prefix = fresh ? "刚刚读取" : "上次读取，已过期"
        let weekly = snapshot.windows.first {
            $0.durationMinutes == 10_080
        }
        let weeklyValue = weekly.map {
            "\($0.usedPercent)% / \($0.remainingPercent)%"
        } ?? "未读取"
        let resetValue = weekly?.resetsAt.map {
            $0.formatted(date: .abbreviated, time: .shortened)
        } ?? "未读取"
        let stalePrefix = fresh ? "" : "上次读取："
        let staleSuffix = fresh ? "" : "（已过期）"
        return Self(
            isFresh: fresh,
            freshnessText:
                "\(prefix) · \(snapshot.observedAt.formatted(date: .abbreviated, time: .shortened))",
            planText:
                "\(stalePrefix)\(snapshot.planType.uppercased())\(staleSuffix)",
            weeklyUsageText:
                "\(stalePrefix)\(weeklyValue)\(staleSuffix)",
            resetText:
                "\(stalePrefix)\(resetValue)\(staleSuffix)"
        )
    }
}
