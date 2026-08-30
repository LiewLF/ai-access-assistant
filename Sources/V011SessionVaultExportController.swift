// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

@MainActor
protocol V011SessionVaultExportControllerDelegate: AnyObject {
    func sessionVaultDidExport(
        _ summary: SessionVaultExportSummary
    )
    func sessionVaultExportDidCancel()
    func sessionVaultExportDidFail(_ error: Error)
    func sessionVaultExportDidBecomeIdle()
}

/// Owns security-scoped destination access, export task lifetime, and
/// detached SessionVault I/O. HistoryModel remains the weak delegate for
/// operation and user-facing status projection.
@MainActor
final class V011SessionVaultExportController {
    private let codexHome: URL
    private weak var delegate:
        (any V011SessionVaultExportControllerDelegate)?
    private var task: Task<Void, Never>?

    init(
        codexHome: URL,
        delegate: any V011SessionVaultExportControllerDelegate
    ) {
        self.codexHome = codexHome
        self.delegate = delegate
    }

    func export(to destination: URL) {
        let codexHome = codexHome
        task = Task { [weak self] in
            guard let self else { return }
            let accessed = destination
                .startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    destination
                        .stopAccessingSecurityScopedResource()
                }
            }
            do {
                let summary = try await Task.detached(
                    priority: .userInitiated
                ) {
                    try SessionVault.export(
                        codexHome: codexHome,
                        destination: destination
                    )
                }.value
                try Task.checkCancellation()
                delegate?.sessionVaultDidExport(summary)
            } catch is CancellationError {
                delegate?.sessionVaultExportDidCancel()
            } catch {
                delegate?.sessionVaultExportDidFail(error)
            }
            delegate?.sessionVaultExportDidBecomeIdle()
            task = nil
        }
    }
}
