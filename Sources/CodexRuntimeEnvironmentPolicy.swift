import CryptoKit
import Foundation
#if canImport(CFNetwork)
import CFNetwork
#endif

enum CodexRuntimeNetworkRoute: String, Codable, Equatable, Sendable {
    case direct
    case inherited
}

struct CodexRuntimeNetworkRouteReceipt: Codable, Equatable, Sendable {
    let route: CodexRuntimeNetworkRoute
    let source: String
    let endpointHost: String?
    let proxyConfigured: Bool
    let observedAt: Date
}

enum CodexRuntimeEndpointProbeStatus: String, Codable, Equatable, Sendable {
    case passed
    case failed
    case unverified
}

struct CodexRuntimeEndpointProbeReceipt: Codable, Equatable, Sendable {
    let route: CodexRuntimeNetworkRoute
    let endpointHost: String?
    let source: String
    let status: CodexRuntimeEndpointProbeStatus
    let evidenceHash: String?
    let observedAt: Date
}

enum CodexRuntimeProxyInspector {
    private static let proxyKeys = [
        "http_proxy", "https_proxy", "all_proxy",
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
    ]

    static func inheritedProxyConfigured(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        proxyKeys.contains { key in
            guard let value = environment[key], !value.isEmpty else {
                return false
            }
            return URL(string: value)?.host != nil
        } || systemProxyConfigured()
    }

    static func proxySources(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        var sources = proxyKeys.compactMap { key -> String? in
            guard let value = environment[key], !value.isEmpty,
                  URL(string: value)?.host != nil else { return nil }
            return key
        }
        #if canImport(CFNetwork)
        if systemProxyConfigured() { sources.append("system-settings") }
        #endif
        return Array(Set(sources)).sorted()
    }

    private static func systemProxyConfigured() -> Bool {
        #if canImport(CFNetwork)
        guard let unmanaged = CFNetworkCopySystemProxySettings(),
              let settings = unmanaged.takeRetainedValue() as? [String: Any] else {
            return false
        }
        let enabledKeys = [
            kCFNetworkProxiesHTTPEnable as String,
            kCFNetworkProxiesHTTPSEnable as String,
            kCFNetworkProxiesSOCKSEnable as String,
            kCFNetworkProxiesFTPEnable as String,
        ]
        return enabledKeys.contains { (settings[$0] as? NSNumber)?.boolValue == true }
        #else
        return false
        #endif
    }

    static func receipt(
        route: CodexRuntimeNetworkRoute,
        endpointHost: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) -> CodexRuntimeNetworkRouteReceipt {
        let sources = proxySources(environment: environment)
        return CodexRuntimeNetworkRouteReceipt(
            route: route,
            source: route == .direct
                ? "verified-direct"
                : sources.isEmpty
                    ? "inherited-environment"
                    : "inherited-\(sources.joined(separator: ","))",
            endpointHost: endpointHost,
            proxyConfigured: inheritedProxyConfigured(
                environment: environment
            ),
            observedAt: now
        )
    }

    /// Probe seam for deterministic fixtures. The closure is injected by the
    /// caller; this helper never opens a socket or performs real network I/O.
    static func injectedEndpointProbe(
        route: CodexRuntimeNetworkRoute,
        endpointHost: String?,
        source: String = "injected-fixture",
        now: Date = Date(),
        probe: () throws -> String
    ) -> CodexRuntimeEndpointProbeReceipt {
        do {
            let evidence = try probe()
            guard !evidence.isEmpty else {
                return CodexRuntimeEndpointProbeReceipt(
                    route: route,
                    endpointHost: endpointHost,
                    source: source,
                    status: .unverified,
                    evidenceHash: nil,
                    observedAt: now
                )
            }
            let hash = SHA256.hash(data: Data(evidence.utf8)).map {
                String(format: "%02x", $0)
            }.joined()
            return CodexRuntimeEndpointProbeReceipt(
                route: route,
                endpointHost: endpointHost,
                source: source,
                status: .passed,
                evidenceHash: hash,
                observedAt: now
            )
        } catch {
            return CodexRuntimeEndpointProbeReceipt(
                route: route,
                endpointHost: endpointHost,
                source: source,
                status: .failed,
                evidenceHash: nil,
                observedAt: now
            )
        }
    }
}

enum FableCommandEnvironmentPolicy {
    private static let inheritedKeys = Set([
        "HOME",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "LOGNAME",
        "NO_PROXY",
        "PATH",
        "SHELL",
        "SSL_CERT_DIR",
        "SSL_CERT_FILE",
        "TMPDIR",
        "USER",
        "all_proxy",
        "http_proxy",
        "https_proxy",
        "no_proxy",
        "ALL_PROXY",
        "HTTP_PROXY",
        "HTTPS_PROXY",
    ])
    private static let proxyKeys = Set([
        "all_proxy",
        "http_proxy",
        "https_proxy",
        "no_proxy",
        "ALL_PROXY",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "NO_PROXY",
    ])
    private static let overrideKeys = inheritedKeys.union(["CODEX_HOME"])

    static func sanitized(
        base: [String: String],
        overrides: [String: String]
    ) -> [String: String] {
        var result = base.filter { inheritedKeys.contains($0.key) }
        for (key, value) in overrides
            where overrideKeys.contains(key) {
            if value.isEmpty {
                result.removeValue(forKey: key)
            } else {
                result[key] = value
            }
        }
        return result
    }

    static func runtime(
        base: [String: String],
        codexHome: String,
        networkRoute: CodexRuntimeNetworkRoute
    ) -> [String: String] {
        var result = sanitized(
            base: base,
            overrides: ["CODEX_HOME": codexHome]
        )
        guard networkRoute == .direct else { return result }
        for key in proxyKeys {
            result.removeValue(forKey: key)
        }
        result["NO_PROXY"] = "*"
        result["no_proxy"] = "*"
        return result
    }
}
