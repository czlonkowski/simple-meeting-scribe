import Foundation
import Network
import MCP

/// Hosts a tiny Model Context Protocol server bound to 127.0.0.1 so Claude
/// Code (and any other MCP client) running on the same Mac can list and read
/// local transcripts while the app is open.
///
/// Wire protocol: MCP "Streamable HTTP" via `StatelessHTTPServerTransport`.
/// The SDK transport is framework-agnostic — we feed it parsed `HTTPRequest`
/// values from a small NWListener and write the resulting `HTTPResponse`
/// back to the socket. Bound to `127.0.0.1` only; the transport's default
/// validators also reject non-localhost `Origin` headers as a second fence.
final class MCPLocalServer: @unchecked Sendable {

    static let shared = MCPLocalServer()

    /// Bound interface — localhost only.
    static let host = "127.0.0.1"
    /// Fixed port. Not officially registered but unlikely to clash on a
    /// developer Mac. If it's in use the listener will fail and the rest of
    /// the app keeps working.
    static let port: UInt16 = 47823
    /// Path matched by the request handler. Anything else returns 404.
    static let endpointPath = "/mcp"

    private let queue = DispatchQueue(label: "com.czlonkowski.MeetingTranscriber.mcp", qos: .utility)

    private var listener: NWListener?
    private var server: Server?
    private var transport: StatelessHTTPServerTransport?
    private var bringUpTask: Task<Void, Never>?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard bringUpTask == nil else { return }
        Self.log("start() called")
        bringUpTask = Task { await self.bringUp() }
    }

    func stop() {
        bringUpTask?.cancel()
        bringUpTask = nil
        listener?.cancel()
        listener = nil
        let server = self.server
        let transport = self.transport
        self.server = nil
        self.transport = nil
        Task {
            await server?.stop()
            await transport?.disconnect()
        }
    }

    private func bringUp() async {
        Self.log("bringUp() entered")
        let server = Server(
            name: "meeting-transcriber",
            version: "0.1.0",
            instructions: "Search and read locally stored meeting transcripts.",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await registerHandlers(on: server)

        let transport = StatelessHTTPServerTransport()
        do {
            try await server.start(transport: transport)
        } catch {
            Self.log("server.start failed — \(error)")
            return
        }
        self.server = server
        self.transport = transport

        guard let nwPort = NWEndpoint.Port(rawValue: Self.port) else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Restrict to loopback / same-device peers — defense-in-depth on top
        // of the transport's own localhost-origin validator.
        parameters.acceptLocalOnly = true
        parameters.includePeerToPeer = false

        do {
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Self.log("listening on http://\(Self.host):\(Int(Self.port))\(Self.endpointPath)")
                case .failed(let error):
                    Self.log("listener failed — \(error)")
                case .waiting(let error):
                    Self.log("listener waiting — \(error)")
                case .cancelled:
                    Self.log("listener cancelled")
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            Self.log("listener.start invoked on port \(Self.port)")
        } catch {
            Self.log("NWListener init failed — \(error)")
        }
    }

    /// Logs to NSLog (unified logging) and appends to /tmp/meeting-transcriber-mcp.log.
    /// The on-disk file is the surest way to verify the listener actually
    /// came up when launched from Finder, where stdout/stderr are detached.
    static func log(_ message: String) {
        let line = "MCP: \(message)"
        NSLog("%@", line)
        let stamped = "\(Date()) \(line)\n"
        if let data = stamped.data(using: .utf8) {
            let url = URL(fileURLWithPath: "/tmp/meeting-transcriber-mcp.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        Task { [weak self] in
            await self?.serve(connection)
            connection.cancel()
        }
    }

    /// Read one HTTP/1.1 request, dispatch it through the MCP transport,
    /// write the response, and close. We don't keep-alive — single
    /// request per TCP connection keeps the parser trivial. Claude Code
    /// reconnects per request, which is fine on localhost.
    private func serve(_ connection: NWConnection) async {
        guard let transport = self.transport else { return }
        do {
            let parsed = try await readRequest(from: connection)
            let request = HTTPRequest(
                method: parsed.method,
                headers: parsed.headers,
                body: parsed.body.isEmpty ? nil : parsed.body,
                path: parsed.path
            )
            let response: HTTPResponse
            if parsed.path == Self.endpointPath {
                response = await transport.handleRequest(request)
            } else {
                response = .error(statusCode: 404, .invalidRequest("Not Found"))
            }
            try await writeResponse(response, to: connection)
        } catch {
            // Client disconnected, malformed request, etc — just close.
            NSLog("MCP: connection closed — %@", String(describing: error))
        }
    }

    // MARK: - Tool registration

    private func registerHandlers(on server: Server) async {
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: MCPTools.definitions)
        }
        await server.withMethodHandler(CallTool.self) { params in
            await MCPTools.handle(name: params.name, arguments: params.arguments)
        }
    }
}

