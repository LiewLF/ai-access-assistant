// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

struct CodexDiscoveredProcessContext: Equatable {
    let processIdentifier: Int32?
    let arguments: [String]
    let codexHome: URL?
    let codexHomeEvidence: CodexHomeEnvironmentEvidence
    let selectedProfile: String?
    let providerID: String?
    let model: String?
    let workingDirectory: URL?
    let projectConfigPaths: [URL]
    let projectContextKnown: Bool
    let configurationOverrides: [String: String]
    let hasUnsupportedConfigurationOverrides: Bool
}

enum CodexHomeEnvironmentEvidence: String, Equatable {
    case notRunning
    case explicit
    case defaulted
    case unreadable
    case unsafe
}

struct CodexProcessSnapshot: Equatable {
    let arguments: [String]
    let codexHome: URL?
    let codexHomeEvidence: CodexHomeEnvironmentEvidence
}

enum CodexProcessSnapshotParser {
    static func parse(
        _ data: Data,
        homeDirectory: URL = FileManager.default
            .homeDirectoryForCurrentUser
    ) -> CodexProcessSnapshot? {
        guard data.count > MemoryLayout<Int32>.size else {
            return nil
        }
        var argcValue = Int32.zero
        withUnsafeMutableBytes(of: &argcValue) { destination in
            _ = data.copyBytes(
                to: destination,
                from: 0..<MemoryLayout<Int32>.size
            )
        }
        let argc = Int(argcValue)
        guard argc > 0, argc < 10_000 else { return nil }
        let bytes = [UInt8](data)
        var index = MemoryLayout<Int32>.size

        // KERN_PROCARGS2 begins with executable path, padding, then argv.
        while index < bytes.count, bytes[index] != 0 {
            index += 1
        }
        while index < bytes.count, bytes[index] == 0 {
            index += 1
        }

        var arguments: [String] = []
        while index < bytes.count, arguments.count < argc {
            let value = readString(bytes, index: &index)
            if !value.isEmpty { arguments.append(value) }
            skipZeros(bytes, index: &index)
        }
        guard arguments.count == argc else { return nil }

        var codexHomeValues: [String] = []
        let codexHomePrefix = Array("CODEX_HOME=".utf8)
        while index < bytes.count {
            skipZeros(bytes, index: &index)
            guard index < bytes.count else { break }
            let start = index
            while index < bytes.count, bytes[index] != 0 {
                index += 1
            }
            let end = index
            if end - start >= codexHomePrefix.count,
               bytes[start..<(start + codexHomePrefix.count)]
                .elementsEqual(codexHomePrefix) {
                let valueStart = start + codexHomePrefix.count
                codexHomeValues.append(
                    String(
                        decoding: bytes[valueStart..<end],
                        as: UTF8.self
                    )
                )
            }
        }
        guard codexHomeValues.count <= 1 else {
            return CodexProcessSnapshot(
                arguments: arguments,
                codexHome: nil,
                codexHomeEvidence: .unsafe
            )
        }
        guard let rawCodexHome = codexHomeValues.first else {
            return CodexProcessSnapshot(
                arguments: arguments,
                codexHome: homeDirectory
                    .appendingPathComponent(
                        ".codex",
                        isDirectory: true
                    )
                    .standardizedFileURL,
                codexHomeEvidence: .defaulted
            )
        }
        guard !rawCodexHome.isEmpty,
              rawCodexHome.count <= 4_096,
              !rawCodexHome.contains("\n"),
              !rawCodexHome.contains("\r") else {
            return CodexProcessSnapshot(
                arguments: arguments,
                codexHome: nil,
                codexHomeEvidence: .unsafe
            )
        }
        let expanded = NSString(
            string: rawCodexHome
        ).expandingTildeInPath
        guard NSString(string: expanded).isAbsolutePath else {
            return CodexProcessSnapshot(
                arguments: arguments,
                codexHome: nil,
                codexHomeEvidence: .unsafe
            )
        }
        let candidate = URL(
            fileURLWithPath: expanded,
            isDirectory: true
        ).standardizedFileURL
        let home = homeDirectory.standardizedFileURL
        guard candidate.path == home.path
                || candidate.path.hasPrefix(home.path + "/") else {
            return CodexProcessSnapshot(
                arguments: arguments,
                codexHome: nil,
                codexHomeEvidence: .unsafe
            )
        }
        return CodexProcessSnapshot(
            arguments: arguments,
            codexHome: candidate,
            codexHomeEvidence: .explicit
        )
    }

