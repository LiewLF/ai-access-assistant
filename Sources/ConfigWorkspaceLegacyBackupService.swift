// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct ConfigWorkspaceLegacyBackupService {
    private let allowedRoot: URL
    private let vaultRoot: URL

    init(
        vaultRoot: URL,
        allowedRoot: URL =
            FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.allowedRoot = allowedRoot
        self.vaultRoot = vaultRoot
    }

    func scan(
        directory: URL
    ) throws -> LegacyBackupRiskReport {
        try scanner.scan(directory: directory)
    }

    func archive(
        directory: URL
    ) throws -> (
        report: LegacyBackupRiskReport,
        receipt: LegacyBackupArchiveReceipt
    ) {
        let report = try scanner.scan(directory: directory)
        let receipt = try scanner.archive(
            report: report,
            vault: SecureProfileVault(rootURL: vaultRoot)
        )
        return (report, receipt)
    }

    private var scanner: LegacyBackupRiskScanner {
        LegacyBackupRiskScanner(allowedRoot: allowedRoot)
    }
}
