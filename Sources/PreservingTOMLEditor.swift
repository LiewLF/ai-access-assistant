// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum PreservingTOMLEditor {
    private static let rootKeys = [
        "model", "model_provider", "model_reasoning_effort",
        "model_context_window", "model_auto_compact_token_limit",
    ]

    static func plan(
        original: String,
        profile: CodexRelayProfile,
        allowLegacyBearerRemoval: Bool = false
    ) throws -> CodexConfigurationPlan {
        guard !profile.id.isEmpty, !profile.defaultModel.isEmpty,
              CodexPlusPlusAdapter.isAllowedBaseURL(profile.baseURL) else {
            throw CodexControlError.invalidProfile
        }
        let lineEnding = original.contains("\r\n") ? "\r\n" : "\n"
        var lines = original.components(separatedBy: lineEnding)
        if lines.last == "" { lines.removeLast() }
        let firstTable = try validateAndFindFirstTable(lines)
        var seen: [String: Int] = [:]
        for index in 0..<firstTable {
            guard let key = rootKey(in: lines[index]), rootKeys.contains(key) else { continue }
            seen[key, default: 0] += 1
            if seen[key, default: 0] > 1 { throw CodexControlError.duplicateManagedKey(key) }
        }

        let providerID = profile.providerID ?? providerIdentifier(profile.id)
        var managedValues: [(String, String)] = [
            ("model", quoted(profile.defaultModel)),
            ("model_provider", quoted(providerID)),
        ]
        if profile.reasoningEffort != .automatic {
            managedValues.append(("model_reasoning_effort", quoted(reasoningValue(profile.reasoningEffort))))
        }
        if let contextWindow = profile.contextWindow {
            managedValues.append(("model_context_window", String(contextWindow)))
        }
        if let compactLimit = profile.autoCompactTokenLimit {
            managedValues.append(("model_auto_compact_token_limit", String(compactLimit)))
        }

        let oldValues = Dictionary(uniqueKeysWithValues: rootKeys.map { key in
            (key, valueForRootKey(key, lines: lines, before: firstTable) ?? "未设置")
        })
        let desiredRootValues = Dictionary(uniqueKeysWithValues: managedValues)
        let root = rewritingRoot(
            Array(lines.prefix(firstTable)),
            desiredValues: desiredRootValues
        )
        let managedRootLines = managedValues.map { "\($0.0) = \($0.1)" }

        var tables = Array(lines.dropFirst(firstTable))
        let existingDocument = try TOMLSemanticEngine.parse(original)
        let managedProviderIDs = Set(existingDocument.providerIDs.filter { $0.hasPrefix("ai_access_") })
            .union([providerID])
        tables = try removingManagedProviderTables(tables, managedProviderIDs: managedProviderIDs)
        while tables.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { tables.removeFirst() }

        let providerLines = [
            "[model_providers.\(providerID)]",
            "name = \(quoted(profile.name))",
            "base_url = \(quoted(cleanBaseURL(profile.baseURL)))",
            "wire_api = \(quoted(wireValue(profile.wireProtocol)))",
        ]
        let authenticationLines = [
            "[model_providers.\(providerID).auth]",
        ] + PersistentCredentialBridge.commandAuthenticationLines(
            profileID: profile.id
        )
        var output = root
        while output.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            output.removeLast()
        }
        output.append("")
        output.append(contentsOf: providerLines)
        output.append("")
        output.append(contentsOf: authenticationLines)
        if !tables.isEmpty {
            output.append("")
            output.append(contentsOf: tables)
        }
        let proposed = output.joined(separator: lineEnding) + lineEnding
        var allowedProviderFields = TOMLChangePolicy.providerFields
        allowedProviderFields.insert("auth")
        allowedProviderFields.insert("requires_openai_auth")
        if allowLegacyBearerRemoval {
            allowedProviderFields.insert("experimental_bearer_token")
        }
        let policy = TOMLChangePolicy(
            managedProviderIDs: managedProviderIDs,
            allowedProviderFields: allowedProviderFields
        )
        let semanticChanges = try TOMLSemanticEngine.validateChanges(
            before: original,
            after: proposed,
            policy: policy
        )
        if semanticChanges.contains(where: {
            TOMLSemanticEngine.decodePath($0.path).last == "experimental_bearer_token"
                && $0.kind != .missing
        }) {
            throw TOMLSemanticError.unmanagedChange(
                semanticChanges.filter {
                    TOMLSemanticEngine.decodePath($0.path).last == "experimental_bearer_token"
                }
            )
        }
        let changes = managedValues.map { ($0.0, oldValues[$0.0] ?? "未设置", $0.1) }
            + (profile.reasoningEffort == .automatic
               ? [("model_reasoning_effort", oldValues["model_reasoning_effort"] ?? "未设置", "移除，使用模型默认")]
               : [])
            + [("model_providers.\(providerID)", "未设置或旧助手段", "新增安全供应商段")]
        let manualBlock = (
            managedRootLines
                + [""]
                + providerLines
                + [""]
                + authenticationLines
        ).joined(separator: "\n")
        return CodexConfigurationPlan(
            original: original,
            proposed: proposed,
            managedChanges: changes,
            manualBlock: manualBlock
        )
    }

    static func validate(_ text: String) throws {
        _ = try validateAndFindFirstTable(text.components(separatedBy: "\n"))
    }

    static func officialOverlay(from original: String) throws -> OfficialOverlay {
        let lines = original.components(separatedBy: "\n")
        let firstTable = try validateAndFindFirstTable(lines)
        var values: [String: String] = [:]
        for key in rootKeys {
            if let value = valueForRootKey(key, lines: lines, before: firstTable) {
                values[key] = value
            }
        }
        return OfficialOverlay(
            id: "official",
            state: .candidate,
            rootValues: values,
            managedProviderIDs: [],
            source: "首次官方基线",
            lastVerifiedAt: nil,
            codexVersion: nil,
            adapterVersion: AppReleaseMetadata.version
        )
    }

    static func planOfficial(
        original: String,
        overlay: OfficialOverlay,
        removingProviderIDs: Set<String>
    ) throws -> CodexConfigurationPlan {
        let lineEnding = original.contains("\r\n") ? "\r\n" : "\n"
        var lines = original.components(separatedBy: lineEnding)
        if lines.last == "" { lines.removeLast() }
        let firstTable = try validateAndFindFirstTable(lines)
        let oldValues = Dictionary(uniqueKeysWithValues: rootKeys.map { key in
            (key, valueForRootKey(key, lines: lines, before: firstTable) ?? "未设置")
        })
        let restoredRootLines = rootKeys.compactMap { key in
            overlay.rootValues[key].map { "\(key) = \($0)" }
        }
        let root = rewritingRoot(
            Array(lines.prefix(firstTable)),
            desiredValues: overlay.rootValues
        )

        var tables = Array(lines.dropFirst(firstTable))
        tables = try removingManagedProviderTables(tables, managedProviderIDs: removingProviderIDs)
        while tables.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { tables.removeFirst() }
        var output = root
        if !tables.isEmpty {
            if !output.isEmpty { output.append("") }
            output.append(contentsOf: tables)
        }
        let proposed = output.joined(separator: lineEnding) + lineEnding
        var allowedProviderFields =
            TOMLChangePolicy.providerFields
        allowedProviderFields.insert("auth")
        allowedProviderFields.insert("requires_openai_auth")
        allowedProviderFields.insert(
            "experimental_bearer_token"
        )
        let policy = TOMLChangePolicy(
            managedProviderIDs: removingProviderIDs,
            allowedProviderFields:
                allowedProviderFields
        )
        _ = try TOMLSemanticEngine.validateChanges(before: original, after: proposed, policy: policy)
        let changes = rootKeys.map { key in
            (key, oldValues[key] ?? "未设置", overlay.rootValues[key] ?? "移除")
        }
        return CodexConfigurationPlan(
            original: original,
            proposed: proposed,
            managedChanges: changes,
            manualBlock: restoredRootLines.joined(separator: "\n")
        )
    }

    private static func validateAndFindFirstTable(_ lines: [String]) throws -> Int {
        var first = lines.count
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let tableToken = trimmed.split(separator: "#", maxSplits: 1).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? trimmed
            if tableToken.hasPrefix("[") {
                let validTable = tableToken.hasPrefix("[[") ? tableToken.hasSuffix("]]") : tableToken.hasSuffix("]")
                guard validTable else {
                    throw CodexControlError.malformedTOML(index + 1)
                }
                first = min(first, index)
            }
            if trimmed.contains("=") && !trimmed.hasPrefix("#") {
                let pieces = trimmed.split(separator: "=", maxSplits: 1)
                guard pieces.count == 2, !pieces[0].trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw CodexControlError.malformedTOML(index + 1)
                }
            }
        }
        return first
    }

    private static func removingManagedProviderTables(
        _ lines: [String],
        managedProviderIDs: Set<String>
    ) throws -> [String] {
        var result: [String] = []
        var skipping = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let tableToken = trimmed.split(separator: "#", maxSplits: 1).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? trimmed
            if tableToken.hasPrefix("[") {
                guard tableToken.hasSuffix("]") else { throw CodexControlError.malformedTOML(index + 1) }
                let table = tableToken.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                let components = table.split(separator: ".").map(String.init)
                skipping = components.count >= 2
                    && components[0] == "model_providers"
                    && managedProviderIDs.contains(components[1])
            }
            if !skipping { result.append(line) }
        }
        return result
    }

    private static func rootKey(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix("["),
              let equals = trimmed.firstIndex(of: "=") else { return nil }
        return String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
    }

    private static func rewritingRoot(
        _ original: [String],
        desiredValues: [String: String]
    ) -> [String] {
        var pending = desiredValues
        var output: [String] = []
        for line in original {
            guard let key = rootKey(in: line), rootKeys.contains(key) else {
                output.append(line)
                continue
            }
            guard let value = pending.removeValue(forKey: key) else {
                continue
            }
            output.append(replacingAssignmentValue(in: line, with: value))
        }
        if !pending.isEmpty {
            while output.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                output.removeLast()
            }
            if !output.isEmpty { output.append("") }
            for key in rootKeys {
                if let value = pending[key] {
                    output.append("\(key) = \(value)")
                }
            }
        }
        return output
    }

    private static func replacingAssignmentValue(in line: String, with value: String) -> String {
        guard let equals = line.firstIndex(of: "=") else { return line }
        let afterEquals = line.index(after: equals)
        let tail = String(line[afterEquals...])
        let leading = tail.prefix { $0 == " " || $0 == "\t" }
        let remainder = String(tail.dropFirst(leading.count))
        var quoted = false
        var literal = false
        var escaped = false
        var commentIndex: String.Index?
        for index in remainder.indices {
            let character = remainder[index]
            if quoted {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    quoted = false
                }
                continue
            }
            if literal {
                if character == "'" { literal = false }
                continue
            }
            if character == "\"" { quoted = true }
            else if character == "'" { literal = true }
            else if character == "#" {
                commentIndex = index
                break
            }
        }
        var comment = ""
        if let commentIndex {
            let prefix = remainder[..<commentIndex]
            let spacing = prefix.reversed().prefix { $0 == " " || $0 == "\t" }.reversed()
            comment = String(spacing) + remainder[commentIndex...]
        }
        return String(line[...equals]) + leading + value + comment
    }

    private static func valueForRootKey(_ key: String, lines: [String], before: Int) -> String? {
        for line in lines.prefix(before) where rootKey(in: line) == key {
            guard let equals = line.firstIndex(of: "=") else { continue }
            return String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func providerIdentifier(_ value: String) -> String {
        if value.hasPrefix("ai_access_") { return value }
        let safe = value.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "_"
        }
        return "ai_access_" + String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private static func cleanBaseURL(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func wireValue(_ value: RelayWireProtocol) -> String {
        switch value {
        case .responses: return "responses"
        case .chatCompletions: return "chat"
        case .anthropicMessages: return "anthropic"
        }
    }

    private static func reasoningValue(_ value: ReasoningEffort) -> String {
        switch value {
        case .automatic: return "medium"
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh: return "xhigh"
        case .max: return "max"
        case .ultra: return "ultra"
        }
    }
}
