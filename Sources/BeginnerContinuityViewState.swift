// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Combine

struct PortableContinuityRelayImportForm:
    Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let baseURL: String
    let defaultModel: String
    var isSelected: Bool
    var targetProfileID: String
    var useIncomingDisplayName: Bool
    var useIncomingBaseURL: Bool
    var useIncomingDefaultModel: Bool
    var credential: String
}

struct PortableContinuityWorkspaceImportForm:
    Identifiable, Equatable {
    let id: UUID
    let label: String
    var isSelected: Bool
    var targetPath: String
}

/// Keeps the migration draft in memory across navigation; it performs no I/O.
@MainActor
final class BeginnerContinuityViewState: ObservableObject {
    @Published var snapshot:
        PortableContinuityExportSnapshot?
    @Published var selection = PortableContinuitySelection(
        accessProfiles: true,
        workspaceLabels: true,
        startDestination: false,
        historyGrouping: false
    )
    @Published var previewStatus = "正在生成本机预览…"
    @Published var exportStatus: String?
    @Published var importPreview:
        PortableContinuityImportPreview?
    @Published var importSession:
        PortableContinuityImportSession?
    @Published var relayImportForms:
        [PortableContinuityRelayImportForm] = []
    @Published var workspaceImportForms:
        [PortableContinuityWorkspaceImportForm] = []
    @Published var importConfirmed = false
    @Published var importStatus =
        "尚未选择迁移设置文件。"
}
