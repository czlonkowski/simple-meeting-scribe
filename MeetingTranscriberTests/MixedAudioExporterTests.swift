import AudioToolbox
import AVFoundation
import XCTest
@testable import MeetingTranscriber

final class MixedAudioExporterTests: XCTestCase {
    private var directoryURL: URL!

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixedAudioExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let directoryURL {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        directoryURL = nil
    }

    func testMixedWAVPreventsClippingBeforeEncoding() throws {
        let voiceURL = directoryURL.appendingPathComponent("voice.wav")
        let systemURL = directoryURL.appendingPathComponent("system.wav")
        let outputURL = directoryURL.appendingPathComponent("mixed.wav")
        try write(samples: [0.8, 0.2, -0.4], to: voiceURL)
        try write(samples: [0.8, 0.3, -0.2], to: systemURL)

        try MixedAudioExporter.writeMixedWAV(
            voiceURL: voiceURL,
            systemURL: systemURL,
            outputURL: outputURL
        )
        let samples = try readSamples(from: outputURL)

        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples[0], 0.98, accuracy: 0.002)
        XCTAssertEqual(samples[1], 0.30625, accuracy: 0.002)
        XCTAssertEqual(samples[2], -0.3675, accuracy: 0.002)
    }

    func testExportsCompressedMP3() throws {
        let encoderURL = try installedLAMEURL()
        let voiceURL = directoryURL.appendingPathComponent("voice.wav")
        let systemURL = directoryURL.appendingPathComponent("system.wav")
        let voiceSamples = sineWave(amplitude: 0.8)
        try write(samples: voiceSamples, to: voiceURL)
        try write(samples: voiceSamples, to: systemURL)

        let outputURL = try MixedAudioExporter.export(
            voiceURL: voiceURL,
            systemURL: systemURL,
            to: directoryURL,
            filenameStem: "Meeting-mixed",
            encoderURL: encoderURL
        )
        let decodedSamples = try readSamples(from: outputURL)
        let decodedPeak = decodedSamples.map { abs($0) }.max() ?? 0
        let inputSize = try fileSize(of: voiceURL) + fileSize(of: systemURL)

        XCTAssertEqual(outputURL.lastPathComponent, "Meeting-mixed.mp3")
        XCTAssertEqual(
            try audioFileType(of: outputURL),
            kAudioFileMP3Type
        )
        XCTAssertLessThan(try fileSize(of: outputURL), inputSize)
        XCTAssertGreaterThan(decodedPeak, 0.7)
        XCTAssertLessThan(decodedPeak, 1.05)
    }

    func testEncodesVoiceOnlyMeetingAndAvoidsOverwrite() throws {
        let encoderURL = try installedLAMEURL()
        let voiceURL = directoryURL.appendingPathComponent("voice.wav")
        try write(samples: sineWave(amplitude: 0.4), to: voiceURL)

        let firstURL = try MixedAudioExporter.export(
            voiceURL: voiceURL,
            systemURL: nil,
            to: directoryURL,
            filenameStem: "Meeting-mixed",
            encoderURL: encoderURL
        )
        let secondURL = try MixedAudioExporter.export(
            voiceURL: voiceURL,
            systemURL: nil,
            to: directoryURL,
            filenameStem: "Meeting-mixed",
            encoderURL: encoderURL
        )

        XCTAssertEqual(firstURL.lastPathComponent, "Meeting-mixed.mp3")
        XCTAssertEqual(secondURL.lastPathComponent, "Meeting-mixed 2.mp3")
        XCTAssertLessThan(try fileSize(of: firstURL), try fileSize(of: voiceURL))
    }

    private func write(samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ),
        let channel = buffer.floatChannelData?[0] else {
            return XCTFail("Could not allocate test audio buffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    private func readSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            XCTFail("Could not allocate result audio buffer")
            return []
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            XCTFail("Result audio is not float PCM")
            return []
        }
        return Array(
            UnsafeBufferPointer(
                start: channel,
                count: Int(buffer.frameLength)
            )
        )
    }

    private func sineWave(amplitude: Float) -> [Float] {
        let sampleRate = 16_000.0
        let frequency = 440.0
        return (0..<Int(sampleRate)).map { frame in
            amplitude * Float(sin(2 * .pi * frequency * Double(frame) / sampleRate))
        }
    }

    private func installedLAMEURL() throws -> URL {
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/lame"),
            URL(fileURLWithPath: "/usr/local/bin/lame")
        ]
        guard let url = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw XCTSkip("LAME is not installed on this test machine.")
        }
        return url
    }

    private func fileSize(of url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return try XCTUnwrap(values.fileSize)
    }

    private func audioFileType(of url: URL) throws -> AudioFileTypeID {
        var audioFile: AudioFileID?
        XCTAssertEqual(
            AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile),
            noErr
        )
        let openedFile = try XCTUnwrap(audioFile)
        defer { AudioFileClose(openedFile) }

        var fileType: AudioFileTypeID = 0
        var propertySize = UInt32(MemoryLayout.size(ofValue: fileType))
        XCTAssertEqual(
            AudioFileGetProperty(
                openedFile,
                kAudioFilePropertyFileFormat,
                &propertySize,
                &fileType
            ),
            noErr
        )
        return fileType
    }
}
