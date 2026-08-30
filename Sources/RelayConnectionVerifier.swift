// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum RelayConnectionVerifier {
    static func verify(
        profile: CodexRelayProfile,
        apiKey: String,
        session: URLSession? = nil,
        confirmedLocalGateway: Bool = false,
        confirmedPrivateNetworkRisk: Bool = false,
        verifyModelCatalog: Bool = true,
        networkRoute: RelayHTTPNetworkRoute = .inherited
    ) async throws -> String {
        if verifyModelCatalog {
            _ = try await ModelCatalogService.fetch(
                baseURL: profile.baseURL,
                apiKey: apiKey,
                wireProtocol: profile.wireProtocol,
                session: session,
                confirmedLocalGateway: confirmedLocalGateway,
                confirmedPrivateNetworkRisk:
                    confirmedPrivateNetworkRisk
            )
        }
        let endpoint = requestEndpoint(baseURL: profile.baseURL, protocolValue: profile.wireProtocol)
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any]
        switch profile.wireProtocol {
        case .responses:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body = [
                "model": profile.defaultModel,
                "input": [[
                    "role": "user",
                    "content": [[
                        "type": "input_text",
                        "text": "Reply only OK.",
                    ]],
                ]],
                "max_output_tokens": 8,
            ]
        case .chatCompletions:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body = ["model": profile.defaultModel, "messages": [["role": "user", "content": "Reply only OK."]], "max_tokens": 8]
        case .anthropicMessages:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": profile.defaultModel, "messages": [["role": "user", "content": "Reply only OK."]], "max_tokens": 8]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let result: (Data, URLResponse)
        if let session {
            result = try await session.data(for: request)
        } else {
            result = try await RelaySecureHTTPClient.data(
                for: request,
                source: .userTyped,
                confirmedLocalGateway: confirmedLocalGateway,
                confirmedPrivateNetworkRisk: confirmedPrivateNetworkRisk,
                networkRoute: networkRoute
            )
        }
        let (data, response) = result
        guard data.count <= 2_000_000 else { throw CodexControlError.responseTooLarge }
        guard let http = response as? HTTPURLResponse else { throw CodexControlError.badResponse(0, "无HTTP响应") }
        guard (200...299).contains(http.statusCode) else {
            let text = SensitiveTextRedactor.redact(String(decoding: data.prefix(500), as: UTF8.self))
            throw CodexControlError.badResponse(http.statusCode, text)
        }
        let object = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        let hasOutput: Bool
        switch profile.wireProtocol {
        case .responses:
            hasOutput = object.map(hasResponsesOutput) == true
                || hasResponsesEventStream(data)
        case .chatCompletions:
            hasOutput = (object?["choices"] as? [Any])?.isEmpty
                == false
        case .anthropicMessages:
            hasOutput = (object?["content"] as? [Any])?.isEmpty
                == false
        }
        guard hasOutput else {
            throw CodexControlError.invalidResponseBody(
                responseStructureSummary(data: data, response: http)
            )
        }
        return "模型接口和最小真实请求均通过"
    }

    private static func hasResponsesOutput(
        _ object: [String: Any]
    ) -> Bool {
        (object["output"] as? [Any])?.isEmpty == false
            || object.keys.contains("output_text")
    }

    private static func hasResponsesEventStream(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        for rawLine in text.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0.isNewline }
        ) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5)
                .trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]",
                  let payloadData = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(
                    with: payloadData
                  ) as? [String: Any] else { continue }
            if hasResponsesOutput(event) { return true }
            if let response = event["response"]
                    as? [String: Any],
               hasResponsesOutput(response) {
                return true
            }
            let type = event["type"] as? String
            if type == "response.output_text.delta",
               let delta = event["delta"] as? String,
               !delta.isEmpty {
                return true
            }
            if type == "response.output_text.done",
               event.keys.contains("text") {
                return true
            }
        }
        return false
    }

    private static func responseStructureSummary(
        data: Data,
        response: HTTPURLResponse
    ) -> String {
        let contentType = safeStructureToken(
            response.value(forHTTPHeaderField: "Content-Type")
                ?? "absent"
        )
        if let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any] {
            let keys = dictionary.keys.sorted()
                .prefix(12)
                .map(safeStructureToken)
                .joined(separator: ",")
            return "Content-Type=\(contentType)；JSON keys=\(keys.isEmpty ? "none" : keys)"
        }
        let text = String(decoding: data.prefix(16_384), as: UTF8.self)
        let events = Set(text.split(whereSeparator: { $0.isNewline })
            .compactMap { rawLine -> String? in
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("event:") else { return nil }
                return safeStructureToken(
                    line.dropFirst(6)
                        .trimmingCharacters(in: .whitespaces)
                )
            })
            .sorted()
            .prefix(12)
            .joined(separator: ",")
        if !events.isEmpty {
            return "Content-Type=\(contentType)；SSE events=\(events)"
        }
        let trimmed = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        let kind = trimmed.hasPrefix("<!doctype html")
            || trimmed.hasPrefix("<html") ? "HTML" : "non-JSON"
        return "Content-Type=\(contentType)；body=\(kind)；bytes=\(data.count)"
    }

    private static func safeStructureToken<S: StringProtocol>(
        _ value: S
    ) -> String {
        let filtered = value.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
                || "._/+;-=".unicodeScalars.contains($0)
        }.map(String.init).joined()
        return String(filtered.prefix(120))
    }

    private static func requestEndpoint(baseURL: String, protocolValue: RelayWireProtocol) -> URL {
        let clean = CodexPlusPlusAdapter.cleanBaseURL(baseURL)
        let basePath = URL(string: clean)?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let versionedBase = basePath.hasSuffix("v1") ? clean : clean + "/v1"
        let suffix: String
        switch protocolValue {
        case .responses: suffix = "responses"
        case .chatCompletions: suffix = "chat/completions"
        case .anthropicMessages: suffix = "messages"
        }
        return URL(string: versionedBase + "/" + suffix)!
    }
}