    private static func readString(
        _ bytes: [UInt8],
        index: inout Int
    ) -> String {
        let start = index
        while index < bytes.count, bytes[index] != 0 {
            index += 1
        }
        return String(
            decoding: bytes[start..<index],
            as: UTF8.self
        )
    }

    private static func skipZeros(
        _ bytes: [UInt8],
        index: inout Int
    ) {
        while index < bytes.count, bytes[index] == 0 {
            index += 1
        }
    }
}

enum CodexProcessArgumentParser {
    static func parse(
        _ arguments: [String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CodexDiscoveredProcessContext {
        var safeArguments: [String] = []
        var profile: String?
        var provider: String?
        var model: String?
        var projectConfigs: [URL] = []
        var configurationOverrides: [String: String] = [:]
        var hasUnsupportedConfigurationOverrides = false
        let recognized: [String: WritableKeyPath<ParsedValues, String?>] = [
            "--profile": \.profile,
            "--model-provider": \.provider,
            "--provider": \.provider,
            "--model": \.model,
            "--config-path": \.configPath,
        ]
        var values = ParsedValues()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--config" || argument == "-c",
               index + 1 < arguments.count {
                parseConfigurationOverride(
                    arguments[index + 1],
                    into: &configurationOverrides,
                    hasUnsupported: &hasUnsupportedConfigurationOverrides
                )
                safeArguments.append(argument)
                safeArguments.append(safeConfigurationOverride(arguments[index + 1]))
                index += 2
                continue
            }
            if argument.hasPrefix("--config=") {
                let value = String(argument.dropFirst("--config=".count))
                parseConfigurationOverride(
                    value,
                    into: &configurationOverrides,
                    hasUnsupported: &hasUnsupportedConfigurationOverrides
                )
                safeArguments.append("--config=\(safeConfigurationOverride(value))")
                index += 1
                continue
            }
            if argument.lowercased().contains("key")
                || argument.lowercased().contains("token")
                || argument.lowercased().contains("auth") {
                safeArguments.append("<敏感参数已跳过>")
                index += 1
                continue
            }
            var matched = false
            for (flag, keyPath) in recognized {
                if argument == flag, index + 1 < arguments.count {
                    let value = arguments[index + 1]
                    values[keyPath: keyPath] = value
                    safeArguments.append(flag)
                    safeArguments.append(safeValue(value))
                    index += 2
                    matched = true
                    break
                }
                if argument.hasPrefix(flag + "=") {
                    let value = String(argument.dropFirst(flag.count + 1))
                    values[keyPath: keyPath] = value
                    safeArguments.append("\(flag)=\(safeValue(value))")
                    index += 1
                    matched = true
                    break
                }
            }
            if matched { continue }
            index += 1
        }
        profile = values.profile
        provider = values.provider
        model = values.model
        if let path = values.configPath {
            let expanded = NSString(string: path).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            let home = homeDirectory.standardizedFileURL.path
            if url.path == home || url.path.hasPrefix(home + "/") {
                projectConfigs.append(url)
            }
        }
        return CodexDiscoveredProcessContext(
            processIdentifier: nil,
            arguments: safeArguments,
            codexHome: nil,
            codexHomeEvidence: .notRunning,
            selectedProfile: profile,
            providerID: provider,
            model: model,
            workingDirectory: nil,
            projectConfigPaths: projectConfigs,
            projectContextKnown: false,
            configurationOverrides: configurationOverrides,
            hasUnsupportedConfigurationOverrides:
                hasUnsupportedConfigurationOverrides
        )
    }

    private struct ParsedValues {
        var profile: String?
        var provider: String?
        var model: String?
        var configPath: String?
    }

    private static func safeValue(_ value: String) -> String {
        let lower = value.lowercased()
        if lower.contains("key") || lower.contains("token") || lower.contains("auth") {
            return "<敏感值已跳过>"
        }
        return String(value.prefix(300))
    }

    private static let safeOverrideKeys: Set<String> = [
        "model",
        "model_provider",
        "model_reasoning_effort",
        "model_context_window",
        "model_auto_compact_token_limit",
    ]

    private static func parseConfigurationOverride(
        _ raw: String,
        into values: inout [String: String],
        hasUnsupported: inout Bool
    ) {
        guard let equals = raw.firstIndex(of: "=") else {
            hasUnsupported = true
            return
        }
        let key = raw[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = raw[raw.index(after: equals)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard safeOverrideKeys.contains(key) else {
            hasUnsupported = true
            return
        }
        values[key] = unquote(value)
    }

    private static func safeConfigurationOverride(_ raw: String) -> String {
        guard let equals = raw.firstIndex(of: "=") else {
            return "<未识别覆盖已跳过>"
        }
        let key = raw[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
        guard safeOverrideKeys.contains(key) else {
            return "<未识别覆盖已跳过>"
        }
        let value = raw[raw.index(after: equals)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(key)=\(safeValue(unquote(value)))"
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              let last = value.last,
              (first == "\"" && last == "\"")
                || (first == "'" && last == "'") else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }
}

enum CodexRuntimeProcessDiscovery {
    @MainActor
    static func discover() -> CodexDiscoveredProcessContext {
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: CodexApplicationLocator.bundleIdentifier
        ).first else {
            return CodexDiscoveredProcessContext(
                processIdentifier: nil,
                arguments: [],
                codexHome: nil,
                codexHomeEvidence: .notRunning,
                selectedProfile: nil,
                providerID: nil,
                model: nil,
                workingDirectory: nil,
                projectConfigPaths: [],
                projectContextKnown: true,
                configurationOverrides: [:],
                hasUnsupportedConfigurationOverrides: false
            )
        }
        let snapshot = processSnapshot(
            processIdentifier: application.processIdentifier
        )
        let parsed = CodexProcessArgumentParser.parse(
            snapshot?.arguments ?? []
        )
        let workingDirectory = processWorkingDirectory(
            processIdentifier: application.processIdentifier
        )
        let discoveredProjectConfigs = workingDirectory.map {
            CodexProjectConfigurationDiscovery.discover(from: $0)
        }
        return CodexDiscoveredProcessContext(
            processIdentifier: application.processIdentifier,
            arguments: parsed.arguments,
            codexHome: snapshot?.codexHome,
            codexHomeEvidence:
                snapshot?.codexHomeEvidence ?? .unreadable,
            selectedProfile: parsed.selectedProfile,
            providerID: parsed.providerID,
            model: parsed.model,
            workingDirectory: workingDirectory,
            projectConfigPaths: discoveredProjectConfigs
                ?? parsed.projectConfigPaths,
            projectContextKnown: workingDirectory != nil
                || !parsed.projectConfigPaths.isEmpty,
            configurationOverrides: parsed.configurationOverrides,
            hasUnsupportedConfigurationOverrides:
                parsed.hasUnsupportedConfigurationOverrides
        )
    }

    private static func processSnapshot(
        processIdentifier: pid_t
    ) -> CodexProcessSnapshot? {
        var mib = [CTL_KERN, KERN_PROCARGS2, processIdentifier]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        var data = Data(count: size)
        let status = data.withUnsafeMutableBytes { buffer in
            sysctl(&mib, 3, buffer.baseAddress, &size, nil, 0)
        }
        guard status == 0 else { return nil }
        if size < data.count { data.removeSubrange(size..<data.count) }
        return CodexProcessSnapshotParser.parse(data)
    }

    private static func processWorkingDirectory(
        processIdentifier: pid_t
    ) -> URL? {
        var info = proc_vnodepathinfo()
        let expectedSize = MemoryLayout<proc_vnodepathinfo>.size
        let result = proc_pidinfo(
            processIdentifier,
            PROC_PIDVNODEPATHINFO,
            0,
            &info,
            Int32(expectedSize)
        )
        guard result == expectedSize else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self,
                capacity: Int(MAXPATHLEN)
            ) {
                String(cString: $0)
            }
        }
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
    }
}

enum CodexProjectConfigurationDiscovery {
    static func discover(from workingDirectory: URL) -> [URL] {
        let fileManager = FileManager.default
        let root = projectRoot(from: workingDirectory)
        var cursor = workingDirectory.standardizedFileURL
        var directories: [URL] = []
        var seen = Set<String>()
        for _ in 0..<256 {
            guard seen.insert(cursor.path).inserted else { break }
            directories.append(cursor)
            if cursor.path == root.path { break }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }
        return directories.reversed().compactMap { directory in
            let candidate = directory
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("config.toml")
            guard fileManager.fileExists(atPath: candidate.path),
                  let values = try? candidate.resourceValues(
                      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                return nil
            }
            return candidate.standardizedFileURL
        }
    }

    static func projectRoot(from workingDirectory: URL) -> URL {
        let fileManager = FileManager.default
        let original = workingDirectory.standardizedFileURL
        var cursor = original
        var seen = Set<String>()
        for _ in 0..<256 {
            guard seen.insert(cursor.path).inserted else { return original }
            if fileManager.fileExists(
                atPath: cursor.appendingPathComponent(".git").path
            ) {
                return cursor
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { return original }
            cursor = parent
        }
        return original
    }
}

enum CodexProfileLocator {
    static func configurationURL(
        profile: String?,
        codexHome: URL
    ) -> URL? {
        guard let profile,
              !profile.isEmpty,
              profile.count <= 100,
              profile != ".",
              profile != "..",
              profile.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0)
                      || "._-".unicodeScalars.contains($0)
              }) else {
            return nil
        }
        return codexHome.appendingPathComponent(
            "\(profile).config.toml",
            isDirectory: false
        ).standardizedFileURL
    }
}

