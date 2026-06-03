import Foundation

public enum api2agentBrand {
    public static let displayName = "API2Agent"
}

public struct api2agentSettings: Codable, Equatable, Sendable {
    public static let legacyapi2agentBaseURL = "https://api.cursor.com"

    public var port: UInt16
    public var api2agentKey: String
    public var keychainapi2agentKeyAvailable: Bool
    public var api2agentBaseURL: String
    public var backendBaseURL: String
    public var localAgentEndpoint: String
    public var clientVersion: String
    public var launchAtLogin: Bool
    public var menuBarOnly: Bool

    public init(
        port: UInt16 = 8787,
        api2agentKey: String = "",
        keychainapi2agentKeyAvailable: Bool = false,
        api2agentBaseURL: String = "",
        backendBaseURL: String = "",
        localAgentEndpoint: String = "",
        clientVersion: String = "sdk-1.0.13",
        launchAtLogin: Bool = false,
        menuBarOnly: Bool = false
    ) {
        self.port = port
        self.api2agentKey = api2agentKey
        self.keychainapi2agentKeyAvailable = keychainapi2agentKeyAvailable
        self.api2agentBaseURL = api2agentBaseURL
        self.backendBaseURL = backendBaseURL
        self.localAgentEndpoint = localAgentEndpoint
        self.clientVersion = clientVersion
        self.launchAtLogin = launchAtLogin
        self.menuBarOnly = menuBarOnly
    }

    public var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)/v1")!
    }

    public var hasapi2agentKey: Bool {
        hasInlineapi2agentKey || keychainapi2agentKeyAvailable
    }

    public var hasInlineapi2agentKey: Bool {
        !api2agentKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var hasCursorSDKConfiguration: Bool {
        true
    }

    public var hasapi2agentExchangeConfiguration: Bool {
        let value = api2agentBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value != Self.legacyapi2agentBaseURL
    }

    private enum CodingKeys: String, CodingKey {
        case port
        case api2agentKey
        case api2agentBaseURL
        case backendBaseURL
        case localAgentEndpoint
        case clientVersion
        case launchAtLogin
        case menuBarOnly
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? 8787
        api2agentKey = try container.decodeIfPresent(String.self, forKey: .api2agentKey) ?? ""
        keychainapi2agentKeyAvailable = false
        api2agentBaseURL = try container.decodeIfPresent(String.self, forKey: .api2agentBaseURL) ?? ""
        backendBaseURL = try container.decodeIfPresent(String.self, forKey: .backendBaseURL) ?? ""
        localAgentEndpoint = try container.decodeIfPresent(String.self, forKey: .localAgentEndpoint) ?? ""
        clientVersion = try container.decodeIfPresent(String.self, forKey: .clientVersion) ?? "sdk-1.0.13"
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        menuBarOnly = try container.decodeIfPresent(Bool.self, forKey: .menuBarOnly) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(port, forKey: .port)
        try container.encode(api2agentKey, forKey: .api2agentKey)
        try container.encode(api2agentBaseURL, forKey: .api2agentBaseURL)
        try container.encode(backendBaseURL, forKey: .backendBaseURL)
        try container.encode(localAgentEndpoint, forKey: .localAgentEndpoint)
        try container.encode(clientVersion, forKey: .clientVersion)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(menuBarOnly, forKey: .menuBarOnly)
    }
}

public enum api2agentError: Error, LocalizedError, Equatable {
    case badRequest(String)
    case notFound
    case unauthorized
    case keychainLocked
    case invalidConfiguration(String)
    case upstream(String)
    case upstreamStatus(String, Int)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .badRequest(let message), .invalidConfiguration(let message), .upstream(let message), .upstreamStatus(let message, _), .transport(let message):
            return message
        case .notFound:
            return "Not found"
        case .unauthorized:
            return "Missing or invalid authorization"
        case .keychainLocked:
            return "Saved Cursor API key is locked. Open \(api2agentBrand.displayName) and click Unlock Key before using one-click agent configs."
        }
    }

    public var statusCode: Int {
        switch self {
        case .badRequest:
            return 400
        case .unauthorized, .keychainLocked:
            return 401
        case .notFound:
            return 404
        case .invalidConfiguration:
            return 500
        case .upstream, .transport:
            return 502
        case .upstreamStatus(_, let status):
            return status
        }
    }

    public var code: String {
        switch self {
        case .badRequest:
            return "invalid_request"
        case .notFound:
            return "not_found"
        case .unauthorized:
            return "unauthorized"
        case .keychainLocked:
            return "keychain_locked"
        case .invalidConfiguration:
            return "invalid_configuration"
        case .upstream, .upstreamStatus:
            return "upstream_error"
        case .transport:
            return "transport_error"
        }
    }
}

