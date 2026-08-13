import Foundation

/// Talks to the analysis server. This is the only place the app makes a network
/// call for analysis — the AI provider is never contacted directly, so the API
/// key stays on the server (docs/architecture.md section 1).
struct AnalyzeClient {
    enum Event: Sendable {
        /// Incremental explanation text. Shown as it arrives; never parsed for meaning.
        case delta(String)
        /// The validated result. Everything drawn on screen comes from here.
        case result(AnalysisResult)
    }

    struct Failure: LocalizedError {
        var code: String
        var message: String
        var errorDescription: String? { message }
    }

    struct Request {
        var image: Data
        var mediaType: String = "image/jpeg"
        var question: String?
        var tapPoint: CGPoint?
        var turns: [Turn] = []
        var contextPackID: String?
        var sourceKind: String = "camera"
    }

    struct Turn: Codable, Sendable {
        var role: String
        var text: String
    }

    var baseURL: URL = AppConfig.apiBaseURL
    var betaToken: String = AppConfig.betaToken
    var session: URLSession = .shared

    /// Streams events until the server sends a result or an error. The stream
    /// finishing without a result is a failure, not a silent success.
    func analyze(_ request: Request) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream(Event.self) { continuation in
            let task = Task {
                do {
                    try await run(request, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ request: Request,
        into continuation: AsyncThrowingStream<Event, Error>.Continuation
    ) async throws {
        let requestID = UUID().uuidString
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("api/analyze"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(betaToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.timeoutInterval = 120
        urlRequest.httpBody = try encodeBody(request, requestID: requestID)

        let (bytes, response) = try await session.bytes(for: urlRequest)

        guard let http = response as? HTTPURLResponse else {
            throw Failure(code: "BAD_RESPONSE", message: "The server sent an unreadable response.")
        }
        guard http.statusCode == 200 else {
            throw try await decodeErrorBody(bytes, status: http.statusCode)
        }

        var eventName = ""
        var dataLines: [String] = []
        var sawResult = false

        for try await line in bytes.lines {
            if line.isEmpty {
                if let event = try dispatch(eventName: eventName, data: dataLines.joined(separator: "\n")) {
                    if case .result = event { sawResult = true }
                    continuation.yield(event)
                }
                eventName = ""
                dataLines.removeAll()
                continue
            }

            if let value = line.dropPrefix("event:") {
                eventName = value.trimmingCharacters(in: .whitespaces)
            } else if let value = line.dropPrefix("data:") {
                dataLines.append(value.hasPrefix(" ") ? String(value.dropFirst()) : value)
            }
        }

        // A stream that ends without a result is a failure. Reporting nothing
        // would leave the user staring at a spinner that already stopped.
        guard sawResult else {
            throw Failure(
                code: "INCOMPLETE",
                message: "The connection ended before the analysis finished. Try again."
            )
        }
    }

    private func dispatch(eventName: String, data: String) throws -> Event? {
        guard !data.isEmpty else { return nil }
        let payload = Data(data.utf8)

        switch eventName {
        case "delta":
            struct Delta: Decodable { var text: String }
            return .delta(try JSONDecoder().decode(Delta.self, from: payload).text)

        case "result":
            return .result(try JSONDecoder().decode(AnalysisResult.self, from: payload))

        case "error":
            struct Envelope: Decodable {
                struct Body: Decodable { var code: String; var message: String }
                var error: Body
            }
            let envelope = try JSONDecoder().decode(Envelope.self, from: payload)
            throw Failure(code: envelope.error.code, message: envelope.error.message)

        default:
            return nil
        }
    }

    private func encodeBody(_ request: Request, requestID: String) throws -> Data {
        var body: [String: Any] = [
            "request_id": requestID,
            "image": request.image.base64EncodedString(),
            "image_media_type": request.mediaType,
            "source": ["kind": request.sourceKind],
            "client": [
                "platform": "ios",
                "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
            ],
        ]

        if let question = request.question?.trimmingCharacters(in: .whitespacesAndNewlines),
           !question.isEmpty {
            body["question"] = question
        }
        if let tap = request.tapPoint {
            body["tap_point"] = ["x": tap.x, "y": tap.y]
        }
        if let pack = request.contextPackID {
            body["context_pack_id"] = pack
        }
        if !request.turns.isEmpty {
            body["turns"] = request.turns.map { ["role": $0.role, "text": $0.text] }
        }

        return try JSONSerialization.data(withJSONObject: body)
    }

    private func decodeErrorBody(
        _ bytes: URLSession.AsyncBytes,
        status: Int
    ) async throws -> Failure {
        var raw = ""
        for try await line in bytes.lines { raw += line }

        struct Envelope: Decodable {
            struct Body: Decodable { var code: String; var message: String }
            var error: Body
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(raw.utf8)) {
            return Failure(code: envelope.error.code, message: envelope.error.message)
        }
        return Failure(code: "HTTP_\(status)", message: "The server returned status \(status).")
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
