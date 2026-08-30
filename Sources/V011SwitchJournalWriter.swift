// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct V011SwitchJournalWriter {
    let keyProvider: () throws -> Data

    func validatedKey() throws -> Data {
        let key = try keyProvider()
        guard key.count == 32 else {
            throw SecureProfileVaultError.encodingFailed
        }
        return key
    }

    func update(
        _ journal: inout V011SwitchJournal,
        phase: V011SwitchPhase,
        message: String,
        store: V011SwitchJournalStore
    ) throws {
        journal.phase = phase
        journal.updatedAt = Date()
        journal.message = message
        if journal.stateCASManaged == true {
            try V011SwitchStateEvidenceAuthenticator.seal(
                &journal,
                key: validatedKey()
            )
        }
        try store.save(journal)
    }
}
