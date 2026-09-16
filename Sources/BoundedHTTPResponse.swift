// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum BoundedHTTPResponseError: Error {
    case responseTooLarge
}

/// Bounds the data accumulated by this reader, not URLSession's internal buffers.
/// The caller retains ownership of session configuration and redirect policy.
enum BoundedHTTPResponse {
    static func data(
        for request: URLRequest,
        session: URLSession,
        maximumBytes: Int? = nil
    ) async throws -> (Data, URLResponse) {
        guard let maximumBytes else { return try await session.data(for: request) }
        precondition(maximumBytes >= 0)
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        var completed = false
        defer { if !completed { bytes.task.cancel() } }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard response.expectedContentLength <= Int64(maximumBytes) else {
                throw BoundedHTTPResponseError.responseTooLarge
            }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumBytes else {
                    throw BoundedHTTPResponseError.responseTooLarge
                }
                data.append(byte)
            }
            try Task.checkCancellation()
            completed = true
            return (data, response)
        } onCancel: {
            bytes.task.cancel()
        }
    }
}
