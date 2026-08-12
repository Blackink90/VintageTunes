import Foundation
import AVFoundation

/// Scrive i testi nei tag del file: l’iPod stock richiede USLT (MP3) o ©lyr (M4A)
/// **e** il lyrics_flag nell’mhit.
enum LyricsTagWriter {
    enum EmbedError: LocalizedError {
        case unsupported
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unsupported: return L10n.t("error.lyrics.unsupported_format")
            case .failed(let m): return m
            }
        }
    }

    @discardableResult
    static func embed(lyrics: String, into fileURL: URL) async throws -> UInt32 {
        let trimmed = lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EmbedError.failed(L10n.t("error.lyrics.empty")) }

        let ext = fileURL.pathExtension.lowercased()
        switch ext {
        case "m4a", "m4b", "mp4", "aac":
            try embedInMPEG4WithFFMPEG(lyrics: trimmed, fileURL: fileURL)
        case "mp3":
            try embedInMP3(lyrics: trimmed, fileURL: fileURL)
        default:
            throw EmbedError.unsupported
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? NSNumber {
            return UInt32(clamping: size.intValue)
        }
        return 0
    }

    // MARK: - M4A (©lyr via ffmpeg — AVFoundation spesso non scrive il tag)

    private static func embedInMPEG4WithFFMPEG(lyrics: String, fileURL: URL) throws {
        guard let ffmpeg = ffmpegBinary() else {
            throw EmbedError.failed(L10n.t("error.lyrics.ffmpeg_required"))
        }
        let fm = FileManager.default
        let temp = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString)-lyrics.m4a")
        try? fm.removeItem(at: temp)

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-y", "-i", fileURL.path,
            "-c", "copy",
            "-map_metadata", "0",
            "-metadata", "lyrics=\(lyrics)",
            temp.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, fm.fileExists(atPath: temp.path) else {
            try? fm.removeItem(at: temp)
            throw EmbedError.failed(L10n.t("error.lyrics.embed_failed"))
        }
        try fm.removeItem(at: fileURL)
        try fm.moveItem(at: temp, to: fileURL)
    }

    // MARK: - MP3 (ID3v2.3 USLT — ffmpeg scrive TXXX:USLT, inutile per iPod)

    private static func embedInMP3(lyrics: String, fileURL: URL) throws {
        let original = try Data(contentsOf: fileURL)
        var otherFrames = Data()
        let audioPayload: Data

        if original.count >= 10, String(bytes: original[0..<3], encoding: .ascii) == "ID3" {
            let verMajor = original[3]
            let tagSize = id3SynchsafeSize(original, at: 6)
            let headerSize = 10 + tagSize
            guard headerSize <= original.count else {
                throw EmbedError.failed(L10n.t("error.lyrics.embed_failed"))
            }
            // Conserva gli altri frame ID3v2.3/2.4 (salto USLT).
            if verMajor == 3 || verMajor == 4 {
                otherFrames = collectID3Frames(from: original, headerSize: 10, tagEnd: headerSize, skip: "USLT")
            }
            audioPayload = original.subdata(in: headerSize..<original.count)
        } else {
            audioPayload = original
        }

        let uslt = buildUSLTFrame(lyrics: lyrics)
        let tagBody = uslt + otherFrames
        var tag = Data()
        tag.append(contentsOf: [0x49, 0x44, 0x33]) // ID3
        tag.append(contentsOf: [0x03, 0x00]) // v2.3.0
        tag.append(0x00) // flags
        tag.append(contentsOf: synchsafeBytes(tagBody.count))
        tag.append(tagBody)
        tag.append(audioPayload)

        let temp = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString)-lyrics.mp3")
        try tag.write(to: temp, options: .atomic)
        let fm = FileManager.default
        try fm.removeItem(at: fileURL)
        try fm.moveItem(at: temp, to: fileURL)
    }

    private static func collectID3Frames(from data: Data, headerSize: Int, tagEnd: Int, skip: String) -> Data {
        var out = Data()
        var c = headerSize
        let skipBytes = Array(skip.utf8)
        while c + 10 <= tagEnd {
            let id = Array(data[c..<(c + 4)])
            if id.allSatisfy({ $0 == 0 }) { break }
            let size: Int
            // v2.3 = plain size; we always rewrite as v2.3 and treat sizes as plain big-endian
            // (good enough for frames we copy through from common tags).
            size = (Int(data[c + 4]) << 24) | (Int(data[c + 5]) << 16) | (Int(data[c + 6]) << 8) | Int(data[c + 7])
            let frameTotal = 10 + size
            guard size >= 0, c + frameTotal <= tagEnd else { break }
            if id != skipBytes {
                out.append(data[c..<(c + frameTotal)])
            }
            c += frameTotal
        }
        return out
    }

    /// ID3v2.3 USLT: encoding UTF-16, lang eng, empty descriptor, lyrics text.
    private static func buildUSLTFrame(lyrics: String) -> Data {
        var body = Data()
        body.append(0x01) // UTF-16 with BOM
        body.append(contentsOf: Array("eng".utf8))
        // Empty content descriptor (UTF-16 NUL)
        body.append(contentsOf: [0xFF, 0xFE, 0x00, 0x00])
        // Lyrics with BOM
        body.append(contentsOf: [0xFF, 0xFE])
        for unit in lyrics.utf16 {
            body.append(UInt8(unit & 0xff))
            body.append(UInt8((unit >> 8) & 0xff))
        }

        var frame = Data()
        frame.append(contentsOf: Array("USLT".utf8))
        let size = UInt32(body.count)
        frame.append(UInt8((size >> 24) & 0xff))
        frame.append(UInt8((size >> 16) & 0xff))
        frame.append(UInt8((size >> 8) & 0xff))
        frame.append(UInt8(size & 0xff))
        frame.append(contentsOf: [0x00, 0x00]) // flags
        frame.append(body)
        return frame
    }

    private static func id3SynchsafeSize(_ data: Data, at offset: Int) -> Int {
        guard offset + 4 <= data.count else { return 0 }
        let b0 = Int(data[offset])
        let b1 = Int(data[offset + 1])
        let b2 = Int(data[offset + 2])
        let b3 = Int(data[offset + 3])
        return (b0 << 21) | (b1 << 14) | (b2 << 7) | b3
    }

    private static func synchsafeBytes(_ size: Int) -> [UInt8] {
        [
            UInt8((size >> 21) & 0x7f),
            UInt8((size >> 14) & 0x7f),
            UInt8((size >> 7) & 0x7f),
            UInt8(size & 0x7f)
        ]
    }

    private static func ffmpegBinary() -> URL? {
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