enum CodexSchemaCompatibilityCatalog {
    static let verifiedAppVersion =
        CodexProviderSchemaCatalog.current.appVersion
    static let verifiedAppBuild =
        CodexProviderSchemaCatalog.current.appBuild

    static func inspect(applicationURL: URL?) -> CodexSchemaCompatibility {
        guard let applicationURL,
              let bundle = Bundle(url: applicationURL) else {
            return CodexSchemaCompatibility(
                state: .unverified,
                appVersion: nil,
                appBuild: nil,
                adapterVersion:
                    AppReleaseMetadata.version,
                evidence: "未找到可读取版本的Codex Desktop"
            )
        }
        let version = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let snapshot = CodexCompatibilityRegistry.snapshot(
            applicationURL: applicationURL
        ),
           snapshot.appVersion == version,
           snapshot.appBuild == build {
            let verified = snapshot.allowsWrites
            return CodexSchemaCompatibility(
                state: verified ? .verified : .unverified,
                appVersion: version,
                appBuild: build,
                adapterVersion: AppReleaseMetadata.version,
                evidence: snapshot.evidenceSummary
            )
        }
        let contract = CodexProviderSchemaCatalog.contract(
            appVersion: version,
            appBuild: build
        )
        let verified = contract != nil
        return CodexSchemaCompatibility(
            state: verified ? .verified : .unverified,
            appVersion: version,
            appBuild: build,
            adapterVersion: AppReleaseMetadata.version,
            evidence: verified
                ? "配置Schema \(contract?.schemaID ?? "unknown") 已在自动夹具和本机只读版本检查中匹配"
                : "当前版本未进入适配器验证清单；保持只读"
        )
    }
}

enum ConfigurationFileOccupancyInspector {
    static func isExclusivelyLocked(_ url: URL) -> Bool? {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK ? true : nil
    }
}
