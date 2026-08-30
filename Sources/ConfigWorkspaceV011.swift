// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

@MainActor
extension ConfigWorkspaceModel {
    func refreshV011RuntimeTruth(force: Bool = false) {
        if isV011RuntimeRefreshing, !force { return }
        v011Collaborator.runtimeTask?.cancel()
        isV011RuntimeRefreshing = true
        v011RuntimeStatus = "正在读取Codex当前状态"
        let home = codexHomeURL
        let transactionRoot = v011Collaborator.controlRoot
            .appendingPathComponent(
            "SwitchTransactions",
            isDirectory: true
        )
        v011Collaborator.runtimeTask = Task { [weak self] in
            let outcome = await Task.detached(
                priority: .userInitiated
            ) {
                () -> Result<
                    (LiveCodexState, Bool),
                    Error
                > in
                do {
                    let discovery =
                        FableCodexVersionDiscovery()
                    let installation =
                        try discovery.discover()
                    let credentials =
                        FableMacOSKeychainCredentialStore()
                    let verifier =
                        FableLiveRuntimeVerifier(
                            codexHome: home,
                            credentialStore: credentials,
                            versionDiscovery: discovery
                        )
                    let core = FableSwitchCore(
                        codexHome: home,
                        resolvedContractEntry:
                            installation.contractEntry,
                        credentialStore: credentials,
                        processController:
                            FableMacOSProcessController(),
                        runtimeVerifier: verifier
                    )
                    let state = try core.inspect(
                        version: installation.identity
                    )
                    let pending =
                        try V011SwitchJournalStore(
                            rootURL: transactionRoot
                        ).pending().isEmpty == false
                    return .success((state, pending))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            self.isV011RuntimeRefreshing = false
            switch outcome {
            case let .success((state, pending)):
                self.v011LiveState = state
                self.v011HasPendingRecovery = pending
                if pending {
                    self.v011RuntimeStatus =
                        "上次切换未完成，请先一键恢复"
                } else if state.versionSupport.allowsWrites {
                    switch state.mode {
                    case .official:
                        self.v011RuntimeStatus =
                            "当前正在使用Codex官方"
                    case let .relay(providerID):
                        let name = self
                            .savedRelayProfiles
                            .first {
                                $0.providerID == providerID
                            }?.name ?? "一个中转"
                        self.v011RuntimeStatus =
                            "当前正在使用\(name)"
                    }
                } else {
                    self.v011RuntimeStatus =
                        "当前Codex版本尚未通过兼容验证，只允许查看"
                }
            case let .failure(error):
                self.v011LiveState = nil
                self.v011RuntimeStatus =
                    error.localizedDescription
            }
            self.v011Collaborator.runtimeTask = nil
        }
    }

    func addRelayV011() {
        guard !isV011AddingRelay else { return }
        wireProtocol = .responses
        guard let profile = makeV011RelayProfileFromDraft() else {
            return
        }
        let key = apiKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !key.isEmpty else {
            errorMessage = "请填写API Key"
            return
        }
        let codexProfile = codexProfile(from: profile)
        isV011AddingRelay = true
        v011OperationStatus = "正在拉取模型并发送最小检测请求"
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await
                    RelayConnectionVerifier.verify(
                        profile: codexProfile,
                        apiKey: key,
                        confirmedLocalGateway:
                            self.confirmsLocalGateway
                    )
                try await Task.detached {
                    try FableMacOSKeychainCredentialStore()
                        .store(
                            key,
                            reference:
                                profile
                                    .credentialReference
                        )
                }.value
                try self.saveV011RelayProfile(
                    codexProfile,
                    makeActive: false
                )
                self.savedRelayProfiles =
                    try self.v011Collaborator.stateStore.load()
                        .relayProfiles
                self.apiKey = ""
                self.isV011AddingRelay = false
                self.v011OperationStatus =
                    "\(status)。已保存，可在“切换模式”中启用。"
                self.errorMessage = nil
            } catch {
                self.isV011AddingRelay = false
                self.v011OperationStatus = "中转尚未添加"
                self.errorMessage =
                    "检测未通过："
                    + error.localizedDescription
            }
        }
    }

