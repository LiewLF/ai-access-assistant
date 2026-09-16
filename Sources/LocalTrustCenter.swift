// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Darwin
import Foundation
import SwiftUI

enum LocalTrustArtifactKind: String, Codable, Sendable {
    case skill = "Skill"
    case plugin = "Plugin"
    case mcpConfiguration = "MCP配置"
    case codexConfiguration = "Codex配置"
    case symbolicLink = "符号链接"
}

struct LocalTrustArtifact: Identifiable, Codable, Equatable, Sendable {
    var id: String {
        [kind.rawValue, sourceRoot, relativePath]
            .joined(separator: "|")
    }

    let kind: LocalTrustArtifactKind
    let name: String
    let sourceRoot: String
    let rootPath: String
    let relativePath: String
    let sha256: String?
    let permissions: String
    let symbolicLink: Bool
    let writableByGroupOrOthers: Bool
    var duplicateName: Bool
    var shadowedBy: String?
}

struct LocalTrustMCPEntry: Identifiable, Codable, Equatable, Sendable {
    var id: String { serverID }

    let serverID: String
    let configurationFields: [String]

    var connectionState: String {
        "仅确认配置存在；连接与工具未验证"
    }
}

struct LocalTrustHookEntry: Identifiable, Codable, Equatable, Sendable {
    var id: String { hookID }

    let hookID: String
    let configurationFields: [String]

    var executionState: String {
        "仅确认配置存在；作用域、触发与执行未验证"
    }
}

struct LocalTrustScanCoverage: Codable, Equatable, Sendable {
    let codexSkills: Bool
    let agentsSkills: Bool
    let plugins: Bool
    let configuration: Bool

    var skillsComplete: Bool {
        codexSkills && agentsSkills
    }
}

struct LocalTrustSnapshot: Codable, Equatable, Sendable {
    let scannedAt: Date
    let artifacts: [LocalTrustArtifact]
    let mcpServers: [LocalTrustMCPEntry]
    let hooks: [LocalTrustHookEntry]
    let warnings: [String]
    let coverage: LocalTrustScanCoverage

    var riskCount: Int {
        artifacts.filter {
            $0.symbolicLink
                || $0.writableByGroupOrOthers
                || $0.duplicateName
        }.count
    }
}

enum LocalTrustScannerError: LocalizedError, Equatable {
    case unsafeRoot(String)
    case fileTooLarge(String)
    case changedDuringRead(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unsafeRoot(let path):
            return "扫描根不是普通目录或是符号链接：\(path)"
        case .fileTooLarge(let path):
            return "文件超过只读核对上限：\(path)"
        case .changedDuringRead(let path):
            return "文件在核对时发生变化：\(path)"
        case .unreadable(let path):
            return "文件无法只读核对：\(path)"
        }
    }
}

struct LocalTrustScanner: Sendable {
    private enum ScanTarget {
        case skills
        case plugins
    }

    private struct FileMetadata: Equatable {
        let mode: mode_t
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64

        var isRegular: Bool {
            mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        }

        var isDirectory: Bool {
            mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        }

        var isSymbolicLink: Bool {
            mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
        }

        var permissions: String {
            String(format: "%03o", mode & 0o777)
        }

        var writableByGroupOrOthers: Bool {
            mode & 0o022 != 0
        }
    }

    private let maximumDepth = 10
    private let maximumEntries = 20_000
    private let maximumArtifacts = 2_000
    private let maximumHashedFileBytes = 8 * 1024 * 1024
    private let maximumConfigBytes = 2 * 1024 * 1024

