// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Foundation

enum V016RedactedSupportBundleError:
    LocalizedError, Equatable {
    case explicitExportRequired
    case invalidDocument
    case unsafeDestination
    case jsonDestinationRequired
    case documentTooLarge
    case atomicWriteFailed

    var errorDescription: String? {
        switch self {
        case .explicitExportRequired:
            return "只有你确认保存后才会导出求助包"
        case .invalidDocument:
            return "求助包格式无效；未写入文件"
        case .unsafeDestination:
            return "只能导出到现有本机文件夹中的普通JSON文件"
        case .jsonDestinationRequired:
            return "求助包必须使用.json扩展名"
        case .documentTooLarge:
            return "求助包超过64 KB安全上限；未写入文件"
        case .atomicWriteFailed:
            return "原子写入失败；目标位置未留下半成品"
        }
    }
}

enum V016RedactedSupportBundleExporter {
    static func write(
        _ document: V016RedactedSupportBundle,
        to destinationURL: URL,
        userConfirmed: Bool,
        fileManager: FileManager = .default,
        makeUUID: () -> UUID = UUID.init
    ) throws {
        guard userConfirmed else {
            throw V016RedactedSupportBundleError
                .explicitExportRequired
        }
        guard destinationURL.isFileURL,
              destinationURL.pathExtension.lowercased() == "json" else {
            throw destinationURL.pathExtension.lowercased() == "json"
                ? V016RedactedSupportBundleError.unsafeDestination
                : V016RedactedSupportBundleError.jsonDestinationRequired
        }
        let destination = destinationURL.standardizedFileURL
        let parent = destination.deletingLastPathComponent()
        guard let parentAttributes = try? fileManager
                .attributesOfItem(atPath: parent.path),
              parentAttributes[.type] as? FileAttributeType
                == .typeDirectory else {
            throw V016RedactedSupportBundleError.unsafeDestination
        }
        if let attributes = try? fileManager.attributesOfItem(
            atPath: destination.path
        ), let type = attributes[.type] as? FileAttributeType,
           type == .typeDirectory || type == .typeSymbolicLink {
            throw V016RedactedSupportBundleError.unsafeDestination
        }
        let temporary = parent.appendingPathComponent(
            ".ai-access-support-\(makeUUID().uuidString).tmp"
        )
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: try document.encodedData(),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw V016RedactedSupportBundleError.atomicWriteFailed
        }
        defer { try? fileManager.removeItem(at: temporary) }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporary.path
            )
        } catch {
            throw V016RedactedSupportBundleError.atomicWriteFailed
        }
        guard Darwin.rename(
            temporary.path,
            destination.path
        ) == 0 else {
            throw V016RedactedSupportBundleError.atomicWriteFailed
        }
    }
}