    func adoptCurrentRelayV011() {
        guard !isV011AddingRelay else { return }
        isV011AddingRelay = true
        v011OperationStatus = "正在接管当前中转并保持现状"
        errorMessage = nil
        let home = codexHomeURL
        let preferredName =
            existingProviderDisplayName.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        Task { [weak self] in
            guard let self else { return }
            let outcome = await Task.detached(
                priority: .userInitiated
            ) {
                () -> Result<
                    (
                        CodexRelayProfile,
                        String,
                        String
                    ),
                    Error
                > in
                do {
                    let discovery =
                        FableCodexVersionDiscovery()
                    let installation =
                        try discovery.discover()
                    let credentials =
                        FableMacOSKeychainCredentialStore()
                    let core = FableSwitchCore(
                        codexHome: home,
                        resolvedContractEntry:
                            installation.contractEntry,
                        credentialStore: credentials,
                        processController:
                            FableMacOSProcessController(),
                        runtimeVerifier:
                            FableLiveRuntimeVerifier(
                                codexHome: home,
                                credentialStore:
                                    credentials,
                                versionDiscovery:
                                    discovery
                            )
                    )
                    let live = try core.inspect(
                        version: installation.identity
                    )
                    guard case let .relay(providerID) =
                            live.mode,
                          let provider = live.provider,
                          provider.wireAPI == "responses",
                          let baseURL = provider.baseURL,
                          let model = live.model else {
                        throw FableSwitchError
                            .invalidConfiguration(
                                "当前不是可接管的Responses中转"
                            )
                    }
                    let configData = try Data(
                        contentsOf:
                            live.configURL
                    )
                    let document =
                        try TOMLSemanticEngine.parse(
                            String(
                                decoding: configData,
                                as: UTF8.self
                            )
                        )
                    guard let bearer = document.string(
                        at: [
                            "model_providers",
                            providerID,
                            "experimental_bearer_token",
                        ]
                    ), !bearer.isEmpty else {
                        throw FableSwitchError
                            .credentialUnavailable
                    }
                    let id = Self.v011ProfileID(
                        providerID: providerID,
                        baseURL: baseURL
                    )
                    let name = preferredName.isEmpty
                        ? (
                            provider.displayName
                                ?? providerID
                        ) : preferredName
                    let profile = CodexRelayProfile(
                        id: id,
                        providerID: providerID,
                        name: name,
                        baseURL: baseURL,
                        wireProtocol: .responses,
                        models: [model],
                        defaultModel: model,
                        contextWindow:
                            live.contextWindow,
                        autoCompactTokenLimit:
                            live
                                .autoCompactTokenLimit,
                        reasoningEffort:
                            Self.reasoningEffort(
                                live.reasoningEffort
                            ),
                        localGatewayConfirmed: nil
                    )
                    return .success(
                        (
                            profile,
                            bearer,
                            Self.v011CredentialReference(
                                profileID: id
                            )
                        )
                    )
                } catch {
                    return .failure(error)
                }
            }.value
            switch outcome {
            case let .success(
                (profile, bearer, reference)
            ):
                do {
                    try await Task.detached {
                        try FableMacOSKeychainCredentialStore()
                            .store(
                                bearer,
                                reference: reference
                            )
                    }.value
                    try self.saveV011RelayProfile(
                        profile,
                        makeActive: true
                    )
                    self.savedRelayProfiles =
                        try self.v011Collaborator.stateStore.load()
                            .relayProfiles
                    self.activeRelayProfileID =
                        profile.id
                    self.codexRuntimeMode = .relay
                    self.v011OperationStatus =
                        "已接管\(profile.name)，当前Codex设置未改动"
                    self.errorMessage = nil
                    self.refreshV011RuntimeTruth(
                        force: true
                    )
                } catch {
                    self.errorMessage =
                        "接管未完成："
                        + error.localizedDescription
                }
            case let .failure(error):
                self.errorMessage =
                    "接管未完成："
                    + error.localizedDescription
            }
            self.isV011AddingRelay = false
        }
    }