public struct ComposerModel: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var inputCost: Double
    public var outputCost: Double
    public var contextWindow: Int
    public var outputLimit: Int

    public init(
        id: String,
        name: String,
        inputCost: Double,
        outputCost: Double,
        contextWindow: Int = 200_000,
        outputLimit: Int = 65_536
    ) {
        self.id = id
        self.name = name
        self.inputCost = inputCost
        self.outputCost = outputCost
        self.contextWindow = contextWindow
        self.outputLimit = outputLimit
    }
}

public enum ComposerModels {
    public static let all: [ComposerModel] = [
        ComposerModel(id: "deepseek-v4-flash", name: "DeepSeek V4 Flash", inputCost: 0, outputCost: 0),
        ComposerModel(id: "deepseek-v4-pro", name: "DeepSeek V4 Pro", inputCost: 0, outputCost: 0),
        ComposerModel(id: "deepseek-chat", name: "DeepSeek Chat (legacy)", inputCost: 0, outputCost: 0),
        ComposerModel(id: "deepseek-reasoner", name: "DeepSeek Reasoner (legacy)", inputCost: 0, outputCost: 0)
    ]

    public static func model(for id: String) -> ComposerModel? {
        let candidates = modelIDCandidates(for: id)
        return all.first { model in
            candidates.contains(model.id.lowercased())
                || candidates.contains(model.id.replacingOccurrences(of: ".", with: "-").lowercased())
        }
    }

    public static func resolvedModelID(for requestedModel: String?) throws -> String {
        guard let requestedModel = requestedModel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requestedModel.isEmpty else {
            return Self.all[0].id
        }
        guard let model = Self.model(for: requestedModel) else {
            throw api2agentError.notFound
        }
        return model.id
    }

    private static func modelIDCandidates(for id: String) -> Set<String> {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        let strippedProvider = trimmed.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? trimmed
        var candidates = Set([trimmed, strippedProvider])
        for candidate in Array(candidates) {
            candidates.insert(candidate.replacingOccurrences(of: ".", with: "-"))
            if candidate.hasSuffix("-sdk") {
                let base = String(candidate.dropLast(4))
                candidates.insert(base)
                candidates.insert(base.replacingOccurrences(of: ".", with: "-"))
            }
        }
        return candidates
    }
}

public struct CursorToolCall: Codable, Equatable, Sendable {
    public var name: String
    public var arguments: [String: JSONValue]

    public init(name: String, arguments: [String: JSONValue]) {
        self.name = name
        self.arguments = arguments
    }
}

public struct CursorSDKOutput: Equatable, Sendable {
    public var text: String
    public var toolCalls: [CursorToolCall]
    public var agentID: String
    public var runID: String

    public init(text: String, toolCalls: [CursorToolCall] = [], agentID: String, runID: String) {
        self.text = text
        self.toolCalls = toolCalls
        self.agentID = agentID
        self.runID = runID
    }
}

public enum AgentIntegrationID: String, CaseIterable, Codable, Sendable {
    case opencode
    case codex
    case vscode
    case cline
    case kilo
    case pi
    case claude
    case continueDev = "continue"
    case aider
    case roo

    public var displayName: String {
        switch self {
        case .opencode:
            return "OpenCode"
        case .codex:
            return "Codex"
        case .vscode:
            return "VS Code"
        case .cline:
            return "Cline"
        case .kilo:
            return "Kilo Code"
        case .pi:
            return "pi"
        case .claude:
            return "Claude Code"
        case .continueDev:
            return "Continue"
        case .aider:
            return "Aider"
        case .roo:
            return "Roo Code"
        }
    }
}

public struct AgentIntegrationStatus: Equatable, Sendable, Identifiable {
    private static let updateableDetails = Set([
        "Provider needs update",
        "Provider found with a different local URL",
        "Provider points at a hosted API"
    ])

    public var id: AgentIntegrationID
    public var installed: Bool
    public var configPath: String?
    public var detail: String
    public var canInstall: Bool

    public var needsUpdate: Bool {
        !installed
            && canInstall
            && Self.updateableDetails.contains(detail)
    }

    public var actionTitle: String {
        if installed {
            return "Installed"
        }
        if !canInstall {
            return "Unavailable"
        }
        return needsUpdate ? "Update" : "Install"
    }

    public init(id: AgentIntegrationID, installed: Bool, configPath: String?, detail: String, canInstall: Bool = true) {
        self.id = id
        self.installed = installed
        self.configPath = configPath
        self.detail = detail
        self.canInstall = canInstall
    }
}
