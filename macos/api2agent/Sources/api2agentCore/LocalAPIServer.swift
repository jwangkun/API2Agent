import Foundation
import Network

private enum RoutedHTTPResponse {
    case response(HTTPResponse)
    case stream(HTTPStreamResponse)

    var status: Int {
        switch self {
        case .response(let response):
            return response.status
        case .stream(let response):
            return response.status
        }
    }

    var isStreaming: Bool {
        if case .stream = self {
            return true
        }
        return false
    }
}

private struct HTTPStreamResponse {
    var status: Int
    var headers: [String: String]
    var chunks: AsyncThrowingStream<Data, any Error>
    var usage: LocalAPIUsageBox?
    var observation: StreamObservation?
}

private struct StreamObservation {
    var method: String
    var path: String
    var started: Date
}

private struct DeepSeekStreamingToolCall: Sendable {
    var id: String?
    var name: String?
    var arguments: String
}

private final class LocalAPIUsageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: LocalAPIUsage?

    func set(_ value: LocalAPIUsage?) {
        lock.withLock {
            storage = value
        }
    }

    func value() -> LocalAPIUsage? {
        lock.withLock {
            storage
        }
    }
}

public struct LocalAPIRequestEvent: Equatable, Sendable {
    public var method: String
    public var path: String
    public var status: Int
    public var durationMilliseconds: Int
    public var streaming: Bool
    public var usage: LocalAPIUsage?
    public var finishedAt: Date

    public init(method: String, path: String, status: Int, durationMilliseconds: Int, streaming: Bool, usage: LocalAPIUsage? = nil, finishedAt: Date = Date()) {
        self.method = method
        self.path = path
        self.status = status
        self.durationMilliseconds = durationMilliseconds
        self.streaming = streaming
        self.usage = usage
        self.finishedAt = finishedAt
    }
}

public struct LocalAPIUsage: Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedInputTokens: Int
    public var costDollars: Double

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cachedInputTokens: Int = 0, costDollars: Double = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.costDollars = costDollars
    }
}

public final class LocalAPIServer: @unchecked Sendable {
    public typealias SettingsProvider = @Sendable () -> api2agentSettings
    public typealias RequestObserver = @Sendable (LocalAPIRequestEvent) -> Void

    private let queue = DispatchQueue(label: "api2agent.LocalAPIServer")
    private let settingsProvider: SettingsProvider
    private let harness: any CursorSDKHarness
    private let responseSessions: LocalResponseSessionStore
    private let requestObserver: RequestObserver?
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    public private(set) var port: UInt16?

    public init(
        settingsProvider: @escaping SettingsProvider,
        harness: any CursorSDKHarness = LocalCursorSDKHarness(),
        responseStateLimit: Int = 512,
        requestObserver: RequestObserver? = nil
    ) {
        self.settingsProvider = settingsProvider
        self.harness = harness
        self.responseSessions = LocalResponseSessionStore(maxEntries: responseStateLimit)
        self.requestObserver = requestObserver
    }

