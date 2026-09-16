import Foundation

/// Produces value-free differences for the already-prepared rollback branch.
/// Failure here only withholds the preview; it cannot change recovery eligibility.
enum V014RecoveryConfigurationPreview {
    static func read(_ prepared: FablePreparedRecoveryConfiguration) -> V014RecoveryFieldPreview {
        do {
            let exists = FileManager.default.fileExists(atPath: prepared.configURL.path)
            guard exists == prepared.expectedCurrentExisted else { return .unavailable }
            var current: Data?
            if exists {
                try SessionSyncFileSafety.requireRegularFile(prepared.configURL)
                let attributes = try FileManager.default.attributesOfItem(atPath: prepared.configURL.path)
                guard let size = attributes[.size] as? NSNumber, size.intValue <= 2_000_000 else {
                    return .unavailable
                }
                current = try Data(contentsOf: prepared.configURL)
            }
            guard current.map(TOMLSemanticEngine.sha256) == prepared.expectedCurrentHash else {
                return .unavailable
            }
            return compare(current: current, rollback: prepared.recoveredData)
        } catch {
            return .unavailable
        }
    }

    static func compare(current: Data?, rollback: Data?) -> V014RecoveryFieldPreview {
        guard (current?.count ?? 0) <= 2_000_000, (rollback?.count ?? 0) <= 2_000_000 else {
            return .unavailable
        }
        do {
            let before = try TOMLSemanticEngine.parse(String(decoding: current ?? Data(), as: UTF8.self))
            let after = try TOMLSemanticEngine.parse(String(decoding: rollback ?? Data(), as: UTF8.self))
            let providers = Array(Set(before.providerIDs + after.providerIDs)).sorted()
            var fields: [String] = []
            var undisplayed = 0
            for change in TOMLSemanticEngine.diff(before: before, after: after) {
                let path = TOMLSemanticEngine.decodePath(change.path)
                guard let name = safeFieldName(path, providers: providers) else {
                    undisplayed += 1
                    continue
                }
                let action: String
                switch change.kind {
                case .added: action = "新增字段"
                case .missing: action = "移除字段"
                case .changed: action = "替换字段值（值不展示）"
                }
                fields.append("\(name)：\(action)")
            }
            return V014RecoveryFieldPreview(fields: Array(Set(fields)).sorted(),
                undisplayedFieldCount: undisplayed, isAvailable: true)
        } catch {
            return .unavailable
        }
    }

    private static func safeFieldName(_ path: [String], providers: [String]) -> String? {
        if path.count == 1, TOMLChangePolicy.providerRootKeys.contains(path[0]) {
            return path[0]
        }
        if path == ["features", "fast_mode"] { return "features.fast_mode" }
        guard path.count >= 3, path[0] == "model_providers",
              let index = providers.firstIndex(of: path[1]),
              CodexProviderSchemaCatalog.current.fieldPolicies[path[2]] != nil else { return nil }
        let suffix = path.count == 3 ? "" : ".<子字段名称已隐藏>"
        return "model_providers.<中转\(index + 1)>.\(path[2])\(suffix)"
    }
}
