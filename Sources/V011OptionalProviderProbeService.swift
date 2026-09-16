import Foundation

enum V011OptionalProviderProbeService {
    static func interpretOptionalProviderCapabilityResponse(
        _ kind: ProviderCapabilityProbeKind,
        data: Data,
        capability: ProviderCapabilityProfile
    ) -> [V011ProviderCapabilityProbeObservation]? {
        guard let object = try? JSONSerialization
                .jsonObject(with: data) as? [String: Any]
        else { return nil }
        let structureHash = responseStructureSHA256(object)
        switch kind {
        case .serviceTier:
            return [serviceTierObservation(
                object,
                capability: capability,
                structureHash: structureHash
            )]
        case .webSearchResponses:
            return webSearchObservations(
                object,
                capability: capability,
                structureHash: structureHash
            )
        case .imageInput:
            return [imageObservation(
                object,
                structureHash: structureHash
            )]
        default:
            return nil
        }
    }

    static func optionalProbeName(
        _ kind: ProviderCapabilityProbeKind
    ) -> String {
        switch kind {
        case .serviceTier:
            return "Fast"
        case .webSearchResponses:
            return "Web Search（Responses）"
        case .webSearchCitations:
            return "来源引用"
        case .imageInput:
            return "图片输入"
        default:
            return kind.rawValue
        }
    }

    static func validateOptionalProbeConfiguration(
        _ kind: ProviderCapabilityProbeKind,
        capability: ProviderCapabilityProfile
    ) throws {
        switch kind {
        case .serviceTier:
            guard capability.serviceTier.requested.kind == .fast
            else {
                throw V011ProviderCapabilityProbeRunError
                    .configurationRequired("Fast")
            }
        case .webSearchResponses:
            guard capability.webSearch.configuredValue == "live"
            else {
                throw V011ProviderCapabilityProbeRunError
                    .configurationRequired(
                        "Web Search（Responses）Live"
                    )
            }
        case .imageInput:
            guard capability.imageInput == .requested
                    || capability.imageInput == .verified else {
                throw V011ProviderCapabilityProbeRunError
                    .configurationRequired("图片输入声明")
            }
        default:
            throw V011ProviderCapabilityProbeRunError
                .unsupportedProbe
        }
    }

    static func performOptionalProviderCapabilityProbe(
        _ kind: ProviderCapabilityProbeKind,
        profile: CodexRelayProfile,
        apiKey: String,
        userConsented: Bool,
        session: URLSession? = nil
    ) async throws -> [V011ProviderCapabilityProbeObservation] {
        guard profile.wireProtocol == .responses,
              CodexPlusPlusAdapter.isAllowedBaseURL(
                profile.baseURL
              ),
              let endpoint = optionalResponsesEndpoint(
                profile.baseURL
              ) else {
            throw V011ProviderCapabilityProbeRunError
                .invalidEndpoint
        }
        let capability = profile.effectiveCapabilityProfile
        try validateOptionalProbeConfiguration(
            kind,
            capability: capability
        )
        guard let plan = ProviderCapabilityProbePlan.optional
            .first(where: { $0.kind == kind }) else {
            throw V011ProviderCapabilityProbeRunError
                .unsupportedProbe
        }
        guard !plan.requiresExplicitConsent
                || userConsented else {
            throw ProviderCapabilityProbeReceiptError
                .consentRequired
        }
        var request = URLRequest(
            url: endpoint,
            timeoutInterval: TimeInterval(
                plan.timeoutSeconds
            )
        )
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "Bearer \(apiKey)",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try
            ProviderCapabilityOptionalRequestFactory.make(
                kind: kind,
                modelID: profile.defaultModel,
                userConsented: userConsented
            )
        let response: (Data, URLResponse)
        do {
            if let session {
                response = try await BoundedHTTPResponse.data(
                    for: request, session: session, maximumBytes: 2_000_000
                )
            } else {
                response = try await RelaySecureHTTPClient.data(
                    for: request,
                    source: .userTyped,
                    confirmedLocalGateway: profile.localGatewayConfirmed == true,
                    maximumBytes: 2_000_000
                )
            }
        } catch BoundedHTTPResponseError.responseTooLarge {
            return optionalProbeFailureObservations(
                kind,
                capability: capability,
                accepted: "response-too-large"
            )
        } catch {
            return optionalProbeFailureObservations(
                kind,
                capability: capability,
                accepted: "network-error"
            )
        }
        let (data, urlResponse) = response
        guard let http = urlResponse as? HTTPURLResponse else {
            return optionalProbeFailureObservations(
                kind,
                capability: capability,
                accepted: "non-http-response"
            )
        }
        guard (200...299).contains(http.statusCode) else {
            return optionalProbeFailureObservations(
                kind,
                capability: capability,
                accepted: "http-\(http.statusCode)"
            )
        }
        guard let observations =
                interpretOptionalProviderCapabilityResponse(
                    kind,
                    data: data,
                    capability: capability
                ) else {
            return optionalProbeFailureObservations(
                kind,
                capability: capability,
                accepted: "invalid-json"
            )
        }
        return observations
    }

