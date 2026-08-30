import Darwin
import Foundation

struct SensitiveTemporaryCleanupReport: Codable, Equatable {
    let scanned: Int
    let removed: Int
    let retainedFresh: Int
    let skippedUnsafe: Int
}

enum SensitiveTemporaryArtifactJanitor {
    static let managedPrefixes = [
        "ai-access-doctor-",
        "ai-access-ocr-",
        "ai-access-capture-",
        "ai-access-agent-loop-",
    ]

    static func cleanupExpired(
        in root: URL = FileManager.default.temporaryDirectory,
        now: Date = Date(),
        maximumAge: TimeInterval = 24 * 60 * 60,
        maximumEntries: Int = 1_000
    ) -> SensitiveTemporaryCleanupReport {
        let manager = FileManager.default
        let standardizedRoot = root.standardizedFileURL
        guard maximumAge >= 0,
              maximumEntries > 0,
              isSafeDirectory(standardizedRoot) else {
            return SensitiveTemporaryCleanupReport(
                scanned: 0,
                removed: 0,
                retainedFresh: 0,
                skippedUnsafe: 1
            )
        }
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
        ]
        guard let entries = try? manager.contentsOfDirectory(
            at: standardizedRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return SensitiveTemporaryCleanupReport(
                scanned: 0,
                removed: 0,
                retainedFresh: 0,
                skippedUnsafe: 1
            )
        }

        var scanned = 0
        var removed = 0
        var retainedFresh = 0
        var skippedUnsafe = 0
        for entry in entries.prefix(maximumEntries) {
            guard managedPrefixes.contains(where: {
                entry.lastPathComponent.hasPrefix($0)
            }) else { continue }
            scanned += 1
            guard entry.deletingLastPathComponent().standardizedFileURL
                == standardizedRoot,
                  let values = try? entry.resourceValues(
                    forKeys: Set(keys)
                  ),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true
                    || values.isDirectory == true,
                  ownerID(of: entry) == getuid(),
                  let modifiedAt = values.contentModificationDate else {
                skippedUnsafe += 1
                continue
            }
            guard now.timeIntervalSince(modifiedAt) >= maximumAge else {
                retainedFresh += 1
                continue
            }
            do {
                try manager.removeItem(at: entry)
                removed += 1
            } catch {
                skippedUnsafe += 1
            }
        }
        return SensitiveTemporaryCleanupReport(
            scanned: scanned,
            removed: removed,
            retainedFresh: retainedFresh,
            skippedUnsafe: skippedUnsafe
        )
    }

    private static func isSafeDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]) else { return false }
        return values.isDirectory == true
            && values.isSymbolicLink != true
            && ownerID(of: url) == getuid()
    }

    private static func ownerID(of url: URL) -> uid_t? {
        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: url.path),
              let value = attributes[.ownerAccountID] as? NSNumber else {
            return nil
        }
        return value.uint32Value
    }
}