    func switchV011(
        to profile: CodexRelayProfile?
    ) {
        guard !isV011SwitchWorking else { return }
        guard !v011HasPendingRecovery else {
            errorMessage =
                V011SwitchError.pendingRecovery
                    .localizedDescription
            return
        }
        let destination: FableSwitchDestination
        if let profile {
            guard let relay =
                    makeFableProfile(profile) else {
                return
            }
            destination = .relay(relay)
        } else {
            destination = .official
        }
        let home = codexHomeURL
        let control = v011Collaborator.controlRoot
        let profiles = savedRelayProfiles
        let managed = Set(
            profiles.compactMap(\.providerID)
        )
        let known = Dictionary(
            uniqueKeysWithValues:
                profiles.compactMap { item in
                    item.providerID.map {
                        (
                            $0,
                            (
                                id: item.id,
                                name: item.name
                            )
                        )
                    }
                }
        )
        let keyProvider =
            v011Collaborator.keyProvider
        isV011SwitchWorking = true
        v011OperationStatus =
            profile == nil
                ? "正在切到Codex官方"
                : "正在切到\(profile!.name)"
        errorMessage = nil
        let coordinator =
            Self.makeV011Coordinator(
                codexHome: home,
                controlRoot: control,
                managedProviderIDs: managed,
                knownProfilesByProvider: known,
                keyProvider: keyProvider,
                progress: { [weak self] message in
                    Task { @MainActor in
                        self?.v011OperationStatus =
                            message
                    }
                }
            )
        Task { [weak self] in
            guard let self else { return }
            let outcome = await Task.detached(
                priority: .userInitiated
            ) {
                do {
                    return Result<
                        V011SwitchResult,
                        Error
                    >.success(
                        try await coordinator.execute(
                            destination:
                                destination
                        )
                    )
                } catch {
                    return .failure(error)
                }
            }.value
            switch outcome {
            case let .success(result):
                do {
                    var state =
                        try self.v011Collaborator.stateStore.load()
                    if let profile {
                        state.currentMode = .relay
                        state.activeRelayID =
                            profile.id
                    } else {
                        state.currentMode = .official
                        state.activeRelayID = nil
                    }
                    state.sessionSyncAuthorized =
                        result.sessionPhase == .committed
                            || result.sessionPhase == .succeeded
                    state.credentialBridgeProfileIDs = []
                    try self.v011Collaborator.stateStore.save(state)
                    self.synchronizeControlState(state)
                    self.v011LiveState = result.state
                    self.v011HasPendingRecovery = false
                    switch result.sessionPhase {
                    case .committed, .succeeded:
                        self.v011OperationStatus =
                            "设置已切换，历史会话已整理"
                    case .retryableFailure:
                        self.v011OperationStatus =
                            result.sessionReceipt?.failureCode
                                == .journalCapacityExceeded
                                ? "设置已切换；历史会话容量不足，可稍后重试"
                                : "设置已切换；历史会话未整理，可稍后重试"
                    case .notStarted, .cancelled:
                        self.v011OperationStatus =
                            "设置已切换；历史会话整理已延期"
                    case .skipped:
                        self.v011OperationStatus =
                            "设置已切换；历史会话未整理"
                    case .reserved, .prepared, .running:
                        self.v011OperationStatus =
                            "设置已切换；历史会话状态待确认"
                    case .terminalFailure:
                        self.v011OperationStatus =
                            "设置已切换；历史会话整理失败，请打开修复工具"
                    case .superseded:
                        self.v011OperationStatus =
                            "设置已切换；历史会话已由新事务替代"
                    }
                    self.errorMessage = nil
                    self.loadV011SessionFirstPage(
                        force: true
                    )
                } catch {
                    self.errorMessage =
                        "切换已完成，但助手状态保存失败："
                        + error.localizedDescription
                }
            case let .failure(error):
                self.v011OperationStatus =
                    "切换未完成，原状态已保护"
                self.errorMessage =
                    error.localizedDescription
                self.refreshV011RuntimeTruth(
                    force: true
                )
            }
            self.isV011SwitchWorking = false
        }
    }

