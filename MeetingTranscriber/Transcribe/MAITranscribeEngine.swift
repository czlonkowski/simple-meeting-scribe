import Foundation
import OSLog

/// Cloud transcription via Microsoft MAI-Transcribe-2 on Azure Speech (the
/// fast-transcription API in `enhancedMode`). Returns MAI's raw phrases;
/// `MAISegmenter` turns them into the app's segment shapes.
struct MAITranscribeEngine {

    /// Full transcribe URL of the user's Azure Speech resource
    /// (see `transcribeURL(endpoint:)`).
    let transcribeURL: URL

    /// Builds the fast-transcription URL from a resource endpoint as shown in
    /// the Azure portal, e.g. `https://<resource>.cognitiveservices.azure.com/`.
    /// The resource must be in a region serving MAI-Transcribe (in the EU:
    /// North Europe, not Sweden Central). Nil for anything but an https URL.
    static func transcribeURL(endpoint: String) -> URL? {
        var base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base), url.scheme == "https", url.host != nil else { return nil }
        if !base.hasSuffix("/") { base += "/" }
        return URL(string: base + "speechtotext/transcriptions:transcribe?api-version=2025-10-15")
    }

    /// The service accepts at most 2 h / 300 MB per request. 110 min of
    /// 16 kHz mono WAV is ~211 MB, leaving margin on both limits.
    static let maxRequestSeconds: Double = 110 * 60

    enum MAIError: LocalizedError {
        case missingAPIKey
        case missingEndpoint
        case unauthorized
        /// Speaker separation failed server-side (the preview is documented
        /// to time out on long recordings). The pipeline retries without it.
        case diarizationUnavailable(status: Int)
        case server(status: Int, message: String?)
        case network(underlying: Error)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Azure Speech key is not set. Add it in Settings → General → Transcription."
            case .missingEndpoint:
                return "Azure Speech endpoint is not set. Add it in Settings → General → Transcription."
            case .unauthorized:
                return "Azure rejected the Speech key. Check it in Settings → General."
            case .diarizationUnavailable(let status):
                return "Azure could not separate speakers (HTTP \(status))."
            case .server(let status, let message):
                let detail = message.map { ": \($0)" } ?? ""
                return "Azure Speech returned HTTP \(status)\(detail). Try again, or re-transcribe with another model."
            case .network(let underlying):
                return "Could not reach Azure Speech: \(underlying.localizedDescription) Check your connection, then use Re-transcribe."
            case .badResponse:
                return "Azure Speech returned an unexpected response. Try again, or re-transcribe with another model."
            }
        }

        /// MAI is a preview service: when it fails for service reasons the
        /// pipeline hands the same audio to Scribe (if a key is set). Credential
        /// problems are the user's to fix, so they surface instead.
        var allowsScribeFallback: Bool {
            switch self {
            case .missingAPIKey, .missingEndpoint, .unauthorized: return false
            default:                            return true
            }
        }
    }

    /// One request. The audio must fit `maxRequestSeconds`. The language is
    /// auto-detected per phrase (see `definitionJSON`), so the app's language
    /// picker does not apply here.
    func transcribe(url: URL,
                    diarize: Bool,
                    phrases: [String],
                    apiKey: String,
                    progress: @escaping (Double, String) -> Void) async throws -> [MAIPhrase] {
        progress(0.05, "Uploading to Azure…")
        Log.pipeline.notice("mai: uploading \(url.lastPathComponent, privacy: .public) diarize=\(diarize, privacy: .public) phrases=\(phrases.count, privacy: .public)")

        let request = try makeRequest(fileURL: url, diarize: diarize,
                                      phrases: phrases, apiKey: apiKey)
        let data: Data
        let response: URLResponse
        do {
            // Like Scribe, nothing comes back until the whole file is done —
            // staged messages only.
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw MAIError.network(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else { throw MAIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            Log.pipeline.error("mai: HTTP \(http.statusCode, privacy: .public) — \(String(data: data, encoding: .utf8) ?? "<binary>", privacy: .public)")
            if http.statusCode == 401 || http.statusCode == 403 {
                throw MAIError.unauthorized
            }
            if Self.isDiarizationFailure(status: http.statusCode, diarize: diarize) {
                throw MAIError.diarizationUnavailable(status: http.statusCode)
            }
            throw MAIError.server(status: http.statusCode, message: Self.errorDetail(from: data))
        }

        progress(0.9, "Parsing results…")
        guard let phrases = try? Self.decode(data) else {
            Log.pipeline.error("mai: response decode failed")
            throw MAIError.badResponse
        }
        Log.pipeline.notice("mai: got \(phrases.count, privacy: .public) phrases")
        return phrases
    }

    /// Transcription without diarization for audio of any length: recordings
    /// over `maxRequestSeconds` are cut at quiet points into several requests
    /// and stitched back on one timeline.
    func transcribeInChunks(url: URL,
                            phrases: [String],
                            apiKey: String,
                            progress: @escaping (Double, String) -> Void) async throws -> [MAISpan] {
        // Every upload source is our own 16 kHz mono WAV (mix, stem, or import).
        let sampleRate = 16_000.0
        let samples = try AudioMixdown.loadSamples(from: url)
        let ranges = MAISegmenter.chunkRanges(samples: samples, sampleRate: sampleRate,
                                              maxChunkSeconds: Self.maxRequestSeconds,
                                              searchSeconds: 30)
        var spans: [MAISpan] = []
        for (index, range) in ranges.enumerated() {
            let chunkURL = ranges.count == 1
                ? url
                : try AudioMixdown.writeTempWav(samples[range], prefix: "mai_chunk")
            defer {
                if chunkURL != url { try? FileManager.default.removeItem(at: chunkURL) }
            }
            let part = ranges.count == 1 ? "" : " (part \(index + 1)/\(ranges.count))"
            let result = try await transcribe(
                url: chunkURL, diarize: false,
                phrases: phrases, apiKey: apiKey,
                progress: { p, s in progress((Double(index) + p) / Double(ranges.count), s + part) }
            )
            spans += MAISegmenter.spans(from: result, offset: Double(range.lowerBound) / sampleRate)
        }
        return spans
    }

    // MARK: – Request

    /// The response stays silent until the whole file is processed, so the
    /// idle timer bounds server-side work: 110 min of audio took under 2 min
    /// in the benchmark, and a hung diarization should fail over after 10.
    /// The resource timer leaves room for a slow upload.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 1800
        return URLSession(configuration: config)
    }()

    private struct Definition: Encodable {
        struct EnhancedMode: Encodable {
            struct ModelOptions: Encodable {
                let timestamps = "word"
                /// Drops fillers and false starts, like Scribe's `no_verbatim`.
                let transcribeStyle = "clean"
            }
            let enabled = true
            let model = "MAI-Transcribe-2"
            let modelOptions = ModelOptions()
        }
        struct Toggle: Encodable { let enabled: Bool }
        struct PhraseList: Encodable { let phrases: [String] }

        let enhancedMode = EnhancedMode()
        let diarization: Toggle?
        let phraseList: PhraseList?
    }

    /// No `locales`: a forced locale that doesn't match the speech makes MAI
    /// translate or drop it (English picker + Polish speech came back as one
    /// English sentence), and auto-detection scored the same as forcing the
    /// right language in the benchmark while also handling PL/EN switching.
    static func definitionJSON(diarize: Bool, phrases: [String]) throws -> Data {
        try JSONEncoder().encode(Definition(
            diarization: diarize ? .init(enabled: true) : nil,
            phraseList: phrases.isEmpty ? nil : .init(phrases: phrases)
        ))
    }

    private func makeRequest(fileURL: URL,
                             diarize: Bool,
                             phrases: [String],
                             apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: transcribeURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")

        let boundary = "meeting-transcriber-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        // In-memory body, as in ScribeEngine: ≤ 110 min of 16 kHz mono WAV.
        let audioData = try Data(contentsOf: fileURL)
        let definition = try Self.definitionJSON(diarize: diarize, phrases: phrases)
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"definition\"\r\nContent-Type: application/json\r\n\r\n".utf8))
        body.append(definition)
        body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"\(fileURL.lastPathComponent)\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(audioData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }

    /// Statuses the docs list for preview diarization failures (408 timeout,
    /// 500, 503 `diarization_unavailable`). Only meaningful when diarization
    /// was requested — without it the same codes are ordinary server errors.
    static func isDiarizationFailure(status: Int, diarize: Bool) -> Bool {
        diarize && [408, 500, 503].contains(status)
    }

    /// Whether a failed diarized request is worth repeating without
    /// diarization: an explicit diarization failure, or a request that hung
    /// until the idle timeout (the other way preview diarization fails).
    static func shouldRetryWithoutDiarization(_ error: MAIError, diarize: Bool) -> Bool {
        guard diarize else { return false }
        switch error {
        case .diarizationUnavailable:
            return true
        case .network(let underlying):
            return (underlying as? URLError)?.code == .timedOut
        default:
            return false
        }
    }

    private static func errorDetail(from data: Data) -> String? {
        // Azure bodies look like {"code": "...", "message": "..."} or
        // {"error": {"code": "...", "message": "..."}}.
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let message = obj["message"] as? String { return message }
        if let error = obj["error"] as? [String: Any], let message = error["message"] as? String { return message }
        return nil
    }

    // MARK: – Response

    private struct Response: Decodable {
        let phrases: [MAIPhrase]?
    }

    static func decode(_ data: Data) throws -> [MAIPhrase] {
        try JSONDecoder().decode(Response.self, from: data).phrases ?? []
    }
}
