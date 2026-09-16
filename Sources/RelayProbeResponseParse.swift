// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// LTP-140: structured result of one bounded specified-model probe.
///
/// A probe only passes when the response carries non-blank visible text *and*
/// a recognizable normal end. Everything else keeps the limited evidence it
/// actually has instead of being reported as a connection fault.
enum RelayProbeResponseOutcome: Equatable, Sendable {
    case completed(text: String)
    case incomplete(RelayProbeIncompleteReason, hasVisibleText: Bool)
    case remoteFailure(RelayProbeRemoteFailure, hasVisibleText: Bool)
    /// The body is not a recognizable payload for the requested wire protocol.
    case unrecognized(hasVisibleText: Bool)

    var hasVisibleText: Bool {
        switch self {
        case .completed:
            return true
        case let .incomplete(_, hasVisibleText),
                let .remoteFailure(_, hasVisibleText),
                let .unrecognized(hasVisibleText):
            return hasVisibleText
        }
    }
}

enum RelayProbeIncompleteReason: String, Equatable, Sendable {
    /// The response hit the probe's own bounded answer budget (8 tokens).
    /// This is not the account's quota or a rate limit.
    case probeBudgetExhausted
    case cancelled
    case refused
    /// Response arrived without a recognizable normal end.
    case missingCompletionEvidence
    case noVisibleText

    /// LTP-140: the persisted health category keeps the exact reason instead
    /// of collapsing every limited outcome into one bucket.
    var healthCategory: V011ConnectionHealthFailureCategory {
        switch self {
        case .probeBudgetExhausted: return .probeBudgetExhausted
        case .cancelled: return .probeCancelled
        case .refused: return .probeRefused
        case .missingCompletionEvidence: return .probeMissingCompletion
        case .noVisibleText: return .probeNoVisibleText
        }
    }
}

/// Explicit failure reported by the endpoint (HTTP 200 with a structured
/// `error`, or an in-band failure event). Classification only uses the
/// machine-readable `code`/`type`; provider prose is never interpreted.
enum RelayProbeRemoteFailure: Equatable, Sendable {
    case authentication
    case permission
    case quotaExhausted
    case rateLimited
    case upstreamUnavailable
    case modelUnavailable
    /// Machine code/type that is not in the bounded table. The raw provider
    /// value is deliberately not retained or shown.
    case unknown

    /// Bounded table of machine-readable codes; unknown values stay unknown
    /// instead of being guessed into a model or account fault.
    static func classify(code: String?, type: String?) -> Self {
        for candidate in [code, type] {
            guard let key = normalize(candidate),
                  let mapped = table[key] else { continue }
            return mapped
        }
        return .unknown
    }

    var healthCategory: V011ConnectionHealthFailureCategory {
        switch self {
        case .authentication: return .authentication
        case .permission: return .permission
        case .quotaExhausted: return .quotaExhausted
        case .rateLimited: return .rateLimited
        case .upstreamUnavailable: return .upstreamUnavailable
        case .modelUnavailable: return .endpointOrModel
        case .unknown: return .unknown
        }
    }

    var label: String {
        switch self {
        case .authentication: return "认证未通过"
        case .permission: return "访问受限"
        case .quotaExhausted: return "账户额度或余额不足"
        case .rateLimited: return "请求过于频繁"
        case .upstreamUnavailable: return "服务暂时异常"
        case .modelUnavailable: return "模型或地址不可用"
        case .unknown:
            return "未识别的结构化错误"
        }
    }

    private static let table: [String: RelayProbeRemoteFailure] = [
        "authentication": .authentication,
        "authentication_error": .authentication,
        "unauthorized": .authentication,
        "unauthenticated": .authentication,
        "invalid_api_key": .authentication,
        "invalid_api_key_error": .authentication,
        "api_key_invalid": .authentication,
        "invalid_credentials": .authentication,
        "permission": .permission,
        "permission_error": .permission,
        "permission_denied": .permission,
        "forbidden": .permission,
        "insufficient_permissions": .permission,
        "model_not_found": .modelUnavailable,
        "modelnotfound": .modelUnavailable,
        "model_not_available": .modelUnavailable,
        "unknown_model": .modelUnavailable,
        "invalid_model": .modelUnavailable,
        "not_found_error": .modelUnavailable,
        "insufficient_quota": .quotaExhausted,
        "quota_exceeded": .quotaExhausted,
        "insufficient_balance": .quotaExhausted,
        "insufficient_credit": .quotaExhausted,
        "payment_required": .quotaExhausted,
        "billing_hard_limit_reached": .quotaExhausted,
        "rate_limit_exceeded": .rateLimited,
        "rate_limit_error": .rateLimited,
        "rate_limited": .rateLimited,
        "too_many_requests": .rateLimited,
        "server_error": .upstreamUnavailable,
        "internal_error": .upstreamUnavailable,
        "api_error": .upstreamUnavailable,
        "overloaded": .upstreamUnavailable,
        "overloaded_error": .upstreamUnavailable,
        "service_unavailable": .upstreamUnavailable,
        "unavailable": .upstreamUnavailable,
        "upstream_error": .upstreamUnavailable,
    ]

