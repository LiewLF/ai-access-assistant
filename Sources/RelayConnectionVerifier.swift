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
        // LTP-130: a specified-model probe needs an explicit model. Block
        // before any request (directory or probe) instead of sending an
        // empty model name to the endpoint.
        let requestedModel = profile.defaultModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedModel.isEmpty else {
            throw RelayConnectionVerifierError.missingModel
        }
        if profile.additionalFields["cpaManagedCapture"] == .bool(true) {
            return try await Task.detached(priority: .userInitiated) {
                let dependencies = V011AccessDependencies.live
                return try V013CPANativeProbe(codexHome: dependencies.codexHome,
                    discovery: dependencies.versionDiscovery,
                    runner: FableSystemCommandRunner()).verify(profile: profile, apiKey: apiKey)
            }.value
        }
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
                "model": requestedModel,
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
            body = ["model": requestedModel, "messages": [["role": "user", "content": "Reply only OK."]], "max_tokens": 8]
        case .anthropicMessages:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": requestedModel, "messages": [["role": "user", "content": "Reply only OK."]], "max_tokens": 8]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
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
                    networkRoute: networkRoute,
                    maximumBytes: 2_000_000
                )
            }
        } catch BoundedHTTPResponseError.responseTooLarge {
            throw CodexControlError.responseTooLarge
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else { throw CodexControlError.badResponse(0, "无HTTP响应") }
        guard (200...299).contains(http.statusCode) else {
            let text = SensitiveTextRedactor.redact(String(decoding: data.prefix(500), as: UTF8.self))
            throw CodexControlError.badResponse(http.statusCode, text)
        }
        // LTP-140: only non-blank visible text together with a recognizable
        // normal end counts as verified. Budget exhaustion, cancellation,
        // refusal, partial output and unknown protocol shapes stay typed
        // failures so callers present the limited evidence instead of
        // inferring a service or account fault.
        switch RelayProbeResponseParser.outcome(
            wireProtocol: profile.wireProtocol,
            data: data
        ) {
        case .completed:
            return Self.successMessage
        case let .incomplete(reason, hasVisibleText):
            throw RelayConnectionVerifierError.probeNotCompleted(
                reason,
                hasVisibleText: hasVisibleText
            )
        case let .remoteFailure(failure, hasVisibleText):
            throw RelayConnectionVerifierError.probeRemoteFailure(
                failure,
                hasVisibleText: hasVisibleText
            )
        case .unrecognized:
            throw CodexControlError.invalidResponseBody(
                responseStructureSummary(data: data, response: http)
            )
        }
    }

    /// LTP-140: the probe proves one bounded request to the specified model.
    /// The wording stays independent of whether a caller also read the
    /// `/models` directory, and it never claims a real client task passed.
    static let successMessage =
        "指定模型的最小真实请求已完成；客户端真实任务仍需单独验证"

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

enum RelayConnectionVerifierError: LocalizedError, Equatable {
    case missingModel
    /// The response arrived but did not complete a verifiable probe.
    case probeNotCompleted(
        RelayProbeIncompleteReason,
        hasVisibleText: Bool
    )
    /// The endpoint reported an explicit, machine-readable failure.
    case probeRemoteFailure(
        RelayProbeRemoteFailure,
        hasVisibleText: Bool
    )

    var errorDescription: String? {
        switch self {
        case .missingModel:
            return "先明确要验证的模型：手工填写或从目录选择后再检测；未发送任何请求。"
        case let .probeNotCompleted(reason, hasVisibleText):
            return "\(Self.notCompletedLead(reason))"
                + "\(Self.visibleTextNote(hasVisibleText))"
                + "未完成验证；这不代表服务不可用或账户额度不足。"
        case let .probeRemoteFailure(failure, _):
            return "服务返回了明确失败：\(failure.label)。这不是探测超时或额度推断。"
        }
    }

    private static func notCompletedLead(
        _ reason: RelayProbeIncompleteReason
    ) -> String {
        switch reason {
        case .probeBudgetExhausted:
            return "已收到响应，但它在本次探测的 8 token 预算内没有完成。"
        case .cancelled:
            return "本次验证在完成前被取消。"
        case .refused:
            return "模型拒绝了本次探测请求。"
        case .missingCompletionEvidence:
            return "已收到响应，但没有可识别的正常结束。"
        case .noVisibleText:
            return "响应没有可见文字（可能只有推理或工具内容）。"
        }
    }

    private static func visibleTextNote(_ hasVisibleText: Bool) -> String {
        hasVisibleText ? "已收到可见文字。" : "未收到可见文字。"
    }
}