    func inspect(
        codexSkillsRoot: URL,
        agentsSkillsRoot: URL,
        pluginsRoot: URL,
        configURL: URL,
        now: Date = Date()
    ) -> LocalTrustSnapshot {
        var artifacts: [LocalTrustArtifact] = []
        var warnings: [String] = []
        let codexSkillsCovered = scan(
            label: "Codex Skills",
            root: codexSkillsRoot,
            target: .skills,
            artifacts: &artifacts,
            warnings: &warnings
        )
        let agentsSkillsCovered = scan(
            label: "Agents Skills",
            root: agentsSkillsRoot,
            target: .skills,
            artifacts: &artifacts,
            warnings: &warnings
        )
        let pluginsCovered = scan(
            label: "Codex Plugins",
            root: pluginsRoot,
            target: .plugins,
            artifacts: &artifacts,
            warnings: &warnings
        )
        let configuration = inspectConfiguration(
            at: configURL,
            artifacts: &artifacts,
            warnings: &warnings
        )
        markDuplicateCandidates(&artifacts)
        artifacts.sort {
            ($0.kind.rawValue, $0.name.lowercased(), $0.sourceRoot, $0.relativePath)
                < ($1.kind.rawValue, $1.name.lowercased(), $1.sourceRoot, $1.relativePath)
        }
        return LocalTrustSnapshot(
            scannedAt: now,
            artifacts: artifacts,
            mcpServers: configuration.mcpServers,
            hooks: configuration.hooks,
            warnings: warnings.sorted(),
            coverage: LocalTrustScanCoverage(
                codexSkills: codexSkillsCovered,
                agentsSkills: agentsSkillsCovered,
                plugins: pluginsCovered,
                configuration: configuration.complete
            )
        )
    }

    private func scan(
        label: String,
        root: URL,
        target: ScanTarget,
        artifacts: inout [LocalTrustArtifact],
        warnings: inout [String]
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: root.path) else {
            warnings.append("\(label)目录不存在：\(root.path)")
            return false
        }
        guard let rootMetadata = metadata(at: root),
              rootMetadata.isDirectory,
              !rootMetadata.isSymbolicLink else {
            warnings.append(
                LocalTrustScannerError.unsafeRoot(root.path)
                    .localizedDescription
            )
            return false
        }

