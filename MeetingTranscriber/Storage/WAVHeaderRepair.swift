import Foundation

/// Fixes the RIFF header of a WAV whose writer never finalized it.
///
/// `AVAudioFile` only writes the real chunk sizes when the file is closed. If
/// the app dies mid-recording, the samples are on disk but the `data` chunk
/// still says 0 bytes, so every AVAudioFile-based reader (and `afinfo`) sees an
/// empty file. Recomputing the sizes from the file length makes it readable.
enum WAVHeaderRepair {
    enum Outcome: Equatable {
        /// Header already matched the file length.
        case intact
        /// Header was rewritten; `dataBytes` is the recovered audio length.
        case repaired(dataBytes: UInt32)
    }

    enum RepairError: Error, LocalizedError {
        case notWAV
        case noDataChunk
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .notWAV:      "The recording is not a WAV file."
            case .noDataChunk: "The recording has no audio data."
            case .tooLarge:    "The recording is too large to repair."
            }
        }
    }

    /// Check `url` and, when its sizes disagree with the file length, patch
    /// them in place. Only the two size fields are written; samples are never
    /// touched. A trailing partial frame is left on disk but excluded from the
    /// `data` size.
    @discardableResult
    static func repairIfNeeded(at url: URL) throws -> Outcome {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        let fileLength = try handle.seekToEnd()
        guard fileLength <= UInt64(UInt32.max) else { throw RepairError.tooLarge }
        try handle.seek(toOffset: 0)
        // AVAudioFile pads with JUNK/FLLR so `data` starts at 4 KB; read a bit more.
        let head = try handle.read(upToCount: 64 * 1024) ?? Data()
        guard head.count >= 12,
              head.prefix(4) == Data("RIFF".utf8),
              head.subdata(in: 8..<12) == Data("WAVE".utf8) else { throw RepairError.notWAV }

        var offset = 12
        var blockAlign: UInt32 = 1
        while offset + 8 <= head.count {
            let id = head.subdata(in: offset..<offset + 4)
            let size = head.uint32(at: offset + 4)
            if id == Data("fmt ".utf8), offset + 8 + 14 <= head.count {
                blockAlign = max(1, UInt32(head.uint16(at: offset + 8 + 12)))
            }
            if id == Data("data".utf8) {
                let dataStart = UInt64(offset + 8)
                guard fileLength > dataStart else { throw RepairError.noDataChunk }
                let available = UInt32(fileLength - dataStart)
                let dataBytes = available - available % blockAlign
                let riffSize = UInt32(fileLength - 8)
                if size == dataBytes && head.uint32(at: 4) == riffSize {
                    return .intact
                }
                try handle.seek(toOffset: 4)
                handle.write(riffSize.littleEndianData)
                try handle.seek(toOffset: UInt64(offset + 4))
                handle.write(dataBytes.littleEndianData)
                try handle.synchronize()
                return .repaired(dataBytes: dataBytes)
            }
            // Chunks are word-aligned: odd sizes carry one pad byte.
            offset += 8 + Int(size) + Int(size & 1)
        }
        throw RepairError.noDataChunk
    }
}

private extension Data {
    func uint32(at offset: Int) -> UInt32 {
        self[startIndex + offset..<startIndex + offset + 4]
            .enumerated()
            .reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }

    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }
}

private extension UInt32 {
    var littleEndianData: Data { withUnsafeBytes(of: littleEndian) { Data($0) } }
}
