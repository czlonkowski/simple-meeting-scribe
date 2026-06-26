import Foundation
import AVFoundation

enum MediaImporter {

    /// Decode any audio/video file into a 16 kHz mono 16-bit WAV in the temp
    /// directory, reporting progress 0…1.
    static func convertToMono16kWav(source: URL,
                                    progress: @escaping (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw NSError(domain: "MediaImporter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio track in file."])
        }
        let duration = try await asset.load(.duration)
        let durationSec = CMTimeGetSeconds(duration)
        let reader = try AVAssetReader(asset: asset)

        let outSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let readerOut = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: outSettings)
        reader.add(readerOut)
        guard reader.startReading() else {
            throw NSError(domain: "MediaImporter", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not start audio reader."])
        }

        let wavSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let name = source.deletingPathExtension().lastPathComponent
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("import_\(Int(Date().timeIntervalSince1970))_\(name).wav")
        let workingFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 16_000,
                                       channels: 1,
                                       interleaved: false)!
        let file = try AVAudioFile(forWriting: outURL, settings: wavSettings)

        var framesWritten: Int64 = 0
        while let sample = readerOut.copyNextSampleBuffer() {
            guard let pcm = cmSampleBufferToFloatBuffer(sample, format: workingFmt) else { continue }
            try file.write(from: pcm)
            framesWritten += Int64(pcm.frameLength)
            if durationSec > 0 {
                let seconds = Double(framesWritten) / 16_000.0
                progress(min(0.98, seconds / durationSec))
            }
        }
        if reader.status == .failed { throw reader.error ?? NSError(domain: "MediaImporter", code: 3) }
        progress(1.0)
        return outURL
    }

    static func duration(of url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let dur = try await asset.load(.duration)
        return CMTimeGetSeconds(dur)
    }

    /// Best-guess "when was this recorded" for an imported media file.
    ///
    /// Priority:
    ///   1. A date in the filename ("Meeting 15.06.2026", "2026-06-15 …") — the
    ///      strongest signal of the actual meeting date, since embedded and
    ///      filesystem dates often reflect when the file was *exported* or
    ///      *downloaded*, not when it was recorded.
    ///   2. The container's embedded creation date (Voice Memos, phone
    ///      recordings, and cameras set it when recording in place).
    ///   3. The file's creation date, then modification date.
    /// Returns nil only if nothing is available.
    static func recordingDate(of url: URL) async -> Date? {
        if let fromName = dateFromFilename(url.lastPathComponent) {
            return fromName
        }
        if let embedded = await embeddedCreationDate(of: url) {
            return embedded
        }
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        if let values = try? url.resourceValues(forKeys: keys) {
            return values.creationDate ?? values.contentModificationDate
        }
        return nil
    }

    /// Extract a calendar date from a filename. Numeric dates are read
    /// **day-first** (15.06.2026 = 15 June), matching European/Polish naming;
    /// ISO (2026-06-15) is detected first since it's unambiguous, and
    /// month-name dates ("15 June 2026") fall through to the system detector.
    /// The date is anchored at noon local time so display never crosses a day
    /// boundary. Returns nil when no clear date is present.
    static func dateFromFilename(_ filename: String) -> Date? {
        let name = (filename as NSString).deletingPathExtension
        // 1. ISO year-first: 2026-06-15 / 2026.06.15 / 2026_06_15
        if let g = numericGroups(#"(\d{4})[._-](\d{1,2})[._-](\d{1,2})"#, in: name),
           let d = makeDate(year: g[0], month: g[1], day: g[2]) {
            return d
        }
        // 2. Day-first numeric: 15.06.2026 / 15-06-2026 / 15_06_2026
        if let g = numericGroups(#"(\d{1,2})[._-](\d{1,2})[._-](\d{4})"#, in: name),
           let d = makeDate(year: g[2], month: g[1], day: g[0]) {
            return d
        }
        // 3. Month-name dates ("15 June 2026", "Jun 15 2026"). Only reached when
        //    no numeric date pattern matched, so it can't misread a numeric one.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let range = NSRange(name.startIndex..., in: name)
            if let match = detector.firstMatch(in: name, range: range), let date = match.date {
                return date
            }
        }
        return nil
    }

    /// Integer capture groups of the first match, or nil if the pattern doesn't
    /// match or any group isn't an integer.
    private static func numericGroups(_ pattern: String, in text: String) -> [Int]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range) else { return nil }
        var groups: [Int] = []
        for i in 1..<m.numberOfRanges {
            guard let r = Range(m.range(at: i), in: text), let v = Int(text[r]) else { return nil }
            groups.append(v)
        }
        return groups
    }

    private static func makeDate(year: Int, month: Int, day: Int) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day),
              year >= 1990, year <= 2100 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = 12
        return cal.date(from: c)
    }

    /// The container's embedded creation date, if present. QuickTime/MPEG-4
    /// files store it as a metadata item that's either a real date value or an
    /// ISO 8601 string, so try both.
    private static func embeddedCreationDate(of url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        guard let item = try? await asset.load(.creationDate) else { return nil }
        if let date = try? await item.load(.dateValue) { return date }
        if let string = try? await item.load(.stringValue),
           let date = ISO8601DateFormatter().date(from: string) {
            return date
        }
        return nil
    }

    private static func cmSampleBufferToFloatBuffer(_ sb: CMSampleBuffer,
                                                    format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(frames)

        var abl = AudioBufferList(mNumberBuffers: 1,
                                  mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil))
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil,
            bufferListOut: &abl, bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &block)
        guard status == noErr, let data = abl.mBuffers.mData,
              let ch = pcm.floatChannelData?[0] else { return nil }
        let count = Int(abl.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        let src = data.bindMemory(to: Float.self, capacity: count)
        ch.update(from: src, count: min(count, Int(pcm.frameLength)))
        return pcm
    }
}
