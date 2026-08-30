// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Owns rollout-path containment validation and guarded continuation packet
/// extraction. HistoryModel keeps the public session-row adapter only.
struct V011HistoryContinuationService: Sendable {
    let codexHome: URL

    func packet(
        rolloutPath: String,
        threadID: String
    ) async throws -> SessionContinuationPacket {
        let url = try validatedRolloutURL(rolloutPath)
        return try await GuardedContinuationPacketExtractor()
            .packet(
                at: url,
                threadID: threadID,
                codexHome: codexHome
            )
    }

    private func validatedRolloutURL(
        _ path: String
    ) throws -> URL {
        guard path.hasPrefix("/") else {
            throw SessionCenterError.unsafePath
        }
        let candidate = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let allowedRoots = [
            codexHome.appendingPathComponent(
                "sessions",
                isDirectory: true
            ),
            codexHome.appendingPathComponent(
                "archived_sessions",
                isDirectory: true
            ),
        ]
        .map {
            $0.standardizedFileURL
                .resolvingSymlinksInPath()
        }
        guard allowedRoots.contains(where: {
            SessionSyncFileSafety.isDescendant(
                candidate.path,
                of: $0.path
            )
        }) else {
            throw SessionCenterError.unsafePath
        }
        return candidate
    }
}
