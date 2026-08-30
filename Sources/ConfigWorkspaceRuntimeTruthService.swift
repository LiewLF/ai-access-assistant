// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Foundation

/// Owns live Codex process/config observation and its verified summary.
/// ConfigWorkspaceModel keeps state reconciliation and drift presentation.
@MainActor
struct ConfigWorkspaceRuntimeTruthService {
    let codexHomeURL: URL
    let controlRootURL: URL

    func inspect() throws -> RuntimeTruth {
        let process = CodexRuntimeProcessDiscovery.discover()
        let schema = CodexSchemaCompatibilityCatalog.inspect(
            applicationURL:
                CodexApplicationLocator.applicationURL()
        )
        return try RuntimeTruthInspector(
            codexHome: codexHomeURL,
            controlRoot: controlRootURL,
            selectedProfile: process.selectedProfile,
            profileConfigPath:
                CodexProfileLocator.configurationURL(
                    profile: process.selectedProfile,
                    codexHome: codexHomeURL
                ),
            processWorkingDirectory:
                process.workingDirectory,
            projectConfigPaths: process.projectConfigPaths,
            projectContextKnown:
                process.projectContextKnown,
            processIdentifier: process.processIdentifier,
            processCodexHome: process.codexHome,
            processCodexHomeEvidence:
                process.codexHomeEvidence,
            processArguments: process.arguments,
            processProviderID: process.providerID,
            processModel: process.model,
            processConfigurationOverrides:
                process.configurationOverrides,
            hasUnsupportedProcessOverrides:
                process.hasUnsupportedConfigurationOverrides,
            schemaCompatibility: schema,
            configurationOccupied:
                ConfigurationFileOccupancyInspector
                    .isExclusivelyLocked(
                        codexHomeURL.appendingPathComponent(
                            "config.toml"
                        )
                    )
        ).inspect()
    }

    func installedCodexVersion() -> String? {
        guard let appURL = NSWorkspace.shared
            .urlForApplication(
                withBundleIdentifier: "com.openai.codex"
            ) else {
            return nil
        }
        return Bundle(url: appURL)?.object(
            forInfoDictionaryKey:
                "CFBundleShortVersionString"
        ) as? String
    }

    static func verifiedStatus(
        _ truth: RuntimeTruth
    ) -> String {
        var parts = [
            "真实配置与助手记录一致",
            "当前Provider：\(truth.activeProviderID ?? "官方默认")",
        ]
        if truth.process.processIdentifier != nil {
            let evidence: String
            switch truth.process.codexHomeEvidence {
            case CodexHomeEnvironmentEvidence.explicit.rawValue:
                evidence = "显式环境"
            case CodexHomeEnvironmentEvidence.defaulted.rawValue:
                evidence = "官方默认"
            default:
                evidence = "未知证据"
            }
            parts.append(
                "运行CODEX_HOME："
                    + (truth.process.codexHome ?? "未知")
                    + "（\(evidence)）"
            )
        } else {
            parts.append("Codex当前未运行")
        }
        return parts.joined(separator: "；")
    }
}
