import api2agentCore
import Foundation

@main
struct API2AgentServer {
    static func main() async {
        var settings = AppSettingsStore().load()
        settings.port = UInt16(ProcessInfo.processInfo.environment["CURSOR_API_PORT"] ?? "") ?? 9871
        if hasDeepSeekAPIKey() {
            settings.api2agentKey = "configured-via-deepseek-env"
            settings.keychainapi2agentKeyAvailable = false
        }

        let resolvedSettings = settings
        let server = LocalAPIServer(settingsProvider: { resolvedSettings })
        do {
            let port = try server.start(preferredPort: resolvedSettings.port, fallbackLimit: 20)
            print("API2Agent local proxy listening on http://127.0.0.1:\(port)/v1")
            dispatchMain()
        } catch {
            fputs("API2Agent failed to start: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func hasDeepSeekAPIKey() -> Bool {
        if let value = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"],
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        for path in deepSeekEnvPaths() {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                let normalized = trimmed.hasPrefix("export ") ? String(trimmed.dropFirst(7)) : trimmed
                guard let equals = normalized.firstIndex(of: "=") else { continue }
                let key = normalized[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = normalized[normalized.index(after: equals)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                if key == "DEEPSEEK_API_KEY", !value.isEmpty {
                    return true
                }
            }
        }
        return false
    }

    private static func deepSeekEnvPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.api2agent-env",
            "\(home)/.env",
            ".api2agent-env",
            ".env"
        ]
    }
}
