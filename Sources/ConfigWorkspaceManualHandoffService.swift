// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Foundation

@MainActor
struct ConfigWorkspaceManualHandoffService {
    func copyManualConfiguration(_ block: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            block,
            forType: .string
        )
    }

    func openConfiguration(
        at configURL: URL
    ) -> String? {
        if FileManager.default.fileExists(
            atPath: configURL.path
        ) {
            NSWorkspace.shared.activateFileViewerSelecting(
                [configURL]
            )
            return nil
        }
        NSWorkspace.shared.open(
            configURL.deletingLastPathComponent()
        )
        return "config.toml尚不存在；已打开CODEX_HOME，请新建config.toml后粘贴配置块"
    }

    func openExternalTool(
        route: AccessRouteKind,
        relayID: String,
        draft: ConfigDraft
    ) throws -> String? {
        let url: URL
        let status: String
        switch route {
        case .codexPlusPlus:
            let record = CompatibilityCatalog.record(
                relayID: relayID,
                manager: .codexPlusPlus,
                method: .toolImport,
                tool: .codexPlusPlus,
                agent: .codexDesktop
            )
            let generated = try CodexPlusPlusAdapter()
                .generate(from: draft, compatibility: record)
            guard let item = generated.artifacts.first,
                  let plist = try PropertyListSerialization
                    .propertyList(
                        from: item.data,
                        format: nil
                    ) as? [String: String],
                  let value = plist["URL"],
                  let importURL = URL(string: value) else {
                throw ConfigurationGenerationError
                    .invalidImportURL
            }
            url = importURL
            status =
                "Codex++导入已打开。只确认导入；完成后回助手检查外部改动。"
        case .ccSwitch:
            guard let importURL = URL(
                string: "ccswitch://v1/import"
            ) else {
                throw ConfigurationGenerationError
                    .invalidImportURL
            }
            url = importURL
            status =
                "CC Switch已打开。按助手字段填写并确认；完成后回助手检查。"
        case .managed, .manual:
            return nil
        }
        NSWorkspace.shared.open(url)
        return status
    }
}
