// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Foundation
import UniformTypeIdentifiers

enum ConfigWorkspaceGovernanceFixtureExportOutcome {
    case cancelled
    case exported(status: String)
    case failed(message: String)
}

@MainActor
final class ConfigWorkspaceGovernanceFixtureExportController {
    func export() ->
        ConfigWorkspaceGovernanceFixtureExportOutcome {
        let openPanel = NSOpenPanel()
        openPanel.title =
            "选择要生成脱敏结构证据的TOML"
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.allowedContentTypes = [
            UTType(filenameExtension: "toml")
                ?? .plainText,
        ]
        guard openPanel.runModal() == .OK,
              let sourceURL = openPanel.url else {
            return .cancelled
        }

        let savePanel = NSSavePanel()
        savePanel.title = "保存脱敏结构证据"
        savePanel.nameFieldStringValue =
            "AI接入助手-配置结构证据.json"
        savePanel.allowedContentTypes = [.json]
        guard savePanel.runModal() == .OK,
              let destinationURL = savePanel.url else {
            return .cancelled
        }

        let accessed = sourceURL
            .startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL
                    .stopAccessingSecurityScopedResource()
            }
        }
        do {
            let fixture = try GovernanceFixtureExporter.export(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                userAuthorized: true
            )
            return .exported(
                status:
                    "已导出：\(fixture.totalLeafCount)个总叶子，\(fixture.nonProviderLeafCount)个非Provider叶子；只含结构、类型、数量和哈希。"
            )
        } catch {
            return .failed(
                message:
                    "脱敏结构导出失败："
                    + error.localizedDescription
            )
        }
    }
}
