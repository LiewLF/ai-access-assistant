import Foundation
import SQLite3

struct V013CPACredentialScopeBinding: Equatable, Sendable {
    let cpaCredentialAuthID: String
    let verifiedOfficialAccountScopeSHA256: String

    init(
        cpaCredentialAuthID: String,
        verifiedOfficialAccountScopeSHA256: String
    ) throws {
        guard !cpaCredentialAuthID.isEmpty,
              cpaCredentialAuthID.utf8.count <= 512 else {
            throw V013CPARawUsageStoreError.invalidBinding("CPA credential/auth ID is missing or too long")
        }
        guard Self.isSHA256(verifiedOfficialAccountScopeSHA256) else {
            throw V013CPARawUsageStoreError.invalidBinding("official account scope is not a lowercase SHA-256")
        }
        self.cpaCredentialAuthID = cpaCredentialAuthID
        self.verifiedOfficialAccountScopeSHA256 = verifiedOfficialAccountScopeSHA256
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct V013CPARawUsageRecord: Equatable, Sendable {
    let rowID: Int64?
    let cycleID: Int64?
    let expectedOfficialAccountScopeSHA256: String
    let requestedAtEpochSeconds: Int64?
    let observedAtEpochSeconds: Int64?
    let provider: String?
    let model: String?
    let alias: String?
    let serviceTier: String?
    let responseModel: String?
    let responseServiceTier: String?
    let inputTokens: Int64?
    let outputTokens: Int64?
    let reasoningTokens: Int64?
    let cacheReadTokens: Int64?
    let cacheWriteTokens: Int64?
    let totalTokens: Int64?
    let failed: Bool?
    let statusCode: Int64?
    let usedPercent: Double?
    let resetAtEpochSeconds: Int64?
    let windowMinutes: Int64?
    let secondaryUsedPercent: Double?
    let secondaryResetAtEpochSeconds: Int64?
    let secondaryWindowMinutes: Int64?
    let planType: String?
    let quotaScope: String?

    var requestedAt: Date? { Self.date(requestedAtEpochSeconds) }
    var observedAt: Date? { Self.date(observedAtEpochSeconds) }
    var resetAt: Date? { Self.date(resetAtEpochSeconds) }
    var secondaryResetAt: Date? { Self.date(secondaryResetAtEpochSeconds) }

    var hasConsistentTokenCounts: Bool {
        guard let inputTokens, let outputTokens, let reasoningTokens,
              let cacheReadTokens, let cacheWriteTokens, let totalTokens,
              [inputTokens, outputTokens, reasoningTokens, cacheReadTokens,
               cacheWriteTokens, totalTokens].allSatisfy({ $0 >= 0 }) else { return false }
        let total = inputTokens.addingReportingOverflow(outputTokens)
        let cached = cacheReadTokens.addingReportingOverflow(cacheWriteTokens)
        return !total.overflow && !cached.overflow
            && totalTokens == total.partialValue && cached.partialValue <= inputTokens
            && reasoningTokens <= outputTokens
    }

    var isEligibleSuccessfulUsage: Bool {
        guard failed == false,
              provider == "codex", quotaScope == "main",
              let model = responseModel ?? model, !model.isEmpty, model.lowercased() != "unknown",
              let tier = responseServiceTier ?? serviceTier, !tier.isEmpty, tier.lowercased() != "unknown",
              let statusCode, statusCode == 0 || (200..<400).contains(statusCode),
              let requestedAtEpochSeconds, requestedAtEpochSeconds > 0,
              let observedAtEpochSeconds,
              observedAtEpochSeconds >= requestedAtEpochSeconds else { return false }
        // CPA stores Failure.StatusCode here; successful records use 0.
        return hasConsistentTokenCounts
    }

    private static func date(_ seconds: Int64?) -> Date? {
        guard let seconds, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}

struct V013CPARawUsageIssue: Equatable, Sendable {
    let rowID: Int64?
    let field: String
    let reason: String
}

struct V013CPARawUsageSnapshot: Equatable, Sendable {
    let expectedOfficialAccountScopeSHA256: String
    let records: [V013CPARawUsageRecord]
    let issues: [V013CPARawUsageIssue]
    let excludedOtherAccountRowCount: Int
    let excludedProviderOrQuotaScopeRowCount: Int

    var eligibleSuccessfulRecords: [V013CPARawUsageRecord] {
        records.filter { record in
            record.isEligibleSuccessfulUsage
                && !issues.contains { $0.rowID == record.rowID }
        }
    }

    var hasEvidenceGaps: Bool { !issues.isEmpty }
}

enum V013CPARawUsageStoreError: Error, Equatable {
    case invalidBinding(String)
    case databaseOpen(String)
    case databaseRead(String)
    case missingColumns([String])
}

struct V013CPARawUsageStore {
    let databaseURL: URL

    func loadSnapshot(
        binding: V013CPACredentialScopeBinding
    ) throws -> V013CPARawUsageSnapshot {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(databaseURL.path, &database, flags, nil)
        guard openResult == SQLITE_OK, let database else {
            let message = database.flatMap { sqlite3_errmsg($0).map(String.init(cString:)) }
                ?? "unknown SQLite error"
            if let database { sqlite3_close(database) }
            throw V013CPARawUsageStoreError.databaseOpen(message)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 0)

        try execute("PRAGMA query_only = ON", database: database)
        try execute("BEGIN DEFERRED TRANSACTION", database: database)
        do {
            let columns = try requireSchema(database)
            let snapshot = try readRows(database, binding: binding, columns: columns)
            try execute("COMMIT", database: database)
            return snapshot
        } catch {
            try? execute("ROLLBACK", database: database)
            throw error
        }
    }

    private func requireSchema(_ database: OpaquePointer) throws -> Set<String> {
        let rows = try query("PRAGMA table_info(usage_events)", database: database)
        let found = Set(rows.compactMap { text($0, 1) })
        let required = ["id", "cycle_id", "requested_at", "observed_at", "account",
            "provider", "model", "alias", "service_tier", "input_tokens",
            "output_tokens", "reasoning_tokens", "cache_read_tokens",
            "cache_write_tokens", "total_tokens", "failed", "status_code",
            "used_percent", "reset_at", "window_minutes", "secondary_used_percent",
            "secondary_reset_at", "secondary_window_minutes", "plan_type", "quota_scope"]
        let missing = required.filter { !found.contains($0) }
        guard missing.isEmpty else { throw V013CPARawUsageStoreError.missingColumns(missing) }
        return found
    }

    private func readRows(
        _ database: OpaquePointer,
        binding: V013CPACredentialScopeBinding,
        columns: Set<String>
    ) throws -> V013CPARawUsageSnapshot {
        let responseModelColumn = columns.contains("response_model") ? "response_model" : "NULL"
        let responseTierColumn = columns.contains("response_service_tier") ? "response_service_tier" : "NULL"
        let tokenFieldsColumn = columns.contains("response_token_fields") ? "response_token_fields" : "NULL"
        let sql = """
        SELECT id, cycle_id, requested_at, observed_at, account, provider, model, alias,
               service_tier, input_tokens, output_tokens, reasoning_tokens,
               cache_read_tokens, cache_write_tokens, total_tokens, failed, status_code,
               used_percent, reset_at, window_minutes, secondary_used_percent,
               secondary_reset_at, secondary_window_minutes, plan_type, quota_scope,
               \(responseModelColumn), \(responseTierColumn), \(tokenFieldsColumn)
        FROM usage_events ORDER BY id ASC
        """
        let rows = try query(sql, database: database)
        var records: [V013CPARawUsageRecord] = []
        var issues: [V013CPARawUsageIssue] = []
        var otherAccounts = 0
        var otherSources = 0
        for row in rows {
            let rowID = integer(row, 0)
            guard let account = text(row, 4) else {
                issues.append(.init(rowID: rowID, field: "account", reason: "missing CPA credential/auth ID"))
                continue
            }
            guard account == binding.cpaCredentialAuthID else {
                otherAccounts += 1
                continue
            }
            let provider = text(row, 5)
            let quotaScope = text(row, 24)
            guard provider == "codex", quotaScope == "main" else {
                otherSources += 1
                issues.append(.init(rowID: rowID, field: "provider/quota_scope",
                                    reason: "matching credential row is not codex/main"))
                continue
            }
            let record = makeRecord(row, binding: binding)
            records.append(record)
            issues.append(contentsOf: validationIssues(record))
        }
        return V013CPARawUsageSnapshot(
            expectedOfficialAccountScopeSHA256: binding.verifiedOfficialAccountScopeSHA256,
            records: records,
            issues: issues,
            excludedOtherAccountRowCount: otherAccounts,
            excludedProviderOrQuotaScopeRowCount: otherSources)
    }

    private func makeRecord(
        _ row: [SQLiteValue],
        binding: V013CPACredentialScopeBinding
    ) -> V013CPARawUsageRecord {
        let present = Set((text(row, 27) ?? "").split(separator: ",").map(String.init))
        func evidenced(_ index: Int, _ field: String) -> Int64? {
            present.contains(field) ? integer(row, index) : nil
        }
        return V013CPARawUsageRecord(
            rowID: integer(row, 0), cycleID: integer(row, 1),
            expectedOfficialAccountScopeSHA256: binding.verifiedOfficialAccountScopeSHA256,
            requestedAtEpochSeconds: integer(row, 2), observedAtEpochSeconds: integer(row, 3),
            provider: text(row, 5), model: text(row, 6), alias: text(row, 7),
            serviceTier: text(row, 8), responseModel: text(row, 25),
            responseServiceTier: text(row, 26), inputTokens: evidenced(9, "input_tokens"),
            outputTokens: evidenced(10, "output_tokens"), reasoningTokens: evidenced(11, "output_tokens_details.reasoning_tokens"),
            cacheReadTokens: evidenced(12, "input_tokens_details.cached_tokens"), cacheWriteTokens: evidenced(13, "input_tokens_details.cache_write_tokens"),
            totalTokens: evidenced(14, "total_tokens"), failed: boolean(row, 15),
            statusCode: integer(row, 16), usedPercent: number(row, 17),
            resetAtEpochSeconds: integer(row, 18), windowMinutes: integer(row, 19),
            secondaryUsedPercent: number(row, 20), secondaryResetAtEpochSeconds: integer(row, 21),
            secondaryWindowMinutes: integer(row, 22), planType: text(row, 23),
            quotaScope: text(row, 24))
    }

    private func validationIssues(_ record: V013CPARawUsageRecord) -> [V013CPARawUsageIssue] {
        var issues: [V013CPARawUsageIssue] = []
        func add(_ field: String, _ reason: String) {
            issues.append(.init(rowID: record.rowID, field: field, reason: reason))
        }
        if record.rowID == nil { add("id", "missing or non-integer row ID") }
        if record.requestedAtEpochSeconds.map({ $0 > 0 }) != true { add("requested_at", "missing or invalid request time") }
        if record.observedAtEpochSeconds.map({ $0 >= (record.requestedAtEpochSeconds ?? 1) }) != true { add("observed_at", "missing or before request time") }
        if (record.responseModel ?? record.model).map({ !$0.isEmpty && $0.lowercased() != "unknown" }) != true { add("model", "missing or unknown model") }
        if (record.responseServiceTier ?? record.serviceTier).map({ !$0.isEmpty && $0.lowercased() != "unknown" }) != true { add("service_tier", "missing or unknown raw tier") }
        let tokens = [record.inputTokens, record.outputTokens, record.reasoningTokens,
                      record.cacheReadTokens, record.cacheWriteTokens, record.totalTokens]
        if tokens.contains(where: { ($0 ?? -1) < 0 }) {
            add("tokens", "missing, non-integer, or negative token component")
        } else if !record.hasConsistentTokenCounts {
            add("tokens", "token components are internally inconsistent")
        }
        if record.failed == nil { add("failed", "missing or invalid failure flag") }
        if record.failed == true { add("failed", "failed request is retained and excluded from successful usage") }
        if record.failed == false
            && record.statusCode.map({ $0 == 0 || (200..<400).contains($0) }) != true {
            add("status_code", "successful flag has an incompatible failure status")
        }
        for (field, percent) in [("used_percent", record.usedPercent),
                                 ("secondary_used_percent", record.secondaryUsedPercent)] {
            if let percent, !(0...100).contains(percent) { add(field, "percentage is outside 0...100") }
        }
        if record.usedPercent != nil
            && (record.resetAtEpochSeconds.map({ $0 > 0 }) != true
                || record.windowMinutes.map({ $0 > 0 }) != true) {
            add("primary_window", "percentage lacks a valid reset or window duration")
        }
        if record.secondaryUsedPercent != nil
            && (record.secondaryResetAtEpochSeconds.map({ $0 > 0 }) != true
                || record.secondaryWindowMinutes.map({ $0 > 0 }) != true) {
            add("secondary_window", "percentage lacks a valid reset or window duration")
        }
        return issues
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure(database) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure(database) }
    }

    private func query(_ sql: String, database: OpaquePointer) throws -> [[SQLiteValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure(database) }
        defer { sqlite3_finalize(statement) }
        var rows: [[SQLiteValue]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw failure(database) }
            rows.append((0..<sqlite3_column_count(statement)).map {
                value(statement, $0)
            })
        }
        return rows
    }

    private func failure(_ database: OpaquePointer) -> V013CPARawUsageStoreError {
        .databaseRead(sqlite3_errmsg(database).map(String.init(cString:)) ?? "unknown SQLite error")
    }

    private enum SQLiteValue {
        case integer(Int64)
        case number(Double)
        case text(String)
        case null
        case invalid
    }

    private func value(_ statement: OpaquePointer, _ index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: return .number(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, index) else { return .invalid }
            return .text(String(cString: text))
        case SQLITE_NULL: return .null
        default: return .invalid
        }
    }

    private func integer(_ row: [SQLiteValue], _ index: Int) -> Int64? {
        guard row.indices.contains(index), case let .integer(value) = row[index] else { return nil }
        return value
    }

    private func number(_ row: [SQLiteValue], _ index: Int) -> Double? {
        guard row.indices.contains(index) else { return nil }
        switch row[index] {
        case let .integer(value): return Double(value)
        case let .number(value): return value
        default: return nil
        }
    }

    private func boolean(_ row: [SQLiteValue], _ index: Int) -> Bool? {
        guard let value = integer(row, index), value == 0 || value == 1 else { return nil }
        return value == 1
    }

    private func text(_ row: [SQLiteValue], _ index: Int) -> String? {
        guard row.indices.contains(index), case let .text(value) = row[index] else { return nil }
        return value
    }
}