    private static func optionalResponsesEndpoint(
        _ baseURL: String
    ) -> URL? {
        let clean = CodexPlusPlusAdapter.cleanBaseURL(baseURL)
        guard let base = URL(string: clean) else { return nil }
        let basePath = base.path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        let versioned = basePath.hasSuffix("v1")
            ? clean : clean + "/v1"
        return URL(string: versioned + "/responses")
    }

    private static func serviceTierObservation(
        _ object: [String: Any],
        capability: ProviderCapabilityProfile,
        structureHash: String
    ) -> V011ProviderCapabilityProbeObservation {
        let actual = normalizedEvidenceValue(
            object["service_tier"] as? String
        )
        let status: ProviderCapabilityStatus
        let fallback: String?
        switch actual {
        case "fast", "priority":
            status = .verified
            fallback = nil
        case "default":
            status = .degraded
            fallback = "standard"
        case .some:
            status = .degraded
            fallback = actual
        case .none:
            status = .requested
            fallback = nil
        }
        return V011ProviderCapabilityProbeObservation(
            kind: .serviceTier,
            status: status,
            stage: ProviderProbeStageObservation(
                configured:
                    capability.serviceTier.requested
                        .configuredValue,
                emitted: "fast",
                accepted: "http-2xx",
                actual: actual,
                fallback: fallback
            ),
            evidenceLevel:
                actual == nil ? .request : .response,
            responseStructureSHA256: structureHash,
            evidenceComponents: [
                "request-service-tier=fast",
                "response-service-tier=" + (actual ?? "absent"),
                "output-present=\(responseOutputPresent(object))",
            ],
            requestCount: 1
        )
    }

    private static func webSearchObservations(
        _ object: [String: Any],
        capability: ProviderCapabilityProfile,
        structureHash: String
    ) -> [V011ProviderCapabilityProbeObservation] {
        let output = object["output"] as? [[String: Any]] ?? []
        let searchCallObserved = output.contains {
            ($0["type"] as? String) == "web_search_call"
        }
        var resultObserved = false
        var citationCount = 0
        for item in output
            where (item["type"] as? String) == "message" {
            for content in item["content"] as? [[String: Any]] ?? [] {
                if let text = content["text"] as? String,
                   !text.isEmpty {
                    resultObserved = true
                }
                for annotation in content["annotations"]
                    as? [[String: Any]] ?? []
                    where (annotation["type"] as? String)
                        == "url_citation" {
                    citationCount += 1
                }
            }
        }
        let searchStatus: ProviderCapabilityStatus =
            searchCallObserved && resultObserved
                ? .verified : .degraded
        let citationStatus: ProviderCapabilityStatus =
            citationCount > 0 ? .verified : .degraded
        let commonComponents = [
            "tool=web_search",
            "search-call=\(searchCallObserved)",
            "result=\(resultObserved)",
            "citations=\(citationCount)",
        ]
        return [
            V011ProviderCapabilityProbeObservation(
                kind: .webSearchResponses,
                status: searchStatus,
                stage: ProviderProbeStageObservation(
                    configured:
                        capability.webSearch.configuredValue,
                    emitted: "web_search",
                    accepted:
                        searchCallObserved
                            ? "tool-call" : "http-2xx",
                    actual:
                        resultObserved ? "result" : nil,
                    fallback: nil
                ),
                evidenceLevel:
                    searchCallObserved && resultObserved
                        ? .response : .request,
                responseStructureSHA256: structureHash,
                evidenceComponents: commonComponents,
                requestCount: 1
            ),
            V011ProviderCapabilityProbeObservation(
                kind: .webSearchCitations,
                status: citationStatus,
                stage: ProviderProbeStageObservation(
                    configured: "web_search",
                    emitted: "web_search",
                    accepted:
                        resultObserved ? "result" : "http-2xx",
                    actual:
                        citationCount > 0
                            ? "url_citation" : "absent",
                    fallback:
                        citationCount > 0 ? nil : "no-citation"
                ),
                evidenceLevel: .response,
                responseStructureSHA256: structureHash,
                evidenceComponents: commonComponents,
                requestCount: 1
            ),
        ]
    }

