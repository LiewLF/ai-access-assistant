import Foundation

/// Each manifest describes one uninterrupted, credential-bound CPA process.
/// Restarting collection creates another directory; databases are never joined.
struct V013CPACollectionManifest: Codable, Equatable {
    let schemaVersion: Int
    let sessionID: UUID
    let credentialAuthID: String
    let accountScopeSHA256: String
    let startedAt: Date
    let stoppedAt: Date?
    let coverageStartedAt: Date?
}

struct V013CPACollectionReadback {
    let snapshots: [V013CPARawUsageSnapshot]
    let unreadableSessionCount: Int
}

struct V013CPACollectionEvidenceStore {
    let root: URL

    func load(accountScopeSHA256: String?) -> V013CPACollectionReadback {
        guard let scope = accountScopeSHA256 else {
            return .init(snapshots: [], unreadableSessionCount: 0)
        }
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else {
            return .init(snapshots: [], unreadableSessionCount: 0)
        }
        var snapshots: [V013CPARawUsageSnapshot] = []
        var unreadable = 0
        do {
            let sessions = try manager.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
            for directory in sessions {
                guard let identifier = UUID(uuidString: directory.lastPathComponent) else { continue }
                do {
                    let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isDirectory == true, values.isSymbolicLink != true else {
                        unreadable += 1
                        continue
                    }
                    let manifestURL = directory.appendingPathComponent("capture.json")
                    let metadata = try manifestURL.resourceValues(forKeys:
                        [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                    guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
                          let size = metadata.fileSize, size <= 16_384 else {
                        unreadable += 1
                        continue
                    }
                    let manifest = try JSONDecoder().decode(V013CPACollectionManifest.self,
                        from: Data(contentsOf: manifestURL))
                    guard manifest.schemaVersion == 2, manifest.sessionID == identifier,
                          manifest.startedAt.timeIntervalSince1970 > 0,
                          manifest.stoppedAt.map({ $0 >= manifest.startedAt }) != false else {
                        unreadable += 1
                        continue
                    }
                    guard manifest.accountScopeSHA256 == scope else { continue }
                    let binding = try V013CPACredentialScopeBinding(
                        cpaCredentialAuthID: manifest.credentialAuthID,
                        verifiedOfficialAccountScopeSHA256: scope)
                    let database = directory.appendingPathComponent("usage.sqlite")
                    let databaseMetadata = try database.resourceValues(forKeys:
                        [.isRegularFileKey, .isSymbolicLinkKey])
                    guard databaseMetadata.isRegularFile == true,
                          databaseMetadata.isSymbolicLink != true else {
                        unreadable += 1
                        continue
                    }
                    let raw = try V013CPARawUsageStore(databaseURL: database).loadSnapshot(binding: binding)
                    // The manifest cannot turn older imported rows into captured evidence.
                    guard raw.records.allSatisfy({ row in
                        guard let requestedAt = row.requestedAt else { return true }
                        return requestedAt.timeIntervalSince1970
                            >= floor(manifest.startedAt.timeIntervalSince1970)
                            && manifest.stoppedAt.map({ requestedAt <= $0 }) != false
                    }) else {
                        unreadable += 1
                        continue
                    }
                    // Preflight traffic precedes verified provider adoption and cannot
                    // bridge an interval over uncaptured requests during the switch.
                    guard let coverage = manifest.coverageStartedAt,
                          coverage >= manifest.startedAt,
                          manifest.stoppedAt.map({ coverage <= $0 }) != false else { continue }
                    let records = raw.records.filter {
                        $0.requestedAt.map { $0 >= coverage } ?? true
                    }
                    let excludedIDs = Set(raw.records.filter {
                        $0.requestedAt.map { $0 < coverage } ?? false
                    }.compactMap(\.rowID))
                    snapshots.append(.init(expectedOfficialAccountScopeSHA256: scope,
                        records: records,
                        issues: raw.issues.filter { $0.rowID.map { !excludedIDs.contains($0) } ?? true },
                        excludedOtherAccountRowCount: raw.excludedOtherAccountRowCount,
                        excludedProviderOrQuotaScopeRowCount: raw.excludedProviderOrQuotaScopeRowCount))
                } catch { unreadable += 1 }
            }
        } catch { unreadable += 1 }
        return .init(snapshots: snapshots, unreadableSessionCount: unreadable)
    }
}