        var complete = true
        var stack: [(url: URL, relative: String, depth: Int)] = [
            (root, "", 0),
        ]
        var visited = 0
        while let current = stack.popLast() {
            guard visited < maximumEntries,
                  artifacts.count < maximumArtifacts else {
                warnings.append("\(label)达到只读扫描上限，剩余项目未展开")
                return false
            }
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: current.url,
                    includingPropertiesForKeys: nil,
                    options: []
                ).sorted { $0.path < $1.path }
            } catch {
                warnings.append("目录无法读取：\(current.url.path)")
                complete = false
                continue
            }
            for child in children {
                visited += 1
                let relative = current.relative.isEmpty
                    ? child.lastPathComponent
                    : current.relative + "/" + child.lastPathComponent
                guard let itemMetadata = metadata(at: child) else {
                    warnings.append("路径无法核对：\(child.path)")
                    complete = false
                    continue
                }
                if itemMetadata.isSymbolicLink {
                    artifacts.append(
                        artifact(
                            kind: .symbolicLink,
                            name: child.lastPathComponent,
                            label: label,
                            root: root,
                            relative: relative,
                            metadata: itemMetadata,
                            digest: nil
                        )
                    )
                    continue
                }
                if itemMetadata.isDirectory {
                    if current.depth < maximumDepth {
                        stack.append((
                            child,
                            relative,
                            current.depth + 1
                        ))
                    } else {
                        complete = false
                        warnings.append(
                            "\(label)达到目录深度上限：\(child.path)"
                        )
                    }
                    continue
                }
                guard itemMetadata.isRegular else { continue }
                let kind: LocalTrustArtifactKind?
                switch target {
                case .skills:
                    kind = child.lastPathComponent == "SKILL.md"
                        ? .skill : nil
                case .plugins:
                    kind = relative.hasSuffix(
                        "/.codex-plugin/plugin.json"
                    ) || relative == ".codex-plugin/plugin.json"
                        ? .plugin : nil
                }
                guard let kind else { continue }
                let digest: String?
                do {
                    digest = try stableDigest(
                        at: child,
                        maximumBytes: maximumHashedFileBytes
                    )
                } catch {
                    digest = nil
                    complete = false
                    warnings.append(error.localizedDescription)
                }
                artifacts.append(
                    artifact(
                        kind: kind,
                        name: artifactName(
                            kind: kind,
                            relativePath: relative
                        ),
                        label: label,
                        root: root,
                        relative: relative,
                        metadata: itemMetadata,
                        digest: digest
                    )
                )
            }
        }
        return complete
    }

    private func inspectConfiguration(
        at url: URL,
        artifacts: inout [LocalTrustArtifact],
        warnings: inout [String]
    ) -> (
        mcpServers: [LocalTrustMCPEntry],
        hooks: [LocalTrustHookEntry],
        complete: Bool
    ) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            warnings.append("Codex config.toml不存在：\(url.path)")
            return ([], [], false)
        }
        guard let itemMetadata = metadata(at: url),
              itemMetadata.isRegular,
              !itemMetadata.isSymbolicLink else {
            warnings.append(
                LocalTrustScannerError.unreadable(url.path)
                    .localizedDescription
            )
            return ([], [], false)
        }
        do {
            let data = try stableData(
                at: url,
                maximumBytes: maximumConfigBytes
            )
            let digest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            artifacts.append(
                artifact(
                    kind: .codexConfiguration,
                    name: "config.toml",
                    label: "Codex配置",
                    root: url.deletingLastPathComponent(),
                    relative: url.lastPathComponent,
                    metadata: itemMetadata,
                    digest: digest
                )
            )
            let structure = safeConfigurationStructure(from: data)
            return (
                structure.mcpServers,
                structure.hooks,
                true
            )
        } catch {
            warnings.append(error.localizedDescription)
            return ([], [], false)
        }
    }

    private func safeConfigurationStructure(
        from data: Data
    ) -> (
        mcpServers: [LocalTrustMCPEntry],
        hooks: [LocalTrustHookEntry]
    ) {
        var mcpFields: [String: Set<String>] = [:]
        var hookFields: [String: Set<String>] = [:]
        var currentTable: [String] = []
        for rawLine in data.split(
            separator: 0x0A,
            omittingEmptySubsequences: false
        ) {
            let bytes = Array(rawLine)
            guard let start = bytes.firstIndex(where: {
                $0 != 0x20 && $0 != 0x09 && $0 != 0x0D
            }),
            bytes[start] != 0x23 else { continue }
            if bytes[start] == 0x5B,
               let close = bytes[start...].firstIndex(of: 0x5D),
               close > start + 1,
               let header = String(
                   bytes: bytes[(start + 1)..<close],
                   encoding: .utf8
                ) {
                currentTable = parseDottedKey(header)
                recordConfigurationPath(
                    currentTable,
                    rootKey: "mcp_servers",
                    fieldsByID: &mcpFields
                )
                recordConfigurationPath(
                    currentTable,
                    rootKey: "hooks",
                    fieldsByID: &hookFields
                )
                continue
            }
            guard let equals = firstTopLevelEquals(
                in: bytes,
                startingAt: start
            ),
            let keyText = String(
                bytes: bytes[start..<equals],
                encoding: .utf8
            ) else { continue }
            let path = currentTable + parseDottedKey(keyText)
            recordConfigurationPath(
                path,
                rootKey: "mcp_servers",
                fieldsByID: &mcpFields
            )
            recordConfigurationPath(
                path,
                rootKey: "hooks",
                fieldsByID: &hookFields
            )
        }
        let mcpServers = mcpFields.keys.sorted().map {
            LocalTrustMCPEntry(
                serverID: $0,
                configurationFields:
                    mcpFields[$0, default: []].sorted()
            )
        }
        let hooks = hookFields.keys.sorted().map {
            LocalTrustHookEntry(
                hookID: $0,
                configurationFields:
                    hookFields[$0, default: []].sorted()
            )
        }
        return (mcpServers, hooks)
    }

    private func firstTopLevelEquals(
        in bytes: [UInt8],
        startingAt start: Int
    ) -> Int? {
        var quote: UInt8?
        var escaped = false
        for index in start..<bytes.count {
            let byte = bytes[index]
            if escaped {
                escaped = false
                continue
            }
            if quote == 0x22, byte == 0x5C {
                escaped = true
                continue
            }
            if byte == 0x22 || byte == 0x27 {
                quote = quote == nil
                    ? byte : quote == byte ? nil : quote
                continue
            }
            if byte == 0x3D, quote == nil {
                return index
            }
        }
        return nil
    }

    private func parseDottedKey(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if quote == "\"", character == "\\" {
                escaped = true
                continue
            }
            if character == "\"" || character == "'" {
                quote = quote == nil
                    ? character
                    : quote == character ? nil : quote
                continue
            }
            if character == ".", quote == nil {
                appendKeyComponent(current, into: &result)
                current = ""
            } else {
                current.append(character)
            }
        }
        appendKeyComponent(current, into: &result)
        return result
    }

    private func appendKeyComponent(
        _ raw: String,
        into result: inout [String]
    ) {
        let value = raw.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty,
              value.count <= 128,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { return }
        result.append(value)
    }

    private func recordConfigurationPath(
        _ path: [String],
        rootKey: String,
        fieldsByID: inout [String: Set<String>]
    ) {
        guard path.count >= 2,
              path[0] == rootKey else { return }
        let itemID = path[1]
        _ = fieldsByID[itemID, default: []]
        if path.count > 2 {
            fieldsByID[itemID, default: []]
                .insert(path.dropFirst(2).joined(separator: "."))
        }
    }

    private func markDuplicateCandidates(
        _ artifacts: inout [LocalTrustArtifact]
    ) {
        var firstByName: [String: Int] = [:]
        for index in artifacts.indices
            where artifacts[index].kind == .skill
                || artifacts[index].kind == .plugin {
            let key = artifacts[index].kind.rawValue
                + "|" + artifacts[index].name.lowercased()
            if let first = firstByName[key] {
                artifacts[first].duplicateName = true
                artifacts[index].duplicateName = true
                artifacts[index].shadowedBy =
                    artifacts[first].sourceRoot + "/"
                    + artifacts[first].relativePath
            } else {
                firstByName[key] = index
            }
        }
    }

    private func artifact(
        kind: LocalTrustArtifactKind,
        name: String,
        label: String,
        root: URL,
        relative: String,
        metadata: FileMetadata,
        digest: String?
    ) -> LocalTrustArtifact {
        LocalTrustArtifact(
            kind: kind,
            name: name,
            sourceRoot: label,
            rootPath: root.path,
            relativePath: relative,
            sha256: digest,
            permissions: metadata.permissions,
            symbolicLink: metadata.isSymbolicLink,
            writableByGroupOrOthers:
                metadata.writableByGroupOrOthers,
            duplicateName: false,
            shadowedBy: nil
        )
    }

    private func artifactName(
        kind: LocalTrustArtifactKind,
        relativePath: String
    ) -> String {
        let components = relativePath.split(separator: "/")
            .map(String.init)
        switch kind {
        case .skill:
            return components.dropLast().last ?? "unknown-skill"
        case .plugin:
            guard let marker = components.firstIndex(
                of: ".codex-plugin"
            ), marker > 0 else {
                return "unknown-plugin"
            }
            let parent = components[marker - 1]
            if marker > 1,
               parent.first?.isNumber == true,
               parent.contains(".") {
                return components[marker - 2]
            }
            return parent
        case .mcpConfiguration, .codexConfiguration, .symbolicLink:
            return components.last ?? relativePath
        }
    }

    private func stableDigest(
        at url: URL,
        maximumBytes: Int
    ) throws -> String {
        let data = try stableData(
            at: url,
            maximumBytes: maximumBytes
        )
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func stableData(
        at url: URL,
        maximumBytes: Int
    ) throws -> Data {
        guard let before = metadata(at: url),
              before.isRegular,
              !before.isSymbolicLink else {
            throw LocalTrustScannerError.unreadable(url.path)
        }
        guard before.size <= maximumBytes else {
            throw LocalTrustScannerError.fileTooLarge(url.path)
        }
        guard let data = try? Data(contentsOf: url),
              data.count == before.size,
              let after = metadata(at: url) else {
            throw LocalTrustScannerError.unreadable(url.path)
        }
        guard before == after else {
            throw LocalTrustScannerError.changedDuringRead(url.path)
        }
        return data
    }

    private func metadata(at url: URL) -> FileMetadata? {
        var value = stat()
        let status: Int32 = url.withUnsafeFileSystemRepresentation {
            path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &value)
        }
        guard status == 0 else { return nil }
        return FileMetadata(
            mode: value.st_mode,
            size: Int64(value.st_size),
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec)
        )
    }
}

