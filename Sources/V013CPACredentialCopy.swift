import Foundation

enum V013CPACollectionError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self { case .unavailable(let reason): return reason }
    }
}

/// Copies only a currently usable access credential. Refresh ownership remains
/// with Codex; CPA never receives the original refresh token.
struct V013CPACredentialCopy {
    let data: Data
    let expiresAt: Date
    let binding: V013CPACredentialScopeBinding

    static func prepare(
        authData: Data, official: V011OfficialUsageSnapshot, now: Date
    ) throws -> Self {
        guard authData.count <= 256 * 1024, official.isFresh(at: now),
              let scope = official.accountScopeSHA256,
              let auth = try JSONSerialization.jsonObject(with: authData) as? [String: Any],
              auth["auth_mode"] as? String == "chatgpt",
              let tokens = auth["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String,
              let identity = tokens["id_token"] as? String,
              let accountID = tokens["account_id"] as? String, !accountID.isEmpty,
              let accessClaims = claims(access), let identityClaims = claims(identity),
              let accessAuth = accessClaims["https://api.openai.com/auth"] as? [String: Any],
              accessAuth["chatgpt_account_id"] as? String == accountID,
              let identityAuth = identityClaims["https://api.openai.com/auth"] as? [String: Any],
              identityAuth["chatgpt_account_id"] as? String == accountID,
              let email = identityClaims["email"] as? String, !email.isEmpty,
              let expiration = accessClaims["exp"] as? Double,
              expiration.isFinite, expiration > now.timeIntervalSince1970 + 300,
              V011LiveOfficialUsageReader.accountScopeSHA256(accountType: official.accountType,
                  email: email, planType: official.planType) == scope else {
            throw V013CPACollectionError.unavailable(
                "当前登录凭据与官方账号不一致或即将过期；请先在 Codex 完成登录并刷新官方资源")
        }
        let expiresAt = Date(timeIntervalSince1970: expiration)
        let copy: [String: Any] = [
            "type": "codex", "access_token": access, "id_token": identity,
            "account_id": accountID, "email": email, "refresh_token": "",
            "expired": ISO8601DateFormatter().string(from: expiresAt),
        ]
        return try Self(data: JSONSerialization.data(withJSONObject: copy, options: [.sortedKeys]),
            expiresAt: expiresAt, binding: V013CPACredentialScopeBinding(
                cpaCredentialAuthID: "codex.json", verifiedOfficialAccountScopeSHA256: scope))
    }

    private static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1].utf8.count <= 128 * 1024 else { return nil }
        var encoded = parts[1].replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
