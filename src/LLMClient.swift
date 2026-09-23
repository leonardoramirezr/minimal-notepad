import Foundation

/// Connection details for any server that implements OpenAI's Chat Completions API.
struct LLMConfiguration {
    var endpoint: String
    var apiKey: String
    var model: String
}

enum LLMError: LocalizedError {
    case missingEndpoint
    case invalidEndpoint
    case server(status: Int, message: String?)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingEndpoint:
            return "Set the endpoint of an OpenAI-compatible API first."
        case .invalidEndpoint:
            return "The endpoint must be a URL that starts with http:// or https://."
        case .server(let status, let message?):
            return "Error \(status): \(message)"
        case .server(let status, nil):
            var description = "Error \(status): \(HTTPURLResponse.localizedString(forStatusCode: status))."
            if status == 404 || status == 405 {
                description += " Check the endpoint, it usually ends in /v1."
            }
            return description
        case .emptyResponse:
            return "The model returned an empty response."
        }
    }
}

enum LLMClient {
    static let systemPrompt = """
        You are an assistant built into a notepad app. The user's current note is included \
        in their message between <note> tags. Answer their request about that note, using \
        Markdown for formatting.
        """

    /// Accepts either a base URL (`https://api.openai.com/v1`) or the full
    /// `…/chat/completions` URL.
    static func chatCompletionsURL(for endpoint: String) throws -> URL {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.missingEndpoint }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { throw LLMError.invalidEndpoint }

        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        if !path.hasSuffix("/chat/completions") {
            path += "/chat/completions"
        }
        components.path = path

        guard let url = components.url else { throw LLMError.invalidEndpoint }
        return url
    }

    /// A single, self-contained request: the prompt plus the note, with no earlier turns,
    /// so asking again always answers about the note as it is now.
    static func makeRequest(prompt: String, note: String, configuration: LLMConfiguration) throws -> URLRequest {
        var request = URLRequest(url: try chatCompletionsURL(for: configuration.endpoint))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = ChatRequest(
            model: model.isEmpty ? nil : model,
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: "<note>\n\(note)\n</note>\n\n\(prompt)"),
            ],
            stream: true
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// Sends the request and yields the answer piece by piece as it arrives.
    /// Cancelling the task that iterates the stream cancels the request.
    static func streamResponse(for request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
                    try await readAnswer(from: bytes, statusCode: statusCode) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Reads a response body, calling `onText` with each piece of the answer.
    static func readAnswer<Bytes: AsyncSequence>(
        from bytes: Bytes,
        statusCode: Int,
        onText: (String) -> Void
    ) async throws where Bytes.Element == UInt8 {
        var parser = ChatResponseParser(statusCode: statusCode)

        // Lines are split on LF here rather than with `lines`, which also breaks at
        // U+2028 and U+2029: both may appear unescaped inside the JSON of an event.
        var line = Data()
        for try await byte in bytes {
            guard byte == UInt8(ascii: "\n") else {
                line.append(byte)
                continue
            }
            if let text = try parser.consume(String(decoding: line, as: UTF8.self)) {
                onText(text)
            }
            line.removeAll(keepingCapacity: true)
            if parser.isComplete { break }
        }

        if !parser.isComplete, let text = try parser.consume(String(decoding: line, as: UTF8.self)) {
            onText(text)
        }
        if let text = try parser.finish() {
            onText(text)
        }
    }
}

private struct ChatRequest: Encodable {
    let model: String?
    let messages: [ChatMessage]
    let stream: Bool
}

private struct ChatMessage: Encodable {
    let role: String
    let content: String
}

/// Turns the lines of a Chat Completions response body into answer text.
///
/// A streamed answer arrives as server-sent events (`data: {…}` lines). Servers that
/// ignore `stream` reply with a single JSON object instead, and failed requests with an
/// error body; both are collected and read once the body has ended.
struct ChatResponseParser {
    let statusCode: Int
    private(set) var isComplete = false
    private var receivedContent = false
    private var otherLines: [String] = []

    init(statusCode: Int) {
        self.statusCode = statusCode
    }

    private var succeeded: Bool { (200..<300).contains(statusCode) }

    /// Returns the answer text carried by one line of the body, if any.
    mutating func consume(_ rawLine: String) throws -> String? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        guard succeeded, line.hasPrefix("data:") else {
            if !line.isEmpty {
                otherLines.append(line)
            }
            return nil
        }

        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            isComplete = true
            return nil
        }
        guard let object = Self.jsonObject(payload) else { return nil }
        if let message = Self.errorMessage(in: object) {
            throw LLMError.server(status: statusCode, message: message)
        }
        guard let content = Self.content(in: object), !content.isEmpty else { return nil }
        receivedContent = true
        return content
    }

    /// Call once the body has ended. Returns the answer of a response that wasn't
    /// streamed, and throws if the request failed or produced no answer at all.
    mutating func finish() throws -> String? {
        isComplete = true
        let body = otherLines.joined(separator: "\n")
        guard succeeded else {
            throw LLMError.server(status: statusCode, message: Self.errorMessage(inBody: body))
        }
        if receivedContent { return nil }

        if let object = Self.jsonObject(body) {
            if let message = Self.errorMessage(in: object) {
                throw LLMError.server(status: statusCode, message: message)
            }
            if let content = Self.content(in: object), !content.isEmpty {
                return content
            }
        }
        throw LLMError.emptyResponse
    }

    static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Text of the first choice, either streamed (`delta`) or complete (`message`).
    static func content(in object: [String: Any]) -> String? {
        guard let choice = (object["choices"] as? [[String: Any]])?.first else { return nil }
        let message = (choice["delta"] ?? choice["message"]) as? [String: Any]
        return message?["content"] as? String ?? choice["text"] as? String
    }

    /// The message of an OpenAI-style error: `{"error": {"message": …}}` or `{"error": "…"}`.
    static func errorMessage(in object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any] {
            return error["message"] as? String ?? "Unknown error."
        }
        return object["error"] as? String
    }

    /// A readable message from the body of a failed request, if it has one.
    static func errorMessage(inBody body: String) -> String? {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let object = jsonObject(text) {
            return errorMessage(in: object) ?? object["message"] as? String ?? object["detail"] as? String
        }
        // Short plain-text bodies are shown as they are; HTML error pages are not.
        guard !text.isEmpty, !text.hasPrefix("<"), text.count <= 300 else { return nil }
        return text
    }
}