    private static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

}

/// Parses the bounded probe response for each supported wire protocol. Pure
/// and network-free so the same rules are reusable by focused tests.
enum RelayProbeResponseParser {
    static func outcome(
        wireProtocol: RelayWireProtocol,
        data: Data
    ) -> RelayProbeResponseOutcome {
        switch wireProtocol {
        case .responses:
            if let object = jsonObject(data) {
                return responsesObject(object)
            }
            if String(decoding: data, as: UTF8.self).contains("data:") {
                return responsesEventStream(data)
            }
            return .unrecognized(hasVisibleText: false)
        case .chatCompletions:
            guard let object = jsonObject(data) else {
                return .unrecognized(hasVisibleText: false)
            }
            return chatObject(object)
        case .anthropicMessages:
            guard let object = jsonObject(data) else {
                return .unrecognized(hasVisibleText: false)
            }
            return anthropicObject(object)
        }
    }

    // MARK: - Responses

    private static func responsesObject(
        _ object: [String: Any]
    ) -> RelayProbeResponseOutcome {
        let visible = responsesVisibleText(object)
        // Explicit failure first: a refusal item must never mask an explicit
        // authentication, permission or model error in the same object.
        if let failure = explicitFailure(object) {
            return .remoteFailure(failure, hasVisibleText: visible)
        }
        // A refusal carries text the endpoint actually sent, so it counts as
        // observed visible content — the same rule the SSE refusal events
        // already follow for their delta text.
        if let refusal = refusalText(object) {
            return .incomplete(
                .refused,
                hasVisibleText: visible || !refusal.isEmpty
            )
        }
        if let details = object["incomplete_details"] as? [String: Any] {
            return .incomplete(
                incompleteReason(details["reason"]),
                hasVisibleText: visible
            )
        }
        if let status = object["status"] as? String {
            switch status {
            case "completed":
                return visible
                    ? .completed(text: responsesVisibleTextValue(object) ?? "")
                    : .incomplete(.noVisibleText, hasVisibleText: false)
            case "incomplete":
                return .incomplete(
                    .missingCompletionEvidence,
                    hasVisibleText: visible
                )
            case "cancelled", "canceled":
                return .incomplete(.cancelled, hasVisibleText: visible)
            case "failed":
                return .remoteFailure(.unknown, hasVisibleText: visible)
            default:
                // Recognized states such as in_progress/queued stay limited.
                return .incomplete(
                    .missingCompletionEvidence,
                    hasVisibleText: visible
                )
            }
        }
        guard isRecognizableResponsesObject(object) else {
            // Truly unreadable structures are a protocol problem, not a
            // partial probe.
            return .unrecognized(hasVisibleText: false)
        }
        // Recognized limited output without a completion marker stays
        // partial; the caller still learns that visible text was received.
        return .incomplete(
            .missingCompletionEvidence,
            hasVisibleText: visible
        )
    }

    private static func isRecognizableResponsesObject(
        _ object: [String: Any]
    ) -> Bool {
        object["output"] != nil
            || object["output_text"] != nil
            || object["status"] != nil
    }

    private static func incompleteReason(_ value: Any?) -> RelayProbeIncompleteReason {
        switch value as? String {
        case "max_output_tokens", "max_tokens", "length":
            return .probeBudgetExhausted
        case "content_filter":
            return .refused
        default:
            return .missingCompletionEvidence
        }
    }

