// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum ConfigWorkspaceArtifactService {
    static func generate(
        draft: ConfigDraft,
        manager: AdapterTarget,
        compatibility: CompatibilityRecord,
        safetyAudit: SafetyAuditResult
    ) throws -> GeneratedConfiguration {
        guard safetyAudit.allowed else {
            throw ConfigurationGenerationError.safetyBlocked(
                safetyAudit.reasons.joined(separator: "；")
            )
        }
        return try ConfigurationAdapters.adapter(for: manager)
            .generate(
                from: draft,
                compatibility: compatibility
            )
    }

    static func export(
        _ preview: GeneratedConfiguration,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> URL {
        let desktop = fileManager.urls(
            for: .desktopDirectory,
            in: .userDomainMask
        ).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Desktop",
                    isDirectory: true
                )
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = desktop
            .appendingPathComponent(
                "AI接入助手导出",
                isDirectory: true
            )
            .appendingPathComponent(
                "\(preview.manager.rawValue)-\(formatter.string(from: now))",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        for artifact in preview.artifacts {
            try artifact.data.write(
                to: folder.appendingPathComponent(
                    artifact.fileName
                ),
                options: .atomic
            )
        }
        return folder
    }
}
