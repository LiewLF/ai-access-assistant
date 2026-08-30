import CryptoKit
import Foundation

enum TOMLSemanticError: LocalizedError, Equatable {
    case malformed(line: Int, reason: String)
    case duplicate(path: String, line: Int)
    case unsupported(line: Int, reason: String)
    case unmanagedChange([TOMLSemanticChange])

    var errorDescription: String? {
        switch self {
        case let .malformed(line, reason):
            return "TOML第\(line)行无法解析：\(reason)"
        case let .duplicate(path, line):
            return "TOML第\(line)行重复定义：\(path)"
        case let .unsupported(line, reason):
            return "TOML第\(line)行使用尚未安全支持的语法：\(reason)"
        case let .unmanagedChange(changes):
            return "检测到\(changes.count)项非托管配置变化"
        }
    }
}

enum TOMLSemanticChangeKind: String, Codable {
    case missing
    case added
    case changed
}

struct TOMLSemanticChange: Codable, Equatable {
    let path: String
    let before: String?
    let after: String?
    let kind: TOMLSemanticChangeKind
}

struct TOMLSemanticDocument: Equatable {
    let leaves: [String: String]
    let providerIDs: [String]
    let semanticHash: String
    let source: String

    func rootString(_ key: String) -> String? {
        let path = TOMLSemanticEngine.path([key])
        guard let value = leaves[path], value.hasPrefix("string:") else { return nil }
        let payload = String(value.dropFirst("string:".count))
        guard let data = payload.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String else {
            return nil
        }
        return decoded
    }

    func rootInteger(_ key: String) -> Int? {
        let path = TOMLSemanticEngine.path([key])
        guard let value = leaves[path], value.hasPrefix("integer:") else { return nil }
        let payload = value.dropFirst("integer:".count).replacingOccurrences(of: "_", with: "")
        return Int(payload)
    }

    func string(at components: [String]) -> String? {
        let path = TOMLSemanticEngine.path(components)
        guard let value = leaves[path], value.hasPrefix("string:") else { return nil }
        let payload = String(value.dropFirst("string:".count))
        guard let data = payload.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(
                  with: data,
                  options: [.fragmentsAllowed]
              ) as? String else {
            return nil
        }
        return decoded
    }

    func integer(at components: [String]) -> Int? {
        let path = TOMLSemanticEngine.path(components)
        guard let value = leaves[path], value.hasPrefix("integer:") else { return nil }
        return Int(value.dropFirst("integer:".count).replacingOccurrences(of: "_", with: ""))
    }

    func boolean(at components: [String]) -> Bool? {
        let path = TOMLSemanticEngine.path(components)
        guard let value = leaves[path], value.hasPrefix("bool:") else {
            return nil
        }
        switch value {
        case "bool:true":
            return true
        case "bool:false":
            return false
        default:
            return nil
        }
    }
}

struct TOMLChangePolicy {
    var allowedRootKeys: Set<String>
    var managedProviderIDs: Set<String>
    var allowedProviderFields: Set<String>

    static let providerRootKeys: Set<String> = [
        "model",
        "model_provider",
        "model_reasoning_effort",
        "model_verbosity",
        "model_context_window",
        "model_auto_compact_token_limit",
        "service_tier",
        "model_catalog_json",
        "web_search",
        "disable_response_storage",
    ]

    static let providerFields =
        CodexProviderSchemaCatalog.current.automaticFields

    init(
        allowedRootKeys: Set<String> = TOMLChangePolicy.providerRootKeys,
        managedProviderIDs: Set<String>,
        allowedProviderFields: Set<String> = TOMLChangePolicy.providerFields
    ) {
        self.allowedRootKeys = allowedRootKeys
        self.managedProviderIDs = managedProviderIDs
        self.allowedProviderFields = allowedProviderFields
    }

