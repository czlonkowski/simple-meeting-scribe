import Foundation
import OSLog

/// Cloud transcription via the ElevenLabs Scribe v2 speech-to-text API.
/// Produces the same `WhisperSegment` / `DiarizedSegment` shapes as the local
/// engines so `TranscriptMerger` works unchanged. The system stem is sent with
/// `diarize=true` and Scribe's native speaker IDs replace FluidAudio.
struct ScribeEngine {
    struct Result {
        let segments: [WhisperSegment]
        /// One entry per segment when diarization was requested; empty otherwise.
        let diarization: [DiarizedSegment]
    }

    enum ScribeError: LocalizedError {
        case missingAPIKey
        case unauthorized
        case server(status: Int, message: String?)
        case network(underlying: Error)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "ElevenLabs API key is not set. Add it in Settings → General → Transcription."
            case .unauthorized:
                return "ElevenLabs rejected the API key. Check it in Settings → General."
            case .server(let status, let message):
                let detail = message.map { ": \($0)" } ?? ""
                return "ElevenLabs returned HTTP \(status)\(detail). Try again, or re-transcribe with a local Whisper model."
            case .network(let underlying):
                return "Could not reach ElevenLabs: \(underlying.localizedDescription) Check your connection, then use Re-transcribe."
            case .badResponse:
                return "ElevenLabs returned an unexpected response. Try again, or re-transcribe with a local Whisper model."
            }
        }
    }

    func transcribe(url: URL,
                    language: TranscriptionLanguage,
                    diarize: Bool,
                    apiKey: String,
                    progress: @escaping (Double, String) -> Void) async throws -> Result {
        progress(0.05, "Uploading to ElevenLabs…")
        Log.pipeline.notice("scribe: uploading \(url.lastPathComponent, privacy: .public) diarize=\(diarize, privacy: .public)")

        let request = try makeRequest(fileURL: url, language: language,
                                      diarize: diarize, apiKey: apiKey)

        let data: Data
        let response: URLResponse
        do {
            // The response arrives only once cloud transcription is done, so
            // there is no observable mid-flight progress — staged messages only.
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw ScribeError.network(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else { throw ScribeError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            Log.pipeline.error("scribe: HTTP \(http.statusCode, privacy: .public) — \(String(data: data, encoding: .utf8) ?? "<binary>", privacy: .public)")
            if http.statusCode == 401 || http.statusCode == 403 {
                throw ScribeError.unauthorized
            }
            throw ScribeError.server(status: http.statusCode,
                                     message: Self.errorDetail(from: data))
        }

        progress(0.9, "Parsing results…")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let parsed = try? decoder.decode(ScribeResponse.self, from: data) else {
            Log.pipeline.error("scribe: response decode failed")
            throw ScribeError.badResponse
        }
        Log.pipeline.notice("scribe: got \(parsed.words?.count ?? 0, privacy: .public) words")

        return Self.makeResult(from: parsed, diarized: diarize)
    }

    // MARK: – Request

    /// Cloud transcription of long audio can take many minutes; allow up to 30.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        // `timeoutIntervalForRequest` is an *idle* timer (resets only when data
        // moves), and Scribe stays silent for the entire server-side transcription
        // — no bytes flow back until the whole job is done. A short value here
        // trips mid-transcription on long recordings ("request timed out") long
        // before the real 30-min total cap below. Match the two so the resource
        // timeout is the only bound.
        config.timeoutIntervalForRequest = 1800
        config.timeoutIntervalForResource = 1800
        return URLSession(configuration: config)
    }()

    private func makeRequest(fileURL: URL,
                             language: TranscriptionLanguage,
                             diarize: Bool,
                             apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let boundary = "meeting-transcriber-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        // In-memory body is fine here: stems are 16 kHz mono WAV (~110 MB/hour).
        // Switch to uploadTask(fromFile:) if memory ever becomes a concern.
        let audioData = try Data(contentsOf: fileURL)
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model_id", "scribe_v2")
        field("timestamps_granularity", "word")
        field("tag_audio_events", "false")
        // Drops filler words ("um", "uh"), false starts, and non-speech
        // sounds from the transcript. scribe_v2-only parameter.
        field("no_verbatim", "true")
        field("language_code", language.rawValue)
        if diarize { field("diarize", "true") }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(audioData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }

    private static func errorDetail(from data: Data) -> String? {
        // ElevenLabs error bodies look like {"detail": "..."} or
        // {"detail": {"message": "..."}}.
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = obj["detail"] else { return nil }
        if let s = detail as? String { return s }
        if let d = detail as? [String: Any], let m = d["message"] as? String { return m }
        return nil
    }

    // MARK: – Response

    private struct ScribeResponse: Decodable {
        struct Word: Decodable {
            let text: String
            let start: Double?
            let end: Double?
            let type: String?       // "word" | "spacing" | "audio_event"
            let speakerId: String?  // "speaker_0", "speaker_1", …
        }
        let languageCode: String?
        let text: String?
        let words: [Word]?
    }

    /// Group word-level results into sentence-ish segments, flushing on
    /// speaker change, sentence-ending punctuation, or a safety cap.
    private static func makeResult(from response: ScribeResponse, diarized: Bool) -> Result {
        let words = (response.words ?? []).filter { $0.type != "audio_event" }

        // Fallback: no word timestamps, but text present → single segment.
        guard !words.isEmpty else {
            let text = (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return Result(segments: [], diarization: []) }
            return Result(segments: [WhisperSegment(start: 0, end: 0, text: text)],
                          diarization: diarized ? [DiarizedSegment(start: 0, end: 0, speakerId: 0)] : [])
        }

        var segments: [WhisperSegment] = []
        var diarization: [DiarizedSegment] = []
        var buffer = ""
        var segStart: Double?
        var segEnd: Double = 0
        var segSpeaker = 0
        var currentSpeaker: Int? = nil

        func flush() {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if let start = segStart, !text.isEmpty {
                segments.append(WhisperSegment(start: start, end: segEnd, text: text))
                if diarized {
                    diarization.append(DiarizedSegment(start: start, end: segEnd,
                                                       speakerId: segSpeaker))
                }
            }
            buffer = ""
            segStart = nil
        }

        for word in words {
            let speaker = speakerIndex(word.speakerId)
            if word.type == "spacing" {
                if segStart != nil { buffer += word.text }
                continue
            }
            if currentSpeaker != nil, speaker != currentSpeaker {
                flush()
            }
            currentSpeaker = speaker

            if segStart == nil {
                segStart = word.start ?? segEnd
                segSpeaker = speaker
            }
            buffer += word.text
            segEnd = word.end ?? word.start ?? segEnd

            let trimmed = word.text.trimmingCharacters(in: .whitespaces)
            let sentenceEnd = trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?")
            let tooLong = buffer.count > 400 || (segStart.map { segEnd - $0 > 30 } ?? false)
            if sentenceEnd || tooLong {
                flush()
            }
        }
        flush()

        return Result(segments: segments, diarization: diarization)
    }

    /// "speaker_3" → 3; missing/unparsable → 0.
    private static func speakerIndex(_ id: String?) -> Int {
        guard let id, let n = Int(id.split(separator: "_").last ?? "") else { return 0 }
        return n
    }
}
