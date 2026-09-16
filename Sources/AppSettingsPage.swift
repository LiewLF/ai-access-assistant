// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct AppSettingsPage: View {
    @ObservedObject var model: ConfigWorkspaceModel
    @ObservedObject var accessModel: V011AccessModel
    @ObservedObject var historyModel: V011HistoryModel
    @ObservedObject var shellState: AppShellState
    @ObservedObject var continuityDraft: BeginnerContinuityViewState

    var body: some View {
        BeginnerSettingsView(
            model: model,
            accessModel: accessModel,
            historyModel: historyModel,
            section: Binding(get: { shellState.settingsSection }, set: shellState.openSettings),
            continuityImportWorking: Binding(
                get: { shellState.isContinuityImportWorking },
                set: shellState.setContinuityImportWorking
            ),
            continuityDraft: continuityDraft,
            openSettingsSection: shellState.openSettings,
            onUseRelayEntry: { entry in
                guard !shellState.navigationLocked else { return }
                model.importDirectoryEntry(entry)
                shellState.openAccess(.addRelay)
            },
            onConfigureCustomRelay: {
                guard !shellState.navigationLocked else { return }
                model.selectRelay(RelayCatalog.customID)
                shellState.openAccess(.addRelay)
            },
            openAccessSection: shellState.openAccess
        )
    }
}