    private static func responsesEventStream(_ data: Data) -> RelayProbeResponseOutcome {
        let text = String(decoding: data, as: UTF8.self)
        var hasVisibleText = false
        // LTP-140: a body full of unknown or unparsable events carries no
        // protocol evidence at all. Only recognized Responses events (or a
        // stream terminator) make an unterminated stream a partial probe.
        var hasProtocolEvidence = false
        var terminal: RelayProbeResponseOutcome?
        for rawLine in text.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0.isNewline }
        ) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5)
                .trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                // The Responses stream terminator is protocol evidence even
                // though it is not a completion marker.
                hasProtocolEvidence = true
                continue
            }
            guard let payloadData = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(
                    with: payloadData
                  ) as? [String: Any] else { continue }
            let type = event["type"] as? String
            if event["response"] != nil
                || type?.hasPrefix("response.") == true
                || type == "error" {
                hasProtocolEvidence = true
            }
            if let response = event["response"] as? [String: Any] {
                hasVisibleText = hasVisibleText || responsesVisibleText(response)
            }
            hasVisibleText = hasVisibleText || responsesVisibleText(event)
            if type == "response.output_text.delta",
               hasNonblankText(event["delta"]) {
                hasVisibleText = true
            }
            if type == "response.output_text.done",
               hasNonblankText(event["text"]) {
                hasVisibleText = true
            }
            if type == "response.refusal.delta",
               hasNonblankText(event["delta"]) {
                hasVisibleText = true
            }
            if type == "response.refusal.done",
               hasNonblankText(event["refusal"]) {
                hasVisibleText = true
            }
            // Every event checks its explicit failure signals before its own
            // semantics, so a failure carried next to another event type
            // keeps its precise machine-readable class.
            if let failure = eventFailure(event) {
                terminal = .remoteFailure(
                    failure,
                    hasVisibleText: hasVisibleText
                )
                continue
            }
            let candidate: RelayProbeResponseOutcome?
            switch type {
            case "response.cancelled":
                candidate = .incomplete(.cancelled, hasVisibleText: hasVisibleText)
            case "response.incomplete":
                let response = event["response"] as? [String: Any]
                let details = response?["incomplete_details"] as? [String: Any]
                candidate = .incomplete(
                    incompleteReason(details?["reason"]),
                    hasVisibleText: hasVisibleText
                )
            case "response.refusal.delta", "response.refusal.done":
                // A refusal locks a non-success outcome; a later completed
                // event must not turn it back into a pass.
                candidate = .incomplete(.refused, hasVisibleText: hasVisibleText)
            case "response.completed":
                candidate = completedEventOutcome(
                    event,
                    streamHasVisibleText: hasVisibleText
                )
            default:
                candidate = nil
            }
            guard let candidate else { continue }
            switch candidate {
            case .completed:
                // A success never overwrites a recorded failure; a later
                // explicit failure still overrides earlier text.
                if terminal == nil { terminal = candidate }
            case .remoteFailure:
                terminal = candidate
            case .incomplete, .unrecognized:
                // A later partial or unreadable event must not erase a
                // precise failure classification already observed.
                if case .remoteFailure = terminal { continue }
                terminal = candidate
            }
        }
        guard let terminal else {
            guard hasProtocolEvidence || hasVisibleText else {
                return .unrecognized(hasVisibleText: false)
            }
            return .incomplete(
                .missingCompletionEvidence,
                hasVisibleText: hasVisibleText
            )
        }
        return terminal
    }

    /// A `response.completed` event still carries its inner response. The
    /// event name may only supply a missing end when the inner body does not
    /// contradict it; every explicit inner state keeps winning.
    private static func completedEventOutcome(
        _ event: [String: Any],
        streamHasVisibleText: Bool
    ) -> RelayProbeResponseOutcome {
        guard let response = event["response"] as? [String: Any],
              !response.isEmpty else {
            return streamHasVisibleText
                ? .completed(text: "")
                : .incomplete(.noVisibleText, hasVisibleText: false)
        }
        let inner = responsesObject(response)
        switch inner {
        case .completed:
            return .completed(text: "")
        case let .remoteFailure(failure, innerVisible):
            return .remoteFailure(
                failure,
                hasVisibleText: streamHasVisibleText || innerVisible
            )
        case let .unrecognized(innerVisible):
            return .unrecognized(
                hasVisibleText: streamHasVisibleText || innerVisible
            )
        case let .incomplete(reason, innerVisible):
            let visible = streamHasVisibleText || innerVisible
            guard borrowsEventName(reason, response: response) else {
                return .incomplete(reason, hasVisibleText: visible)
            }
            // The text may have arrived as earlier deltas, so an inner body
            // without text of its own still passes at a recognized end.
            return visible
                ? .completed(text: "")
                : .incomplete(.noVisibleText, hasVisibleText: false)
        }
    }

    /// The `response.completed` event name may supply a missing end only when
    /// the inner body does not contradict it: the reason must be a missing
    /// end or text (never a refusal, cancellation or budget limit), no
    /// incomplete details may be present, and the inner status must be absent
    /// or `completed`. Explicit states such as `incomplete`, `in_progress`,
    /// `queued` or `failed` therefore stay non-pass.
    private static func borrowsEventName(
        _ reason: RelayProbeIncompleteReason,
        response: [String: Any]
    ) -> Bool {
        guard reason == .noVisibleText || reason == .missingCompletionEvidence
        else { return false }
        guard response["incomplete_details"] == nil else { return false }
        guard let status = response["status"] as? String else { return true }
        return status == "completed"
    }

    /// Explicit failure signals on one event: a non-null `error` (on the
    /// event or on its response), a failed status, or an `error` event. A
    /// machine-readable top-level `code` is still classified.
    private static func eventFailure(
        _ event: [String: Any]
    ) -> RelayProbeRemoteFailure? {
        if let response = event["response"] as? [String: Any],
           let failure = explicitFailure(response) {
            return failure
        }
        if let failure = explicitFailure(event) {
            return failure == .unknown ? relayEventFailure(event) : failure
        }
        return nil
    }

    /// Structured failures in an event stream may sit on the event itself or
    /// inside its `response`/`error` payload.
    private static func relayEventFailure(
        _ event: [String: Any]
    ) -> RelayProbeRemoteFailure {
        if let response = event["response"] as? [String: Any],
           let failure = explicitFailure(response) {
            return failure
        }
        if let error = event["error"] as? [String: Any] {
            return .classify(
                code: error["code"] as? String,
                type: error["type"] as? String
            )
        }
        return .classify(
            code: event["code"] as? String,
            type: event["type"] as? String
        )
    }

    /// Returns the refusal text of the first non-blank refusal item, if any.
    private static func refusalText(_ object: [String: Any]) -> String? {
        for case let item as [String: Any] in object["output"] as? [Any] ?? [] {
            for case let content as [String: Any] in item["content"] as? [Any] ?? [] {
                if content["type"] as? String == "refusal",
                   let refusal = content["refusal"] as? String,
                   hasNonblankText(refusal) {
                    return refusal
                }
            }
        }
        return nil
    }

    /// Explicit failure: a non-null structured `error`, a `status` of
    /// `failed`, or a top-level error event. `error: null` is not a failure.
    private static func explicitFailure(
        _ object: [String: Any]
    ) -> RelayProbeRemoteFailure? {
        // A null `error` field is ignored for that field only; other failure
        // signals in the same object still apply.
        if let error = object["error"], !(error is NSNull) {
            if let dictionary = error as? [String: Any] {
                return .classify(
                    code: dictionary["code"] as? String,
                    type: dictionary["type"] as? String
                )
            }
            return .unknown
        }
        if object["status"] as? String == "failed" {
            return .unknown
        }
        if let type = object["type"] as? String,
           type == "error" || type == "response.failed" {
            return .unknown
        }
        return nil
    }

    private static func responsesVisibleText(_ object: [String: Any]) -> Bool {
        responsesVisibleTextValue(object) != nil
    }

    private static func responsesVisibleTextValue(_ object: [String: Any]) -> String? {
        if let text = object["output_text"] as? String,
           hasNonblankText(text) {
            return text
        }
        for case let item as [String: Any] in object["output"] as? [Any] ?? [] {
            // Retain compatible relays that omit the message discriminator.
            guard item["type"] == nil || item["type"] as? String == "message" else { continue }
            for case let content as [String: Any] in item["content"] as? [Any] ?? [] {
                switch content["type"] as? String {
                case "output_text", nil:
                    if let text = content["text"] as? String,
                       hasNonblankText(text) {
                        return text
                    }
                default:
                    continue
                }
            }
        }
        return nil
    }

    // MARK: - Chat completions

    private static func chatObject(
        _ object: [String: Any]
    ) -> RelayProbeResponseOutcome {
        if let error = object["error"], !(error is NSNull) {
            let dictionary = error as? [String: Any]
            return .remoteFailure(
                .classify(
                    code: dictionary?["code"] as? String,
                    type: dictionary?["type"] as? String
                ),
                hasVisibleText: false
            )
        }
        guard let choice = (object["choices"] as? [Any])?.first
                as? [String: Any] else {
            return .unrecognized(hasVisibleText: false)
        }
        let message = choice["message"] as? [String: Any]
        // A refusal is a model decision, not a normal end and not a missing
        // answer; it must never pass as empty output either.
        if chatRefusalText(message) != nil {
            return .incomplete(.refused, hasVisibleText: true)
        }
        let visibleText = chatVisibleText(choice)
        switch choice["finish_reason"] as? String {
        case "stop", "end_turn":
            return visibleText != nil
                ? .completed(text: visibleText ?? "")
                : .incomplete(.noVisibleText, hasVisibleText: false)
        case "length", "max_tokens", "max_output_tokens":
            return .incomplete(
                .probeBudgetExhausted,
                hasVisibleText: visibleText != nil
            )
        case "content_filter":
            return .incomplete(.refused, hasVisibleText: visibleText != nil)
        case "error", "failed":
            return .remoteFailure(.unknown, hasVisibleText: visibleText != nil)
        default:
            // An absent or unrecognized `finish_reason` is not an observed
            // normal end, so the evidence stays "missing completion" whether
            // or not text arrived. Never claim an end that was not seen.
            return .incomplete(
                .missingCompletionEvidence,
                hasVisibleText: visibleText != nil
            )
        }
    }

    private static func chatVisibleText(_ choice: [String: Any]) -> String? {
        guard let message = choice["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String, hasNonblankText(text) {
            return text
        }
        for case let part as [String: Any] in message["content"] as? [Any] ?? [] {
            let type = part["type"] as? String
            guard type == nil || type == "text" || type == "output_text" else { continue }
            if let text = part["text"] as? String, hasNonblankText(text) {
                return text
            }
        }
        return nil
    }

    private static func chatRefusalText(
        _ message: [String: Any]?
    ) -> String? {
        guard let message else { return nil }
        if let refusal = message["refusal"] as? String,
           hasNonblankText(refusal) {
            return refusal
        }
        for case let part as [String: Any] in message["content"] as? [Any] ?? [] {
            guard part["type"] as? String == "refusal" else { continue }
            if let refusal = (part["refusal"] ?? part["text"]) as? String,
               hasNonblankText(refusal) {
                return refusal
            }
        }
        return nil
    }

    // MARK: - Anthropic messages

    private static func anthropicObject(
        _ object: [String: Any]
    ) -> RelayProbeResponseOutcome {
        if let error = object["error"], !(error is NSNull) {
            let dictionary = error as? [String: Any]
            return .remoteFailure(
                .classify(
                    code: dictionary?["code"] as? String,
                    type: dictionary?["type"] as? String
                ),
                hasVisibleText: false
            )
        }
        guard object["content"] != nil || object["stop_reason"] != nil
                || object["type"] != nil else {
            return .unrecognized(hasVisibleText: false)
        }
        let visibleText = anthropicVisibleText(object)
        switch object["stop_reason"] as? String {
        case "end_turn", "stop_sequence":
            return visibleText != nil
                ? .completed(text: visibleText ?? "")
                : .incomplete(.noVisibleText, hasVisibleText: false)
        case "max_tokens":
            return .incomplete(
                .probeBudgetExhausted,
                hasVisibleText: visibleText != nil
            )
        case "refusal":
            return .incomplete(.refused, hasVisibleText: visibleText != nil)
        default:
            // Same rule as Chat: without a recognized `stop_reason` the end
            // state is unobserved, so limited evidence stays missing
            // completion instead of asserting a normal end.
            return .incomplete(
                .missingCompletionEvidence,
                hasVisibleText: visibleText != nil
            )
        }
    }

    private static func anthropicVisibleText(_ object: [String: Any]) -> String? {
        guard let content = object["content"] as? [Any] else { return nil }
        for case let part as [String: Any] in content {
            guard part["type"] as? String == "text" || part["type"] == nil else { continue }
            if let text = part["text"] as? String, hasNonblankText(text) {
                return text
            }
        }
        return nil
    }

    // MARK: - Shared

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return object as? [String: Any]
    }

    private static func hasNonblankText(_ value: Any?) -> Bool {
        guard let text = value as? String else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
