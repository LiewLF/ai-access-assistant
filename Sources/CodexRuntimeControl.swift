// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Foundation

@MainActor
final class CodexApplicationController {
    static let bundleIdentifier = CodexApplicationLocator.bundleIdentifier

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
    }

    func requestQuit() async throws {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
        for application in applications { application.terminate() }
        for _ in 0..<30 {
            if !isRunning { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw CodexControlError.codexStillRunning
    }

    func launch() async throws {
        guard let appURL = CodexApplicationLocator.applicationURL() else {
            throw CodexControlError.codexApplicationMissing
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }
}

enum ManagedRuntimeReconciliationPolicy {
    static func accepts(
        runtimeMode: CodexRuntimeMode,
        fileHash: String?,
        state: CodexStateStore.State
    ) -> Bool {
        guard runtimeMode == state.currentMode,
              let transaction = state.lastTransaction,
              transaction.phase == .committed
                || transaction.phase == .rolledBack,
              transaction.toMode == state.currentMode else {
            return false
        }
        return transaction.afterConfigHash == fileHash
    }
}

enum ConfigurationWriterProcessInspector {
    private static let writerNameTokens = [
        "codex++", "codexplusplus", "cc switch", "ccswitch",
    ]

    @MainActor
    static func runningWriters() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard let name = application.localizedName else { return nil }
            let normalized = name.lowercased()
            return writerNameTokens.contains(where: normalized.contains) ? name : nil
        }
        .uniqued()
        .sorted()
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
