// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Foundation

enum PortableContinuityExportError: LocalizedError, Equatable {
    case noFieldSelected
    case unsafeDestination
    case jsonDestinationRequired
    case atomicWriteFailed

    var errorDescription: String? {
        switch self {
        case .noFieldSelected:
            return "至少选择一项再导出"
        case .unsafeDestination:
            return "只能导出到现有本机文件夹中的普通JSON文件"
        case .jsonDestinationRequired:
            return "导出文件必须使用.json扩展名"
        case .atomicWriteFailed:
            return "原子写入失败；目标位置未留下半成品"
        }
    }
}

struct PortableContinuityRelaySource: Equatable, Sendable {
    let sourceIdentifier: String
    let displayName: String
    let baseURL: String
    let defaultModel: String
    let usesResponsesAPI: Bool
}

struct PortableContinuityWorkspaceSource: Equatable, Sendable {
    let localPath: String
    let label: String
}

struct PortableContinuityExportSnapshot: Equatable, Sendable {
    let sourceVersion: String
    let sourceBuild: String
    let accessProfiles: [PortableAccessProfile]
    let workspaceLabels: [PortableWorkspaceLabel]
    let skippedRelayCount: Int
    let skippedWorkspaceLabelCount: Int
    let startDestination: PortableStartDestination
    let historyGrouping: PortableHistoryGrouping

    func manifest(
        selection: PortableContinuitySelection
    ) throws -> PortableContinuityManifest {
        guard selection.hasSelectedField else {
            throw PortableContinuityExportError.noFieldSelected
        }
        return try PortableContinuityManifest(
            sourceVersion: sourceVersion,
            sourceBuild: sourceBuild,
            platform: .macOS,
            selection: selection,
            accessProfiles:
                selection.accessProfiles ? accessProfiles : [],
            workspaceLabels:
                selection.workspaceLabels ? workspaceLabels : [],
            preferences: PortableContinuityPreferences(
                startDestination: selection.startDestination
                    ? startDestination : nil,
                historyGrouping: selection.historyGrouping
                    ? historyGrouping : nil
            )
        )
    }
}

enum PortableContinuityExportPlanner {
    static func snapshot(
        sourceVersion: String,
        sourceBuild: String,
        relaySources: [PortableContinuityRelaySource],
        workspaceSources: [PortableContinuityWorkspaceSource],
        startDestination: PortableStartDestination = .start,
        historyGrouping: PortableHistoryGrouping = .workspace,
        makeUUID: () -> UUID = UUID.init
    ) throws -> PortableContinuityExportSnapshot {
        var usedIDs: Set<UUID> = []
        func nextOpaqueID() throws -> UUID {
            for _ in 0..<32 {
                let candidate = makeUUID()
                if usedIDs.insert(candidate).inserted {
                    return candidate
                }
            }
            throw PortableContinuityError.duplicateIdentifier
        }

        var profiles = [try PortableAccessProfile(
            id: nextOpaqueID(),
            kind: .official,
            displayName: "Codex官方"
        )]
        var skippedRelayCount = 0
        for source in relaySources {
            guard source.usesResponsesAPI,
                profiles.count < 1_000
            else {
                skippedRelayCount += 1
                continue
            }
            do {
                profiles.append(
                    try PortableAccessProfile(
                        id: nextOpaqueID(),
                        kind: .relay,
                        displayName: source.displayName,
                        baseURL: source.baseURL,
                        defaultModel: source.defaultModel,
                        apiProtocol: .responses
                    )
                )
            } catch {
                skippedRelayCount += 1
            }
        }

        var labels: [PortableWorkspaceLabel] = []
        var skippedWorkspaceLabelCount = 0
        for source in workspaceSources {
            guard labels.count < 20 else {
                skippedWorkspaceLabelCount += 1
                continue
            }
            do {
                labels.append(
                    try PortableWorkspaceLabel(
                        id: nextOpaqueID(),
                        label: source.label
                    )
                )
            } catch {
                skippedWorkspaceLabelCount += 1
            }
        }

        return PortableContinuityExportSnapshot(
            sourceVersion: sourceVersion,
            sourceBuild: sourceBuild,
            accessProfiles: profiles,
            workspaceLabels: labels,
            skippedRelayCount: skippedRelayCount,
            skippedWorkspaceLabelCount: skippedWorkspaceLabelCount,
            startDestination: startDestination,
            historyGrouping: historyGrouping
        )
    }
}

enum PortableContinuityAtomicExporter {
    static func write(
        _ manifest: PortableContinuityManifest,
        to destinationURL: URL,
        fileManager: FileManager = .default,
        makeUUID: () -> UUID = UUID.init
    ) throws {
        guard destinationURL.isFileURL else {
            throw PortableContinuityExportError.unsafeDestination
        }
        guard destinationURL.pathExtension.lowercased() == "json" else {
            throw PortableContinuityExportError.jsonDestinationRequired
        }

        let destination = destinationURL.standardizedFileURL
        let parent = destination.deletingLastPathComponent()
        let parentAttributes: [FileAttributeKey: Any]
        do {
            parentAttributes = try fileManager.attributesOfItem(
                atPath: parent.path
            )
        } catch {
            throw PortableContinuityExportError.unsafeDestination
        }
        guard parentAttributes[.type] as? FileAttributeType
            == .typeDirectory else {
            throw PortableContinuityExportError.unsafeDestination
        }
        if let attributes = try? fileManager.attributesOfItem(
            atPath: destination.path
        ), let type = attributes[.type] as? FileAttributeType,
            type == .typeDirectory || type == .typeSymbolicLink
        {
            throw PortableContinuityExportError.unsafeDestination
        }

        let data = try manifest.encodedData()
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(makeUUID().uuidString).tmp"
        )
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw PortableContinuityExportError.atomicWriteFailed
        }
        defer {
            try? fileManager.removeItem(at: temporary)
        }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporary.path
            )
        } catch {
            throw PortableContinuityExportError.atomicWriteFailed
        }

        guard Darwin.rename(
            temporary.path,
            destination.path
        ) == 0 else {
            throw PortableContinuityExportError.atomicWriteFailed
        }
    }
}