    func allows(path: String) -> Bool {
        if allowedRootKeys.contains(where: {
            TOMLSemanticEngine.path([$0]) == path
        }) {
            return true
        }
        for providerID in managedProviderIDs {
            for field in allowedProviderFields {
                let prefix = TOMLSemanticEngine.path(["model_providers", providerID, field])
                if path == prefix || path.hasPrefix(prefix + "/") {
                    return true
                }
            }
        }
        return false
    }
}

enum TOMLSemanticEngine {
    private struct Statement {
        let text: String
        let line: Int
    }

    static func parse(_ text: String) throws -> TOMLSemanticDocument {
        let statements = try splitStatements(text)
        var currentTable: [String] = []
        var leaves: [String: String] = [:]
        var tablePaths = Set<String>()
        var tableValueCount: [String: Int] = [:]
        var arrayTableCounts: [String: Int] = [:]
        var providerIDs = Set<String>()

        for statement in statements {
            let cleaned = stripTrailingComment(statement.text).trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty { continue }
            if cleaned.hasPrefix("[[") {
                guard cleaned.hasSuffix("]]") else {
                    throw TOMLSemanticError.malformed(line: statement.line, reason: "数组表缺少结束括号")
                }
                let body = String(cleaned.dropFirst(2).dropLast(2))
                let base = try parseKeyPath(body, line: statement.line)
                let baseKey = path(base)
                let index = arrayTableCounts[baseKey, default: 0]
                arrayTableCounts[baseKey] = index + 1
                currentTable = base + ["[\(index)]"]
                let tableKey = path(currentTable)
                tablePaths.insert(tableKey)
                tableValueCount[tableKey] = 0
                collectProviderID(currentTable, into: &providerIDs)
                continue
            }
            if cleaned.hasPrefix("[") {
                guard cleaned.hasSuffix("]"), !cleaned.hasPrefix("[[") else {
                    throw TOMLSemanticError.malformed(line: statement.line, reason: "表头格式错误")
                }
                let body = String(cleaned.dropFirst().dropLast())
                currentTable = try parseKeyPath(body, line: statement.line)
                let tableKey = path(currentTable)
                if tablePaths.contains(tableKey) {
                    throw TOMLSemanticError.duplicate(path: tableKey, line: statement.line)
                }
                tablePaths.insert(tableKey)
                tableValueCount[tableKey] = 0
                collectProviderID(currentTable, into: &providerIDs)
                continue
            }

            guard let equals = topLevelEquals(in: cleaned) else {
                throw TOMLSemanticError.malformed(line: statement.line, reason: "缺少等号")
            }
            let keyText = String(cleaned[..<equals])
            let valueText = String(cleaned[cleaned.index(after: equals)...])
            let keyPath = try parseKeyPath(keyText, line: statement.line)
            guard !keyPath.isEmpty else {
                throw TOMLSemanticError.malformed(line: statement.line, reason: "键为空")
            }
            let fullPath = currentTable + keyPath
            try flatten(
                valueText.trimmingCharacters(in: .whitespacesAndNewlines),
                at: fullPath,
                line: statement.line,
                leaves: &leaves
            )
            if !currentTable.isEmpty {
                tableValueCount[path(currentTable), default: 0] += 1
            }
        }

        for table in tablePaths where tableValueCount[table, default: 0] == 0 {
            let marker = table + "/<empty-table>"
            if leaves[marker] == nil { leaves[marker] = "empty-table" }
        }
        let semanticHash = sha256(Data(canonicalLeaves(leaves).utf8))
        return TOMLSemanticDocument(
            leaves: leaves,
            providerIDs: providerIDs.sorted(),
            semanticHash: semanticHash,
            source: text
        )
    }

    static func diff(
        before: TOMLSemanticDocument,
        after: TOMLSemanticDocument
    ) -> [TOMLSemanticChange] {
        let keys = Set(before.leaves.keys).union(after.leaves.keys)
        return keys.sorted().compactMap { key in
            let old = before.leaves[key]
            let new = after.leaves[key]
            if old == new { return nil }
            if old == nil {
                return TOMLSemanticChange(path: key, before: nil, after: new, kind: .added)
            }
            if new == nil {
                return TOMLSemanticChange(path: key, before: old, after: nil, kind: .missing)
            }
            return TOMLSemanticChange(path: key, before: old, after: new, kind: .changed)
        }
    }

