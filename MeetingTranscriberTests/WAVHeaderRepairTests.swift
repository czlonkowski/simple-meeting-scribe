import AVFoundation
import XCTest
@testable import MeetingTranscriber

final class WAVHeaderRepairTests: XCTestCase {
    private var directoryURL: URL!

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WAVHeaderRepairTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func testClosedFileIsLeftIntact() throws {
        let url = try writeStem(seconds: 1)
        XCTAssertEqual(try WAVHeaderRepair.repairIfNeeded(at: url), .intact)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 16_000)
    }

    /// Simulates a crash mid-recording: samples on disk, header sizes zeroed.
    func testZeroedHeaderIsRepairedAndReadable() throws {
        let url = try writeStem(seconds: 2)
        try zeroSizes(in: url)
        // Unfinalized: AVAudioFile either refuses the file or sees no samples.
        XCTAssertEqual((try? AVAudioFile(forReading: url))?.length ?? 0, 0)

        guard case .repaired(let bytes) = try WAVHeaderRepair.repairIfNeeded(at: url) else {
            return XCTFail("expected a repair")
        }
        XCTAssertEqual(bytes, 64_000)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 32_000)
        XCTAssertEqual(try WAVHeaderRepair.repairIfNeeded(at: url), .intact)
    }

    func testTrailingPartialFrameIsExcluded() throws {
        let url = try writeStem(seconds: 1)
        try zeroSizes(in: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        handle.write(Data([0x01]))           // half of a 16-bit frame
        try handle.close()

        XCTAssertEqual(try WAVHeaderRepair.repairIfNeeded(at: url), .repaired(dataBytes: 32_000))
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 16_000)
    }

    func testNonWAVIsRejected() throws {
        let url = directoryURL.appendingPathComponent("x.wav")
        try Data("not a wav at all".utf8).write(to: url)
        XCTAssertThrowsError(try WAVHeaderRepair.repairIfNeeded(at: url))
    }

    // MARK: – Helpers

    /// Same settings StemWriter uses: 16 kHz mono 16-bit PCM WAV.
    private func writeStem(seconds: Int) throws -> URL {
        let url = directoryURL.appendingPathComponent("\(UUID().uuidString).voice.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let frames = AVAudioFrameCount(16_000 * seconds)
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                        frameCapacity: frames))
            buffer.frameLength = frames
            for i in 0..<Int(frames) {
                buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.3
            }
            try file.write(from: buffer)
        } // file closes here
        return url
    }

    /// Zero the RIFF and `data` sizes, as an unfinalized AVAudioFile leaves them.
    private func zeroSizes(in url: URL) throws {
        var data = try Data(contentsOf: url)
        data.replaceSubrange(4..<8, with: [0, 0, 0, 0])
        let range = try XCTUnwrap(data.range(of: Data("data".utf8)))
        data.replaceSubrange(range.upperBound..<range.upperBound + 4, with: [0, 0, 0, 0])
        try data.write(to: url)
    }
}