    func recoverV011PendingSwitch() {
        guard !isV011SwitchWorking else { return }
        let coordinator = makeLiveV011Coordinator()
        isV011SwitchWorking = true
        v011OperationStatus = "正在恢复未完成的切换"
        Task { [weak self] in
            guard let self else { return }
            do {
                let count = try await Task.detached {
                    try await coordinator
                        .recoverPending()
                }.value
                self.v011OperationStatus =
                    "已恢复\(count)个未完成操作"
                self.v011HasPendingRecovery = false
                self.errorMessage = nil
                self.refreshV011RuntimeTruth(
                    force: true
                )
            } catch {
                self.errorMessage =
                    "一键恢复未完成："
                    + error.localizedDescription
            }
            self.isV011SwitchWorking = false
        }
    }

    func loadV011SessionFirstPage(
        force: Bool = false
    ) {
        if isV011SessionLoading, !force { return }
        v011Collaborator.sessionListTask?.cancel()
        v011SessionRows = []
        v011SessionTotal = 0
        v011SessionVisibleCount = nil
        v011SessionHasMore = false
        loadV011SessionPage(offset: 0)
    }

    func loadMoreV011Sessions() {
        guard v011SessionHasMore,
              !isV011SessionLoading else { return }
        loadV011SessionPage(
            offset: v011SessionRows.count
        )
    }

    func cancelV011SessionList() {
        v011Collaborator.sessionListTask?.cancel()
        v011Collaborator.sessionListTask = nil
        isV011SessionLoading = false
    }

