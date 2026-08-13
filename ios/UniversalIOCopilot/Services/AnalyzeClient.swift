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

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch let error as URLError {
            // URLSession's own wording sends people to check their Wi-Fi, which
            // is rarely the problem when the server is a machine on the desk.
            throw Failure(code: "UNREACHABLE", message: reachabilityMessage(for: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw Failure(code: "BAD_RESPONSE", message: "The server sent an unreadable response.")
        }
        guard http.statusCode == 200 else {
            throw try await decodeErrorBody(bytes, status: http.statusCode)
        }

        var sawResult = false

        // Framed from raw bytes rather than `bytes.lines`, because that sequence
        // discards blank lines — and in Server-Sent Events the blank line *is*
        // the record separator. Reading it that way silently yielded no events
        // at all: the stream simply ended, and the failure looked like a dropped
        // connection rather than a parser that could never fire.
        for try await block in bytes.serverSentEventBlocks {
            if let event = try dispatch(block) {
                if case .result = event { sawResult = true }
                continuation.yield(event)
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

    /// Turns one SSE record into an event. Unknown record types are ignored so a
    /// server that adds one does not break an older client.
    private func dispatch(_ block: String) throws -> Event? {
        var eventName = ""
        var dataLines: [String] = []

        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if let value = text.dropPrefix("event:") {
                eventName = value.trimmingCharacters(in: .whitespaces)
            } else if let value = text.dropPrefix("data:") {
                dataLines.append(value.hasPrefix(" ") ? String(value.dropFirst()) : value)
            }
        }

        let data = dataLines.joined(separator: "\n")
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

    /// Says which address failed and what the plausible causes are, in the order
    /// they are worth checking. `notConnectedToInternet` is the misleading one:
    /// iOS reports it when it blocks a local-network connection, so a device with
    /// working internet still lands here.
    private func reachabilityMessage(for error: URLError) -> String {
        let host = baseURL.absoluteString

        switch error.code {
        case .notConnectedToInternet:
            return """
            Could not reach \(host).
            If the server is on your own network, allow this app under \
            Settings › Privacy & Security › Local Network, and check that this \
            device is on the same Wi-Fi as the server.
            """
        case .cannotConnectToHost, .cannotFindHost:
            return """
            Nothing answered at \(host).
            Check that the server is running and that the address is right.
            """
        case .timedOut:
            return "\(host) did not answer in time. The analysis may take a moment on a slow connection."
        case .appTransportSecurityRequiresSecureConnection:
            return "\(host) was refused because it is not HTTPS."
        default:
            return "Could not reach \(host). \(error.localizedDescription)"
        }
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

extension URLSession.AsyncBytes {
    /// Splits the stream into Server-Sent Event records on the blank line that
    /// terminates each one, keeping every line inside a record intact.
    ///
    /// Framed at the byte level on purpose: a newline byte cannot occur inside a
    /// multi-byte UTF-8 character, so this is safe, and it does not inherit
    /// `lines`' habit of throwing blank lines away.
    var serverSentEventBlocks: AsyncThrowingStream<String, Error> {
        AsyncThrowingStream(String.self) { continuation in
            let task = Task {
                var buffer: [UInt8] = []
                var newlineRun = 0

                func flush() {
                    guard !buffer.isEmpty else { return }
                    continuation.yield(String(decoding: buffer, as: UTF8.self))
                    buffer.removeAll(keepingCapacity: true)
                }

                do {
                    for try await byte in self {
                        if byte == 0x0D { continue } // carriage returns carry no meaning here
                        guard byte == 0x0A else {
                            newlineRun = 0
                            buffer.append(byte)
                            continue
                        }
                        newlineRun += 1
                        if newlineRun >= 2 {
                            if buffer.last == 0x0A { buffer.removeLast() }
                            flush()
                            newlineRun = 0
                        } else {
                            buffer.append(byte)
                        }
                    }
                    // A final record that arrived without its blank line still counts.
                    flush()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
