import Foundation

struct V013CPACollectorEndpoint {
    let baseURL: URL
    let apiKey: String
    let sessionID: UUID
    let expiresAt: Date
}

/// Owns one CPA process and its disposable credential copy. It does not select
/// a Codex provider, refresh OAuth credentials, or start model requests.
@MainActor
final class V013CPACollectorProcess {
    private let runtimeRoot: URL
    private let captureRoot: URL
    private let fileManager: FileManager
    private var process: Process?
    private var capture: V013CPACollectionManifest?
    private var directory: URL?
    private var log: FileHandle?

    init(runtimeRoot: URL, captureRoot: URL, fileManager: FileManager = .default) {
        self.runtimeRoot = runtimeRoot
        self.captureRoot = captureRoot
        self.fileManager = fileManager
    }

    var isRunning: Bool { process?.isRunning == true }

    func refreshCredential(_ credential: V013CPACredentialCopy) throws {
        guard isRunning, let directory, let capture,
              credential.binding.cpaCredentialAuthID == capture.credentialAuthID,
              credential.binding.verifiedOfficialAccountScopeSHA256 == capture.accountScopeSHA256 else {
            throw V013CPACollectionError.unavailable("登录账号发生变化，不能替换当前采集账号")
        }
        let file = directory.appendingPathComponent(".auth/\(capture.credentialAuthID)")
        let before = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        let after = try JSONSerialization.jsonObject(with: credential.data) as? [String: Any]
        guard let account = before?["account_id"] as? String,
              after?["account_id"] as? String == account else {
            throw V013CPACollectionError.unavailable("当前登录已切换账号，采集仍绑定原账号")
        }
        try privateWrite(credential.data, to: file)
    }