    func repairV011SessionsToCurrentMode() {
        guard !isV011SessionWorking else { return }
        guard let provider =
                v011CurrentProviderID else {
            errorMessage =
                "尚未识别当前模式，请先重新检查"
            return
        }
        let home = codexHomeURL
        let recoveryRoot =
            v011SessionRecoveryRoot
        let keyProvider =
            v011Collaborator.keyProvider
        isV011SessionWorking = true
        v011SessionStatus =
            "正在正常关闭Codex并整理历史会话"
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            let outcome = await Task.detached(
                priority: .userInitiated
            ) {
                () -> Result<
                    SessionCoreRepairSummary,
                    Error
                > in
                do {
                    let process =
                        FableMacOSProcessController()
                    try process
                        .stopConfigurationWriters()
                    let summary =
                        try await SessionCoreClient()
                            .repair(
                                codexHome: home,
                                provider: provider,
                                recoveryRoot:
                                    recoveryRoot,
                                journalKey:
                                    try keyProvider(),
                                progress: { event in
                                    Task { @MainActor in
                                        self
                                            .v011SessionStatus =
                                            "正在整理 \(event.current)/\(event.total)"
                                    }
                                }
                            )
                    try process.relaunchCodex()
                    return .success(summary)
                } catch {
                    return .failure(error)
                }
            }.value
            switch outcome {
            case let .success(summary):
                do {
                    if let path =
                        summary.journalPath {
                        try self
                            .saveV011LastSessionJournal(
                                path
                            )
                    }
                    self.v011SessionStatus =
                        summary.noChanges
                            ? "全部历史会话已经可见"
                            : "已让全部历史会话在当前模式可见"
                    self.errorMessage = nil
                    self.loadV011SessionFirstPage(
                        force: true
                    )
                } catch {
                    self.errorMessage =
                        "会话已修复，但恢复入口保存失败："
                        + error.localizedDescription
                }
            case let .failure(error):
                self.v011SessionStatus =
                    "历史会话修复未完成"
                self.errorMessage =
                    error.localizedDescription
            }
            self.isV011SessionWorking = false
        }
    }

    func restoreLastV011SessionRepair() {
        guard !isV011SessionWorking else { return }
        guard let journal =
                loadV011LastSessionJournal() else {
            errorMessage = "没有可恢复的历史会话操作"
            return
        }
        let home = codexHomeURL
        let recoveryRoot =
            v011SessionRecoveryRoot
        let keyProvider =
            v011Collaborator.keyProvider
        isV011SessionWorking = true
        v011SessionStatus = "正在恢复上次历史会话操作"
        Task { [weak self] in
            guard let self else { return }
            let outcome = await Task.detached {
                () -> Result<
                    SessionCoreRollbackSummary,
                    Error
                > in
                do {
                    let process =
                        FableMacOSProcessController()
                    try process
                        .stopConfigurationWriters()
                    let result =
                        try await SessionCoreClient()
                            .rollback(
                                codexHome: home,
                                recoveryRoot:
                                    recoveryRoot,
                                journal: journal,
                                journalKey:
                                    try keyProvider()
                            )
                    try process.relaunchCodex()
                    return .success(result)
                } catch {
                    return .failure(error)
                }
            }.value
            switch outcome {
            case .success:
                self.v011SessionStatus =
                    "已恢复上次历史会话操作"
                self.errorMessage = nil
                self.loadV011SessionFirstPage(
                    force: true
                )
            case let .failure(error):
                self.errorMessage =
                    "恢复未完成："
                    + error.localizedDescription
            }
            self.isV011SessionWorking = false
        }
    }

    private func loadV011SessionPage(offset: Int) {
        isV011SessionLoading = true
        v011SessionStatus =
            offset == 0
                ? "正在读取首批历史会话"
                : "正在读取更多历史会话"
        let home = codexHomeURL
        let ledgerRoot =
            v011Collaborator.controlRoot.appendingPathComponent(
                "SessionOriginLedger",
                isDirectory: true
            )
        let keyProvider =
            v011Collaborator.keyProvider
        let provider = v011CurrentProviderID
        v011Collaborator.sessionListTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await
                    SessionCoreClient().list(
                        codexHome: home,
                        limit: 50,
                        offset: offset,
                        provider: provider
                    )
                let ledger = try await Task.detached {
                    try V011SessionOriginLedgerStore(
                        rootURL: ledgerRoot,
                        keyProvider: keyProvider
                    ).load()
                }.value
                let rows = page.sessions.map {
                    Self.v011SessionItem(
                        $0,
                        ledger: ledger
                    )
                }
                if offset == 0 {
                    self.v011SessionRows = rows
                } else {
                    self.v011SessionRows
                        .append(contentsOf: rows)
                }
                self.v011SessionTotal = page.total
                self.v011SessionVisibleCount =
                    page.visibleTotal
                self.v011SessionHasMore =
                    page.hasMore
                self.v011SessionStatus =
                    "共\(page.total)个会话"
                    + (
                        page.visibleTotal.map {
                            "，当前可见\($0)个"
                        } ?? ""
                    )
                self.errorMessage = nil
            } catch is CancellationError {
                self.v011SessionStatus =
                    "历史会话读取已暂停"
            } catch {
                self.v011SessionStatus =
                    "历史会话读取未完成"
                self.errorMessage =
                    error.localizedDescription
            }
            self.isV011SessionLoading = false
            self.v011Collaborator.sessionListTask = nil
        }
    }

    private var v011CurrentProviderID: String? {
        guard let state = v011LiveState else {
            return nil
        }
        switch state.mode {
        case .official:
            return "openai"
        case let .relay(providerID):
            return providerID
        }
    }

    private var v011SessionRecoveryRoot: URL {
        v011Collaborator.controlRoot.appendingPathComponent(
            "SessionCoreRecovery",
            isDirectory: true
        )
    }

    private func makeLiveV011Coordinator()
        -> V011UnifiedSwitchCoordinator {
        let profiles = savedRelayProfiles
        let known = Dictionary(
            uniqueKeysWithValues:
                profiles.compactMap { profile in
                    profile.providerID.map {
                        (
                            $0,
                            (
                                id: profile.id,
                                name: profile.name
                            )
                        )
                    }
                }
        )
        return Self.makeV011Coordinator(
            codexHome: codexHomeURL,
            controlRoot: v011Collaborator.controlRoot,
            managedProviderIDs: Set(
                profiles.compactMap(\.providerID)
            ),
            knownProfilesByProvider: known,
            keyProvider:
                v011Collaborator.keyProvider
        )
    }

    private static func makeV011Coordinator(
        codexHome: URL,
        controlRoot: URL,
        managedProviderIDs: Set<String>,
        knownProfilesByProvider:
            [String: (id: String, name: String)],
        keyProvider: @escaping () throws -> Data,
        progress: @escaping @Sendable (String) -> Void =
            { _ in }
    ) -> V011UnifiedSwitchCoordinator {
        let credentials =
            FableMacOSKeychainCredentialStore()
        let discovery =
            FableCodexVersionDiscovery()
        return V011UnifiedSwitchCoordinator(
            codexHome: codexHome,
            controlRoot: controlRoot,
            managedProviderIDs:
                managedProviderIDs,
            knownProfilesByProvider:
                knownProfilesByProvider,
            credentialStore: credentials,
            processController:
                FableMacOSProcessController(),
            runtimeVerifier:
                FableLiveRuntimeVerifier(
                    codexHome: codexHome,
                    credentialStore:
                        credentials,
                    versionDiscovery:
                        discovery
                ),
            versionDiscovery: discovery,
            relayPreflightVerifier: { profile, secret in
                _ = try await RelayConnectionVerifier.verify(
                    profile: profile,
                    apiKey: secret,
                    confirmedLocalGateway:
                        profile.localGatewayConfirmed == true
                )
            },
            keyProvider: keyProvider,
            progress: progress
        )
    }

    private static func fableFieldIntent<Value: Equatable>(
        _ value: Value?
    ) -> FableFieldIntent<Value> {
        value.map(FableFieldIntent.set) ?? .preserve
    }

    private func makeV011RelayProfileFromDraft()
        -> RelayProfile? {
        let name = providerName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let cleanBase =
            CodexPlusPlusAdapter.cleanBaseURL(baseURL)
        let model = modelName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !name.isEmpty else {
            errorMessage = "请填写中转名称"
            return nil
        }
        guard wireProtocol == .responses else {
            errorMessage =
                "当前Codex版本只开放Responses协议"
            return nil
        }
        guard CodexPlusPlusAdapter
                .isAllowedBaseURL(cleanBase) else {
            errorMessage = "请填写有效的Base URL"
            return nil
        }
        guard !model.isEmpty else {
            errorMessage = "请添加并选择一个模型"
            return nil
        }
        guard let context = Int(
            contextWindow.replacingOccurrences(
                of: "_",
                with: ""
            )
        ), context > 0 else {
            errorMessage = "请填写有效的上下文长度"
            return nil
        }
        guard let compact = Int(
            autoCompactTokenLimit
                .replacingOccurrences(
                    of: "_",
                    with: ""
                )
        ), compact > 0, compact < context else {
            errorMessage =
                "自动压缩阈值必须小于上下文长度"
            return nil
        }
        let providerID = Self.v011ProviderID(
            name: name,
            baseURL: cleanBase
        )
        let profileID = Self.v011ProfileID(
            providerID: providerID,
            baseURL: cleanBase
        )
        return RelayProfile(
            id: profileID,
            providerID: providerID,
            displayName: name,
            baseURL: cleanBase,
            model: model,
            contextWindow: context,
            autoCompactTokenLimit: compact,
            reasoningEffort:
                Self.fableReasoningValue(
                    reasoningEffort
                ),
            credentialReference:
                Self.v011CredentialReference(
                    profileID: profileID
                ),
            upstreamName:
                normalizedProviderCompatibilityName,
            modelVerbosity:
                Self.fableFieldIntent(
                    modelVerbositySetting.configuredValue
                ),
            serviceTier: Self.fableFieldIntent(
                configuredServiceTierValue
            ),
            webSearch: Self.fableFieldIntent(
                webSearchSetting.configuredValue
            ),
            disableResponseStorage:
                Self.fableFieldIntent(
                    responseStorageDisabledSetting.value
                ),
            fastMode: Self.fableFieldIntent(
                fastModeSetting.value
            )
        )
    }

    private func makeFableProfile(
        _ profile: CodexRelayProfile
    ) -> RelayProfile? {
        guard profile.wireProtocol == .responses,
              profile.providerID != nil else {
            errorMessage =
                "该中转档缺少Responses、上下文或压缩阈值，请重新核对后保存"
            return nil
        }
        let effective = profile.fableProfile
        guard let context = effective.contextWindow,
              let compact =
                effective.autoCompactTokenLimit,
              compact < context else {
            errorMessage =
                "该中转档缺少Responses、上下文或压缩阈值，请重新核对后保存"
            return nil
        }
        return RelayProfile(
            id: effective.id,
            providerID: effective.providerID,
            displayName: effective.displayName,
            baseURL: effective.baseURL,
            model: effective.model,
            contextWindow: context,
            autoCompactTokenLimit: compact,
            reasoningEffort: effective.reasoningEffort,
            credentialReference:
                Self.v011CredentialReference(
                    profileID: profile.id
                ),
            requiresOpenAIAuth:
                effective.requiresOpenAIAuth,
            upstreamName: effective.upstreamName,
            modelVerbosity: effective.modelVerbosity,
            serviceTier: effective.serviceTier,
            modelCatalogJSON:
                effective.modelCatalogJSON,
            webSearch: effective.webSearch,
            disableResponseStorage:
                effective.disableResponseStorage,
            fastMode: effective.fastMode,
            supportsWebSockets:
                effective.supportsWebSockets,
            supportsStandaloneWebSearch:
                effective
                    .supportsStandaloneWebSearch
        )
    }

    private func codexProfile(
        from profile: RelayProfile
    ) -> CodexRelayProfile {
        let existing = savedRelayProfiles.first {
            $0.id == profile.id
                || $0.v011ProviderID
                    == profile.providerID
        }
        let resolvedModels = existing?.models
            ?? (modelNames.isEmpty
                ? [profile.model] : modelNames)
        let capability = existing?.capabilityProfile
            ?? capabilityConfigurationDraft.makeProfile(
                providerID: profile.providerID,
                displayName: profile.displayName,
                baseURL: profile.baseURL,
                models: resolvedModels,
                defaultModel: profile.model,
                contextWindow: profile.contextWindow,
                localAutoCompactLimit:
                    profile.autoCompactTokenLimit,
                reasoningEffort: profile.reasoningEffort,
                supportsTextInput: supportsTextInput,
                supportsImageInput: supportsImageInput
            )
        return CodexRelayProfile(
            id: profile.id,
            providerID: profile.providerID,
            name: profile.displayName,
            baseURL: profile.baseURL,
            wireProtocol: .responses,
            models: resolvedModels,
            defaultModel: profile.model,
            contextWindow: profile.contextWindow,
            autoCompactTokenLimit:
                profile.autoCompactTokenLimit,
            reasoningEffort: reasoningEffort,
            localGatewayConfirmed:
                existing?.localGatewayConfirmed
                    ?? (isLocalGateway
                        ? confirmsLocalGateway : nil),
            catalogEntryID:
                existing?.catalogEntryID,
            capabilityProfile:
                capability,
            additionalFields:
                existing?.additionalFields ?? [:]
        )
    }

    private func saveV011RelayProfile(
        _ profile: CodexRelayProfile,
        makeActive: Bool
    ) throws {
        var state = try v011Collaborator.stateStore.load()
        state.relayProfiles.removeAll {
            $0.id == profile.id
                || (
                    $0.providerID != nil
                        && $0.providerID
                            == profile.providerID
                )
        }
        state.relayProfiles.append(profile)
        state.unverifiedLegacyRelayProfileIDs
            .removeAll { $0 == profile.id }
        state.credentialBridgeProfileIDs = []
        if makeActive {
            state.currentMode = .relay
            state.activeRelayID = profile.id
        }
        try v011Collaborator.stateStore.save(state)
    }

    private func saveV011LastSessionJournal(
        _ path: String
    ) throws {
        let url = v011Collaborator.controlRoot.appendingPathComponent(
            "SessionCoreRecovery/last-repair.json"
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONSerialization.data(
            withJSONObject: ["journalPath": path],
            options: [.sortedKeys]
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func loadV011LastSessionJournal()
        -> URL? {
        let url = v011Collaborator.controlRoot.appendingPathComponent(
            "SessionCoreRecovery/last-repair.json"
        )
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization
                .jsonObject(with: data)
                    as? [String: Any],
              let path =
                object["journalPath"] as? String
        else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private static func v011SessionItem(
        _ session: SessionCoreSession,
        ledger: V011SessionOriginLedgerPayload
    ) -> V011SessionListItem {
        V011SessionListItem(
            id: session.id,
            title: session.title.isEmpty
                ? "未命名会话" : session.title,
            originLabel:
                ledger.records[session.id]?.label
                    ?? "历史来源未知",
            currentProvider:
                session.currentProvider,
            createdAt: v011Date(
                session.createdAt
            ),
            updatedAt: v011Date(
                session.updatedAt
            ),
            workingDirectory: session.cwd,
            archived: session.archived
        )
    }

    private static func v011Date(
        _ value: SessionCoreJSONValue
    ) -> Date? {
        switch value {
        case let .number(number):
            let seconds =
                number > 10_000_000_000
                    ? number / 1_000 : number
            return Date(
                timeIntervalSince1970: seconds
            )
        case let .string(text):
            if let number = Double(text) {
                let seconds =
                    number > 10_000_000_000
                        ? number / 1_000 : number
                return Date(
                    timeIntervalSince1970:
                        seconds
                )
            }
            return ISO8601DateFormatter()
                .date(from: text)
        default:
            return nil
        }
    }

    nonisolated private static func v011ProviderID(
        name: String,
        baseURL: String
    ) -> String {
        "ai_access_"
            + String(
                TOMLSemanticEngine.sha256(
                    Data(
                        "\(name)|\(baseURL)"
                            .utf8
                    )
                ).prefix(16)
            )
    }

    nonisolated private static func v011ProfileID(
        providerID: String,
        baseURL: String
    ) -> String {
        "relay-"
            + String(
                TOMLSemanticEngine.sha256(
                    Data(
                        "\(providerID)|\(baseURL)"
                            .utf8
                    )
                ).prefix(20)
            )
    }

    nonisolated private static func v011CredentialReference(
        profileID: String
    ) -> String {
        "v011/\(profileID)"
    }

    nonisolated private static func fableReasoningValue(
        _ effort: ReasoningEffort
    ) -> String {
        switch effort {
        case .automatic:
            return "high"
        case .low:
            return "low"
        case .medium:
            return "medium"
        case .high:
            return "high"
        case .xhigh:
            return "xhigh"
        case .max:
            return "max"
        case .ultra:
            return "ultra"
        }
    }

    nonisolated private static func reasoningEffort(
        _ raw: String?
    ) -> ReasoningEffort {
        switch raw {
        case "low": return .low
        case "medium": return .medium
        case "xhigh": return .xhigh
        case "max": return .max
        case "ultra": return .ultra
        case "high": return .high
        default: return .automatic
        }
    }
}
