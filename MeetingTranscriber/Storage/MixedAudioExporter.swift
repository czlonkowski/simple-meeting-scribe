import Accelerate
import AudioToolbox
import AVFoundation
import Foundation

enum MixedAudioExporter {
    private static let chunkFrameCount: AVAudioFrameCount = 65_536
    private static let maximumPeak: Float = 0.98
    private static let mp3BitRateKbps = 64

    static func export(
        voiceURL: URL,
        systemURL: URL?,
        to destinationDirectory: URL,
        filenameStem: String,
        encoderURL providedEncoderURL: URL? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        let destinationURL = uniqueDestination(
            in: destinationDirectory,
            filenameStem: filenameStem,
            fileManager: fileManager
        )
        let workingDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "MeetingTranscriber-MP3-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? fileManager.removeItem(at: workingDirectory)
        }

        let mixedWAVURL = workingDirectory.appendingPathComponent("mixed.wav")
        let encodedMP3URL = workingDirectory.appendingPathComponent("mixed.mp3")
        let sourceWAVURL: URL
        if let systemURL, fileManager.fileExists(atPath: systemURL.path) {
            try writeMixedWAV(
                voiceURL: voiceURL,
                systemURL: systemURL,
                outputURL: mixedWAVURL
            )
            sourceWAVURL = mixedWAVURL
        } else {
            sourceWAVURL = voiceURL
        }

