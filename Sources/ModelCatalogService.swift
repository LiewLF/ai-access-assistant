import Foundation

struct RemoteModelRecord: Identifiable, Equatable {
    let id: String
    let displayName: String
}

enum ModelCatalogError: LocalizedError {
    case invalidBaseURL
    case missingAPIKey
    case badStatus(Int)
    case responseTooLarge
    case invalidResponse
    case emptyModels

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "Base URL 无效；只允许 HTTPS 或本机 HTTP"
        case .missingAPIKey: return "先填写 API Key"
        case let .badStatus(code): return "模型接口返回 HTTP \(code)"
        case .responseTooLarge: return "模型列表超过 2 MB，已停止读取"
        case .invalidResponse: return "模型接口返回格式无法识别"
        case .emptyModels: return "接口没有返回模型"
        }
    }
}

enum ModelCatalogService {
    static func fetch(
        baseURL: String,
        apiKey: String,
        wireProtocol: RelayWireProtocol,
        session: URLSession? = nil,
        confirmedLocalGateway: Bool = false,
        confirmedPrivateNetworkRisk: Bool = false
    ) async throws -> [RemoteModelRecord] {
        guard CodexPlusPlusAdapter.isAllowedBaseURL(baseURL),
              let base = URL(string: CodexPlusPlusAdapter.cleanBaseURL(baseURL)) else {
            throw ModelCatalogError.invalidBaseURL
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ModelCatalogError.missingAPIKey }

        let candidates = endpointCandidates(base)
        var lastStatus = 0
        for endpoint in candidates {
            var request = URLRequest(url: endpoint, timeoutInterval: 15)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("AIConnectionAssistant/0.6", forHTTPHeaderField: "User-Agent")
            if wireProtocol == .anthropicMessages {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            let result: (Data, URLResponse)
            if let session {
                result = try await session.data(for: request)
            } else {
                result = try await RelaySecureHTTPClient.data(
                    for: request,
                    source: .userTyped,
                    confirmedLocalGateway: confirmedLocalGateway,
                    confirmedPrivateNetworkRisk: confirmedPrivateNetworkRisk
                )
            }
            let (data, response) = result
            guard let http = response as? HTTPURLResponse else { throw ModelCatalogError.invalidResponse }
            lastStatus = http.statusCode
            if http.statusCode == 404 { continue }
            guard (200...299).contains(http.statusCode) else { throw ModelCatalogError.badStatus(http.statusCode) }
            guard data.count <= 2_000_000 else { throw ModelCatalogError.responseTooLarge }
            let models = try parse(data)
            guard !models.isEmpty else { throw ModelCatalogError.emptyModels }
            return models
        }
        throw ModelCatalogError.badStatus(lastStatus)
    }

    static func parse(_ data: Data) throws -> [RemoteModelRecord] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelCatalogError.invalidResponse
        }
        let rawItems = (root["data"] as? [[String: Any]])
            ?? (root["models"] as? [[String: Any]])
            ?? []
        var seen = Set<String>()
        return rawItems.compactMap { item in
            let identifier = (item["id"] as? String)
                ?? (item["name"] as? String)
                ?? (item["model"] as? String)
            guard let id = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty, seen.insert(id).inserted else { return nil }
            let display = (item["display_name"] as? String)
                ?? (item["displayName"] as? String)
                ?? id
            return RemoteModelRecord(id: id, displayName: display)
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private static func endpointCandidates(_ base: URL) -> [URL] {
        let path = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix("v1") {
            return [base.appendingPathComponent("models")]
        }
        return [
            base.appendingPathComponent("v1/models"),
            base.appendingPathComponent("models"),
        ]
    }
}
