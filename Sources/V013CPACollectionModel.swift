import Combine
import Foundation

@MainActor
final class V013CPACollectionModel: ObservableObject {
    static let shared = V013CPACollectionModel(dependencies: .live)
    @Published private(set) var isBusy = false
    @Published private(set) var isCollecting = false
    @Published private(set) var status = "周/月容量外推已退役"
    @Published private(set) var error: String?
    private let dependencies: V011AccessDependencies
    private let process: V013CPACollectorProcess
    private weak var accessModel: V011AccessModel?
    private var activeProfile: CodexRelayProfile?
    private var credentialExpiry: Date?
    private var maintenance: Task<Void, Never>?

    init(dependencies: V011AccessDependencies, runtimeRoot: URL? = nil) {
        self.dependencies = dependencies
        process = V013CPACollectorProcess(runtimeRoot: runtimeRoot
            ?? Bundle.main.resourceURL!.appendingPathComponent("CPACollector"),
            captureRoot: dependencies.controlRoot.appendingPathComponent("V013/CPA/captures"))
    }

    func usesOfficialAccount(_ live: LiveCodexState?) -> Bool {
        guard isCollecting, process.isRunning, let profile = activeProfile,
              case let .relay(provider)? = live?.mode else { return false }
        return provider == profile.v011ProviderID
    }

    func start(access: V011AccessModel, port: UInt16 = 8317) async {
        guard !isBusy, !process.isRunning else { return }
        accessModel = access
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            guard case .official? = access.liveState?.mode,
                  let official = access.officialUsageSnapshot else {
                throw V013CPACollectionError.unavailable("请先恢复官方连接并读取当前官方资源")
            }
            let original = try read("config.toml", maximum: 2 * 1024 * 1024)
            let document = try TOMLSemanticEngine.parse(String(decoding: original, as: UTF8.self))
            let credential = try credential(official)
            status = "正在启动本机采集组件"
            let endpoint = try await process.start(credential: credential, port: port)
            credentialExpiry = endpoint.expiresAt
            let draft = try Self.profile(document: document, endpoint: endpoint)
            status = "正在用原生 Codex 验证采集线路，将使用少量官方额度"
            let added = try await V011SavedRelayService(dependencies: dependencies)
                .add(draft: draft, apiKey: endpoint.apiKey)
            guard let profile = added.managedState.relayProfiles.first(where: {
                $0.baseURL == draft.baseURL && $0.name == draft.name
                    && $0.additionalFields["cpaManagedCapture"] == .bool(true)
            }), try read("config.toml", maximum: 2 * 1024 * 1024) == original else {
                throw V013CPACollectionError.unavailable("准备期间 Codex 设置变化，尚未切换采集线路")
            }
            activeProfile = profile
            status = "正在通过现有切换与恢复机制接入采集线路"
            access.switchToRelay(profile)
            try await awaitConnection(access, provider: profile.v011ProviderID)
            try process.beginCoverage()
            isCollecting = true
            access.refreshOfficialUsage()
            status = "正在采集日常 Codex 请求；保持助手运行，停止时恢复官方连接"
            startMaintenance(access)
        } catch {
            self.error = V011RecoveryErrorText.safeDetail(error)
            status = "采集未完成启用"
            // If a switch actually adopted this endpoint, preserve the process
            // until the existing recovery transaction can restore connectivity.
            if let profile = activeProfile, case let .relay(provider)? = access.liveState?.mode,
               provider == profile.v011ProviderID {
                isCollecting = process.isRunning
            } else {
                try? await process.stop()
            }
        }
    }

    @discardableResult
    func stop() async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        maintenance?.cancel()
        maintenance = nil
        do {
            if let access = accessModel, let profile = activeProfile,
               case let .relay(provider)? = access.liveState?.mode,
               provider == profile.v011ProviderID {
                status = "正在恢复官方连接，随后停止采集"
                access.switchToOfficial()
                try await awaitConnection(access, provider: nil)
            }
            try await process.stop()
            isCollecting = false
            credentialExpiry = nil
            status = "采集已停止，历史用量记录已保留"
            error = nil
            activeProfile = nil
            return true
        } catch {
            self.error = V011RecoveryErrorText.safeDetail(error)
            status = "采集停止未完成，进程与恢复证据已保留"
            return false
        }
    }

    var needsShutdown: Bool { isBusy || process.isRunning || activeProfile != nil }

    private func startMaintenance(_ access: V011AccessModel) {
        maintenance?.cancel()
        maintenance = Task { [weak self, weak access] in
            var tick = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, let access else { return }
                guard self.process.isRunning else {
                    self.isCollecting = false
                    self.error = "采集进程已退出；请恢复官方连接后重新启用"
                    return
                }
                tick += 1
                if tick % 10 == 0, access.canRefreshOfficialUsage { access.refreshOfficialUsage() }
                if let expiration = self.credentialExpiry,
                   expiration.timeIntervalSinceNow < 300,
                   let official = access.officialUsageSnapshot {
                    do {
                        let updated = try self.credential(official)
                        try self.process.refreshCredential(updated)
                        self.credentialExpiry = updated.expiresAt
                    } catch {
                        self.error = "登录凭据需要更新；请在 Codex 完成官方登录，或停止采集恢复官方连接"
                        if expiration <= Date() {
                            Task { _ = await self.stop() }
                            return
                        }
                    }
                }
            }
        }
    }

    private func credential(_ official: V011OfficialUsageSnapshot) throws -> V013CPACredentialCopy {
        try V013CPACredentialCopy.prepare(authData: read("auth.json", maximum: 256 * 1024),
            official: official, now: dependencies.now())
    }

    private func read(_ name: String, maximum: Int) throws -> Data {
        let url = dependencies.codexHome.appendingPathComponent(name)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= maximum else {
            throw V013CPACollectionError.unavailable("当前 Codex 文件无法安全读取")
        }
        return try Data(contentsOf: url)
    }

    private func awaitConnection(_ access: V011AccessModel, provider: String?) async throws {
        for _ in 0..<240 {
            let matched: Bool
            if let provider { matched = access.liveState?.mode == .relay(providerID: provider) }
            else { matched = access.liveState?.mode == .official }
            if matched && !access.isWorking { return }
            if !access.isWorking, access.errorMessage != nil {
                throw V013CPACollectionError.unavailable("连接切换未完成，请按现有恢复提示处理")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw V013CPACollectionError.unavailable("连接切换仍未确认，采集进程和恢复证据已保留")
    }

    static func profile(document: TOMLSemanticDocument, endpoint: V013CPACollectorEndpoint) throws -> CodexRelayProfile {
        guard let model = document.rootString("model"), !model.isEmpty,
              let selectedEffort = document.rootString("model_reasoning_effort"),
              let effort = ["low": ReasoningEffort.low, "medium": .medium,
                "high": .high, "xhigh": .xhigh, "max": .max, "ultra": .ultra][selectedEffort] else {
            throw V013CPACollectionError.unavailable("当前模型或思考设置无法原样保留，未建立采集线路")
        }
        return CodexRelayProfile(id: "cpa-capture", name: "官方订阅·本机用量采集",
            baseURL: endpoint.baseURL.absoluteString, wireProtocol: .responses,
            models: [model], defaultModel: model,
            contextWindow: document.rootInteger("model_context_window"),
            autoCompactTokenLimit: document.rootInteger("model_auto_compact_token_limit"),
            reasoningEffort: effort, localGatewayConfirmed: true,
            additionalFields: ["cpaManagedCapture": .bool(true)])
    }
}
