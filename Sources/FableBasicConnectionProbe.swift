import Foundation

/// An ephemeral response check using the selected account, model and proxy.
/// Raw output is bounded in memory and never included in receipts or errors.
enum FableBasicConnectionProbe {
    static func run(installation: FableCodexInstallation, codexHome: URL,
        commandRunner: any FableCommandRunning, commandTimeout: TimeInterval) throws {
        try Task.checkCancellation()
        let manager = FileManager.default
        let workspace = manager.temporaryDirectory
            .appendingPathComponent("ai-access-basic-probe-\(UUID().uuidString)")
        let result: FableCommandResult
        do {
            try manager.createDirectory(at: workspace,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            defer { try? manager.removeItem(at: workspace) }
            result = try commandRunner.run(
                executable: installation.cliURL,
                arguments: try verificationArguments(codexHome: codexHome, workspace: workspace),
                environmentOverrides: ["CODEX_HOME": codexHome.path],
                timeout: commandTimeout,
                maximumCapturedBytes: 512 * 1024
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as FableLiveAdapterError {
            throw error
        } catch {
            throw FableLiveAdapterError.commandFailed
        }
        try Task.checkCancellation()
        guard result.terminationStatus == 0, hasCompletedReply(result.standardOutput) else {
            throw FableLiveAdapterError.commandFailed
        }
    }

    private static func verificationArguments(codexHome: URL, workspace: URL) throws -> [String] {
        var arguments = ["exec"]
        if let override = try mcpIsolationOverride(codexHome: codexHome) {
            arguments.append(contentsOf: ["-c", override])
        }
        arguments.append(contentsOf: [
            "--ephemeral", "--json", "--skip-git-repo-check",
            "-c", "features.apps=false", "-c", "features.plugins=false",
            "-c", "project_doc_max_bytes=0",
            "--sandbox", "read-only", "-C", workspace.path,
            "--color", "never",
            "Reply with exactly OK. Do not call tools.",
        ])
        return arguments
    }

    static func hasCompletedReply(_ data: Data) -> Bool {
        var started = false
        var replied = false
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: { $0.isNewline }) {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "turn.started": started = true; replied = false
            case "item.completed" where started:
                if let item = event["item"] as? [String: Any],
                   item["type"] as? String == "agent_message" {
                    replied = (item["text"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) == "OK"
                }
            case "turn.completed" where started && replied: return true
            default: break
            }
        }
        return false
    }

    private static func mcpIsolationOverride(codexHome: URL) throws -> String? {
        let configURL = codexHome.appendingPathComponent(
            "config.toml",
            isDirectory: false
        )
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return nil
        }
        let document: TOMLSemanticDocument
        do {
            let data = try Data(contentsOf: configURL)
            document = try TOMLSemanticEngine.parse(
                String(decoding: data, as: UTF8.self)
            )
        } catch {
            throw FableLiveAdapterError.verificationPreparationFailed
        }
        let names = Set(document.leaves.keys.compactMap { path -> String? in
            let components = TOMLSemanticEngine.decodePath(path)
            guard components.count >= 2,
                  components[0] == "mcp_servers" else {
                return nil
            }
            if components.count == 2,
               components[1] == "<empty-table>" {
                return nil
            }
            return components[1]
        })
        guard !names.isEmpty else { return nil }
        do {
            let entries = try names.sorted().map { name in
                let encoded = try JSONEncoder().encode(name)
                let key = String(decoding: encoded, as: UTF8.self)
                return "\(key) = { enabled = false }"
            }
            return "mcp_servers={ \(entries.joined(separator: ", ")) }"
        } catch {
            throw FableLiveAdapterError.verificationPreparationFailed
        }
    }

}
