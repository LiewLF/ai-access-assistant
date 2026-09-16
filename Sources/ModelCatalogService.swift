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
        case let .badStatus(code):
            let suggestion: String
            switch code {
            case 401: suggestion = "请核对 API Key 是否有效。"
            case 403: suggestion = "请向中转方核对该密钥的模型列表权限。"
            case 404: suggestion = "请核对 Base URL；该服务也可能不提供模型列表，可按文档手动填写模型。"
            case 429: suggestion = "服务暂时限制请求，请稍后手动重试或向中转方核对额度。"
            case 500...599: suggestion = "中转服务暂时异常，请稍后手动重试。"
            default: suggestion = "请按中转文档核对地址与访问条件。"
            }
            return "模型接口返回 HTTP \(code)。\(suggestion)"
        case .responseTooLarge: return "模型列表超过 2 MB，已停止读取"
        case .invalidResponse: return "模型接口未返回可识别的模型列表。请核对 Base URL；也可按中转文档手动填写模型。"
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
            do {
                if let session {
                    result = try await BoundedHTTPResponse.data(
                        for: request, session: session, maximumBytes: 2_000_000
                    )
                } else {
                    result = try await RelaySecureHTTPClient.data(
                        for: request,
                        source: .userTyped,
                        confirmedLocalGateway: confirmedLocalGateway,
                        confirmedPrivateNetworkRisk: confirmedPrivateNetworkRisk,
                        maximumBytes: 2_000_000
                    )
                }
            } catch BoundedHTTPResponseError.responseTooLarge {
                throw ModelCatalogError.responseTooLarge
            }
            let (data, response) = result
            guard let http = response as? HTTPURLResponse else { throw ModelCatalogError.invalidResponse }
            lastStatus = http.statusCode
            if http.statusCode == 404 { continue }
            guard (200...299).contains(http.statusCode) else { throw ModelCatalogError.badStatus(http.statusCode) }
            let models = try parse(data)
            guard !models.isEmpty else { throw ModelCatalogError.emptyModels }
            return models
        }
        throw ModelCatalogError.badStatus(lastStatus)
    }

    static func parse(_ data: Data) throws -> [RemoteModelRecord] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
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

    static func endpointCandidates(_ base: URL) -> [URL] {
        let path = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.split(separator: "/").last == "v1" {
            return [base.appendingPathComponent("models")]
        }
        return [
            base.appendingPathComponent("v1/models"),
            base.appendingPathComponent("models"),
        ]
    }
}