    public func start(port: UInt16) throws {
        stop()
        let endpointPort = NWEndpoint.Port(rawValue: port)!
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: endpointPort)
        let listener = try NWListener(using: parameters)
        let startResult = ListenerStartResult(port: port)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = port
                startResult.succeed()
            case .failed(let error):
                self?.port = nil
                startResult.fail(error)
            case .cancelled:
                self?.port = nil
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        do {
            try startResult.wait()
        } catch {
            listener.cancel()
            self.listener = nil
            self.port = nil
            throw error
        }
    }

    @discardableResult
    public func start(preferredPort: UInt16, fallbackLimit: Int) throws -> UInt16 {
        var lastError: (any Error)?
        let maxAttempts = max(1, fallbackLimit)
        for offset in 0..<maxAttempts {
            let candidateValue = Int(preferredPort) + offset
            guard candidateValue <= Int(UInt16.max), let candidate = UInt16(exactly: candidateValue) else {
                break
            }
            do {
                try start(port: candidate)
                return candidate
            } catch {
                lastError = error
            }
        }
        throw lastError ?? api2agentError.transport("Could not find an available local API port.")
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        queue.async { [weak self] in
            guard let self else { return }
            let connections = Array(self.connections.values)
            self.connections.removeAll()
            for connection in connections {
                connection.cancel()
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections[id] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        read(connection: connection, accumulated: Data(), sentContinue: false)
    }

    private func read(connection: NWConnection, accumulated: Data, sentContinue: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.send(connection: connection, response: self.errorResponse(error))
                return
            }
            var data = accumulated
            if let content {
                data.append(content)
            }
            if let request = HTTPParser.parse(data) {
                Task {
                    let routed = await self.route(request)
                    switch routed {
                    case .response(let response):
                        self.send(connection: connection, response: response)
                    case .stream(let response):
                        await self.sendStreaming(connection: connection, response: response)
                    }
                }
            } else if isComplete {
                self.send(connection: connection, response: self.errorResponse(api2agentError.badRequest("Could not parse HTTP request.")))
            } else if !sentContinue, HTTPParser.shouldSendContinue(data) {
                self.sendContinue(connection: connection, accumulated: data)
            } else {
                self.read(connection: connection, accumulated: data, sentContinue: sentContinue)
            }
        }
    }

    private func sendContinue(connection: NWConnection, accumulated: Data) {
        let data = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.send(connection: connection, response: self.errorResponse(error))
            } else {
                self.read(connection: connection, accumulated: accumulated, sentContinue: true)
            }
        })
    }

    private func route(_ request: HTTPRequest) async -> RoutedHTTPResponse {
        let started = Date()
        let method = request.method.uppercased()
        let path = normalizedAPIPath(request.path)
        let routed = await routedResponse(for: request, method: method, path: path)
        switch routed {
        case .response(let response):
            requestObserver?(LocalAPIRequestEvent(
                method: method,
                path: path,
                status: response.status,
                durationMilliseconds: max(0, Int(Date().timeIntervalSince(started) * 1000)),
                streaming: false,
                usage: Self.usage(from: response)
            ))
            return routed
        case .stream(var response):
            response.observation = StreamObservation(method: method, path: path, started: started)
            return .stream(response)
        }
    }

    private static func usage(from response: HTTPResponse) -> LocalAPIUsage? {
        guard response.status < 400,
              let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let usageObject = root["usage"] as? [String: Any] else {
            return nil
        }
        return usage(fromObject: root, usage: usageObject)
    }

    private static func usage(fromObject root: [String: Any]) -> LocalAPIUsage? {
        guard let usageObject = root["usage"] as? [String: Any] else {
            return nil
        }
        return usage(fromObject: root, usage: usageObject)
    }

    private static func usage(fromObject root: [String: Any], usage usageObject: [String: Any]) -> LocalAPIUsage? {
        let inputTokens = intValue(usageObject["input_tokens"]) ?? intValue(usageObject["prompt_tokens"]) ?? 0
        let outputTokens = intValue(usageObject["output_tokens"]) ?? intValue(usageObject["completion_tokens"]) ?? 0
        let inputDetails = usageObject["input_tokens_details"] as? [String: Any]
        let promptDetails = usageObject["prompt_tokens_details"] as? [String: Any]
        let cachedTokens = intValue(inputDetails?["cached_tokens"]) ?? intValue(promptDetails?["cached_tokens"]) ?? 0
        let modelID = stringValue(root["model"]) ?? "composer-2.5"
        let model = ComposerModels.model(for: modelID) ?? ComposerModels.all[0]
        let billableInput = max(0, inputTokens - cachedTokens)
        let cost = (Double(billableInput) * model.inputCost + Double(outputTokens) * model.outputCost) / 1_000_000
        return LocalAPIUsage(inputTokens: inputTokens, outputTokens: outputTokens, cachedInputTokens: cachedTokens, costDollars: cost)
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static let envCache: [String: String] = {
        var env: [String: String] = [:]
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".api2agent-env").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".env").path,
            ".api2agent-env",
            ".env"
        ]
        for path in candidates {
            guard let data = FileManager.default.contents(atPath: path),
                  let content = String(data: data, encoding: .utf8) else { continue }
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let val = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                env[key] = val
            }
        }
        return env
    }()

    static func resolveDeepSeekKey(settings: api2agentSettings, authorizationHeader: String?) -> String {
        // 1. Env file (~/.api2agent-env, ./env) - always reliable, survives save()
        if let envKey = envCache["DEEPSEEK_API_KEY"],
           !envKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return envKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 2. System environment
        if let envKey = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"],
           !envKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return envKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 3. Authorization header (skip cursor-local placeholder)
        if let raw = authorizationHeader {
            let stripped = raw.replacingOccurrences(of: "Bearer ", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty, stripped.lowercased() != "cursor-local" {
                return stripped
            }
        }
        // 4. Plist fallback (may be empty if save() overwrote it)
        if let stored = stringValue(settings.api2agentKey), !stored.isEmpty {
            return stored
        }
        return ""
    }

    private static func deepSeekBaseURL() -> String {
        if let envBase = envCache["DEEPSEEK_API_BASE"],
           !envBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return envBase.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let envBase = ProcessInfo.processInfo.environment["DEEPSEEK_API_BASE"] ?? "https://api.deepseek.com"
        return envBase.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func deepSeekChatModel(for rawModel: String) -> String {
        switch rawModel {
        case "deepseek-v4-pro", "deepseek-v3", "deepseek-v4-flash":
            return "deepseek-chat"
        case "deepseek-r1", "deepseek-reasoner":
            return "deepseek-reasoner"
        default:
            return rawModel
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func routedResponse(for request: HTTPRequest, method: String, path: String) async -> RoutedHTTPResponse {
        do {
            if method == "OPTIONS" {
                return .response(HTTPResponse(status: 204, headers: corsHeaders(), body: Data()))
            }
            if isReadMethod(method), path == "/" || path == "/v1" {
                let settings = settingsProvider()
                let responseState = await responseSessions.stats()
                return try readResponse(withCORS(HTTPResponse.json(serviceObject(settings: settings, responseState: responseState))), method: method)
            }
            if isReadMethod(method), path == "/health" {
                let settings = settingsProvider()
                let responseState = await responseSessions.stats()
                return try readResponse(HTTPResponse.json(healthObject(settings: settings, responseState: responseState)), method: method)
            }
            if isReadMethod(method), path == "/v1/models" {
                return try readResponse(withCORS(HTTPResponse.json(OpenAICompatibility.modelList())), method: method)
            }
            if isReadMethod(method), let modelID = modelID(from: path) {
                guard let model = ComposerModels.model(for: modelID) else {
                    throw api2agentError.notFound
                }
                return try readResponse(withCORS(HTTPResponse.json(OpenAICompatibility.modelObject(model))), method: method)
            }
            if method == "POST", path == "/v1/responses/input_tokens" {
                return try .response(withCORS(HTTPResponse.json(OpenAICompatibility.responseInputTokenCountObject(request.body))))
            }
            if method == "POST", path == "/v1/responses/compact" {
                let prepared = try OpenAICompatibility.prepareResponseCompactionRequest(request.body)
                let settings = settingsProvider()
                try harness.validate(settings: settings, authorization: request.header("authorization"))
                let id = "resp_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                let created = Int(Date().timeIntervalSince1970)
                let output = try await harness.complete(prepared: prepared, settings: settings, authorization: request.header("authorization"))
                return try .response(withCORS(HTTPResponse.json(OpenAICompatibility.responseCompactionObject(id: id, created: created, prepared: prepared, output: output))))
            }
            if method == "POST", path == "/v1/completions" {
                var prepared = try OpenAICompatibility.prepareCompletionRequest(request.body)
                prepared.sessionKey = sessionAffinity(request) ?? prepared.toolContext?.workingDirectory
                let settings = settingsProvider()
                try harness.validate(settings: settings, authorization: request.header("authorization"))
                let id = "cmpl_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                let created = Int(Date().timeIntervalSince1970)
                if prepared.stream {
                    let usage = LocalAPIUsageBox()
                    return .stream(HTTPStreamResponse(
                        status: 200,
                        headers: streamingHeaders(),
                        chunks: completionChunks(id: id, created: created, prepared: prepared, settings: settings, authorization: request.header("authorization"), usage: usage),
                        usage: usage
                    ))
                }
                let output = try await harness.complete(prepared: prepared, settings: settings, authorization: request.header("authorization"))
                return try .response(withCORS(HTTPResponse.json(OpenAICompatibility.completionResponse(id: id, created: created, prepared: prepared, output: output))))
            }
            if method == "POST", path == "/v1/chat/completions" {
                let rawBody = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] ?? [:]
                let requestedModel = (rawBody["model"] as? String) ?? ""
                if requestedModel.hasPrefix("deepseek-") {
                    let settings = settingsProvider()
                    let apiKey = Self.resolveDeepSeekKey(settings: settings, authorizationHeader: request.header("authorization"))
                    if apiKey.isEmpty {
                        throw api2agentError.unauthorized
                    }
                    let deepseekBase = Self.deepSeekBaseURL()
                    var urlRequest = URLRequest(url: URL(string: "\(deepseekBase)/chat/completions")!)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue((rawBody["stream"] as? Bool == true) ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
                    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    var deepseekBody = rawBody
                    let mapped = Self.deepSeekChatModel(for: requestedModel)
                    if mapped != requestedModel {
                        deepseekBody["model"] = mapped
                        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: deepseekBody)
                    } else {
                        urlRequest.httpBody = request.body
                    }
                    if rawBody["stream"] as? Bool == true {
                        let (bytes, urlResponse) = try await URLSession.shared.bytes(for: urlRequest)
                        guard let httpResponse = urlResponse as? HTTPURLResponse else {
                            throw api2agentError.transport("DeepSeek request failed")
                        }
                        guard httpResponse.statusCode == 200 else {
                            throw api2agentError.upstreamStatus("DeepSeek API error (\(httpResponse.statusCode))", httpResponse.statusCode)
                        }
                        return .stream(HTTPStreamResponse(
                            status: 200,
                            headers: streamingHeaders(),
                            chunks: AsyncThrowingStream { continuation in
                                Task {
                                    do {
                                        for try await line in bytes.lines {
                                            if line.hasPrefix("data: ") {
                                                let payload = line.dropFirst(6)
                                                if payload == "[DONE]" {
                                                    break
                                                }
                                                if let chunkData = "\(line)\n\n".data(using: .utf8) {
                                                    continuation.yield(chunkData)
                                                }
                                            }
                                        }
                                        continuation.finish()
                                    } catch {
                                        continuation.finish(throwing: error)
                                    }
                                }
                            },
                            usage: nil
                        ))
                    }
                    let (data, urlResponse) = try await URLSession.shared.data(for: urlRequest)
                    guard let httpResponse = urlResponse as? HTTPURLResponse else {
                        throw api2agentError.transport("DeepSeek request failed")
                    }
                    if httpResponse.statusCode != 200 {
                        let errorBody = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                        let message = ((errorBody?["error"] as? [String: Any])?["message"] as? String) ?? "DeepSeek API error (\(httpResponse.statusCode))"
                        throw api2agentError.upstreamStatus(message, httpResponse.statusCode)
                    }
                    return .response(withCORS(HTTPResponse(status: httpResponse.statusCode, headers: ["content-type": "application/json; charset=utf-8"], body: data)))
                }
                var prepared = try OpenAICompatibility.prepareChatRequest(request.body)
                let shortcutOutput = try OpenAICompatibility.localChatShortcutOutput(request.body)
                prepared.sessionKey = sessionAffinity(request) ?? prepared.toolContext?.workingDirectory
                let settings = settingsProvider()
                try harness.validate(settings: settings, authorization: request.header("authorization"))
                let id = "chatcmpl_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                let created = Int(Date().timeIntervalSince1970)
                if let shortcutOutput {
                    if prepared.stream {
                        let responseObject = OpenAICompatibility.chatCompletionResponse(id: id, created: created, prepared: prepared, output: shortcutOutput)
                        let usage = LocalAPIUsageBox()
                        usage.set(Self.usage(fromObject: responseObject))
                        let streamData = try OpenAICompatibility.chatCompletionStream(id: id, created: created, prepared: prepared, output: shortcutOutput)
                        return .stream(HTTPStreamResponse(
                            status: 200,
                            headers: streamingHeaders(),
                            chunks: singleChunkStream(streamData),
                            usage: usage
                        ))
                    }
                    return try .response(withCORS(HTTPResponse.json(OpenAICompatibility.chatCompletionResponse(id: id, created: created, prepared: prepared, output: shortcutOutput))))
                }
                if prepared.stream {
                    let usage = LocalAPIUsageBox()
                    return .stream(HTTPStreamResponse(
                        status: 200,
                        headers: streamingHeaders(),
                        chunks: chatCompletionChunks(id: id, created: created, prepared: prepared, settings: settings, authorization: request.header("authorization"), usage: usage),
                        usage: usage
                    ))
                }
                let output = try await harness.complete(prepared: prepared, settings: settings, authorization: request.header("authorization"))
                return try .response(withCORS(HTTPResponse.json(OpenAICompatibility.chatCompletionResponse(id: id, created: created, prepared: prepared, output: output))))
            }
            if method == "POST", path == "/v1/responses" {
                let responsesRawBody = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] ?? [:]
                let responsesRequestedModel = (responsesRawBody["model"] as? String) ?? ""
                if responsesRequestedModel.hasPrefix("deepseek-") {
                    let settings = settingsProvider()
                    return try await proxyDeepSeekResponses(
                        rawBody: responsesRawBody,
                        requestBody: request.body,
                        authorization: request.header("authorization"),
                        settings: settings
                    )
                }
                let currentResponseInputItems = try OpenAICompatibility.responseInputItems(from: request.body)
                var responseContextInputItems = currentResponseInputItems
                let currentPrepared = try OpenAICompatibility.prepareResponsesRequest(request.body)
                var prepared = currentPrepared
                if let previousResponseID = prepared.previousResponseID {
                    guard await responseSessions.knowsResponse(responseID: previousResponseID) else {
                        throw api2agentError.notFound
                    }
                    let rememberedToolCalls = await responseSessions.responseToolCalls(responseID: previousResponseID)
                    let previousContextItemsData = await responseSessions.responseContextInputItemsData(responseID: previousResponseID)
                    responseContextInputItems = OpenAICompatibility.responseContextInputItems(
                        previousContextItemsData: previousContextItemsData,
                        currentInputItems: currentResponseInputItems
                    )
                    let promptBody = try OpenAICompatibility.responseRequestBody(request.body, replacingInputWith: responseContextInputItems)
                    prepared = try OpenAICompatibility.prepareResponsesRequest(promptBody, rememberedToolCalls: rememberedToolCalls)
                    prepared.incrementalPrompt = prepared.prompt
                    prepared.responseInputItems = currentResponseInputItems
                }
                let settings = settingsProvider()
                try harness.validate(settings: settings, authorization: request.header("authorization"))
                let id = "resp_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                prepared.sessionKey = await responseSessions.sessionKey(
                    responseID: id,
                    previousResponseID: prepared.previousResponseID,
                    explicitSessionKey: sessionAffinity(request) ?? prepared.requestedSessionKey
                )
                let created = Int(Date().timeIntervalSince1970)
                if prepared.stream {
                    let usage = LocalAPIUsageBox()
                    return .stream(HTTPStreamResponse(
                        status: 200,
                        headers: streamingHeaders(),
                        chunks: responseChunks(
                            id: id,
                            created: created,
                            prepared: prepared,
                            responseContextInputItems: responseContextInputItems,
                            settings: settings,
                            authorization: request.header("authorization"),
                            usage: usage
                        ),
                        usage: usage
                    ))
                }
                let output = try await harness.complete(prepared: prepared, settings: settings, authorization: request.header("authorization"))
                let responseObject = OpenAICompatibility.responseObject(id: id, created: created, prepared: prepared, output: output)
                let response = try HTTPResponse.json(responseObject)
                await responseSessions.storeToolCalls(
                    responseID: id,
                    toolCalls: OpenAICompatibility.responseToolCallMemory(id: id, prepared: prepared, output: output)
                )
                let contextInputItems = try JSONSerialization.data(
                    withJSONObject: OpenAICompatibility.responseContextInputItemsObject(inputItems: responseContextInputItems, response: responseObject),
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                )
                await responseSessions.storeResponseContext(responseID: id, inputItemsData: contextInputItems)
                if prepared.storeResponse {
                    let inputItems = try JSONSerialization.data(
                        withJSONObject: OpenAICompatibility.responseInputItemsObject(prepared.responseInputItems),
                        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    )
                    await responseSessions.storeResponse(responseID: id, responseData: response.body, inputItemsData: inputItems)
                }
                return .response(withCORS(response))
            }
            if isReadMethod(method), let responseID = responseInputItemsID(from: path) {
                guard let data = await responseSessions.responseInputItemsData(responseID: responseID) else {
                    throw api2agentError.notFound
                }
                let listData = try paginatedInputItemsData(data, query: request.query)
                return readResponse(withCORS(HTTPResponse.data(listData, contentType: "application/json; charset=utf-8")), method: method)
            }
            if method == "POST", let responseID = responseCancelID(from: path) {
                guard await responseSessions.knowsResponse(responseID: responseID) else {
                    throw api2agentError.notFound
                }
                throw api2agentError.badRequest("Only background responses can be cancelled. \(api2agentBrand.displayName) runs local responses synchronously.")
            }
            if method == "DELETE", let responseID = responseID(from: path) {
                guard await responseSessions.deleteResponse(responseID: responseID) else {
                    throw api2agentError.notFound
                }
                return try .response(withCORS(HTTPResponse.json([
                    "id": responseID,
                    "object": "response",
                    "deleted": true
                ])))
            }
            if isReadMethod(method), let responseID = responseID(from: path) {
                guard let data = await responseSessions.responseData(responseID: responseID) else {
                    throw api2agentError.notFound
                }
                return readResponse(withCORS(HTTPResponse.data(data, contentType: "application/json; charset=utf-8")), method: method)
            }
            throw api2agentError.notFound
        } catch {
            return readResponse(errorResponse(error), method: method)
        }
    }

    private func isReadMethod(_ method: String) -> Bool {
        method == "GET" || method == "HEAD"
    }

    private func readResponse(_ response: HTTPResponse, method: String) -> RoutedHTTPResponse {
        var response = response
        if method == "HEAD" {
            response.headers["Content-Length"] = "\(response.body.count)"
            response.body = Data()
        }
        return .response(response)
    }

    private func singleChunkStream(_ data: Data) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            if !data.isEmpty {
                continuation.yield(data)
            }
            continuation.finish()
        }
    }

    private func proxyDeepSeekResponses(
        rawBody: [String: Any],
        requestBody: Data,
        authorization: String?,
        settings: api2agentSettings
    ) async throws -> RoutedHTTPResponse {
        let apiKey = Self.resolveDeepSeekKey(settings: settings, authorizationHeader: authorization)
        if apiKey.isEmpty {
            throw api2agentError.unauthorized
        }
        let currentResponseInputItems = try OpenAICompatibility.responseInputItems(from: requestBody)
        var responseContextInputItems = currentResponseInputItems
        var effectiveRawBody = rawBody
        if let previousResponseID = rawBody["previous_response_id"] as? String,
           !previousResponseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard await responseSessions.knowsResponse(responseID: previousResponseID) else {
                throw api2agentError.notFound
            }
            let previousContextItemsData = await responseSessions.responseContextInputItemsData(responseID: previousResponseID)
            responseContextInputItems = OpenAICompatibility.responseContextInputItems(
                previousContextItemsData: previousContextItemsData,
                currentInputItems: currentResponseInputItems
            )
            effectiveRawBody["input"] = responseContextInputItems.map(\.foundationValue)
        }
        let responseContextInputItemsForStorage = responseContextInputItems

        func rememberResponseContext(_ responseObject: [String: Any]) async {
            let responseOutputItems = Self.responseOutputItems(from: responseObject)
            let contextItems = responseContextInputItemsForStorage
                + responseOutputItems.map { .object($0.mapValues(JSONValue.from)) }
            if let contextInputItemsData = try? JSONSerialization.data(
                withJSONObject: OpenAICompatibility.responseInputItemsObject(contextItems),
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ) {
                await responseSessions.storeResponseContext(responseID: responseID, inputItemsData: contextInputItemsData)
            }
        }

        let rawModel = (effectiveRawBody["model"] as? String) ?? "deepseek-v4-flash"
        let model = Self.deepSeekChatModel(for: rawModel)
        let stream = effectiveRawBody["stream"] as? Bool == true

        var messages = Self.deepSeekMessages(from: effectiveRawBody, model: model)
        if messages.isEmpty {
            messages.append(["role": "user", "content": ""])
        }

        var chatBody: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": stream
        ]
        if let maxTokens = effectiveRawBody["max_output_tokens"] as? Int {
            chatBody["max_tokens"] = maxTokens
        }
        if let temperature = effectiveRawBody["temperature"] as? Double {
            chatBody["temperature"] = temperature
        }
        if let tools = Self.deepSeekTools(from: effectiveRawBody["tools"]) {
            chatBody["tools"] = tools
        }
        if let toolChoice = Self.deepSeekToolChoice(from: effectiveRawBody["tool_choice"]) {
            chatBody["tool_choice"] = toolChoice
        }

        let chatBodyData = try JSONSerialization.data(withJSONObject: chatBody)
        let deepseekBase = Self.deepSeekBaseURL()
        var urlRequest = URLRequest(url: URL(string: "\(deepseekBase)/chat/completions")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = chatBodyData

        let responseID = "resp_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let created = Int(Date().timeIntervalSince1970)

        if stream {
            let (bytes, urlResponse) = try await URLSession.shared.bytes(for: urlRequest)
            guard let httpResponse = urlResponse as? HTTPURLResponse else {
                throw api2agentError.transport("DeepSeek request failed")
            }
            if httpResponse.statusCode != 200 {
                let body = try await Self.collectDeepSeekErrorBody(bytes)
                throw api2agentError.upstreamStatus(Self.deepSeekErrorMessage(from: body, status: httpResponse.statusCode), httpResponse.statusCode)
            }
            return .stream(HTTPStreamResponse(
                status: 200,
                headers: streamingHeaders(),
                chunks: AsyncThrowingStream { continuation in
                    Task {
                        do {
                            let messageID = "msg_\(responseID)"
                            if let createdEvent = Self.responsesCreatedEvent(responseID: responseID, created: created, model: model).data(using: .utf8) {
                                continuation.yield(createdEvent)
                            }
                            if let inProgressEvent = Self.responsesInProgressEvent(responseID: responseID, created: created, model: model).data(using: .utf8) {
                                continuation.yield(inProgressEvent)
                            }
                            var accumulated = ""
                            var textStarted = false
                            var toolCalls: [Int: DeepSeekStreamingToolCall] = [:]
                            for try await line in bytes.lines {
                                if line.hasPrefix("data: ") {
                                    let payload = line.dropFirst(6)
                                    if payload == "[DONE]" { break }
                                    if let chunkData = payload.data(using: .utf8),
                                       let chunk = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any] {
                                        let delta = Self.extractChatDeltaText(chunk)
                                        if !delta.isEmpty {
                                            if !textStarted {
                                                if let itemAddedEvent = Self.responsesOutputItemAddedEvent(responseID: responseID, messageID: messageID).data(using: .utf8) {
                                                    continuation.yield(itemAddedEvent)
                                                }
                                                if let partAddedEvent = Self.responsesContentPartAddedEvent(responseID: responseID, messageID: messageID).data(using: .utf8) {
                                                    continuation.yield(partAddedEvent)
                                                }
                                                textStarted = true
                                            }
                                            accumulated += delta
                                            let event = Self.responsesTextDeltaEvent(responseID: responseID, messageID: messageID, delta: delta)
                                            if let eventData = event.data(using: .utf8) {
                                                continuation.yield(eventData)
                                            }
                                        }
                                        Self.accumulateDeepSeekToolCalls(from: chunk, into: &toolCalls)
                                    }
                                }
                            }
                            var outputItems: [[String: Any]] = []
                            if textStarted {
                                if let textDoneEvent = Self.responsesTextDoneEvent(responseID: responseID, messageID: messageID, fullText: accumulated).data(using: .utf8) {
                                    continuation.yield(textDoneEvent)
                                }
                                if let partDoneEvent = Self.responsesContentPartDoneEvent(responseID: responseID, messageID: messageID, fullText: accumulated).data(using: .utf8) {
                                    continuation.yield(partDoneEvent)
                                }
                                if let itemDoneEvent = Self.responsesOutputItemDoneEvent(responseID: responseID, messageID: messageID, fullText: accumulated).data(using: .utf8) {
                                    continuation.yield(itemDoneEvent)
                                }
                                outputItems.append(Self.responsesTextOutputItem(messageID: messageID, fullText: accumulated))
                            }
                            let toolOutputStart = outputItems.count
                            for (offset, call) in Self.deepSeekResponseToolCallItems(responseID: responseID, toolCalls: toolCalls).enumerated() {
                                let outputIndex = toolOutputStart + offset
                                outputItems.append(call)
                                for event in Self.responsesToolCallEvents(item: call, outputIndex: outputIndex) {
                                    if let eventData = event.data(using: .utf8) {
                                        continuation.yield(eventData)
                                    }
                                }
                            }
                            if outputItems.isEmpty {
                                outputItems.append(Self.responsesTextOutputItem(messageID: messageID, fullText: ""))
                            }
                            let completedResponse = Self.buildResponsesObject(responseID: responseID, created: created, model: model, outputItems: outputItems)
                            await rememberResponseContext(completedResponse)
                            let completed = Self.responsesCompletedEvent(responseID: responseID, created: created, model: model, outputItems: outputItems)
                            if let eventData = completed.data(using: .utf8) {
                                continuation.yield(eventData)
                            }
                            continuation.finish()
                        } catch {
                            let errEvent = Self.responsesErrorEvent(message: error.localizedDescription)
                            if let errData = errEvent.data(using: .utf8) {
                                continuation.yield(errData)
                            }
                            continuation.finish(throwing: error)
                        }
                    }
                },
                usage: nil
            ))
        }

        let (data, urlResponse) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw api2agentError.transport("DeepSeek request failed")
        }
        if httpResponse.statusCode != 200 {
            throw api2agentError.upstreamStatus(Self.deepSeekErrorMessage(from: data, status: httpResponse.statusCode), httpResponse.statusCode)
        }
        guard let chatJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw api2agentError.upstream("DeepSeek response was not valid JSON")
        }
        let responseObject = Self.buildResponsesObject(responseID: responseID, created: created, model: model, chatJSON: chatJSON)
        await rememberResponseContext(responseObject)
        return try .response(withCORS(HTTPResponse.json(responseObject)))
    }

    private static func deepSeekMessages(from rawBody: [String: Any], model: String) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        if let instructions = rawBody["instructions"] as? String,
           !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(["role": "system", "content": instructions])
        }

        let input = rawBody["input"]
        if let inputString = input as? String {
            messages.append(["role": "user", "content": inputString])
            return messages
        }
        guard let inputArray = input as? [[String: Any]] else {
            let text = deepSeekContentText(input)
            if !text.isEmpty {
                messages.append(["role": "user", "content": text])
            }
            return messages
        }

        for item in inputArray {
            let type = (item["type"] as? String)?.lowercased()
            if type == "function_call" {
                guard let toolCall = deepSeekAssistantToolCall(from: item) else { continue }
                messages.append([
                    "role": "assistant",
                    "content": NSNull(),
                    "tool_calls": [toolCall]
                ])
                continue
            }
            if type == "function_call_output" {
                let callID = stringValue(item["call_id"]) ?? stringValue(item["id"]) ?? ""
                let output = deepSeekContentText(item["output"] ?? item["content"])
                guard !callID.isEmpty, !output.isEmpty else { continue }
                messages.append([
                    "role": "tool",
                    "tool_call_id": callID,
                    "content": output
                ])
                continue
            }
            if type == "reasoning" {
                continue
            }

            let role = deepSeekMessageRole(item["role"] as? String)
            let content = deepSeekContentText(item["content"] ?? item["text"])
            guard !content.isEmpty else { continue }
            messages.append(["role": role, "content": content])
        }
        return messages
    }

    private static func deepSeekMessageRole(_ role: String?) -> String {
        switch role?.lowercased() {
        case "developer", "system":
            return "system"
        case "assistant":
            return "assistant"
        case "tool":
            return "tool"
        default:
            return "user"
        }
    }

    private static func deepSeekContentText(_ value: Any?) -> String {
        if let value = value as? String {
            return value
        }
        if let value = value as? [String: Any] {
            if let text = stringValue(value["text"]) {
                return text
            }
            if let output = value["output"] {
                return deepSeekContentText(output)
            }
            if let content = value["content"] {
                return deepSeekContentText(content)
            }
            return ""
        }
        if let values = value as? [[String: Any]] {
            return values.compactMap { part in
                let type = (part["type"] as? String)?.lowercased()
                if type == nil || type == "text" || type == "input_text" || type == "output_text" {
                    return stringValue(part["text"]) ?? deepSeekContentText(part["content"])
                }
                if type == "function_call_output" {
                    return deepSeekContentText(part["output"] ?? part["content"])
                }
                return nil
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        }
        if let values = value as? [Any] {
            return values.map { deepSeekContentText($0) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
        return ""
    }

    private static func deepSeekAssistantToolCall(from item: [String: Any]) -> [String: Any]? {
        guard let name = stringValue(item["name"]) else {
            return nil
        }
        let callID = stringValue(item["call_id"]) ?? stringValue(item["id"]) ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let arguments = stringValue(item["arguments"]) ?? jsonString(item["arguments"] ?? [:])
        return [
            "id": callID,
            "type": "function",
            "function": [
                "name": name,
                "arguments": arguments
            ]
        ]
    }

    private static func deepSeekTools(from rawTools: Any?) -> [[String: Any]]? {
        guard let tools = rawTools as? [[String: Any]] else {
            return nil
        }
        var converted: [[String: Any]] = []
        for tool in tools {
            guard (tool["type"] as? String)?.lowercased() == "function",
                  let name = stringValue(tool["name"]),
                  isDeepSeekFunctionName(name) else {
                continue
            }
            let description = stringValue(tool["description"]).map { String($0.prefix(4096)) } ?? ""
            let parameters = (tool["parameters"] as? [String: Any]) ?? [
                "type": "object",
                "properties": [:],
                "additionalProperties": false
            ]
            converted.append([
                "type": "function",
                "function": [
                    "name": name,
                    "description": description,
                    "parameters": parameters
                ]
            ])
        }
        return converted.isEmpty ? nil : converted
    }

    private static func isDeepSeekFunctionName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        return name.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }

    private static func deepSeekToolChoice(from rawToolChoice: Any?) -> Any? {
        if let choice = rawToolChoice as? String {
            return choice == "required" ? "auto" : choice
        }
        guard let object = rawToolChoice as? [String: Any],
              (object["type"] as? String) == "function" else {
            return nil
        }
        if let function = object["function"] as? [String: Any],
           let name = stringValue(function["name"]),
           isDeepSeekFunctionName(name) {
            return ["type": "function", "function": ["name": name]]
        }
        if let name = stringValue(object["name"]),
           isDeepSeekFunctionName(name) {
            return ["type": "function", "function": ["name": name]]
        }
        return nil
    }

    private static func collectDeepSeekErrorBody(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await line in bytes.lines {
            data.append(Data(line.utf8))
            data.append(0x0A)
        }
        return data
    }

    private static func deepSeekErrorMessage(from data: Data, status: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = (json["error"] as? [String: Any])?["message"] as? String {
                return message
            }
            if let message = json["message"] as? String {
                return message
            }
        }
        if let text = String(data: data, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "DeepSeek API error (\(status)): \(String(text.prefix(500)))"
        }
        return "DeepSeek API error (\(status))"
    }

    private static func accumulateDeepSeekToolCalls(from chunk: [String: Any], into toolCalls: inout [Int: DeepSeekStreamingToolCall]) {
        let choices = chunk["choices"] as? [[String: Any]] ?? []
        guard let delta = choices.first?["delta"] as? [String: Any],
              let calls = delta["tool_calls"] as? [[String: Any]] else {
            return
        }
        for call in calls {
            let index = intValue(call["index"]) ?? toolCalls.count
            var current = toolCalls[index] ?? DeepSeekStreamingToolCall(id: nil, name: nil, arguments: "")
            if let id = stringValue(call["id"]) {
                current.id = id
            }
            if let function = call["function"] as? [String: Any] {
                if let name = stringValue(function["name"]) {
                    current.name = name
                }
                if let arguments = stringValue(function["arguments"]) {
                    current.arguments += arguments
                }
            }
            toolCalls[index] = current
        }
    }

    private static func deepSeekResponseToolCallItems(responseID: String, toolCalls: [Int: DeepSeekStreamingToolCall]) -> [[String: Any]] {
        toolCalls.keys.sorted().compactMap { index in
            guard let call = toolCalls[index] else { return nil }
            return responseToolCallItem(responseID: responseID, index: index, callID: call.id, name: call.name, arguments: call.arguments)
        }
    }

    private static func deepSeekResponseToolCallItems(responseID: String, chatJSON: [String: Any]) -> [[String: Any]] {
        let choices = chatJSON["choices"] as? [[String: Any]] ?? []
        guard let message = choices.first?["message"] as? [String: Any],
              let calls = message["tool_calls"] as? [[String: Any]] else {
            return []
        }
        return calls.enumerated().compactMap { index, call in
            let function = call["function"] as? [String: Any]
            let arguments = stringValue(function?["arguments"]) ?? jsonString(function?["arguments"] ?? [:])
            return responseToolCallItem(
                responseID: responseID,
                index: index,
                callID: stringValue(call["id"]),
                name: stringValue(function?["name"]),
                arguments: arguments
            )
        }
    }

    private static func responseToolCallItem(responseID: String, index: Int, callID: String?, name: String?, arguments: String) -> [String: Any]? {
        guard let name, !name.isEmpty else {
            return nil
        }
        let suffix = responseID.replacingOccurrences(of: "[^A-Za-z0-9]", with: "", options: .regularExpression).suffix(18)
        return [
            "id": "fc_\(suffix)_\(index)",
            "type": "function_call",
            "call_id": callID ?? "call_\(suffix)_\(index)",
            "name": name,
            "arguments": arguments.isEmpty ? "{}" : arguments,
            "status": "completed"
        ]
    }

    private static func responsesToolCallEvents(item: [String: Any], outputIndex: Int) -> [String] {
        var pending = item
        pending["arguments"] = ""
        pending["status"] = "in_progress"
        let itemID = stringValue(item["id"]) ?? "fc_\(outputIndex)"
        let arguments = stringValue(item["arguments"]) ?? "{}"
        return [
            sseEvent(event: "response.output_item.added", data: [
                "type": "response.output_item.added",
                "output_index": outputIndex,
                "item": pending
            ]),
            sseEvent(event: "response.function_call_arguments.delta", data: [
                "type": "response.function_call_arguments.delta",
                "item_id": itemID,
                "output_index": outputIndex,
                "delta": arguments
            ]),
            sseEvent(event: "response.function_call_arguments.done", data: [
                "type": "response.function_call_arguments.done",
                "item_id": itemID,
                "output_index": outputIndex,
                "arguments": arguments
            ]),
            sseEvent(event: "response.output_item.done", data: [
                "type": "response.output_item.done",
                "output_index": outputIndex,
                "item": item
            ])
        ]
    }

    private static func extractChatDeltaText(_ chunk: [String: Any]) -> String {
        let choices = chunk["choices"] as? [[String: Any]] ?? []
        let first = choices.first
        let delta = first?["delta"] as? [String: Any]
        return (delta?["content"] as? String) ?? ""
    }

    private static func extractChatFullText(_ payload: [String: Any]) -> String? {
        let choices = payload["choices"] as? [[String: Any]] ?? []
        let first = choices.first
        if let message = first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        if let text = first?["text"] as? String {
            return text
        }
        return nil
    }

    private static func responsesTextDeltaEvent(responseID: String, messageID: String, delta: String) -> String {
        let payload: [String: Any] = [
            "type": "response.output_text.delta",
            "response_id": responseID,
            "item_id": messageID,
            "output_index": 0,
            "content_index": 0,
            "delta": delta
        ]
        return sseEvent(event: "response.output_text.delta", data: payload)
    }

    private static func responsesCreatedEvent(responseID: String, created: Int, model: String) -> String {
        let payload: [String: Any] = [
            "type": "response.created",
            "response": responsesBaseObject(responseID: responseID, created: created, model: model, status: "in_progress")
        ]
        return sseEvent(event: "response.created", data: payload)
    }

    private static func responsesInProgressEvent(responseID: String, created: Int, model: String) -> String {
        let payload: [String: Any] = [
            "type": "response.in_progress",
            "response": responsesBaseObject(responseID: responseID, created: created, model: model, status: "in_progress")
        ]
        return sseEvent(event: "response.in_progress", data: payload)
    }

    private static func responsesOutputItemAddedEvent(responseID: String, messageID: String) -> String {
        let item: [String: Any] = [
            "id": messageID,
            "type": "message",
            "status": "in_progress",
            "role": "assistant",
            "content": []
        ]
        let payload: [String: Any] = [
            "type": "response.output_item.added",
            "output_index": 0,
            "item": item
        ]
        return sseEvent(event: "response.output_item.added", data: payload)
    }

    private static func responsesContentPartAddedEvent(responseID: String, messageID: String) -> String {
        let payload: [String: Any] = [
            "type": "response.content_part.added",
            "item_id": messageID,
            "output_index": 0,
            "content_index": 0,
            "part": ["type": "output_text", "text": "", "annotations": []]
        ]
        return sseEvent(event: "response.content_part.added", data: payload)
    }

    private static func responsesTextDoneEvent(responseID: String, messageID: String, fullText: String) -> String {
        let payload: [String: Any] = [
            "type": "response.output_text.done",
            "item_id": messageID,
            "output_index": 0,
            "content_index": 0,
            "text": fullText
        ]
        return sseEvent(event: "response.output_text.done", data: payload)
    }

    private static func responsesContentPartDoneEvent(responseID: String, messageID: String, fullText: String) -> String {
        let part: [String: Any] = ["type": "output_text", "text": fullText, "annotations": []]
        let payload: [String: Any] = [
            "type": "response.content_part.done",
            "item_id": messageID,
            "output_index": 0,
            "content_index": 0,
            "part": part
        ]
        return sseEvent(event: "response.content_part.done", data: payload)
    }

    private static func responsesOutputItemDoneEvent(responseID: String, messageID: String, fullText: String) -> String {
        let item: [String: Any] = [
            "id": messageID,
            "type": "message",
            "status": "completed",
            "role": "assistant",
            "content": [["type": "output_text", "text": fullText, "annotations": []]]
        ]
        let payload: [String: Any] = [
            "type": "response.output_item.done",
            "output_index": 0,
            "item": item
        ]
        return sseEvent(event: "response.output_item.done", data: payload)
    }

    private static func responsesBaseObject(responseID: String, created: Int, model: String, status: String) -> [String: Any] {
        return [
            "id": responseID,
            "object": "response",
            "created_at": created,
            "model": model,
            "status": status,
            "output": []
        ]
    }

    private static func responsesTextOutputItem(messageID: String, fullText: String) -> [String: Any] {
        return [
            "id": messageID,
            "type": "message",
            "role": "assistant",
            "status": "completed",
            "content": [
                ["type": "output_text", "text": fullText, "annotations": []]
            ]
        ]
    }

    private static func responsesCompletedEvent(responseID: String, created: Int, model: String, fullText: String) -> String {
        let outputItems = [responsesTextOutputItem(messageID: "msg_\(responseID)", fullText: fullText)]
        return responsesCompletedEvent(responseID: responseID, created: created, model: model, outputItems: outputItems)
    }

    private static func responsesCompletedEvent(responseID: String, created: Int, model: String, outputItems: [[String: Any]]) -> String {
        let payload: [String: Any] = [
            "type": "response.completed",
            "response": [
                "id": responseID,
                "object": "response",
                "created_at": created,
                "model": model,
                "status": "completed",
                "output": outputItems
            ]
        ]
        return sseEvent(event: "response.completed", data: payload)
    }

    private static func responsesErrorEvent(message: String) -> String {
        let payload: [String: Any] = [
            "type": "error",
            "error": ["message": message]
        ]
        return sseEvent(event: "error", data: payload)
    }

    private static func buildResponsesObject(responseID: String, created: Int, model: String, fullText: String) -> [String: Any] {
        buildResponsesObject(
            responseID: responseID,
            created: created,
            model: model,
            outputItems: [responsesTextOutputItem(messageID: "msg_\(responseID)", fullText: fullText)]
        )
    }

    private static func buildResponsesObject(responseID: String, created: Int, model: String, outputItems: [[String: Any]]) -> [String: Any] {
        return [
            "id": responseID,
            "object": "response",
            "created_at": created,
            "model": model,
            "status": "completed",
            "output": outputItems
        ]
    }

    private static func responseOutputItems(from responseObject: [String: Any]) -> [[String: Any]] {
        if let outputItems = responseObject["output"] as? [[String: Any]] {
            return outputItems
        }
        if let outputItems = responseObject["output"] as? [Any] {
            return outputItems.compactMap { $0 as? [String: Any] }
        }
        return []
    }

    private static func buildResponsesObject(responseID: String, created: Int, model: String, chatJSON: [String: Any]) -> [String: Any] {
        let fullText = extractChatFullText(chatJSON) ?? ""
        let toolItems = deepSeekResponseToolCallItems(responseID: responseID, chatJSON: chatJSON)
        var outputItems: [[String: Any]] = []
        if !fullText.isEmpty || toolItems.isEmpty {
            outputItems.append(responsesTextOutputItem(messageID: "msg_\(responseID)", fullText: fullText))
        }
        outputItems.append(contentsOf: toolItems)
        return buildResponsesObject(responseID: responseID, created: created, model: model, outputItems: outputItems)
    }

    private static func sseEvent(event: String, data: [String: Any]) -> String {
        let jsonData = (try? JSONSerialization.data(withJSONObject: data)) ?? Data()
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
        return "event: \(event)\ndata: \(jsonString)\n\n"
    }

    private static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private func completionChunks(
        id: String,
        created: Int,
        prepared: PreparedChatRequest,
        settings: api2agentSettings,
        authorization: String?,
        usage: LocalAPIUsageBox?
    ) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var emittedText = ""
                    var finalOutput: CursorSDKOutput?

                    for try await event in harness.stream(prepared: prepared, settings: settings, authorization: authorization) {
                        switch event {
                        case .text(let delta):
                            emittedText += delta
                            continuation.yield(OpenAICompatibility.completionStreamText(id: id, created: created, model: prepared.model, text: delta))
                        case .toolCall:
                            continue
                        case .done(let output):
                            finalOutput = output
                        }
                    }

                    let output = resolvedOutput(finalOutput: finalOutput, emittedText: emittedText, emittedToolCalls: [])
                    usage?.set(Self.usage(fromObject: OpenAICompatibility.completionResponse(id: id, created: created, prepared: prepared, output: output)))
                    if output.text.count > emittedText.count, output.text.hasPrefix(emittedText) {
                        let suffix = String(output.text.dropFirst(emittedText.count))
                        continuation.yield(OpenAICompatibility.completionStreamText(id: id, created: created, model: prepared.model, text: suffix))
                    } else if emittedText.isEmpty, !output.text.isEmpty {
                        continuation.yield(OpenAICompatibility.completionStreamText(id: id, created: created, model: prepared.model, text: output.text))
                    }
                    continuation.yield(OpenAICompatibility.completionStreamFinish(id: id, created: created, model: prepared.model))
                    continuation.yield(OpenAICompatibility.completionStreamDone())
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func chatCompletionChunks(
        id: String,
        created: Int,
        prepared: PreparedChatRequest,
        settings: api2agentSettings,
        authorization: String?,
        usage: LocalAPIUsageBox?
    ) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    continuation.yield(OpenAICompatibility.chatCompletionStreamStart(id: id, created: created, model: prepared.model))
                    let bufferTextUntilToolDecision = shouldBufferTextUntilToolDecision(prepared)
                    var emittedText = ""
                    var emittedToolCalls: [CursorToolCall] = []
                    var finalOutput: CursorSDKOutput?

                    for try await event in harness.stream(prepared: prepared, settings: settings, authorization: authorization) {
                        switch event {
                        case .text(let delta):
                            emittedText += delta
                            if !bufferTextUntilToolDecision {
                                continuation.yield(OpenAICompatibility.chatCompletionStreamText(id: id, created: created, model: prepared.model, delta: delta))
                            }
                        case .toolCall(let toolCall):
                            let index = emittedToolCalls.count
                            emittedToolCalls.append(toolCall)
                            continuation.yield(OpenAICompatibility.chatCompletionStreamToolCall(id: id, created: created, prepared: prepared, toolCall: toolCall, index: index))
                        case .done(let output):
                            finalOutput = output
                        }
                    }

                    let output = resolvedOutput(finalOutput: finalOutput, emittedText: emittedText, emittedToolCalls: emittedToolCalls)
                    usage?.set(Self.usage(fromObject: OpenAICompatibility.chatCompletionResponse(id: id, created: created, prepared: prepared, output: output)))
                    let shouldEmitText = output.toolCalls.isEmpty
                    if shouldEmitText, output.text.count > emittedText.count, output.text.hasPrefix(emittedText) {
                        let suffix = String(output.text.dropFirst(emittedText.count))
                        continuation.yield(OpenAICompatibility.chatCompletionStreamText(id: id, created: created, model: prepared.model, delta: suffix))
                        emittedText += suffix
                    } else if shouldEmitText, (bufferTextUntilToolDecision || emittedText.isEmpty), !output.text.isEmpty {
                        continuation.yield(OpenAICompatibility.chatCompletionStreamText(id: id, created: created, model: prepared.model, delta: output.text))
                    }
                    if output.toolCalls.count > emittedToolCalls.count {
                        for (offset, toolCall) in output.toolCalls.dropFirst(emittedToolCalls.count).enumerated() {
                            let index = emittedToolCalls.count + offset
                            continuation.yield(OpenAICompatibility.chatCompletionStreamToolCall(id: id, created: created, prepared: prepared, toolCall: toolCall, index: index))
                        }
                    }
                    continuation.yield(OpenAICompatibility.chatCompletionStreamFinish(
                        id: id,
                        created: created,
                        model: prepared.model,
                        emittedToolCallCount: max(emittedToolCalls.count, output.toolCalls.count)
                    ))
                    if prepared.streamIncludeUsage {
                        continuation.yield(OpenAICompatibility.chatCompletionStreamUsage(id: id, created: created, prepared: prepared, output: output))
                    }
                    continuation.yield(OpenAICompatibility.chatCompletionStreamDone())
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func responseChunks(
        id: String,
        created: Int,
        prepared: PreparedChatRequest,
        responseContextInputItems: [JSONValue],
        settings: api2agentSettings,
        authorization: String?,
        usage: LocalAPIUsageBox?
    ) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    for chunk in OpenAICompatibility.responseStreamStart(id: id, created: created, prepared: prepared) {
                        continuation.yield(chunk)
                    }
                    let bufferTextUntilToolDecision = shouldBufferTextUntilToolDecision(prepared)
                    var emittedText = ""
                    var emittedToolCalls: [CursorToolCall] = []
                    var finalOutput: CursorSDKOutput?
                    var nextOutputIndex = 0
                    var textStarted = false
                    var textOutputIndex = 0

                    func startTextIfNeeded() {
                        guard !textStarted else { return }
                        textOutputIndex = nextOutputIndex
                        nextOutputIndex += 1
                        textStarted = true
                        for chunk in OpenAICompatibility.responseStreamTextStart(id: id, outputIndex: textOutputIndex) {
                            continuation.yield(chunk)
                        }
                    }

                    for try await event in harness.stream(prepared: prepared, settings: settings, authorization: authorization) {
                        switch event {
                        case .text(let delta):
                            guard !delta.isEmpty else { continue }
                            emittedText += delta
                            if !bufferTextUntilToolDecision {
                                startTextIfNeeded()
                                continuation.yield(OpenAICompatibility.responseStreamText(id: id, delta: delta, outputIndex: textOutputIndex))
                            }
                        case .toolCall(let toolCall):
                            let index = emittedToolCalls.count
                            let outputIndex = nextOutputIndex
                            nextOutputIndex += 1
                            emittedToolCalls.append(toolCall)
                            for chunk in OpenAICompatibility.responseStreamToolCall(id: id, prepared: prepared, toolCall: toolCall, index: index, outputIndex: outputIndex) {
                                continuation.yield(chunk)
                            }
                        case .done(let output):
                            finalOutput = output
                        }
                    }

                    let output = resolvedOutput(finalOutput: finalOutput, emittedText: emittedText, emittedToolCalls: emittedToolCalls)
                    let shouldEmitText = output.toolCalls.isEmpty
                    if shouldEmitText, output.text.count > emittedText.count, output.text.hasPrefix(emittedText) {
                        let suffix = String(output.text.dropFirst(emittedText.count))
                        if !suffix.isEmpty {
                            startTextIfNeeded()
                            continuation.yield(OpenAICompatibility.responseStreamText(id: id, delta: suffix, outputIndex: textOutputIndex))
                        }
                    } else if shouldEmitText, (bufferTextUntilToolDecision || emittedText.isEmpty), !output.text.isEmpty {
                        startTextIfNeeded()
                        continuation.yield(OpenAICompatibility.responseStreamText(id: id, delta: output.text, outputIndex: textOutputIndex))
                    }
                    if output.toolCalls.count > emittedToolCalls.count {
                        for (offset, toolCall) in output.toolCalls.dropFirst(emittedToolCalls.count).enumerated() {
                            let index = emittedToolCalls.count + offset
                            let outputIndex = nextOutputIndex
                            nextOutputIndex += 1
                            for chunk in OpenAICompatibility.responseStreamToolCall(id: id, prepared: prepared, toolCall: toolCall, index: index, outputIndex: outputIndex) {
                                continuation.yield(chunk)
                            }
                        }
                    }
                    let includeMessage = output.toolCalls.isEmpty
                    if includeMessage {
                        startTextIfNeeded()
                    }
                    let completedResponse = OpenAICompatibility.responseObject(id: id, created: created, prepared: prepared, output: output)
                    usage?.set(Self.usage(fromObject: completedResponse))
                    await responseSessions.storeToolCalls(
                        responseID: id,
                        toolCalls: OpenAICompatibility.responseToolCallMemory(id: id, prepared: prepared, output: output)
                    )
                    if let contextInputItemsData = try? JSONSerialization.data(
                        withJSONObject: OpenAICompatibility.responseContextInputItemsObject(inputItems: responseContextInputItems, response: completedResponse),
                        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    ) {
                        await responseSessions.storeResponseContext(responseID: id, inputItemsData: contextInputItemsData)
                    }
                    if prepared.storeResponse,
                       let responseData = try? JSONSerialization.data(withJSONObject: completedResponse, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                       let inputItemsData = try? JSONSerialization.data(
                        withJSONObject: OpenAICompatibility.responseInputItemsObject(prepared.responseInputItems),
                        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                       ) {
                        await responseSessions.storeResponse(responseID: id, responseData: responseData, inputItemsData: inputItemsData)
                    }
                    for chunk in OpenAICompatibility.responseStreamFinish(
                        id: id,
                        created: created,
                        prepared: prepared,
                        output: output,
                        includeMessage: includeMessage,
                        textOutputIndex: textOutputIndex,
                        completedResponse: completedResponse
                    ) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func resolvedOutput(
        finalOutput: CursorSDKOutput?,
        emittedText: String,
        emittedToolCalls: [CursorToolCall]
    ) -> CursorSDKOutput {
        guard var output = finalOutput else {
            return CursorSDKOutput(text: emittedText, toolCalls: emittedToolCalls, agentID: "", runID: "")
        }
        if output.text.isEmpty, !emittedText.isEmpty {
            output.text = emittedText
        }
        if output.toolCalls.isEmpty, !emittedToolCalls.isEmpty {
            output.toolCalls = emittedToolCalls
        }
        return output
    }

    private func shouldBufferTextUntilToolDecision(_ prepared: PreparedChatRequest) -> Bool {
        guard !prepared.tools.isEmpty else { return false }
        if prepared.prompt.contains("LOCAL TOOL REQUIRED FOR THE LATEST USER REQUEST") {
            return true
        }
        return prepared.prompt.range(
            of: #"\b(run|execute|start|launch)\b[\s\S]{0,120}\b(command|shell|terminal|server)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func send(connection: NWConnection, response: HTTPResponse) {
        var headers = response.headers
        if !headers.keys.contains(where: { $0.caseInsensitiveCompare("Content-Length") == .orderedSame }) {
            headers["Content-Length"] = "\(response.body.count)"
        }
        headers["Connection"] = "close"
        for (key, value) in corsHeaders() {
            headers[key] = value
        }
        let headerLines = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
        var data = Data("HTTP/1.1 \(response.status) \(HTTPStatusText.text(for: response.status))\r\n\(headerLines)\r\n\r\n".utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendStreaming(connection: NWConnection, response: HTTPStreamResponse) async {
        defer {
            if let observation = response.observation {
                requestObserver?(LocalAPIRequestEvent(
                    method: observation.method,
                    path: observation.path,
                    status: response.status,
                    durationMilliseconds: max(0, Int(Date().timeIntervalSince(observation.started) * 1000)),
                    streaming: true,
                    usage: response.usage?.value()
                ))
            }
            connection.cancel()
        }
        var headers = response.headers
        headers["Transfer-Encoding"] = "chunked"
        headers["Connection"] = "close"
        for (key, value) in corsHeaders() {
            headers[key] = value
        }
        let headerLines = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
        let headerData = Data("HTTP/1.1 \(response.status) \(HTTPStatusText.text(for: response.status))\r\n\(headerLines)\r\n\r\n".utf8)
        do {
            try await sendData(headerData, connection: connection)
            for try await chunk in response.chunks {
                guard !chunk.isEmpty else { continue }
                try await sendData(chunked(chunk), connection: connection)
            }
            try await sendData(Data("0\r\n\r\n".utf8), connection: connection)
        } catch {
            let errorChunk = chunked(OpenAICompatibility.streamError(error))
            try? await sendData(errorChunk, connection: connection)
            try? await sendData(Data("0\r\n\r\n".utf8), connection: connection)
        }
    }

    private func sendData(_ data: Data, connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func chunked(_ data: Data) -> Data {
        var chunk = Data("\(String(data.count, radix: 16))\r\n".utf8)
        chunk.append(data)
        chunk.append(Data("\r\n".utf8))
        return chunk
    }

    private func errorResponse(_ error: any Error) -> HTTPResponse {
        let status = (error as? api2agentError)?.statusCode ?? 500
        return (try? withCORS(HTTPResponse.json(OpenAICompatibility.openAIError(error), status: status)))
            ?? HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: Data())
    }

    private func withCORS(_ response: HTTPResponse) -> HTTPResponse {
        var response = response
        for (key, value) in corsHeaders() {
            response.headers[key] = value
        }
        return response
    }

    private func corsHeaders() -> [String: String] {
        [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Authorization, Content-Type, OpenAI-Beta, OpenAI-Organization, OpenAI-Project, X-Request-ID, X-Stainless-Arch, X-Stainless-Lang, X-Stainless-OS, X-Stainless-Package-Version, X-Stainless-Retry-Count, X-Stainless-Runtime, X-Stainless-Runtime-Version, X-Stainless-Timeout, X-Session-Affinity, X-OpenCode-Session-Id, X-OpenCode-Session, X-api2agent-Session, X-api2agent-Project, X-Project-Path, X-Workspace-Path, X-Working-Directory",
            "Access-Control-Allow-Methods": "GET, HEAD, POST, DELETE, OPTIONS",
            "Access-Control-Max-Age": "86400"
        ]
    }

    private func streamingHeaders() -> [String: String] {
        [
            "Content-Type": "text/event-stream; charset=utf-8",
            "Cache-Control": "no-cache, no-transform",
            "X-Accel-Buffering": "no"
        ]
    }

    private func normalizedAPIPath(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        if value == "/models" || value.hasPrefix("/models/") {
            return "/v1\(value)"
        }
        if value == "/completions" {
            return "/v1/completions"
        }
        if value == "/chat/completions" {
            return "/v1/chat/completions"
        }
        if value == "/responses" || value.hasPrefix("/responses/") {
            return "/v1\(value)"
        }
        return value
    }

    private func responseID(from path: String) -> String? {
        let prefix = "/v1/responses/"
        guard path.hasPrefix(prefix) else { return nil }
        let value = String(path.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("/") else { return nil }
        return value
    }

    private func modelID(from path: String) -> String? {
        let prefix = "/v1/models/"
        guard path.hasPrefix(prefix) else { return nil }
        let value = String(path.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return value.removingPercentEncoding ?? value
    }

    private func responseInputItemsID(from path: String) -> String? {
        let prefix = "/v1/responses/"
        let suffix = "/input_items"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let start = path.index(path.startIndex, offsetBy: prefix.count)
        let end = path.index(path.endIndex, offsetBy: -suffix.count)
        let value = String(path[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("/") else { return nil }
        return value
    }

    private func responseCancelID(from path: String) -> String? {
        let prefix = "/v1/responses/"
        let suffix = "/cancel"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let start = path.index(path.startIndex, offsetBy: prefix.count)
        let end = path.index(path.endIndex, offsetBy: -suffix.count)
        let value = String(path[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("/") else { return nil }
        return value
    }

    private func paginatedInputItemsData(_ data: Data, query: String?) throws -> Data {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inputItems = root["data"] as? [[String: Any]] else {
            return data
        }
        let parameters = queryParameters(query)
        let order = parameters["order"]?.lowercased() == "desc" ? "desc" : "asc"
        let limit = max(1, min(Int(parameters["limit"] ?? "") ?? inputItems.count, 100))
        var items: [[String: Any]] = order == "desc" ? Array(inputItems.reversed()) : inputItems

        if let after = parameters["after"]?.trimmingCharacters(in: .whitespacesAndNewlines), !after.isEmpty {
            if let index = items.firstIndex(where: { ($0["id"] as? String) == after }) {
                items = Array(items[items.index(after: index)...])
            } else {
                items = []
            }
        }
        if let before = parameters["before"]?.trimmingCharacters(in: .whitespacesAndNewlines), !before.isEmpty {
            if let index = items.firstIndex(where: { ($0["id"] as? String) == before }) {
                items = Array(items[..<index])
            } else {
                items = []
            }
        }

        let hasMore = items.count > limit
        let page = Array(items.prefix(limit))
        let object: [String: Any] = [
            "object": "list",
            "data": page,
            "first_id": page.first?["id"] as? String ?? NSNull(),
            "last_id": page.last?["id"] as? String ?? NSNull(),
            "has_more": hasMore
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func queryParameters(_ query: String?) -> [String: String] {
        guard let query, !query.isEmpty else { return [:] }
        var components = URLComponents()
        components.percentEncodedQuery = query
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            values[item.name] = item.value ?? ""
        }
        return values
    }

    private func sessionAffinity(_ request: HTTPRequest) -> String? {
        for name in [
            "x-session-affinity",
            "x-opencode-session-id",
            "x-opencode-session",
            "x-api2agent-session",
            "x-api2agent-project",
            "x-project-path",
            "x-workspace-path",
            "x-working-directory"
        ] {
            if let value = nonEmptyHeader(request.header(name)) {
                return value
            }
        }
        return nil
    }

    private func nonEmptyHeader(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func serviceObject(settings: api2agentSettings, responseState: LocalResponseSessionStore.Stats) -> [String: Any] {
        let health = healthObject(settings: settings, responseState: responseState)
        return [
            "object": "api.service",
            "service": api2agentBrand.displayName,
            "baseUrl": settings.baseURL.absoluteString,
            "status": health["status"] ?? "unknown",
            "ready": health["ready"] ?? false,
            "models": ComposerModels.all.map(\.id),
            "endpoints": [
                "models": "/v1/models",
                "chat_completions": "/v1/chat/completions",
                "responses": "/v1/responses",
                "response_input_tokens": "POST /v1/responses/input_tokens",
                "compact_response": "POST /v1/responses/compact",
                "delete_response": "DELETE /v1/responses/{response_id}",
                "cancel_response": "POST /v1/responses/{response_id}/cancel",
                "completions": "/v1/completions",
                "health": "/health"
            ],
            "features": [
                "chat_completions": true,
                "responses": true,
                "stateful_responses": true,
                "response_input_tokens": true,
                "response_compaction": true,
                "response_deletion": true,
                "response_cancellation": false,
                "streaming": true,
                "tool_calls": true
            ]
        ]
    }

    private func healthObject(settings: api2agentSettings, responseState: LocalResponseSessionStore.Stats) -> [String: Any] {
        let sdkBridgeConfigured = settings.hasCursorSDKConfiguration
        let apiKeyConfigured = settings.hasapi2agentKey
        let apiKeyUnlocked = settings.hasInlineapi2agentKey
        let missing = [
            apiKeyConfigured ? nil : "api2agentKey",
            sdkBridgeConfigured ? nil : "sdkBridge"
        ].compactMap { $0 }
        let status: String
        if apiKeyUnlocked && sdkBridgeConfigured {
            status = "ready"
        } else if !apiKeyConfigured {
            status = "needs_api_key"
        } else if !sdkBridgeConfigured {
            status = "sdk_bridge_missing"
        } else {
            status = "needs_unlock"
        }
        return [
            "ok": true,
            "ready": apiKeyUnlocked && sdkBridgeConfigured,
            "status": status,
            "service": api2agentBrand.displayName,
            "baseUrl": settings.baseURL.absoluteString,
            "host": "127.0.0.1",
            "routingConfigured": sdkBridgeConfigured,
            "sdkConfigured": sdkBridgeConfigured,
            "apiKeyConfigured": apiKeyConfigured,
            "apiKeyUnlocked": apiKeyUnlocked,
            "keychainKeyAvailable": settings.keychainapi2agentKeyAvailable,
            "missing": missing,
            "models": ComposerModels.all.map(\.id),
            "responses": [
                "sessions": responseState.sessions,
                "stored": responseState.storedResponses,
                "inputItems": responseState.inputItems,
                "toolCallMemory": responseState.toolCallMemory,
                "maxStored": responseState.maxEntries
            ],
            "routing": [
                "configured": sdkBridgeConfigured,
                "sdkBridgeConfigured": sdkBridgeConfigured,
                "clientVersion": settings.clientVersion
            ]
        ]
    }
}

private actor LocalResponseSessionStore {
    struct Stats: Sendable {
        var sessions: Int
        var storedResponses: Int
        var inputItems: Int
        var toolCallMemory: Int
        var maxEntries: Int
    }

    private let maxEntries: Int
    private var responseOrder: [String] = []
    private var responseSessions: [String: String] = [:]
    private var storedResponses: [String: Data] = [:]
    private var storedResponseInputItems: [String: Data] = [:]
    private var storedResponseContextInputItems: [String: Data] = [:]
    private var storedResponseToolCalls: [String: [String: ResponseToolCallMemory]] = [:]

    init(maxEntries: Int) {
        self.maxEntries = max(1, maxEntries)
    }

    func sessionKey(responseID: String, previousResponseID: String?, explicitSessionKey: String?) -> String {
        let sessionKey: String
        if let previousResponseID, let existing = responseSessions[previousResponseID] {
            sessionKey = existing
        } else if let explicitSessionKey, !explicitSessionKey.isEmpty {
            sessionKey = "affinity:\(explicitSessionKey)"
        } else if let previousResponseID, !previousResponseID.isEmpty {
            sessionKey = "previous-response:\(previousResponseID)"
        } else {
            sessionKey = "response:\(responseID)"
        }
        responseSessions[responseID] = sessionKey
        touch(responseID)
        evictIfNeeded()
        return sessionKey
    }

    func storeResponse(responseID: String, responseData: Data, inputItemsData: Data) {
        storedResponses[responseID] = responseData
        storedResponseInputItems[responseID] = inputItemsData
        touch(responseID)
        evictIfNeeded()
    }

    func storeResponseContext(responseID: String, inputItemsData: Data) {
        storedResponseContextInputItems[responseID] = inputItemsData
        touch(responseID)
        evictIfNeeded()
    }

    func storeToolCalls(responseID: String, toolCalls: [String: ResponseToolCallMemory]) {
        guard !toolCalls.isEmpty else { return }
        storedResponseToolCalls[responseID] = toolCalls
        touch(responseID)
        evictIfNeeded()
    }

    func responseData(responseID: String) -> Data? {
        guard let data = storedResponses[responseID] else { return nil }
        touch(responseID)
        return data
    }

    func responseInputItemsData(responseID: String) -> Data? {
        guard let data = storedResponseInputItems[responseID] else { return nil }
        touch(responseID)
        return data
    }

    func responseContextInputItemsData(responseID: String) -> Data? {
        guard let data = storedResponseContextInputItems[responseID] else { return nil }
        touch(responseID)
        return data
    }

    func responseToolCalls(responseID: String) -> [String: ResponseToolCallMemory] {
        guard let toolCalls = storedResponseToolCalls[responseID] else { return [:] }
        touch(responseID)
        return toolCalls
    }

    func knowsResponse(responseID: String) -> Bool {
        let exists = responseSessions[responseID] != nil
            || storedResponses[responseID] != nil
            || storedResponseInputItems[responseID] != nil
            || storedResponseContextInputItems[responseID] != nil
            || storedResponseToolCalls[responseID] != nil
        if exists {
            touch(responseID)
        }
        return exists
    }

    func deleteResponse(responseID: String) -> Bool {
        let existed = responseSessions[responseID] != nil
            || storedResponses[responseID] != nil
            || storedResponseInputItems[responseID] != nil
            || storedResponseContextInputItems[responseID] != nil
            || storedResponseToolCalls[responseID] != nil
        responseSessions.removeValue(forKey: responseID)
        storedResponses.removeValue(forKey: responseID)
        storedResponseInputItems.removeValue(forKey: responseID)
        storedResponseContextInputItems.removeValue(forKey: responseID)
        storedResponseToolCalls.removeValue(forKey: responseID)
        responseOrder.removeAll { $0 == responseID }
        return existed
    }

    func stats() -> Stats {
        Stats(
            sessions: responseSessions.count,
            storedResponses: storedResponses.count,
            inputItems: storedResponseInputItems.count,
            toolCallMemory: storedResponseToolCalls.count,
            maxEntries: maxEntries
        )
    }

    private func touch(_ responseID: String) {
        if let index = responseOrder.firstIndex(of: responseID) {
            responseOrder.remove(at: index)
        }
        responseOrder.append(responseID)
    }

    private func evictIfNeeded() {
        while responseOrder.count > maxEntries, let evicted = responseOrder.first {
            responseOrder.removeFirst()
            responseSessions.removeValue(forKey: evicted)
            storedResponses.removeValue(forKey: evicted)
            storedResponseInputItems.removeValue(forKey: evicted)
            storedResponseContextInputItems.removeValue(forKey: evicted)
            storedResponseToolCalls.removeValue(forKey: evicted)
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

private final class ListenerStartResult: @unchecked Sendable {
    private let port: UInt16
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Void, any Error>?

    init(port: UInt16) {
        self.port = port
    }

    func succeed() {
        complete(.success(()))
    }

    func fail(_ error: any Error) {
        complete(.failure(api2agentError.transport("Could not listen on 127.0.0.1:\(port): \(error.localizedDescription)")))
    }

    func wait(timeout: TimeInterval = 2.0) throws {
        let deadline = DispatchTime.now() + timeout
        if semaphore.wait(timeout: deadline) == .timedOut {
            throw api2agentError.transport("Timed out starting local API on 127.0.0.1:\(port).")
        }
        let completed = lock.withLock { result }
        if case .failure(let error) = completed {
            throw error
        }
    }

    private func complete(_ newResult: Result<Void, any Error>) {
        let shouldSignal = lock.withLock {
            guard result == nil else { return false }
            result = newResult
            return true
        }
        if shouldSignal {
            semaphore.signal()
        }
    }
}

enum HTTPParser {
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headers = parseHeaderBlock(data) else { return nil }
        let lines = headers.lines
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        let target = requestTarget(String(parts[1]))
        let headerFields = headerFields(lines)
        let bodyStart = headers.bodyStart
        let body: Data
        if transferEncodingIsChunked(headerFields["transfer-encoding"]) {
            guard let decoded = decodeChunkedBody(Data(data[bodyStart..<data.endIndex])) else {
                return nil
            }
            body = decoded
        } else {
            let expectedLength = Int(headerFields["content-length"] ?? "0") ?? 0
            guard data.count - bodyStart >= expectedLength else { return nil }
            body = Data(data[bodyStart..<(bodyStart + expectedLength)])
        }
        return HTTPRequest(
            method: String(parts[0]),
            path: target.path,
            query: target.query,
            headers: headerFields,
            body: body
        )
    }

    static func shouldSendContinue(_ data: Data) -> Bool {
        guard let headers = parseHeaderBlock(data) else { return false }
        let fields = headerFields(headers.lines)
        guard fields["expect"]?
            .split(separator: ",")
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            .contains("100-continue") == true else {
            return false
        }
        if transferEncodingIsChunked(fields["transfer-encoding"]) {
            return decodeChunkedBody(Data(data[headers.bodyStart..<data.endIndex])) == nil
        }
        let expectedLength = Int(fields["content-length"] ?? "0") ?? 0
        return expectedLength > 0 && data.count - headers.bodyStart < expectedLength
    }

    private static func parseHeaderBlock(_ data: Data) -> (lines: [Substring], bodyStart: Data.Index)? {
        guard let separatorRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<separatorRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        return (
            headerText.split(separator: "\r\n", omittingEmptySubsequences: false),
            separatorRange.upperBound
        )
    }

    private static func headerFields(_ lines: [Substring]) -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let index = line.firstIndex(of: ":") else { continue }
            let key = line[..<index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        return headers
    }

    private static func requestTarget(_ raw: String) -> (path: String, query: String?) {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://"),
           let components = URLComponents(string: raw) {
            let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
            return (path, components.percentEncodedQuery)
        }

        let targetParts = raw.split(separator: "?", maxSplits: 1).map(String.init)
        return (
            targetParts.first ?? "/",
            targetParts.count > 1 ? targetParts[1] : nil
        )
    }

    private static func transferEncodingIsChunked(_ value: String?) -> Bool {
        value?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains("chunked") == true
    }

    private static func decodeChunkedBody(_ data: Data) -> Data? {
        let lineBreak = Data("\r\n".utf8)
        let trailerTerminator = Data("\r\n\r\n".utf8)
        var offset = data.startIndex
        var output = Data()

        while offset < data.endIndex {
            guard let lineRange = data[offset..<data.endIndex].range(of: lineBreak),
                  let line = String(data: data[offset..<lineRange.lowerBound], encoding: .utf8) else {
                return nil
            }
            let sizeText = line
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let size = Int(sizeText, radix: 16), size >= 0 else {
                return nil
            }

            offset = lineRange.upperBound
            if size == 0 {
                let remaining = data[offset..<data.endIndex]
                if remaining.starts(with: lineBreak) {
                    return output
                }
                return remaining.range(of: trailerTerminator) == nil ? nil : output
            }

            guard data.endIndex - offset >= size + lineBreak.count else {
                return nil
            }
            output.append(data[offset..<(offset + size)])
            offset += size
            guard data[offset..<(offset + lineBreak.count)] == lineBreak else {
                return nil
            }
            offset += lineBreak.count
        }

        return nil
    }
}
