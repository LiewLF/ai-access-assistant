import Dispatch
import Foundation

struct V011ConnectionHealthService {
    private let controlRoot: URL
    private let now: @Sendable () -> Date

    init(
        controlRoot: URL,
        now: @escaping @Sendable () -> Date
    ) {
        self.controlRoot = controlRoot
        self.now = now
    }

    var receiptStore: V011ConnectionReceiptStore {
        V011ConnectionReceiptStore(
            fileURL: v011Root.appendingPathComponent(
                "connection-receipt.json"
            )
        )
    }

    func loadHistory() throws
        -> [V011ConnectionHealthObservation] {
        try historyStore.load()
    }

    func appendObservation(
        startedNanoseconds: UInt64,
        providerID: String?,
        configHash: String?,
        outcome: V011ConnectionHealthOutcome,
        failureCode: V011ConnectionHealthFailureCode?,
        failureCategory:
            V011ConnectionHealthFailureCategory? = nil,
        httpStatus: Int? = nil,
        sessionProviderCheck: V011SessionProviderCheck?,
        runtimeFreshness: V011RuntimeFreshness
    ) throws -> [V011ConnectionHealthObservation] {
        let elapsedNanoseconds =
            DispatchTime.now().uptimeNanoseconds
                - startedNanoseconds
        let observation = V011ConnectionHealthObservation(
            observedAt: now(),
            durationMilliseconds:
                Double(elapsedNanoseconds) / 1_000_000,
            providerID: providerID,
            configHash: configHash,
            outcome: outcome,
            failureCode: failureCode,
            failureCategory: failureCategory,
            httpStatus: httpStatus,
            sessionProviderCheck: sessionProviderCheck,
            runtimeState: Self.runtimeState(runtimeFreshness)
        )
        return try historyStore.append(observation)
    }

    static func providerID(_ live: LiveCodexState) -> String {
        switch live.mode {
        case .official:
            return "openai"
        case let .relay(providerID):
            return providerID
        }
    }

    static func endpointHost(_ baseURL: String?) -> String? {
        guard let baseURL,
              let components = URLComponents(string: baseURL),
              let rawHost = components.host,
              !rawHost.isEmpty else {
            return nil
        }
        return components.port.map {
            "\(rawHost.lowercased()):\($0)"
        } ?? rawHost.lowercased()
    }

    static func normalizedEndpointHost(
        _ value: String?
    ) -> String? {
        guard let value = value?
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
              !value.isEmpty,
              !value.contains(where: { $0.isWhitespace }) else {
            return nil
        }
        if value.contains("://") {
            return endpointHost(value)
        }
        guard !value.contains(where: {
            "/@?#\\".contains($0)
        }) else {
            return nil
        }
        guard let components = URLComponents(
                string: "https://\(value)"
              ),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty,
              let rawHost = components.host,
              !rawHost.isEmpty else {
            return nil
        }
        return components.port.map {
            "\(rawHost.lowercased()):\($0)"
        } ?? rawHost.lowercased()
    }

    static func receiptMatches(
        _ receipt: V011ConnectionReceipt,
        live: LiveCodexState,
        at now: Date
    ) -> Bool {
        guard isReceiptFresh(receipt, at: now) else {
            return false
        }
        guard receipt.configHash == live.configHash,
              receipt.providerID == providerID(live) else {
            return false
        }
        switch live.mode {
        case .official:
            return receipt.endpointHost == nil
        case .relay:
            guard let configuredHost = endpointHost(
                    live.provider?.baseURL
                  ),
                  let verifiedHost = normalizedEndpointHost(
                    receipt.endpointHost
                  ) else {
                return false
            }
            return configuredHost == verifiedHost
        }
    }

    static func isReceiptFresh(
        _ receipt: V011ConnectionReceipt,
        at now: Date
    ) -> Bool {
        receipt.freshness(at: now) == .fresh
    }

    /// History remains readable; only a bounded observation of the current
    /// configuration may drive the current failure card or its next action.
    static func observationMatches(
        _ observation: V011ConnectionHealthObservation,
        live: LiveCodexState,
        receipt: V011ConnectionReceipt?,
        at now: Date
    ) -> Bool {
        guard observation.providerID == providerID(live),
              observation.configHash == live.configHash,
              observation.observedAt <= now,
              now < observation.observedAt.addingTimeInterval(
                  V011ConnectionReceipt.validityDuration
              ) else { return false }
        if observation.failureCode == .sessionProviderDrift {
            guard let receipt,
                  receipt.sessionProviderCheck == .drifted,
                  receiptMatches(receipt, live: live, at: now)
            else { return false }
        }
        return true
    }

    static func runtimeFreshness(
        live: LiveCodexState,
        runtimeObservation: V011CodexRuntimeObservation
    ) -> V011RuntimeFreshness {
        switch runtimeObservation {
        case .notRunning:
            return .notRunning
        case .runningUnknown:
            return .unknown
        case let .running(codexLaunchDate):
            guard let modifiedAt = try? live.configURL
                .resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate else {
                return .unknown
            }
            if modifiedAt > codexLaunchDate {
                return .stale
            }
            if modifiedAt < codexLaunchDate {
                return .fresh
            }
            return .unknown
        }
    }

    static func failureCode(
        for error: Error
    ) -> V011ConnectionHealthFailureCode {
        guard let verificationError = error as?
                V011CurrentConnectionVerificationError else {
            return .unavailable
        }
        switch verificationError {
        case .savedProfileMissing:
            return .savedProfileMissing
        case .savedProfileMismatch:
            return .savedProfileMismatch
        case .endpointHostUnavailable:
            return .endpointHostUnavailable
        case .configurationChangedDuringCheck:
            return .configurationChangedDuringCheck
        }
    }

    private static func runtimeState(
        _ freshness: V011RuntimeFreshness
    ) -> V011ConnectionHealthRuntimeState {
        switch freshness {
        case .fresh:
            return .fresh
        case .stale:
            return .stale
        case .notRunning:
            return .notRunning
        case .unknown:
            return .unknown
        }
    }

    private var v011Root: URL {
        controlRoot.appendingPathComponent(
            "V011",
            isDirectory: true
        )
    }

    private var historyStore: V011ConnectionHealthHistoryStore {
        V011ConnectionHealthHistoryStore(
            fileURL: v011Root.appendingPathComponent(
                "connection-health-history.json"
            )
        )
    }
}
