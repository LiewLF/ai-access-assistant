import Foundation

/// Uses the installed official CLI to produce its own wire metadata. This is a
/// single response preflight, not a claim that a tool execution loop passed.
struct V013CPANativeProbe {
    let codexHome: URL
    let discovery: any FableCodexVersionDiscovering
    let runner: any FableCommandRunning

    func verify(profile: CodexRelayProfile, apiKey: String) throws -> String {
        guard profile.additionalFields["cpaManagedCapture"] == .bool(true),
              profile.localGatewayConfirmed == true,
              V011RelayEndpointPolicy.allows(profile.fableProfile),
              URLComponents(string: profile.baseURL)?.host == "127.0.0.1" else {
            throw V013CPACollectionError.unavailable("原生采集验证只接受已确认的本机采集入口")
        }
        let installation = try discovery.discover()
        guard installation.support.allowsWrites else {
            throw V013CPACollectionError.unavailable("当前 Codex 版本尚未支持原生采集验证")
        }
        let configURL = codexHome.appendingPathComponent("config.toml")
        let metadata = try configURL.resourceValues(forKeys:
            [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
              (metadata.fileSize ?? Int.max) <= V011LiveAgentLoopVerifier.maximumConfigurationBytes else {
            throw V013CPACollectionError.unavailable("当前配置无法安全复制到采集验证环境")
        }
        let original = try String(contentsOf: configURL, encoding: .utf8)
        _ = try TOMLSemanticEngine.parse(original)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-access-cpa-probe-\(UUID().uuidString)")
        let manager = FileManager.default
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: temporary) }
        let provider = "cpa_probe_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        func quoted(_ value: String) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        let configuration = try original + """

        [model_providers.\(provider)]
        name = "CPA native preflight"
        base_url = \(quoted(profile.baseURL))
        wire_api = "responses"
        requires_openai_auth = false
        experimental_bearer_token = \(quoted(apiKey))

        """
        let copied = temporary.appendingPathComponent("config.toml")
        try Data(configuration.utf8).write(to: copied, options: [.atomic])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copied.path)
        let result = try runner.run(executable: installation.cliURL,
            arguments: ["exec", "--ignore-rules", "--skip-git-repo-check", "--ephemeral",
                "--sandbox", "read-only", "--json", "--color", "never",
                "-c", "mcp_servers={}", "-c", "model_provider=\(try quoted(provider))",
                "-m", profile.defaultModel,
                "-c", "model_reasoning_effort=\(try quoted(profile.fableProfile.reasoningEffort))",
                "-C", temporary.path,
                "Reply only AI_ACCESS_CPA_READY. Do not call tools."],
            environmentOverrides: ["CODEX_HOME": temporary.path,
                "HTTP_PROXY": "", "HTTPS_PROXY": "", "ALL_PROXY": "",
                "http_proxy": "", "https_proxy": "", "all_proxy": "",
                "NO_PROXY": "127.0.0.1", "no_proxy": "127.0.0.1"],
            timeout: 90, maximumCapturedBytes: 512 * 1024)
        var threadID: String?
        var hasReply = false
        var started = false
        var usage: V011AgentLoopExecUsage?
        for line in String(decoding: result.standardOutput, as: UTF8.self).split(whereSeparator: { $0.isNewline }) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            switch object["type"] as? String {
            case "thread.started": threadID = object["thread_id"] as? String
            case "turn.started": started = true
            case "item.completed":
                if let item = object["item"] as? [String: Any], item["type"] as? String == "agent_message" {
                    hasReply = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        == "AI_ACCESS_CPA_READY"
                }
            case "turn.completed" where started && hasReply:
                usage = V011AgentLoopTraceAnalyzer.parseExecUsage(object["usage"], threadID: threadID)
            default: break
            }
        }
        guard result.terminationStatus == 0, usage?.isStructurallyValid == true else {
            throw V013CPACollectionError.unavailable("原生 Codex 采集响应验证未通过，未切换当前连接")
        }
        return "原生 Codex 已经本机采集入口完成一次响应；工具闭环另行验证"
    }
}
