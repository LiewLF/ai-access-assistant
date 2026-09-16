// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum RelayDirectoryPublicProbeRunner {
    typealias Transport =
        (URLRequest) async throws -> (Data, URLResponse)

    static func run(
        entry: ProviderCatalogEntryV2,
        task: ScheduledRelayProbe,
        userAuthorized: Bool,
        now: Date = Date(),
        transport: Transport? = nil
    ) async throws -> RelayProbeRunResult {
        guard userAuthorized else {
            throw RelayDirectoryProbeError.authorizationRequired
        }
        guard task.entryID == entry.id else {
            throw RelayDirectoryProbeError.taskMismatch
        }
        var request = URLRequest(
            url: entry.documentationURL,
            timeoutInterval: 15
        )
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "AI-Access-Assistant-Relay-Probe/1",
            forHTTPHeaderField: "User-Agent"
        )
        do {
            let result: (Data, URLResponse)
            if let transport {
                result = try await transport(request)
            } else {
                result = try await RelaySecureHTTPClient.data(
                    for: request,
                    source: .catalog,
                    maximumBytes: 1_000_000
                )
            }
            let tlsState: RelayProbeState =
                result.1.url?.scheme?.lowercased() == "https"
                ? .passed : .failed
            guard result.0.count <= 1_000_000,
                  let response = result.1 as? HTTPURLResponse,
                  (200...399).contains(response.statusCode),
                  tlsState == .passed else {
                return resultRecord(
                    entry: entry,
                    task: task,
                    now: now,
                    documentation: .failed,
                    tls: tlsState,
                    failureCode: "invalid-http-response"
                )
            }
            return resultRecord(
                entry: entry,
                task: task,
                now: now,
                documentation: .passed,
                tls: .passed,
                failureCode: nil
            )
        } catch BoundedHTTPResponseError.responseTooLarge {
            // Reception stopped before the final URL/DNS checks completed.
            // An oversized document does not establish a TLS failure.
            return resultRecord(
                entry: entry, task: task, now: now,
                documentation: .failed, tls: .unverified,
                failureCode: "response-too-large"
            )
        } catch {
            let nsError = error as NSError
            return resultRecord(
                entry: entry,
                task: task,
                now: now,
                documentation: .failed,
                tls: .failed,
                failureCode: "\(nsError.domain):\(nsError.code)"
            )
        }
    }

    private static func resultRecord(
        entry: ProviderCatalogEntryV2,
        task: ScheduledRelayProbe,
        now: Date,
        documentation: RelayProbeState,
        tls: RelayProbeState,
        failureCode: String?
    ) -> RelayProbeRunResult {
        RelayProbeRunResult(
            entryID: entry.id,
            verifierTaskID: task.verifierTaskID,
            completedAt: now,
            documentation: documentation,
            tls: tls,
            modelList: .unverified,
            minimalRequest: .unverified,
            failureSummarySHA256: failureCode.map {
                RelayCatalogPackageImporter.fingerprint(Data($0.utf8))
            }
        )
    }
}
