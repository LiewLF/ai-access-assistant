import Foundation

enum V011RelayEndpointPolicy {
    static func allows(_ profile: RelayProfile) -> Bool {
        addressIssue(profile.baseURL,
            localGatewayConfirmed: profile.localGatewayConfirmed) == nil
    }

    /// The live-route check needs the same loopback rules as saving, without
    /// the interactive "本机网关已确认" step: the relay is already live, so
    /// there is nothing left to confirm. Every other plain-HTTP address stays
    /// rejected, and remote relays still require HTTPS.
    static func isLoopbackGatewayAddress(_ value: String) -> Bool {
        guard let url = URLComponents(string: value),
              url.scheme?.lowercased() == "http",
              url.host == "127.0.0.1",
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.port.map({ (1024...65535).contains($0) }) == true
        else { return false }
        return true
    }

    /// The same endpoint rules as saving, with actionable draft-only guidance.
    static func draftIssue(_ value: String, localGatewayConfirmed: Bool) -> String? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let issue = addressIssue(cleaned, localGatewayConfirmed: localGatewayConfirmed) {
            return issue
        }
        let path = URLComponents(string: cleaned)?.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        if ["responses", "chat/completions", "messages"].contains(where: {
            path == $0 || path.hasSuffix("/" + $0)
        }) {
            return "这里需要基础接口地址（Base URL），不要填写 responses、chat/completions 或 messages 的完整请求地址。请按中转文档核对；助手不会自动改写。"
        }
        return nil
    }

    private static func addressIssue(_ value: String, localGatewayConfirmed: Bool) -> String? {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "请填写中转提供的基础接口地址（Base URL）。"
        }
        guard let url = URLComponents(string: value), url.host?.isEmpty == false else {
            return "地址格式不完整。请填写含 https:// 和主机名的基础接口地址（Base URL）。"
        }
        guard url.user == nil, url.password == nil else {
            return "地址不能包含用户名或密码；API Key 请填在下方密钥框。"
        }
        guard url.query == nil, url.fragment == nil else {
            return "基础接口地址不能包含 ? 查询参数或 # 片段；API Key 请填在下方密钥框。"
        }
        if url.scheme?.lowercased() == "https" { return nil }
        guard isLoopbackGatewayAddress(value) else {
            return "远程中转需要 HTTPS。已有本机网关仅支持 http://127.0.0.1:端口，端口范围为1024–65535。"
        }
        return localGatewayConfirmed ? nil : "这是本机网关地址。请先在添加中转页面确认本机网关，再读取或保存。"
    }
}
