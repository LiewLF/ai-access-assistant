// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SwiftUI

enum MainMode: String, CaseIterable, Identifiable, Sendable {
    case home = "开始"
    case access = "接入与切换"
    case sessions = "历史会话"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .home:
            return "house"
        case .access:
            return "arrow.triangle.2.circlepath"
        case .sessions:
            return "bubble.left.and.bubble.right"
        }
    }
}

enum BeginnerAccessSection:
    String, CaseIterable, Identifiable, Sendable {
    case addRelay = "添加中转"
    case switchMode = "切换模式"

    var id: String { rawValue }
}

enum BeginnerSettingsSection:
    String, CaseIterable, Identifiable, Sendable {
    case software = "软件安装"
    case capabilities = "扩展能力"
    case relayDirectory = "中转资料"
    case continuity = "迁移设置"
    case diagnostics = "高级诊断"
    case guide = "使用说明"
    case about = "关于"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .software:
            return "square.and.arrow.down"
        case .capabilities:
            return "sparkles"
        case .relayDirectory:
            return "books.vertical"
        case .continuity:
            return "square.and.arrow.up.on.square"
        case .diagnostics:
            return "stethoscope"
        case .guide:
            return "book.closed"
        case .about:
            return "info.circle"
        }
    }
}

enum AppDisplayTextSize:
    String, CaseIterable, Identifiable, Sendable {
    case standard
    case large
    case extraLarge

    static let storageKey = "app.display.text-size"
    static let defaultValue = Self.standard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "标准"
        case .large: return "较大"
        case .extraLarge: return "最大"
        }
    }

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .standard: return .large
        case .large: return .xLarge
        case .extraLarge: return .xxLarge
        }
    }
}

@MainActor
final class AppShellState: ObservableObject {
    @Published private(set) var mode: MainMode = .home
    @Published private(set) var accessSection:
        BeginnerAccessSection = .addRelay
    @Published private(set) var settingsOpen = false
    @Published private(set) var settingsInitialSection:
        BeginnerSettingsSection = .software

    func selectMainMode(_ mode: MainMode) {
        self.mode = mode
    }

    func selectAccessSection(
        _ section: BeginnerAccessSection
    ) {
        accessSection = section
    }

    func openAccess(_ section: BeginnerAccessSection) {
        accessSection = section
        mode = .access
    }

    func openSettings(_ section: BeginnerSettingsSection) {
        settingsInitialSection = section
        settingsOpen = true
    }

    func setSettingsPresented(_ presented: Bool) {
        settingsOpen = presented
    }
}

enum AppVaultKeyMigrationState: Equatable, Sendable {
    case checking
    case ready
    case migrationRequired
    case cleanupRequired
    case migrating
    case migrated(legacyRemoved: Bool)
    case failed(String)
}

struct AppVaultKeyMigrationDependencies: Sendable {
    let refreshState:
        @Sendable () async throws -> AppVaultKeyMigrationState
    let migrateState:
        @Sendable () async throws -> AppVaultKeyMigrationState
}

@MainActor
final class AppVaultKeyMigrationModel: ObservableObject {
    @Published private(set) var state:
        AppVaultKeyMigrationState = .checking

    private let dependencies: AppVaultKeyMigrationDependencies
    private var operationGeneration: UInt64 = 0
    private var task: Task<Void, Never>?

    init(dependencies: AppVaultKeyMigrationDependencies) {
        self.dependencies = dependencies
    }

    var hasActiveOperation: Bool {
        task != nil
    }

    var showsBanner: Bool {
        switch state {
        case .checking, .ready:
            return false
        case .migrationRequired, .cleanupRequired,
             .migrating, .migrated, .failed:
            return true
        }
    }

    func refresh() {
        start(
            initialState: .checking,
            operation: dependencies.refreshState
        )
    }

    func migrate() {
        guard state != .migrating else { return }
        start(
            initialState: .migrating,
            operation: dependencies.migrateState
        )
    }

    func dismissCompletedState() {
        if case .migrated = state {
            state = .ready
        }
    }

    private func start(
        initialState: AppVaultKeyMigrationState,
        operation: @escaping @Sendable () async throws
            -> AppVaultKeyMigrationState
    ) {
        operationGeneration &+= 1
        let generation = operationGeneration
        task?.cancel()
        state = initialState
        task = Task { [weak self] in
            do {
                let nextState = try await operation()
                try Task.checkCancellation()
                self?.commit(
                    nextState,
                    generation: generation
                )
            } catch is CancellationError {
                self?.finish(generation: generation)
            } catch {
                self?.commit(
                    .failed(error.localizedDescription),
                    generation: generation
                )
            }
        }
    }

    private func commit(
        _ nextState: AppVaultKeyMigrationState,
        generation: UInt64
    ) {
        guard generation == operationGeneration else {
            return
        }
        state = nextState
        task = nil
    }

    private func finish(generation: UInt64) {
        guard generation == operationGeneration else {
            return
        }
        task = nil
    }
}