    static func validateChanges(
        before: String,
        after: String,
        policy: TOMLChangePolicy
    ) throws -> [TOMLSemanticChange] {
        let changes = diff(before: try parse(before), after: try parse(after))
        let blocked = changes.filter { !policy.allows(path: $0.path) }
        if !blocked.isEmpty {
            throw TOMLSemanticError.unmanagedChange(blocked)
        }
        return changes
    }

    static func unmanagedLeaves(
        in document: TOMLSemanticDocument,
        policy: TOMLChangePolicy
    ) -> [String: String] {
        document.leaves.filter { !policy.allows(path: $0.key) }
    }

    static func path(_ components: [String]) -> String {
        components.map(encodePathComponent).joined(separator: "/")
    }

    static func decodePath(_ value: String) -> [String] {
        value.split(separator: "/", omittingEmptySubsequences: false).compactMap { token in
            guard let data = String(token).data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(
                      with: data,
                      options: [.fragmentsAllowed]
                  ) as? String else {
                return String(token)
            }
            return value
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func splitStatements(_ text: String) throws -> [Statement] {
        let lines = text.components(separatedBy: .newlines)
        var statements: [Statement] = []
        var buffer = ""
        var startLine = 1
        var scanner = BalanceScanner()
        for (offset, line) in lines.enumerated() {
            let number = offset + 1
            if buffer.isEmpty { startLine = number }
            if !buffer.isEmpty { buffer.append("\n") }
            buffer.append(line)
            scanner.consume(line)
            if scanner.invalid {
                throw TOMLSemanticError.malformed(line: number, reason: "字符串或括号不平衡")
            }
            if scanner.isComplete {
                statements.append(Statement(text: buffer, line: startLine))
                buffer = ""
                scanner = BalanceScanner()
            }
        }
        if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw TOMLSemanticError.malformed(line: startLine, reason: "多行值未结束")
        }
        return statements
    }

    private struct BalanceScanner {
        var square = 0
        var curly = 0
        var basic = false
        var literal = false
        var tripleBasic = false
        var tripleLiteral = false
        var escaped = false
        var invalid = false

        var isComplete: Bool {
            square == 0 && curly == 0 && !basic && !literal && !tripleBasic && !tripleLiteral
        }

        mutating func consume(_ line: String) {
            let chars = Array(line)
            var index = 0
            while index < chars.count {
                let char = chars[index]
                let triple = index + 2 < chars.count
                    && chars[index] == chars[index + 1]
                    && chars[index] == chars[index + 2]
                if tripleBasic {
                    if char == "\"", triple {
                        tripleBasic = false
                        index += 3
                        continue
                    }
                    index += 1
                    continue
                }
                if tripleLiteral {
                    if char == "'", triple {
                        tripleLiteral = false
                        index += 3
                        continue
                    }
                    index += 1
                    continue
                }
                if basic {
                    if escaped {
                        escaped = false
                    } else if char == "\\" {
                        escaped = true
                    } else if char == "\"" {
                        basic = false
                    }
                    index += 1
                    continue
                }
                if literal {
                    if char == "'" { literal = false }
                    index += 1
                    continue
                }
                if char == "#" { break }
                if char == "\"", triple {
                    tripleBasic = true
                    index += 3
                    continue
                }
                if char == "'", triple {
                    tripleLiteral = true
                    index += 3
                    continue
                }
                if char == "\"" { basic = true }
                else if char == "'" { literal = true }
                else if char == "[" { square += 1 }
                else if char == "]" { square -= 1 }
                else if char == "{" { curly += 1 }
                else if char == "}" { curly -= 1 }
                if square < 0 || curly < 0 { invalid = true }
                index += 1
            }
            escaped = false
        }
    }

    private static func stripTrailingComment(_ text: String) -> String {
        let chars = Array(text)
        var basic = false
        var literal = false
        var tripleBasic = false
        var tripleLiteral = false
        var escaped = false
        var index = 0
        while index < chars.count {
            let char = chars[index]
            let triple = index + 2 < chars.count
                && chars[index] == chars[index + 1]
                && chars[index] == chars[index + 2]
            if tripleBasic {
                if char == "\"", triple { tripleBasic = false; index += 3; continue }
            } else if tripleLiteral {
                if char == "'", triple { tripleLiteral = false; index += 3; continue }
            } else if basic {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { basic = false }
            } else if literal {
                if char == "'" { literal = false }
            } else {
                if char == "#" { return String(chars[..<index]) }
                if char == "\"", triple { tripleBasic = true; index += 3; continue }
                if char == "'", triple { tripleLiteral = true; index += 3; continue }
                if char == "\"" { basic = true }
                else if char == "'" { literal = true }
            }
            index += 1
        }
        return text
    }

    private static func topLevelEquals(in text: String) -> String.Index? {
        var square = 0
        var curly = 0
        var basic = false
        var literal = false
        var escaped = false
        for index in text.indices {
            let char = text[index]
            if basic {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { basic = false }
                continue
            }
            if literal {
                if char == "'" { literal = false }
                continue
            }
            if char == "\"" { basic = true }
            else if char == "'" { literal = true }
            else if char == "[" { square += 1 }
            else if char == "]" { square -= 1 }
            else if char == "{" { curly += 1 }
            else if char == "}" { curly -= 1 }
            else if char == "=", square == 0, curly == 0 { return index }
        }
        return nil
    }

    private static func parseKeyPath(_ text: String, line: Int) throws -> [String] {
        var output: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for char in text.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let activeQuote = quote {
                if escaped {
                    current.append(char)
                    escaped = false
                } else if activeQuote == "\"", char == "\\" {
                    escaped = true
                } else if char == activeQuote {
                    selfAppendKey(&output, &current)
                    quote = nil
                } else {
                    current.append(char)
                }
                continue
            }
            if char == "\"" || char == "'" {
                if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                    throw TOMLSemanticError.malformed(line: line, reason: "引号键前有未结束字符")
                }
                quote = char
            } else if char == "." {
                selfAppendKey(&output, &current)
            } else {
                current.append(char)
            }
        }
        if quote != nil {
            throw TOMLSemanticError.malformed(line: line, reason: "键的引号未结束")
        }
        selfAppendKey(&output, &current)
        if output.contains(where: \.isEmpty) {
            throw TOMLSemanticError.malformed(line: line, reason: "空键路径")
        }
        return output
    }

    private static func selfAppendKey(_ output: inout [String], _ current: inout String) {
        let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { output.append(value) }
        current = ""
    }

    private static func flatten(
        _ value: String,
        at components: [String],
        line: Int,
        leaves: inout [String: String]
    ) throws {
        guard !value.isEmpty else {
            throw TOMLSemanticError.malformed(line: line, reason: "值为空")
        }
        if value.hasPrefix("[") {
            guard value.hasSuffix("]") else {
                throw TOMLSemanticError.malformed(line: line, reason: "数组未结束")
            }
            let body = String(value.dropFirst().dropLast())
            let items = splitTopLevel(body, separator: ",")
            if items.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                try insert("empty-array", at: components + ["<empty-array>"], line: line, leaves: &leaves)
                return
            }
            for (index, item) in items.enumerated() where !item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try flatten(item.trimmingCharacters(in: .whitespacesAndNewlines), at: components + ["[\(index)]"], line: line, leaves: &leaves)
            }
            return
        }
        if value.hasPrefix("{") {
            guard value.hasSuffix("}") else {
                throw TOMLSemanticError.malformed(line: line, reason: "内联表未结束")
            }
            let body = String(value.dropFirst().dropLast())
            let fields = splitTopLevel(body, separator: ",")
            if fields.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                try insert("empty-inline-table", at: components + ["<empty-table>"], line: line, leaves: &leaves)
                return
            }
            for field in fields where !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let equals = topLevelEquals(in: field) else {
                    throw TOMLSemanticError.malformed(line: line, reason: "内联表字段缺少等号")
                }
                let key = try parseKeyPath(String(field[..<equals]), line: line)
                let nested = String(field[field.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                try flatten(nested, at: components + key, line: line, leaves: &leaves)
            }
            return
        }
        try insert(canonicalScalar(value, line: line), at: components, line: line, leaves: &leaves)
    }

    private static func canonicalScalar(_ value: String, line: Int) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("\"\"\"") && trimmed.hasSuffix("\"\"\""))
            || (trimmed.hasPrefix("'''") && trimmed.hasSuffix("'''")) {
            let inner = String(trimmed.dropFirst(3).dropLast(3))
            return "string:\(jsonString(inner))"
        }
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            let data = Data(trimmed.utf8)
            if let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String {
                return "string:\(jsonString(decoded))"
            }
            throw TOMLSemanticError.malformed(line: line, reason: "基本字符串转义错误")
        }
        if trimmed.hasPrefix("'"), trimmed.hasSuffix("'"), trimmed.count >= 2 {
            return "string:\(jsonString(String(trimmed.dropFirst().dropLast())))"
        }
        if trimmed == "true" || trimmed == "false" { return "bool:\(trimmed)" }
        let compact = trimmed.replacingOccurrences(of: "_", with: "")
        if compact.range(of: #"^[+-]?(?:0|[1-9][0-9]*|0x[0-9A-Fa-f]+|0o[0-7]+|0b[01]+)$"#, options: .regularExpression) != nil {
            return "integer:\(compact.lowercased())"
        }
        if compact.range(of: #"^[+-]?(?:[0-9]+\.[0-9]+|[0-9]+[eE][+-]?[0-9]+|inf|nan)$"#, options: .regularExpression) != nil {
            return "float:\(compact.lowercased())"
        }
        if compact.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}(?:[Tt ][0-9:.+-Zz]+)?$"#, options: .regularExpression) != nil
            || compact.range(of: #"^[0-9]{2}:[0-9]{2}:[0-9]{2}"#, options: .regularExpression) != nil {
            return "datetime:\(compact.uppercased())"
        }
        throw TOMLSemanticError.unsupported(line: line, reason: "无法判定值类型")
    }

    private static func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var square = 0
        var curly = 0
        var basic = false
        var literal = false
        var escaped = false
        for char in text {
            if basic {
                current.append(char)
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { basic = false }
                continue
            }
            if literal {
                current.append(char)
                if char == "'" { literal = false }
                continue
            }
            if char == "\"" { basic = true; current.append(char) }
            else if char == "'" { literal = true; current.append(char) }
            else if char == "[" { square += 1; current.append(char) }
            else if char == "]" { square -= 1; current.append(char) }
            else if char == "{" { curly += 1; current.append(char) }
            else if char == "}" { curly -= 1; current.append(char) }
            else if char == separator, square == 0, curly == 0 {
                result.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        result.append(current)
        return result
    }

    private static func insert(
        _ value: String,
        at components: [String],
        line: Int,
        leaves: inout [String: String]
    ) throws {
        let key = path(components)
        if leaves[key] != nil {
            throw TOMLSemanticError.duplicate(path: key, line: line)
        }
        leaves[key] = value
    }

    private static func collectProviderID(_ table: [String], into providers: inout Set<String>) {
        if table.count >= 2, table[0] == "model_providers" {
            providers.insert(table[1])
        }
    }

    private static func canonicalLeaves(_ leaves: [String: String]) -> String {
        leaves.keys.sorted().map { "\($0)=\(leaves[$0]!)" }.joined(separator: "\n")
    }

    private static func encodePathComponent(_ value: String) -> String {
        jsonString(
            value
                .replacingOccurrences(of: "~", with: "~0")
                .replacingOccurrences(of: "/", with: "~1")
        )
    }

    private static func jsonString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }
}