@MainActor
final class LocalTrustCenterModel: ObservableObject {
    @Published private(set) var snapshot: LocalTrustSnapshot?
    @Published private(set) var compatibilityReport:
        CapabilityCompatibilityReport?
    @Published private(set) var compatibilityDiffResult:
        CapabilityCompatibilityDiffResult?
    @Published private(set) var hasCompatibilityBaseline = false
    @Published private(set) var isScanning = false
    @Published private(set) var status = "尚未生成只读信任快照"

    private var scanTask: Task<Void, Never>?
    private var codexEvidence:
        CapabilityCompatibilityCodexEvidence = .unverified
    private var compatibilityBaseline:
        CapabilityCompatibilityReport?

    func captureCompatibilityBaseline() {
        guard let compatibilityReport else { return }
        compatibilityBaseline = compatibilityReport
        compatibilityDiffResult = nil
        hasCompatibilityBaseline = true
        status = "升级前基线已在本次应用运行期间保留；完成外部升级后重新扫描"
    }

    func refresh() {
        refresh(codexEvidence: codexEvidence)
    }

    func refresh(
        codexEvidence: CapabilityCompatibilityCodexEvidence
    ) {
        guard !isScanning else { return }
        self.codexEvidence = codexEvidence
        isScanning = true
        status = "正在只读核对Codex、Skills、Plugins、MCP与Hooks"
        let home = FileManager.default.homeDirectoryForCurrentUser
        scanTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = await Task.detached(
                priority: .userInitiated
            ) {
                LocalTrustScanner().inspect(
                    codexSkillsRoot: home
                        .appendingPathComponent(
                            ".codex/skills",
                            isDirectory: true
                        ),
                    agentsSkillsRoot: home
                        .appendingPathComponent(
                            ".agents/skills",
                            isDirectory: true
                        ),
                    pluginsRoot: home
                        .appendingPathComponent(
                            ".codex/plugins",
                            isDirectory: true
                        ),
                    configURL: home
                        .appendingPathComponent(
                            ".codex/config.toml"
                        )
                )
            }.value
            guard !Task.isCancelled else { return }
            self.snapshot = snapshot
            let report =
                CapabilityCompatibilityEvaluator.evaluate(
                    codexEvidence: codexEvidence,
                    snapshot: snapshot
                )
            self.compatibilityReport = report
            if let baseline = self.compatibilityBaseline {
                self.compatibilityDiffResult =
                    CapabilityCompatibilityDiffEvaluator.compare(
                        before: baseline,
                        after: report
                    )
            }
            self.status = "只读快照已生成；未修改任何扩展或配置"
            self.isScanning = false
            self.scanTask = nil
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }
}
