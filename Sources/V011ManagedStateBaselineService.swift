// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct V011ManagedStateBaseline {
    let state: V011ManagedState
    let data: Data?
    let hash: String?
    let existed: Bool
}

struct V011ManagedStateBaselineService {
    let managedStateStore: V011ManagedStateStore

    func capture() throws -> V011ManagedStateBaseline {
        let firstState = try managedStateStore.load()
        let stateURL = managedStateStore.fileURL
        let existed = FileManager.default.fileExists(
            atPath: stateURL.path
        )
        let data: Data?
        if existed {
            try SessionSyncFileSafety.requireRegularFile(
                stateURL
            )
            data = try Data(
                contentsOf: stateURL,
                options: .mappedIfSafe
            )
        } else {
            data = nil
        }
        let hash = data.map(TOMLSemanticEngine.sha256)
        let baseline = V011ManagedStateBaseline(
            state: firstState,
            data: data,
            hash: hash,
            existed: existed
        )
        try requireCurrent(baseline)
        let verifiedState = try managedStateStore.load()
        try requireCurrent(baseline)
        guard verifiedState == firstState else {
            throw V011SwitchError
                .concurrentConfigurationChange
        }
        return baseline
    }

    func requireCurrent(
        _ baseline: V011ManagedStateBaseline
    ) throws {
        let stateURL = managedStateStore.fileURL
        let exists = FileManager.default.fileExists(
            atPath: stateURL.path
        )
        guard exists == baseline.existed else {
            throw V011SwitchError
                .concurrentConfigurationChange
        }
        if exists {
            try SessionSyncFileSafety.requireRegularFile(
                stateURL
            )
        }
        guard SessionSyncFileSafety.hashIfPresent(stateURL)
                == baseline.hash else {
            throw V011SwitchError
                .concurrentConfigurationChange
        }
    }
}
