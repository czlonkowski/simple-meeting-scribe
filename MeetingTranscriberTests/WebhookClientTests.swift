import Foundation
import XCTest
@testable import MeetingTranscriber

/// Stubs every request made through a session configured with it.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        guard let handler = Self.handler else { return }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class WebhookClientTests: XCTestCase {
    private let config = WebhookConfig(url: "https://n8n.example.com/webhook/abc",
                                       headerName: "X-Api-Key", headerValue: " secret ")

    private func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: c)
    }

    private func respond(_ status: Int, _ body: String = "") {
        StubProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
             Data(body.utf8))
        }
    }

    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
    }

    func testRequestCarriesAuthHeaderAndJSON() throws {
        let request = try WebhookClient.request(for: .ping(), config: config)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNotNil(request.httpBody)
    }

    func testEmptyHeaderNameFallsBackToAuthorization() throws {
        let cfg = WebhookConfig(url: config.url, headerName: " ", headerValue: "Bearer t")
        let request = try WebhookClient.request(for: .ping(), config: cfg)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }

    func testRejectsMissingOrInsecureURL() {
        XCTAssertThrowsError(try WebhookClient.request(for: .ping(), config: WebhookConfig(url: "", headerName: "", headerValue: ""))) {
            XCTAssertEqual($0 as? WebhookError, .notConfigured)
        }
        XCTAssertThrowsError(try WebhookClient.request(for: .ping(), config: WebhookConfig(url: "http://n8n.example.com/x", headerName: "", headerValue: ""))) {
            XCTAssertEqual($0 as? WebhookError, .invalidURL)
        }
        XCTAssertNotNil(WebhookStore.validatedURL("http://localhost:5678/webhook/x"))
    }

    func testSuccessOn2xx() async throws {
        respond(200, "{\"ok\":true}")
        try await WebhookClient.send(.ping(), config: config, session: session())
        XCTAssertEqual(StubProtocol.lastRequest?.url?.absoluteString, config.url)
    }

    func testHTTPErrorCarriesStatusAndBody() async {
        respond(403, "Authorization data is wrong!")
        do {
            try await WebhookClient.send(.ping(), config: config, session: session())
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? WebhookError, .http(status: 403, body: "Authorization data is wrong!"))
        }
    }
}
