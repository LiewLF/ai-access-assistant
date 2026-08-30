import Foundation

struct V011BoundedDisplayText: Equatable, Sendable {
    let source: String
    let summary: String
    let isTruncated: Bool
}

enum V011HistoryDisplayProjection {
    static func title(_ source: String) -> V011BoundedDisplayText {
        bounded(source, maximumCharacters: 180, maximumLines: 2)
    }

    static func workspace(_ source: String) -> V011BoundedDisplayText {
        bounded(source, maximumCharacters: 220, maximumLines: 2)
    }

    private static func bounded(
        _ source: String,
        maximumCharacters: Int,
        maximumLines: Int
    ) -> V011BoundedDisplayText {
        precondition(maximumCharacters > 0 && maximumLines > 0)
        var result = ""
        var emittedCharacters = 0
        var emittedLines = 1
        var truncated = false

        for character in source {
            if character == "\n" || character == "\r" {
                if emittedLines >= maximumLines {
                    truncated = true
                    break
                }
                if result.last != "\n" {
                    result.append("\n")
                    emittedLines += 1
                }
                continue
            }
            guard emittedCharacters < maximumCharacters else {
                truncated = true
                break
            }
            result.append(character)
            emittedCharacters += 1
        }
        if result.count < source.count {
            truncated = true
        }
        let trimmed = result.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let summary = truncated ? trimmed + "…" : source
        return V011BoundedDisplayText(
            source: source,
            summary: summary,
            isTruncated: truncated
        )
    }
}