// MARK: - Minimal HTTP/1.1 request parser

private struct ParsedHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

private enum HTTPParseError: Error {
    case clientClosed
    case malformed
    case bodyTooLarge
    case missingBody
}

/// Cap on request body size we'll accept — MCP requests are JSON-RPC and
/// run a few KB at most, but we leave headroom for verbose tool arguments.
private let maxRequestBodyBytes = 1 * 1024 * 1024

private func readRequest(from connection: NWConnection) async throws -> ParsedHTTPRequest {
    var buffer = Data()
    var headerEnd: Int? = nil

    // Read until we see the end-of-headers marker.
    while headerEnd == nil {
        let chunk = try await receive(on: connection)
        if chunk.isEmpty { throw HTTPParseError.clientClosed }
        buffer.append(chunk)
        if buffer.count > maxRequestBodyBytes { throw HTTPParseError.bodyTooLarge }
        headerEnd = indexOfHeaderTerminator(in: buffer)
    }

    guard let end = headerEnd else { throw HTTPParseError.malformed }
    let headerData = buffer.prefix(end)
    guard let headerString = String(data: Data(headerData), encoding: .utf8) else {
        throw HTTPParseError.malformed
    }

    let lines = headerString.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { throw HTTPParseError.malformed }
    let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    guard parts.count >= 2 else { throw HTTPParseError.malformed }
    let method = String(parts[0])
    let uri = String(parts[1])
    let path = String(uri.split(separator: "?", maxSplits: 1).first ?? Substring(uri))

    var headers: [String: String] = [:]
    for line in lines.dropFirst() where !line.isEmpty {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = line[..<colon].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        // Combine duplicate header values with comma per RFC 7230.
        if let existing = headers[name] {
            headers[name] = existing + ", " + value
        } else {
            headers[name] = value
        }
    }

    let bodyStart = end + 4 // skip the \r\n\r\n
    let contentLengthHeader = headers
        .first { $0.key.caseInsensitiveCompare("Content-Length") == .orderedSame }?
        .value
    let contentLength = contentLengthHeader.flatMap(Int.init) ?? 0
    if contentLength > maxRequestBodyBytes { throw HTTPParseError.bodyTooLarge }

    var body = Data()
    if contentLength > 0 {
        if buffer.count >= bodyStart {
            body = buffer.subdata(in: bodyStart..<min(buffer.count, bodyStart + contentLength))
        }
        while body.count < contentLength {
            let chunk = try await receive(on: connection)
            if chunk.isEmpty { throw HTTPParseError.missingBody }
            body.append(chunk)
            if body.count > contentLength {
                body = body.prefix(contentLength)
            }
        }
    }

    return ParsedHTTPRequest(method: method, path: path, headers: headers, body: body)
}

private func indexOfHeaderTerminator(in data: Data) -> Int? {
    let needle: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
    guard data.count >= needle.count else { return nil }
    let bytes = [UInt8](data)
    for i in 0...(bytes.count - needle.count) {
        if Array(bytes[i..<(i + needle.count)]) == needle {
            return i
        }
    }
    return nil
}

private func receive(on connection: NWConnection) async throws -> Data {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            data, _, isComplete, error in
            if let error {
                continuation.resume(throwing: error)
                return
            }
            if let data, !data.isEmpty {
                continuation.resume(returning: data)
                return
            }
            if isComplete {
                continuation.resume(returning: Data())
                return
            }
            // Spurious wake without data — treat as EOF.
            continuation.resume(returning: Data())
        }
    }
}

// MARK: - Response writer

private func writeResponse(_ response: HTTPResponse, to connection: NWConnection) async throws {
    let body = response.bodyData ?? Data()
    var head = "HTTP/1.1 \(response.statusCode) \(httpReasonPhrase(response.statusCode))\r\n"
    var headers = response.headers
    headers["Content-Length"] = String(body.count)
    headers["Connection"] = "close"
    for (name, value) in headers {
        head += "\(name): \(value)\r\n"
    }
    head += "\r\n"
    var payload = Data(head.utf8)
    payload.append(body)
    try await send(payload, on: connection)
}

private func send(_ data: Data, on connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        })
    }
}

private func httpReasonPhrase(_ status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 202: return "Accepted"
    case 400: return "Bad Request"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 500: return "Internal Server Error"
    default: return "OK"
    }
}
