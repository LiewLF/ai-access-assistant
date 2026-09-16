// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum V013UsageHistoryCoverage: String, Codable, Equatable, Sendable {
    case unknown
    case loading
    case complete
    case incomplete
    case overflow

    var isComplete: Bool { self == .complete }
}

struct V013UsageWindowHistoryResult: Equatable {
    let rows: [V011SessionRow]
    let coverage: V013UsageHistoryCoverage
}

struct V013UsageWindowHistoryReader {
    static let pageSize = 50
    static let maximumPages = 40
    static let maximumSessions = 2_000

    static func orderByRecentActivity(
        _ candidates: [V011SessionRow]
    ) -> [V011SessionRow] {
        candidates.sorted { lhs, rhs in
            let lhsDate = lhs.updatedAt ?? .distantPast
            let rhsDate = rhs.updatedAt ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.id < rhs.id
        }
    }

    func read(
        windowStart: Date,
        loadPage: @escaping @Sendable (
            Int,
            Int
        ) async throws -> SessionCoreSessionPage
    ) async throws -> V013UsageWindowHistoryResult {
        var rows: [V011SessionRow] = []
        var offset = 0
        var sourceIdentity: String?

        for _ in 0..<Self.maximumPages {
            try Task.checkCancellation()
            let page = try await loadPage(Self.pageSize, offset)
            try Task.checkCancellation()
            let pageSourceIdentity =
                "\(page.databasePath)|\(page.total)|\(page.visibleTotal ?? -1)"
            if let sourceIdentity,
               sourceIdentity != pageSourceIdentity {
                return .init(rows: rows, coverage: .incomplete)
            }
            sourceIdentity = pageSourceIdentity
            if page.sessions.isEmpty {
                return .init(
                    rows: rows,
                    coverage: page.hasMore ? .incomplete : .complete
                )
            }

            let pageRows = page.sessions.map {
                V011SessionRow(session: $0, origin: nil)
            }
            rows.append(contentsOf: pageRows.filter {
                ($0.updatedAt ?? .distantPast) >= windowStart
            })
            rows = Self.uniqueRecent(rows)

            guard rows.count <= Self.maximumSessions else {
                return .init(
                    rows: Array(rows.prefix(Self.maximumSessions)),
                    coverage: .overflow
                )
            }
            guard page.hasMore else {
                return .init(rows: rows, coverage: .complete)
            }
            guard let oldest = pageRows.compactMap(\.updatedAt).min()
            else {
                return .init(rows: rows, coverage: .incomplete)
            }
            if oldest <= windowStart {
                return .init(rows: rows, coverage: .complete)
            }
            offset += page.sessions.count
        }
        return .init(rows: rows, coverage: .overflow)
    }

    private static func uniqueRecent(
        _ rows: [V011SessionRow]
    ) -> [V011SessionRow] {
        Dictionary(
            rows.map { ($0.id, $0) },
            uniquingKeysWith: { lhs, rhs in
                (lhs.updatedAt ?? .distantPast)
                    >= (rhs.updatedAt ?? .distantPast) ? lhs : rhs
            }
        ).values.sorted {
            ($0.updatedAt ?? .distantPast)
                > ($1.updatedAt ?? .distantPast)
        }
    }
}
