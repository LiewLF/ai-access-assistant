// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct CodexStateStore {
    let fileURL: URL

    struct State: Codable, Equatable {
        static let currentSchemaVersion = 5

        var schemaVersion: Int
        var baseline: OfficialBaseline?
        var officialBaselineTrust: OfficialBaselineTrust
        var officialOverlay: OfficialOverlay?
        var relayProfiles: [CodexRelayProfile]
        var unverifiedLegacyRelayProfileIDs: [String]
        var currentMode: CodexRuntimeMode
        var activeRelayID: String?
        var sessionSyncAuthorized: Bool
        var credentialBridgeProfileIDs: [String]
        var lastTransaction: RealSwitchTransaction?

        init(
            schemaVersion: Int = State.currentSchemaVersion,
            baseline: OfficialBaseline?,
            officialBaselineTrust: OfficialBaselineTrust? = nil,
            officialOverlay: OfficialOverlay?,
            relayProfiles: [CodexRelayProfile],
            unverifiedLegacyRelayProfileIDs: [String] = [],
            currentMode: CodexRuntimeMode,
            activeRelayID: String?,
            sessionSyncAuthorized: Bool = false,
            credentialBridgeProfileIDs: [String] = [],
            lastTransaction: RealSwitchTransaction?
        ) {
            self.schemaVersion = schemaVersion
            self.baseline = baseline
            self.officialBaselineTrust =
                officialBaselineTrust
                    ?? (
                        baseline == nil
                            ? .missing : .candidate
                    )
            self.officialOverlay = officialOverlay
            self.relayProfiles = relayProfiles
            self.unverifiedLegacyRelayProfileIDs =
                unverifiedLegacyRelayProfileIDs
            self.currentMode = currentMode
            self.activeRelayID = activeRelayID
            self.sessionSyncAuthorized = sessionSyncAuthorized
            self.credentialBridgeProfileIDs =
                credentialBridgeProfileIDs
            self.lastTransaction = lastTransaction
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case baseline
            case officialBaselineTrust
            case officialOverlay
            case relayProfiles
            case unverifiedLegacyRelayProfileIDs
            case currentMode
            case activeRelayID
            case sessionSyncAuthorized
            case credentialBridgeProfileIDs
            case lastTransaction
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decodeIfPresent(
                Int.self,
                forKey: .schemaVersion
            ) ?? 1
            baseline = try values.decodeIfPresent(
                OfficialBaseline.self,
                forKey: .baseline
            )
            officialBaselineTrust = try values
                .decodeIfPresent(
                    OfficialBaselineTrust.self,
                    forKey: .officialBaselineTrust
                )
                ?? (
                    baseline == nil
                        ? .missing : .legacyCandidate
                )
            officialOverlay = try values.decodeIfPresent(
                OfficialOverlay.self,
                forKey: .officialOverlay
            )
            relayProfiles = try values.decodeIfPresent(
                [CodexRelayProfile].self,
                forKey: .relayProfiles
            ) ?? []
            unverifiedLegacyRelayProfileIDs = try values
                .decodeIfPresent(
                    [String].self,
                    forKey:
                        .unverifiedLegacyRelayProfileIDs
                )
                ?? relayProfiles.map(\.id)
            currentMode = try values.decodeIfPresent(
                CodexRuntimeMode.self,
                forKey: .currentMode
            ) ?? .official
            activeRelayID = try values.decodeIfPresent(
                String.self,
                forKey: .activeRelayID
            )
            sessionSyncAuthorized = try values
                .decodeIfPresent(
                    Bool.self,
                    forKey: .sessionSyncAuthorized
                ) ?? false
            credentialBridgeProfileIDs = try values
                .decodeIfPresent(
                    [String].self,
                    forKey:
                        .credentialBridgeProfileIDs
                ) ?? []
            lastTransaction = try values.decodeIfPresent(
                RealSwitchTransaction.self,
                forKey: .lastTransaction
            )
        }

        var needsMigration: Bool {
            schemaVersion < State.currentSchemaVersion
        }

        func migratedToCurrentSchema() -> State {
            var copy = self
            copy.schemaVersion = State.currentSchemaVersion
            return copy
        }
    }

    func load() throws -> State {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return State(
                baseline: nil,
                officialBaselineTrust: .missing,
                officialOverlay: nil,
                relayProfiles: [],
                currentMode: .official,
                activeRelayID: nil,
                lastTransaction: nil
            )
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(State.self, from: Data(contentsOf: fileURL))
        guard state.schemaVersion <= State.currentSchemaVersion else {
            throw CodexControlError.unsupportedStateSchema(state.schemaVersion)
        }
        return state.needsMigration ? state.migratedToCurrentSchema() : state
    }

    func save(_ state: State) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state.migratedToCurrentSchema()).write(
            to: fileURL,
            options: .atomic
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
