// SPDX-License-Identifier: AGPL-3.0-only

enum V015PerformanceOperation:
    String, CaseIterable, Equatable, Sendable {
    case startupProjection = "startup-projection"
    case accessListProjection = "access-list-projection"
    case historyPagination = "history-pagination"
    case diagnosticEncoding = "diagnostic-encoding"
    case userBenefitJourney = "user-benefit-journey"
}

struct V015PerformanceBudget: Equatable, Sendable {
    let operation: V015PerformanceOperation
    let workload: String
    let maximumP95Milliseconds: Double
    let installedMaximumP95Milliseconds: Double
}

enum V015PerformanceBudgetCatalog {
    static let warmupCount = 5
    static let minimumMeasuredSamples = 30
    static let maximumVisibleHistoryRows = 10_000

    static let all: [V015PerformanceBudget] = [
        .init(
            operation: .startupProjection,
            workload: "1000 shell-state and user-journey projections",
            maximumP95Milliseconds: 20,
            installedMaximumP95Milliseconds: 400
        ),
        .init(
            operation: .accessListProjection,
            workload: "project 1000 saved relay rows",
            maximumP95Milliseconds: 50,
            installedMaximumP95Milliseconds: 100
        ),
        .init(
            operation: .historyPagination,
            workload: "merge 100 rows into 9950 visible rows",
            maximumP95Milliseconds: 50,
            installedMaximumP95Milliseconds: 250
        ),
        .init(
            operation: .diagnosticEncoding,
            workload: "encode and summarize 100 redacted diagnostics",
            maximumP95Milliseconds: 100,
            installedMaximumP95Milliseconds: 500
        ),
        .init(
            operation: .userBenefitJourney,
            workload:
                "project 1000 readiness states and 100 support bundles",
            maximumP95Milliseconds: 100,
            installedMaximumP95Milliseconds: 500
        ),
    ]

    static func budget(
        for operation: V015PerformanceOperation
    ) -> V015PerformanceBudget {
        switch operation {
        case .startupProjection:
            return all[0]
        case .accessListProjection:
            return all[1]
        case .historyPagination:
            return all[2]
        case .diagnosticEncoding:
            return all[3]
        case .userBenefitJourney:
            return all[4]
        }
    }
}

enum V015PerformanceStatus: String, Equatable, Sendable {
    case pass
    case fail
    case insufficientSamples = "insufficient-samples"
}

struct V015PerformanceEvaluation: Equatable, Sendable {
    let operation: V015PerformanceOperation
    let workload: String
    let warmupCount: Int
    let sampleCount: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let maximumP95Milliseconds: Double
    let status: V015PerformanceStatus
}

enum V015PerformanceEvaluator {
    static func evaluate(
        operation: V015PerformanceOperation,
        milliseconds: [Double],
        warmupCount: Int =
            V015PerformanceBudgetCatalog.warmupCount
    ) -> V015PerformanceEvaluation {
        let budget = V015PerformanceBudgetCatalog.budget(
            for: operation
        )
        let boundedWarmup = min(
            max(0, warmupCount),
            milliseconds.count
        )
        let measured = milliseconds
            .dropFirst(boundedWarmup)
            .filter { $0 >= 0 }
            .sorted()
        let status: V015PerformanceStatus
        if measured.count
            < V015PerformanceBudgetCatalog.minimumMeasuredSamples {
            status = .insufficientSamples
        } else if percentile(measured, numerator: 95)
            <= budget.maximumP95Milliseconds {
            status = .pass
        } else {
            status = .fail
        }
        return V015PerformanceEvaluation(
            operation: operation,
            workload: budget.workload,
            warmupCount: boundedWarmup,
            sampleCount: measured.count,
            p50Milliseconds:
                percentile(measured, numerator: 50),
            p95Milliseconds:
                percentile(measured, numerator: 95),
            maximumP95Milliseconds:
                budget.maximumP95Milliseconds,
            status: status
        )
    }

    private static func percentile(
        _ sorted: [Double],
        numerator: Int
    ) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = (sorted.count * numerator + 99) / 100
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }
}

struct V015AccessListRow: Equatable, Identifiable {
    let profile: CodexRelayProfile
    let detail: String
    let active: Bool

    var id: String { profile.id }
}

enum V015AccessListProjector {
    static func project(
        _ profiles: [CodexRelayProfile],
        currentProviderID: String?
    ) -> [V015AccessListRow] {
        profiles.map { profile in
            V015AccessListRow(
                profile: profile,
                detail:
                    "\(profile.defaultModel) · \(profile.baseURL)",
                active:
                    currentProviderID == profile.v011ProviderID
            )
        }
    }
}

enum V015BoundedPageMerger {
    static func replacing<Element>(
        _ incoming: [Element],
        limit: Int
    ) -> [Element] {
        Array(incoming.prefix(max(0, limit)))
    }

    static func appending<Element, Identifier: Hashable>(
        existing: [Element],
        incoming: [Element],
        limit: Int,
        id: KeyPath<Element, Identifier>
    ) -> [Element] {
        guard limit > 0 else { return [] }
        var seen: Set<Identifier> = []
        var result: [Element] = []
        result.reserveCapacity(
            min(limit, existing.count + incoming.count)
        )
        for item in existing + incoming {
            guard result.count < limit else { break }
            if seen.insert(item[keyPath: id]).inserted {
                result.append(item)
            }
        }
        return result
    }
}