    func start(
        credential: V013CPACredentialCopy,
        port: UInt16,
        now: Date = Date()
    ) async throws -> V013CPACollectorEndpoint {
        guard process == nil, port >= 1024,
              credential.expiresAt > now.addingTimeInterval(300) else {
            throw V013CPACollectionError.unavailable("采集进程已存在、端口无效或登录凭据即将过期")
        }
        let executable = runtimeRoot.appendingPathComponent("bin/cli-proxy-api")
        let plugins = runtimeRoot.appendingPathComponent("plugins")
        guard fileManager.isExecutableFile(atPath: executable.path),
              fileManager.fileExists(atPath: plugins
                .appendingPathComponent("cpa-quota-estimator.dylib").path) else {
            throw V013CPACollectionError.unavailable("安装包未包含完整采集组件")
        }
        let id = UUID()
        let root = captureRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        directory = root
        let auth = root.appendingPathComponent(".auth", isDirectory: true)
        try fileManager.createDirectory(at: auth, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        capture = V013CPACollectionManifest(schemaVersion: 2, sessionID: id,
            credentialAuthID: credential.binding.cpaCredentialAuthID,
            accountScopeSHA256: credential.binding.verifiedOfficialAccountScopeSHA256,
            startedAt: now, stoppedAt: nil, coverageStartedAt: nil)
        let key = UUID().uuidString + UUID().uuidString
        do {
            try privateWrite(credential.data,
                to: auth.appendingPathComponent(credential.binding.cpaCredentialAuthID))
            let configuration = Self.configuration(port: port, apiKey: key,
                authDirectory: auth, plugins: plugins,
                database: root.appendingPathComponent("usage.sqlite"))
            let configURL = root.appendingPathComponent(".config.yaml")
            try privateWrite(Data(configuration.utf8), to: configURL)
            let logURL = root.appendingPathComponent("collector.log")
            try privateWrite(Data(), to: logURL)
            log = try FileHandle(forWritingTo: logURL)
            let child = Process()
            child.executableURL = executable
            child.arguments = ["-config", configURL.path]
            child.currentDirectoryURL = root
            child.standardOutput = log
            child.standardError = log
            process = child
            try child.run()
            let baseURL = URL(string: "http://127.0.0.1:\(port)/v1")!
            try await waitUntilReady(baseURL: baseURL, key: key)
            if let capture {
                try privateWrite(JSONEncoder().encode(capture),
                    to: root.appendingPathComponent("capture.json"))
            }
            return V013CPACollectorEndpoint(baseURL: baseURL, apiKey: key,
                sessionID: id, expiresAt: credential.expiresAt)
        } catch {
            // Preserve the primary failure, while retaining files if the owned
            // process cannot be confirmed stopped.
            try? await stop()
            throw error
        }
    }

    func beginCoverage(now: Date = Date()) throws {
        guard isRunning, let capture, let directory, capture.coverageStartedAt == nil else {
            throw V013CPACollectionError.unavailable("采集覆盖起点无法确认")
        }
        // CPA timestamps have whole-second precision; exclude the transition second.
        let activated = V013CPACollectionManifest(schemaVersion: capture.schemaVersion,
            sessionID: capture.sessionID, credentialAuthID: capture.credentialAuthID,
            accountScopeSHA256: capture.accountScopeSHA256, startedAt: capture.startedAt,
            stoppedAt: nil, coverageStartedAt: Date(timeIntervalSince1970:
                floor(max(now, capture.startedAt).timeIntervalSince1970) + 1))
        try privateWrite(JSONEncoder().encode(activated), to: directory.appendingPathComponent("capture.json"))
        self.capture = activated
    }

    func stop(now: Date = Date()) async throws {
        if let process, process.isRunning {
            process.terminate()
            for _ in 0..<40 {
                if !process.isRunning { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard !process.isRunning else {
                throw V013CPACollectionError.unavailable("采集进程尚未退出；凭据副本和恢复证据已保留")
            }
        }
        process = nil
        try log?.close()
        log = nil
        guard let directory else { return }
        if let capture {
            let stopped = V013CPACollectionManifest(schemaVersion: capture.schemaVersion,
                sessionID: capture.sessionID, credentialAuthID: capture.credentialAuthID,
                accountScopeSHA256: capture.accountScopeSHA256,
                startedAt: capture.startedAt, stoppedAt: max(now, capture.startedAt),
                coverageStartedAt: capture.coverageStartedAt)
            try privateWrite(JSONEncoder().encode(stopped),
                to: directory.appendingPathComponent("capture.json"))
        }
        for name in [".auth", ".config.yaml"] {
            let owned = directory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: owned.path) { try fileManager.removeItem(at: owned) }
        }
        self.directory = nil
        capture = nil
    }

    private func waitUntilReady(baseURL: URL, key: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        // Local startup readiness only; these calls never invoke a model.
        for _ in 0..<20 {
            guard process?.isRunning == true else {
                throw V013CPACollectionError.unavailable("采集组件未能启动；已保留本机启动日志")
            }
            do {
                let (_, response) = try await session.data(for: request)
                if (response as? HTTPURLResponse)?.statusCode == 200,
                   process?.isRunning == true { return }
            } catch { /* The owned process may still be binding its local port. */ }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw V013CPACollectionError.unavailable("采集组件未在期限内就绪；没有发送模型请求")
    }

    private func privateWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func configuration(
        port: UInt16, apiKey: String, authDirectory: URL, plugins: URL, database: URL
    ) -> String {
        // JSON string literals are valid YAML scalars and cannot add YAML keys.
        func quoted(_ string: String) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return String(decoding: try! encoder.encode(string), as: UTF8.self)
        }
        return """
        host: "127.0.0.1"
        port: \(port)
        auth-dir: \(quoted(authDirectory.path))
        api-keys: [\(quoted(apiKey))]
        remote-management:
          allow-remote: false
          secret-key: ""
          disable-control-panel: true
          disable-auto-update-panel: true
        logging-to-file: false
        commercial-mode: true
        request-log: false
        error-logs-max-files: 0
        request-retry: 0
        max-retry-credentials: 1
        max-retry-interval: 0
        quota-exceeded:
          switch-project: false
          switch-preview-model: false
          antigravity-credits: false
        codex:
          disable-codex-cloaking: true
        plugins:
          enabled: true
          dir: \(quoted(plugins.path))
          configs:
            cpa-quota-estimator:
              enabled: true
              data_path: \(quoted(database.path))
              sample_interval_minutes: 5
              history_days: 365
        """
    }
}
