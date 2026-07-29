import Foundation

/// The only thing in maiku that talks to a network, and it talks to one
/// process on the same machine (plan §5.3, §12).
///
/// An actor because the model id is discovered once and cached, and because
/// nothing else should be able to interleave with a request in flight.
public actor LMStudioClient {

    public nonisolated let configuration: LMStudioConfiguration
    private let session: URLSession
    private var discoveredModelID: String?

    /// The default session is ephemeral so responses containing transcript text
    /// are never written to the on-disk URL cache.
    public init(
        configuration: LMStudioConfiguration = LMStudioConfiguration(),
        session: URLSession = URLSession(configuration: .ephemeral)
    ) {
        self.configuration = configuration
        self.session = session
    }

    // MARK: - Connection

    public func testConnection() async throws -> LMStudioConnectionStatus {
        LMStudioConnectionStatus(
            baseURL: configuration.baseURL,
            isLoopback: configuration.isLoopback,
            models: try await listModels())
    }

    /// Never returns an empty list — "running but no model loaded" is its own
    /// failure so the UI can offer "Choose Model" instead of "Retry".
    public func listModels() async throws -> [LMStudioModel] {
        let data = try await send(urlRequest(path: "/v1/models"))
        guard let list = try? JSONDecoder().decode(ModelListResponse.self, from: data),
            !list.data.isEmpty
        else {
            throw MaikuError.lmStudioNoModelAvailable
        }
        return list.data
    }

    // MARK: - Organization

    /// A single pass over the whole transcript. `OrganizationPipeline` is what
    /// decides whether this suffices (a recording short enough for one
    /// `TranscriptChunker` chunk) or whether `summarizeChunk` /
    /// `reduceChunkSummaries` are needed instead — this method itself has no
    /// chunking ceiling beyond whatever the loaded model's own context holds,
    /// so a transcript that does not fit comes back as
    /// `.lmStudioContextTooLarge` rather than being split here.
    public func organizeTranscript(_ request: OrganizationRequest) async throws -> OrganizedRecording
    {
        try await structuredCompletion(
            messages: PromptFactory.organization(request),
            schema: OrganizationSchema.finalReduction(),
            schemaName: "organized_recording")
    }

    /// Map half of map-reduce (plan §7.2 pass 1): what one chunk supports on
    /// its own.
    public func summarizeChunk(_ request: ChunkSummaryRequest) async throws -> ChunkSummary {
        try await structuredCompletion(
            messages: PromptFactory.chunkExtraction(request),
            schema: OrganizationSchema.chunkExtraction(),
            schemaName: "chunk_summary")
    }

    /// Reduce half (plan §7.2 pass 2): every chunk's claims combined and
    /// deduplicated into one `OrganizedRecording`. Same response shape as
    /// `organizeTranscript`, so the same schema — the difference is entirely
    /// in what the model is shown (`PromptFactory.reduce` presents chunk
    /// summaries, never the raw transcript).
    public func reduceChunkSummaries(_ request: ReduceRequest) async throws -> OrganizedRecording {
        try await structuredCompletion(
            messages: PromptFactory.reduce(request),
            schema: OrganizationSchema.finalReduction(),
            schemaName: "organized_recording")
    }

    // MARK: - Structured completion

    private func structuredCompletion<T: Decodable>(
        messages: [ChatMessage], schema: [String: Any], schemaName: String
    ) async throws -> T {
        let content = try await complete(messages: messages, schema: schema, name: schemaName)
        do {
            return try Self.decode(content)
        } catch {
            // One repair attempt quoting the validation error (plan §7.4).
            let detail = Self.describe(error)
            let repair =
                messages + [
                    ChatMessage(role: "assistant", content: content),
                    PromptFactory.repair(validationError: detail),
                ]
            let second = try await complete(messages: repair, schema: schema, name: schemaName)
            do {
                return try Self.decode(second)
            } catch {
                throw MaikuError.lmStudioInvalidStructuredOutput(
                    detail: "\(Self.describe(error)) Raw reply: \(second.prefix(400))")
            }
        }
    }

    private func complete(
        messages: [ChatMessage], schema: [String: Any], name: String
    ) async throws -> String {
        let model = try await modelID()
        let body: [String: Any] = [
            "model": model,
            "temperature": configuration.temperature,
            "stream": false,
            "messages": messages.map(\.wireForm),
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": name, "strict": true, "schema": schema],
            ],
        ]
        let data = try await send(
            urlRequest(
                path: "/v1/chat/completions", method: "POST",
                body: try JSONSerialization.data(withJSONObject: body)))

        guard let response = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data),
            let choice = response.choices.first
        else {
            throw MaikuError.lmStudioInvalidStructuredOutput(
                detail: "The reply was not a chat completion.")
        }
        // A truncated reply is never valid JSON; reporting it as a format
        // problem would send the user to the wrong recovery action.
        if choice.finishReason == "length" {
            throw MaikuError.lmStudioContextTooLarge(tokens: response.usage?.totalTokens)
        }
        let content = (choice.message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw MaikuError.lmStudioInvalidStructuredOutput(detail: "The reply was empty.")
        }
        return content
    }

    private func modelID() async throws -> String {
        if let configured = configuration.modelID, !configured.isEmpty { return configured }
        if let discoveredModelID { return discoveredModelID }
        guard let first = try await listModels().first else {
            throw MaikuError.lmStudioNoModelAvailable
        }
        discoveredModelID = first.id
        return first.id
    }

    // MARK: - Decoding

    /// Some models still fence their JSON even under a strict schema; unwrapping
    /// it here is cheaper than a repair round trip.
    static func decode<T: Decodable>(_ content: String) throws -> T {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = String(text.drop(while: { $0 != "\n" }))
            if let fence = text.range(of: "```", options: .backwards) {
                text = String(text[..<fence.lowerBound])
            }
        }
        let object = try JSONSerialization.jsonObject(
            with: Data(text.utf8), options: [.fragmentsAllowed])
        let repaired = try JSONSerialization.data(withJSONObject: Self.normalize(object))
        return try JSONDecoder().decode(T.self, from: repaired)
    }

    /// Fills in the ids the model was never asked for, and drops references it
    /// got wrong.
    ///
    /// A single malformed UUID anywhere would otherwise fail the whole decode
    /// and cost a repair round trip. A dropped citation is not silently
    /// accepted — `OutputValidator` rejects an item left with none.
    private static func normalize(_ value: Any) -> Any {
        if var object = value as? [String: Any] {
            for (key, nested) in object {
                switch key {
                case "sourceSegmentIDs":
                    object[key] = ((nested as? [Any]) ?? []).compactMap { element -> String? in
                        guard let text = element as? String, UUID(uuidString: text) != nil else {
                            return nil
                        }
                        return text
                    }
                case "speakerID", "ownerSpeakerID":
                    if let text = nested as? String, UUID(uuidString: text) == nil {
                        object[key] = NSNull()
                    }
                default:
                    object[key] = normalize(nested)
                }
            }
            if object["id"] == nil { object["id"] = UUID().uuidString }
            return object
        }
        if let array = value as? [Any] { return array.map(normalize) }
        return value
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        func at(_ context: DecodingError.Context) -> String {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "the top level" : path
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "missing required field \"\(key.stringValue)\" at \(at(context))."
        case .typeMismatch(let type, let context):
            return "wrong type at \(at(context)) — expected \(type)."
        case .valueNotFound(let type, let context):
            return "null where a \(type) is required, at \(at(context))."
        case .dataCorrupted(let context):
            return "unreadable value at \(at(context)) — \(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }

    // MARK: - HTTP

    private func urlRequest(path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token = configuration.apiToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw MaikuError.lmStudioTimedOut(seconds: configuration.timeout)
            default: throw MaikuError.lmStudioUnreachable(baseURL: baseURLText)
            }
        } catch {
            throw MaikuError.lmStudioUnreachable(baseURL: baseURLText)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MaikuError.lmStudioUnreachable(baseURL: baseURLText)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.failure(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    private nonisolated var baseURLText: String { configuration.baseURL.absoluteString }

    /// LM Studio reports an overflowing context as a plain 4xx with the reason
    /// in the body, which is the difference between "try again" and "this will
    /// never fit".
    static func failure(status: Int, body: String) -> MaikuError {
        let lowered = body.lowercased()
        let overflow =
            lowered.contains("context")
            && ["overflow", "length", "window", "exceed", "too long", "too large", "too many"]
                .contains(where: lowered.contains)
        guard overflow else {
            return .lmStudioHTTPError(status: status, body: String(body.prefix(500)))
        }
        return .lmStudioContextTooLarge(tokens: tokenCount(in: body))
    }

    /// The first "<number> tokens" in the server's message, when it says one.
    private static func tokenCount(in body: String) -> Int? {
        let words = body.split { !$0.isNumber && !$0.isLetter }
        for (number, next) in zip(words, words.dropFirst())
        where next.lowercased().hasPrefix("token") {
            if let value = Int(number) { return value }
        }
        return nil
    }
}
