// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct V011WorkspaceRow: Identifiable, Equatable {
    var id: String { path }

    let path: String
    let sessionCount: Int
    let archivedCount: Int
    let latestUpdatedAt: Date?
    let isIndexed: Bool

    init(workspace: SessionCoreWorkspace) {
        path = workspace.cwd
        sessionCount = workspace.sessionCount
        archivedCount = workspace.archivedCount
        latestUpdatedAt = Self.date(workspace.latestUpdatedAt)
        isIndexed = true
    }

    init(missingFavoritePath path: String) {
        self.path = path
        sessionCount = 0
        archivedCount = 0
        latestUpdatedAt = nil
        isIndexed = false
    }

    private static func date(
        _ value: SessionCoreJSONValue
    ) -> Date? {
        switch value {
        case let .string(raw):
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [
                .withInternetDateTime,
                .withFractionalSeconds,
            ]
            return fractional.date(from: raw)
                ?? ISO8601DateFormatter().date(from: raw)
        case let .number(raw):
            let seconds = raw > 10_000_000_000
                ? raw / 1_000 : raw
            return Date(timeIntervalSince1970: seconds)
        case .bool, .object, .array, .null:
            return nil
        }
    }
}
