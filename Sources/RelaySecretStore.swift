// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Security

enum RelaySecretStore {
    private static let legacyService =
        "io.github.liewlf.aiaccessassistant.relay-key"

    static func save(_ value: String, relayID: String) throws {
        try requireLiveKeychain()
        do {
            try PersistentCredentialBridge.save(
                value,
                profileID: relayID
            )
        } catch {
            throw map(error)
        }
    }

    static func load(relayID: String) throws -> String {
        try requireLiveKeychain()
        do {
            return try PersistentCredentialBridge.load(
                profileID: relayID
            )
        } catch let error as PersistentCredentialBridgeError {
            if case let .helperFailure(code) = error,
               code == TokenHelperCompatibleExit.missingSecret {
                guard let legacy = try loadLegacy(relayID: relayID)
                else { throw CodexControlError.missingSecret }
                try save(legacy, relayID: relayID)
                try deleteLegacy(relayID: relayID)
                return legacy
            }
            throw map(error)
        } catch {
            throw map(error)
        }
    }

    static func delete(relayID: String) throws {
        try requireLiveKeychain()
        do {
            try PersistentCredentialBridge.delete(
                profileID: relayID
            )
            try deleteLegacy(relayID: relayID)
        } catch {
            throw map(error)
        }
    }

    private enum TokenHelperCompatibleExit {
        static let missingSecret: Int32 = 78
    }

    private static func loadLegacy(
        relayID: String
    ) throws -> String? {
        var query = legacyBaseQuery(relayID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            throw CodexControlError.secretStore(status)
        }
        return value
    }

    private static func deleteLegacy(
        relayID: String
    ) throws {
        let status = SecItemDelete(
            legacyBaseQuery(relayID) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CodexControlError.secretStore(status)
        }
    }

    private static func legacyBaseQuery(
        _ relayID: String
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: relayID,
        ]
    }

    private static func map(_ error: Error) -> CodexControlError {
        if let bridge = error as? PersistentCredentialBridgeError {
            switch bridge {
            case .testingBlocked:
                return .testKeychainAccessBlocked
            case let .helperFailure(code)
                where code == TokenHelperCompatibleExit.missingSecret:
                return .missingSecret
            default:
                return .credentialBridge(
                    bridge.localizedDescription
                )
            }
        }
        if let control = error as? CodexControlError {
            return control
        }
        return .credentialBridge(error.localizedDescription)
    }

    private static func requireLiveKeychain() throws {
        if ProcessInfo.processInfo.environment[
            "AI_ACCESS_ASSISTANT_TESTING"
        ] == "1" {
            throw CodexControlError.testKeychainAccessBlocked
        }
    }
}
