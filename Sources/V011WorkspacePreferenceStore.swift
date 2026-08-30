// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum V011WorkspacePreferenceStore {
    struct Snapshot {
        let paths: Set<String>
        let labels: [String: String]
        let error: String?
    }

    private struct Document: Codable {
        let schemaVersion: Int
        let paths: [String]
        let labels: [String: String]?
    }

    static func normalizedPath(
        _ path: String
    ) -> String? {
        let normalized = path.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty,
              normalized.count <= 4_096,
              !normalized.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return normalized
    }

    static func normalizedLabel(
        _ label: String
    ) -> String? {
        let normalized = label.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty,
              normalized.count <= 40,
              !normalized.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return normalized
    }

    static func load(at controlRoot: URL) -> Snapshot {
        let url = preferencesURL(at: controlRoot)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Snapshot(paths: [], labels: [:], error: nil)
        }
        do {
            let document = try JSONDecoder().decode(
                Document.self,
                from: Data(contentsOf: url)
            )
            guard document.schemaVersion == 1
                    || document.schemaVersion == 2 else {
                return Snapshot(
                    paths: [],
                    labels: [:],
                    error: "工作区收藏版本无法识别，已保持只读"
                )
            }
            var normalized: [String] = []
            for path in document.paths.compactMap(
                normalizedPath
            ) where !normalized.contains(path) {
                normalized.append(path)
            }
            let overflow = normalized.count > 20
            let paths = Set(normalized.prefix(20))
            var labels: [String: String] = [:]
            var invalidLabelObserved = false
            if document.schemaVersion == 2 {
                for (rawPath, rawLabel) in document.labels ?? [:] {
                    guard let path = normalizedPath(rawPath),
                          paths.contains(path),
                          let label = normalizedLabel(rawLabel) else {
                        invalidLabelObserved = true
                        continue
                    }
                    labels[path] = label
                }
            }
            var warnings: [String] = []
            if overflow {
                warnings.append("工作区收藏最多读取20个")
            }
            if invalidLabelObserved {
                warnings.append("部分工作区名称无效，已忽略")
            }
            return Snapshot(
                paths: paths,
                labels: labels,
                error: warnings.isEmpty
                    ? nil : warnings.joined(separator: "；")
            )
        } catch {
            return Snapshot(
                paths: [],
                labels: [:],
                error: "工作区收藏读取失败：\(error.localizedDescription)"
            )
        }
    }

    static func persist(
        _ paths: Set<String>,
        labels: [String: String],
        at controlRoot: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: controlRoot,
            withIntermediateDirectories: true
        )
        let document = Document(
            schemaVersion: 2,
            paths: paths.sorted(),
            labels: labels.filter { paths.contains($0.key) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(
            to: preferencesURL(at: controlRoot),
            options: .atomic
        )
    }

    private static func preferencesURL(
        at controlRoot: URL
    ) -> URL {
        controlRoot.appendingPathComponent(
            "workspace-favorites.json",
            isDirectory: false
        )
    }
}
