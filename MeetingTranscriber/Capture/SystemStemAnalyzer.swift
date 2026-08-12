import Foundation
import AVFoundation

/// Measures how much of a recorded system stem is digital silence, so a
/// recording that lost the remote party gets flagged as partial instead of
/// being presented as a complete meeting.
enum SystemStemAnalyzer {
    /// A stem this silent is reported to the user as a partial capture.
    static let partialThreshold = 0.25

    /// Fraction (0...1) of frames that are exactly zero, or nil when the file
    /// can't be read.
    ///
    /// Exact-zero rather than a level threshold, for the same reason
    /// `SystemAudioHealth` uses one: a real capture of a quiet room carries a
    /// noise floor, while audio the capture dropped is literal zeros.
    ///
    /// Scans the whole file, so call it off the main actor — a three-hour stem
    /// is ~350 MB.
    static func silentFraction(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let total = file.length
        guard total > 0 else { return nil }

        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: chunk) else { return nil }

        var silentFrames: Int64 = 0
        while file.framePosition < total {
            do { try file.read(into: buffer, frameCount: chunk) } catch { return nil }
            let count = Int(buffer.frameLength)
            guard count > 0, let channel = buffer.floatChannelData?[0] else { break }
            let samples = UnsafeBufferPointer(start: channel, count: count)
            for sample in samples where sample == 0 { silentFrames += 1 }
        }
        return Double(silentFrames) / Double(total)
    }
}
