import Foundation

enum V013OfficialPricingUpdateError: LocalizedError, Equatable {
    case unavailable
    case responseTooLarge
    case unsupportedDocument

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "官方价格页面暂时无法读取；生效快照保持不变"
        case .responseTooLarge:
            return "官方价格页面超过安全读取上限；生效快照保持不变"
        case .unsupportedDocument:
            return "官方价格页面格式已变化；未生成更新，生效快照保持不变"
        }
    }
}

private struct V013OfficialPricingDocument: Codable {
    let schemaVersion: Int
    let active: V013OfficialPricingSnapshot
}

struct V013OfficialPricingStore {
    static let maximumBytes = 128 * 1024

    let fileURL: URL
    private let fileManager: FileManager
    private let writer: V011ReceiptFileWriter

    init(
        fileURL: URL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.fileManager = fileManager
        writer = V011ReceiptFileWriter(fileManager: fileManager)
    }

    func load() throws -> V013OfficialPricingSnapshot? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        // Re-read metadata so a restored file is not rejected using a cached size.
        let values = try URL(fileURLWithPath: fileURL.path).resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size <= Self.maximumBytes else {
            throw V012PricingError.invalidValue
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(
            V013OfficialPricingDocument.self,
            from: Data(contentsOf: fileURL)
        )
        guard document.schemaVersion
                == V013OfficialPricingSnapshot.schemaVersion,
              document.active.isStructurallyValid else {
            throw V012PricingError.invalidValue
        }
        return document.active
    }

    func commit(_ value: V013OfficialPricingSnapshot) throws {
        do { _ = try load() }
        catch { throw V012PricingError.unreadableLocalFile }
        guard value.isStructurallyValid else {
            throw V012PricingError.invalidValue
        }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            V013OfficialPricingDocument(
                schemaVersion: V013OfficialPricingSnapshot.schemaVersion,
                active: value
            )
        )
        guard data.count <= Self.maximumBytes else {
            throw V012PricingError.responseTooLarge
        }
        try writer.write(data, to: fileURL)
    }
}

struct V013OfficialPricingChecker: Sendable {
    static let maximumBytes = 128 * 1024
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    struct APIPrice: Equatable {
        let model: String
        let input: Double
        let cached: Double
        let output: Double
    }

    let now: @Sendable () -> Date
    private let transport: Transport?

    init(now: @escaping @Sendable () -> Date = { Date() }, transport: Transport? = nil) {
        self.now = now
        self.transport = transport
    }

    func check(
        current: V013OfficialPricingSnapshot
    ) async throws -> V013OfficialPricingSnapshot {
        let models = Set(current.rates.map(\.model)).sorted()
        async let speed = fetch(
            URL(string: "https://developers.openai.com/codex/speed.md")!
        )
        var prices: [APIPrice] = []
        for model in models { prices.append(try await fetchModel(model)) }
        let speedText = String(decoding: try await speed, as: UTF8.self)
        let normalizedSpeed = speedText.split(whereSeparator: {
            $0.isWhitespace
        }).joined(separator: " ")
        guard normalizedSpeed.contains(
            "GPT-5.6 and GPT-5.5 consume credits at 2.5x the Standard rate"
        ), normalizedSpeed.contains(
            "for GPT-5.6, it costs 2x the Standard API token rate"
        ) else {
            throw V013OfficialPricingUpdateError.unsupportedDocument
        }
        let map = Dictionary(
            uniqueKeysWithValues: prices.map {
                ($0.model, (
                    input: $0.input,
                    cached: $0.cached,
                    output: $0.output
                ))
            }
        )
        guard let candidate = current.replacingAPIPrices(
            map,
            checkedAt: now()
        ) else {
            throw V013OfficialPricingUpdateError.unsupportedDocument
        }
        return candidate
    }

    static func parseModelMarkdown(
        _ data: Data,
        expectedModel: String
    ) throws -> APIPrice {
        guard data.count <= maximumBytes else {
            throw V013OfficialPricingUpdateError.responseTooLarge
        }
        let text = String(decoding: data, as: UTF8.self)
        let normalized = text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let supportedLongContext = normalized.contains(
            "Prompts with >272K input tokens are priced at 2x input and 1.5x output"
        ) || normalized.contains(
            "Prompts with more than 272K input tokens are priced at 2x input and cache rates and 1.5x output"
        )
        guard text.contains("Model ID: `\(expectedModel)`"),
              supportedLongContext,
              normalized.contains(
                  "Cache writes are billed at 1.25x the uncached input token rate"
              ),
              let input = tablePrice("Input", in: text),
              let cached = tablePrice("Cached input", in: text),
              let output = tablePrice("Output", in: text) else {
            throw V013OfficialPricingUpdateError.unsupportedDocument
        }
        return APIPrice(
            model: expectedModel,
            input: input,
            cached: cached,
            output: output
        )
    }

    private func fetchModel(_ model: String) async throws -> APIPrice {
        let url = URL(
            string: "https://developers.openai.com/api/docs/models/\(model).md"
        )!
        return try Self.parseModelMarkdown(
            await fetch(url),
            expectedModel: model
        )
    }

    private func fetch(_ url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("text/markdown", forHTTPHeaderField: "Accept")
        let pair: (Data, URLResponse)
        do {
            if let transport { pair = try await transport(request) }
            else { pair = try await session.data(for: request) }
        } catch {
            throw V013OfficialPricingUpdateError.unavailable
        }
        guard let response = pair.1 as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              response.url?.scheme == "https",
              ["developers.openai.com", "learn.chatgpt.com"]
                .contains(response.url?.host ?? "") else {
            throw V013OfficialPricingUpdateError.unavailable
        }
        guard pair.0.count <= Self.maximumBytes else {
            throw V013OfficialPricingUpdateError.responseTooLarge
        }
        return pair.0
    }

    private static func tablePrice(
        _ metric: String,
        in text: String
    ) -> Double? {
        let prefix = "| \(metric) | $"
        guard let line = text.split(separator: "\n").first(where: {
            $0.hasPrefix(prefix) && $0.hasSuffix("| 1M tokens |")
        }) else { return nil }
        let cells = line.split(separator: "|", omittingEmptySubsequences: true)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        guard cells.count == 3,
              cells[0] == metric,
              cells[2] == "1M tokens" else { return nil }
        return Double(cells[1].dropFirst())
    }
}