        guard let encoderURL = providedEncoderURL ?? lameExecutableURL(fileManager: fileManager) else {
            throw ExportError.mp3EncoderUnavailable
        }
        try encodeMP3(
            sourceWAVURL: sourceWAVURL,
            outputURL: encodedMP3URL,
            encoderURL: encoderURL
        )
        try fileManager.moveItem(at: encodedMP3URL, to: destinationURL)
        return destinationURL
    }

    static func writeMixedWAV(
        voiceURL: URL,
        systemURL: URL,
        outputURL: URL
    ) throws {
        let voiceFile = try AVAudioFile(forReading: voiceURL)
        let systemFile = try AVAudioFile(forReading: systemURL)
        let voiceFormat = voiceFile.processingFormat
        let systemFormat = systemFile.processingFormat

        guard voiceFormat.commonFormat == .pcmFormatFloat32,
              systemFormat.commonFormat == .pcmFormatFloat32,
              !voiceFormat.isInterleaved,
              !systemFormat.isInterleaved else {
            throw ExportError.unsupportedAudioFormat
        }
        guard voiceFormat.sampleRate == systemFormat.sampleRate,
              voiceFormat.channelCount == systemFormat.channelCount else {
            throw ExportError.incompatibleStems
        }

        var peak: Float = 0
        try forEachMixedChunk(
            voiceFile: voiceFile,
            systemFile: systemFile
        ) { buffer, frameCount in
            guard let channels = buffer.floatChannelData else {
                throw ExportError.unsupportedAudioFormat
            }
            for channel in 0..<Int(buffer.format.channelCount) {
                var channelPeak: Float = 0
                vDSP_maxmgv(
                    channels[channel],
                    1,
                    &channelPeak,
                    vDSP_Length(frameCount)
                )
                peak = max(peak, channelPeak)
            }
        }

        let gain = peak > maximumPeak ? maximumPeak / peak : 1
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: voiceFormat.sampleRate,
            AVNumberOfChannelsKey: voiceFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        try forEachMixedChunk(
            voiceFile: voiceFile,
            systemFile: systemFile
        ) { buffer, frameCount in
            guard let channels = buffer.floatChannelData else {
                throw ExportError.unsupportedAudioFormat
            }
            if gain < 1 {
                var mutableGain = gain
                for channel in 0..<Int(buffer.format.channelCount) {
                    vDSP_vsmul(
                        channels[channel],
                        1,
                        &mutableGain,
                        channels[channel],
                        1,
                        vDSP_Length(frameCount)
                    )
                }
            }
            try outputFile.write(from: buffer)
        }
    }

    private static func encodeMP3(
        sourceWAVURL: URL,
        outputURL: URL,
        encoderURL: URL
    ) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = encoderURL
        process.arguments = [
            "--silent",
            "-b", String(mp3BitRateKbps),
            "-h",
            sourceWAVURL.path,
            outputURL.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw ExportError.mp3EncodingFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        guard process.terminationReason == .exit,
              process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: outputURL.path),
              isMP3File(outputURL) else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let details = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ExportError.mp3EncodingFailed(
                details?.isEmpty == false
                    ? details!
                    : "LAME exited with status \(process.terminationStatus)."
            )
        }
    }

    private static func isMP3File(_ url: URL) -> Bool {
        var audioFile: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile) == noErr,
              let audioFile else {
            return false
        }
        defer { AudioFileClose(audioFile) }

        var fileType: AudioFileTypeID = 0
        var propertySize = UInt32(MemoryLayout.size(ofValue: fileType))
        guard AudioFileGetProperty(
            audioFile,
            kAudioFilePropertyFileFormat,
            &propertySize,
            &fileType
        ) == noErr else {
            return false
        }
        return fileType == kAudioFileMP3Type
    }

    private static func lameExecutableURL(fileManager: FileManager) -> URL? {
        [
            "/opt/homebrew/bin/lame",
            "/usr/local/bin/lame"
        ]
        .map { URL(fileURLWithPath: $0) }
        .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func forEachMixedChunk(
        voiceFile: AVAudioFile,
        systemFile: AVAudioFile,
        body: (AVAudioPCMBuffer, AVAudioFrameCount) throws -> Void
    ) throws {
        voiceFile.framePosition = 0
        systemFile.framePosition = 0

        let format = voiceFile.processingFormat
        guard let voiceBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: chunkFrameCount
        ),
        let systemBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: chunkFrameCount
        ),
        let mixedBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: chunkFrameCount
        ) else {
            throw ExportError.couldNotAllocateBuffer
        }

        while voiceFile.framePosition < voiceFile.length
                || systemFile.framePosition < systemFile.length {
            clear(voiceBuffer)
            clear(systemBuffer)
            clear(mixedBuffer)

            let voiceFrames = try readNextChunk(from: voiceFile, into: voiceBuffer)
            let systemFrames = try readNextChunk(from: systemFile, into: systemBuffer)
            let frameCount = max(voiceFrames, systemFrames)
            guard frameCount > 0 else { break }

            guard let voiceChannels = voiceBuffer.floatChannelData,
                  let systemChannels = systemBuffer.floatChannelData,
                  let mixedChannels = mixedBuffer.floatChannelData else {
                throw ExportError.unsupportedAudioFormat
            }

            mixedBuffer.frameLength = frameCount
            for channel in 0..<Int(format.channelCount) {
                vDSP_vadd(
                    voiceChannels[channel],
                    1,
                    systemChannels[channel],
                    1,
                    mixedChannels[channel],
                    1,
                    vDSP_Length(frameCount)
                )
            }
            try body(mixedBuffer, frameCount)
        }
    }

    private static func readNextChunk(
        from file: AVAudioFile,
        into buffer: AVAudioPCMBuffer
    ) throws -> AVAudioFrameCount {
        let remainingFrames = max(0, file.length - file.framePosition)
        guard remainingFrames > 0 else { return 0 }
        let frameCount = AVAudioFrameCount(
            min(AVAudioFramePosition(chunkFrameCount), remainingFrames)
        )
        try file.read(into: buffer, frameCount: frameCount)
        return buffer.frameLength
    }

    private static func clear(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            vDSP_vclr(
                channels[channel],
                1,
                vDSP_Length(buffer.frameCapacity)
            )
        }
        buffer.frameLength = 0
    }

    private static func uniqueDestination(
        in directory: URL,
        filenameStem: String,
        fileManager: FileManager
    ) -> URL {
        let baseName = filenameStem.isEmpty ? "Meeting-mixed" : filenameStem
        var candidate = directory.appendingPathComponent("\(baseName).mp3")
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) \(suffix).mp3")
            suffix += 1
        }
        return candidate
    }
}

extension MixedAudioExporter {
    enum ExportError: LocalizedError {
        case couldNotAllocateBuffer
        case incompatibleStems
        case mp3EncoderUnavailable
        case mp3EncodingFailed(String)
        case unsupportedAudioFormat

        var errorDescription: String? {
            switch self {
            case .couldNotAllocateBuffer:
                return "Could not allocate an audio mixing buffer."
            case .incompatibleStems:
                return "The voice and system recordings use incompatible audio formats."
            case .mp3EncoderUnavailable:
                return "MP3 export requires LAME. Install it with “brew install lame”, then relaunch Meeting Transcriber."
            case .mp3EncodingFailed(let details):
                return "Could not encode the MP3: \(details)"
            case .unsupportedAudioFormat:
                return "The recording uses an unsupported audio format."
            }
        }
    }
}
