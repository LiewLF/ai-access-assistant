import Foundation

struct V012UsageScanSource: Sendable {
    let url: URL
    let providerID: String
}

struct V012UsageScanResult: Sendable {
    let turns: [V012CompletedTurnUsage]
    let changedSourceCount: Int
    let readSourceCount: Int
    let overflowed: Bool
}

actor V012UsageScanCoordinator {
    static let maximumTurns = 2_000

    typealias IdentityReader = @Sendable (URL) throws
        -> SessionRolloutSnapshot
    typealias UsageReader = @Sendable (URL, String) throws
        -> V012UsageReadResult

    private struct CacheEntry: Sendable {
        let identity: SessionRolloutSnapshot
        let providerID: String
        let turns: [V012CompletedTurnUsage]
    }

    private let identityReader: IdentityReader
    private let usageReader: UsageReader
    private var cache: [String: CacheEntry] = [:]

    init(
        identityReader: @escaping IdentityReader = { url in
            guard let value = SessionRolloutSnapshot.capture(at: url) else {
                throw SessionCenterError.unsafePath
            }
            return value
        },
        usageReader: @escaping UsageReader
    ) {
        self.identityReader = identityReader
        self.usageReader = usageReader
    }

    func scan(
        _ sources: [V012UsageScanSource]
    ) async throws -> V012UsageScanResult {
        var values: [V012CompletedTurnUsage] = []
        var changed = 0
        var read = 0
        var overflowed = false
        var activePaths = Set<String>()

        for source in sources {
            try Task.checkCancellation()
            let path = source.url.standardizedFileURL.path
            activePaths.insert(path)
            let before = try identityReader(source.url)
            if let cached = cache[path],
               cached.identity == before,
               cached.providerID == source.providerID {
                values.append(contentsOf: cached.turns)
                continue
            }
            let result = try usageReader(source.url, source.providerID)
            try Task.checkCancellation()
            let after = try identityReader(source.url)
            read += 1
            values.append(contentsOf: result.turns)
            if result.overflowed { overflowed = true }
            if result.sourceChangedDuringRead || before != after {
                changed += 1
                cache.removeValue(forKey: path)
            } else {
                cache[path] = CacheEntry(
                    identity: after,
                    providerID: source.providerID,
                    turns: result.turns
                )
            }
        }
        cache = cache.filter { activePaths.contains($0.key) }
        let unique = Dictionary(
            values.map { ($0.id, $0) },
            uniquingKeysWith: { lhs, rhs in
                lhs.completedAt >= rhs.completedAt ? lhs : rhs
            }
        ).values.sorted { $0.completedAt > $1.completedAt }
        if unique.count > Self.maximumTurns { overflowed = true }
        return V012UsageScanResult(
            turns: Array(unique.prefix(Self.maximumTurns)),
            changedSourceCount: changed,
            readSourceCount: read,
            overflowed: overflowed
        )
    }
}
