// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct ConfigWorkspaceOfficialCandidateSnapshot {
    let candidates: [OfficialOverlayCandidate]
    let selectedCandidateID: String?
}

/// Owns official-overlay candidate loading, backup parsing, and selection
/// persistence. ConfigWorkspaceModel keeps eligibility gates and presentation.
struct ConfigWorkspaceOfficialCandidateService {
    let codexHomeURL: URL
    let adapter: CodexConfigurationAdapter
    let stateStore: CodexStateStore

    func load()
        throws -> ConfigWorkspaceOfficialCandidateSnapshot {
        let currentText = try currentConfigurationText()
        let state = try stateStore.load()
        var candidates = [
            try OfficialOverlayCandidateFactory
                .currentWithoutProvider(
                    currentText: currentText
                ),
        ]
        if let overlay = state.officialOverlay {
            candidates.append(
                try OfficialOverlayCandidateFactory
                    .assistantOverlay(
                        overlay,
                        currentText: currentText
                    )
            )
        }
        if let baseline = state.baseline,
           let baselineData = try adapter
            .baselineConfigData(baseline) {
            candidates.append(
                try OfficialOverlayCandidateFactory.backup(
                    text: String(
                        decoding: baselineData,
                        as: UTF8.self
                    ),
                    filename:
                        "AI接入助手加密灾备-\(baseline.snapshot.id)",
                    currentText: currentText
                )
            )
        }
        return ConfigWorkspaceOfficialCandidateSnapshot(
            candidates: candidates,
            selectedCandidateID:
                state.officialOverlay.map {
                    "assistant-\($0.id)"
                }
        )
    }

    func importBackup(
        from url: URL
    ) throws -> OfficialOverlayCandidate {
        try OfficialOverlayCandidateFactory.backup(
            text: String(
                decoding: try Data(
                    contentsOf: url,
                    options: .mappedIfSafe
                ),
                as: UTF8.self
            ),
            filename: url.lastPathComponent,
            currentText: try currentConfigurationText()
        )
    }

    func select(
        _ candidate: OfficialOverlayCandidate
    ) throws {
        var state = try stateStore.load()
        var overlay = candidate.overlay
        overlay.state = .candidate
        overlay.lastVerifiedAt = nil
        state.officialOverlay = overlay
        state.officialBaselineTrust = .candidate
        try stateStore.save(state)
    }

    private func currentConfigurationText() throws -> String {
        let configURL = codexHomeURL.appendingPathComponent(
            "config.toml"
        )
        guard FileManager.default.fileExists(
            atPath: configURL.path
        ) else {
            return ""
        }
        return String(
            decoding: try Data(contentsOf: configURL),
            as: UTF8.self
        )
    }
}
