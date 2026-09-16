import Foundation

/// Whether the official usage card can start a read right now. The official
/// read runs in its own read-only RPC process against the built-in provider
/// and leaves the user's configuration and model route untouched, so the
/// current route is not what decides availability; only a busy helper is.
enum V011OfficialUsageRefreshAvailability: Equatable, Sendable {
    case available
    case busy

    init(isBusy: Bool) {
        self = isBusy ? .busy : .available
    }

    var unavailableReason: String? {
        self == .busy ? "其他操作进行中，结束后可刷新" : nil
    }
}

struct V011OfficialUsageCardPresentation: Equatable, Sendable {
    let isFresh: Bool
    let freshnessText: String?
    let refreshFailureText: String?
    let planText: String
    let weeklyUsageText: String
    let resetText: String
    let refreshAvailability: V011OfficialUsageRefreshAvailability

    /// Copy for a retained but expired value. It points at a refresh only when
    /// the card can actually perform one.
    var staleValueHint: String {
        guard let reason = refreshAvailability.unavailableReason else {
            return "过期值仅供回看，请刷新"
        }
        return "过期值仅供回看；\(reason)"
    }

    static func make(
        snapshot: V011OfficialUsageSnapshot?,
        now: Date,
        refreshFailedAt: Date? = nil,
        refreshAvailability: V011OfficialUsageRefreshAvailability = .available
    ) -> Self {
        guard let snapshot else {
            return Self(
                isFresh: false,
                freshnessText: nil,
                refreshFailureText: refreshFailedAt.map {
                    "本次刷新失败 · \($0.formatted(date: .abbreviated, time: .shortened))；没有可用的成功快照"
                },
                planText: "未读取",
                weeklyUsageText: "未读取",
                resetText: "未读取",
                refreshAvailability: refreshAvailability
            )
        }
        let fresh = snapshot.isFresh(at: now)
        let prefix = fresh
            ? "上次成功读取，仍在有效期内" : "上次成功读取，已过期"
        let weekly = snapshot.windows.first {
            $0.durationMinutes == 10_080
        }
        let weeklyValue = weekly.map {
            "\($0.usedPercent)% / \($0.remainingPercent)%"
        } ?? "未读取"
        let resetValue = weekly?.resetsAt.map {
            $0.formatted(date: .abbreviated, time: .shortened)
        } ?? "未读取"
        let stalePrefix = fresh ? "" : "上次成功读取："
        let staleSuffix = fresh ? "" : "（已过期）"
        return Self(
            isFresh: fresh,
            freshnessText:
                "\(prefix) · \(snapshot.observedAt.formatted(date: .abbreviated, time: .shortened))",
            refreshFailureText: refreshFailedAt.map {
                let retainedState = fresh
                    ? "仍显示有效期内的上次成功快照"
                    : "保留快照已过期，不代表当前额度"
                return "本次刷新失败 · \($0.formatted(date: .abbreviated, time: .shortened))；\(retainedState)"
            },
            planText:
                "\(stalePrefix)\(snapshot.planType.uppercased())\(staleSuffix)",
            weeklyUsageText:
                "\(stalePrefix)\(weeklyValue)\(staleSuffix)",
            resetText:
                "\(stalePrefix)\(resetValue)\(staleSuffix)",
            refreshAvailability: refreshAvailability
        )
    }
}