    private static func imageObservation(
        _ object: [String: Any],
        structureHash: String
    ) -> V011ProviderCapabilityProbeObservation {
        let outputPresent = responseOutputPresent(object)
        return V011ProviderCapabilityProbeObservation(
            kind: .imageInput,
            status: outputPresent ? .verified : .degraded,
            stage: ProviderProbeStageObservation(
                configured: "declared",
                emitted: "input_image:data:image/png",
                accepted: "http-2xx",
                actual: outputPresent ? "output" : nil,
                fallback: nil
            ),
            evidenceLevel:
                outputPresent ? .response : .request,
            responseStructureSHA256: structureHash,
            evidenceComponents: [
                "synthetic-image-sha256="
                    + SyntheticImageProbeFixture
                        .onePixelPNG.sha256,
                "pixels=1x1",
                "output-present=\(outputPresent)",
            ],
            requestCount: 1
        )
    }

    private static func optionalProbeFailureObservations(
        _ kind: ProviderCapabilityProbeKind,
        capability: ProviderCapabilityProfile,
        accepted: String
    ) -> [V011ProviderCapabilityProbeObservation] {
        let configured: String?
        let emitted: String
        switch kind {
        case .serviceTier:
            configured = capability.serviceTier.requested
                .configuredValue
            emitted = "fast"
        case .webSearchResponses:
            configured = capability.webSearch.configuredValue
            emitted = "web_search"
        case .imageInput:
            configured = "declared"
            emitted = "input_image:data:image/png"
        default:
            configured = nil
            emitted = kind.rawValue
        }
        let kinds: [ProviderCapabilityProbeKind] =
            kind == .webSearchResponses
                ? [.webSearchResponses, .webSearchCitations]
                : [kind]
        return kinds.map { receiptKind in
            V011ProviderCapabilityProbeObservation(
                kind: receiptKind,
                status: .degraded,
                stage: ProviderProbeStageObservation(
                    configured: configured,
                    emitted: emitted,
                    accepted: accepted,
                    actual: nil,
                    fallback: "unverified"
                ),
                evidenceLevel: .request,
                responseStructureSHA256: nil,
                evidenceComponents: [
                    "synthetic-request=true",
                    "result=\(accepted)",
                ],
                requestCount: 1
            )
        }
    }

    private static func responseOutputPresent(
        _ object: [String: Any]
    ) -> Bool {
        if let outputText = object["output_text"] as? String,
           !outputText.isEmpty {
            return true
        }
        let output = object["output"] as? [[String: Any]] ?? []
        return output.contains { item in
            guard (item["type"] as? String) == "message" else {
                return false
            }
            return (item["content"] as? [[String: Any]] ?? [])
                .contains { content in
                    guard let text = content["text"] as? String else {
                        return false
                    }
                    return !text.isEmpty
                }
        }
    }

    private static func responseStructureSHA256(
        _ object: [String: Any]
    ) -> String {
        var components = object.keys.sorted()
        for item in object["output"] as? [[String: Any]] ?? [] {
            components.append(
                "output:" + ((item["type"] as? String) ?? "unknown")
            )
            for content in item["content"] as? [[String: Any]] ?? [] {
                components.append(
                    "content:"
                        + ((content["type"] as? String) ?? "unknown")
                )
                for annotation in content["annotations"]
                    as? [[String: Any]] ?? [] {
                    components.append(
                        "annotation:"
                            + ((annotation["type"] as? String)
                                ?? "unknown")
                    )
                }
            }
        }
        return ProviderCapabilityProbeReceiptFactory.sha256(
            Data(components.joined(separator: "\u{001F}").utf8)
        )
    }

    private static func normalizedEvidenceValue(
        _ value: String?
    ) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        guard !normalized.isEmpty,
              normalized.utf8.count <= 64,
              !normalized.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return normalized
    }
}
