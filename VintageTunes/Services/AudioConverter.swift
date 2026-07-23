import Foundation
import AppKit

enum AudioConversionError: LocalizedError {
    case afconvertMissing
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .afconvertMissing: return "afconvert non trovato (strumento di sistema macOS)."
        case .failed(let m): return m
        case .cancelled: return "Conversione annullata."
        }
    }
}

enum AudioConverter {
    /// Formati da convertire in M4A AAC (come Music.app) prima del sync stock.
    static let convertibleExtensions: Set<String> = [
        "flac", "ogg", "opus", "wma", "aiff", "aif", "wav", "caf"
    ]

    private static let iPodAACBitrate = "256000"

    static var convertedFolderURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("VintageTunes", isDirectory: true)
            .appendingPathComponent("Converted", isDirectory: true)
    }

    static func needsConversion(_ url: URL) -> Bool {
        convertibleExtensions.contains(url.pathExtension.lowercased())
    }

    /// Prep on-device: M4A/AAC → faststart se serve; MP3 → CBR pulito; altro → M4A.
    static func needsiPodAudioPrep(_ url: URL) -> Bool {
        ["m4a", "m4b", "mp4", "aac", "mp3"].contains(url.pathExtension.lowercased())
            || needsConversion(url)
    }

    static func convertToMP3(
        _ source: URL,
        preferredName: String? = nil,
        artist: String = "",
        album: String = "",
        artworkData: Data? = nil,
        progress: ((String) -> Void)? = nil
    ) async throws -> URL {
        try await convertToM4A(
            source,
            preferredName: preferredName,
            artist: artist,
            album: album,
            artworkData: artworkData,
            progress: progress
        )
    }

    /// Converte in M4A AAC (formato usato da Music.app sul Video 5.5G).
    static func convertToM4A(
        _ source: URL,
        preferredName: String? = nil,
        artist: String = "",
        album: String = "",
        artworkData: Data? = nil,
        progress: ((String) -> Void)? = nil
    ) async throws -> URL {
        _ = artworkData
        _ = artist
        _ = album
        let fm = FileManager.default
        try fm.createDirectory(at: convertedFolderURL, withIntermediateDirectories: true)

        let baseName = sanitizeFilename(
            preferredName ?? source.deletingPathExtension().lastPathComponent
        )
        let archive = convertedFolderURL.appendingPathComponent("\(baseName).m4a")
        try? fm.removeItem(at: archive)

        progress?("Converto \(source.lastPathComponent) → M4A…")
        try encodeAAC(from: source, to: archive, bitrate: iPodAACBitrate)

        let tempDir = fm.temporaryDirectory.appendingPathComponent("VintageTunesConvert", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dest = tempDir.appendingPathComponent("\(UUID().uuidString).m4a")
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: archive, to: dest)
        return dest
    }

    static func prepareM4AForiPod(_ source: URL, progress: ((String) -> Void)? = nil) throws -> URL {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("VintageTunesConvert", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let ext = source.pathExtension.lowercased()

        if ext == "mp3" {
            let dest = tempDir.appendingPathComponent("\(UUID().uuidString).mp3")
            try? fm.removeItem(at: dest)
            progress?("Preparo \(source.lastPathComponent) come MP3…")
            try encodeMP3(from: source, to: dest, bitrate: "192k")
            return dest
        }

        let dest = tempDir.appendingPathComponent("\(UUID().uuidString).m4a")
        try? fm.removeItem(at: dest)

        if ["m4a", "m4b", "mp4", "aac"].contains(ext) {
            progress?("Ottimizzo \(source.lastPathComponent) per iPod…")
            if isiPodFriendlyAAC(source), remuxFaststart(from: source, to: dest) {
                return dest
            }
            try? fm.removeItem(at: dest)
        }

        progress?("Converto \(source.lastPathComponent) → M4A…")
        try encodeAAC(from: source, to: dest, bitrate: iPodAACBitrate)
        return dest
    }

    /// Solo remux se già AAC-LC ~44.1/48 kHz (altrimenti ri-encodiamo).
    private static func isiPodFriendlyAAC(_ url: URL) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/afinfo")
        proc.arguments = [url.path]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return false
        }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .lowercased() ?? ""
        guard text.contains("aac") || text.contains("mpeg-4 aac") || text.contains("m4a") else {
            return false
        }
        if text.contains("96000") || text.contains("88200") || text.contains("192000") {
            return false
        }
        return true
    }

    private static func encodeAAC(from source: URL, to dest: URL, bitrate: String) throws {
        let afconvert = URL(fileURLWithPath: "/usr/bin/afconvert")
        guard FileManager.default.isExecutableFile(atPath: afconvert.path) else {
            throw AudioConversionError.afconvertMissing
        }
        // Preferisci 44.1 kHz stereo; se fallisce (es. sorgente particolare), riprova senza -c.
        let attempts: [[String]] = [
            [source.path, dest.path, "-d", "aac@44100", "-f", "m4af", "-b", bitrate, "-c", "2"],
            [source.path, dest.path, "-d", "aac@44100", "-f", "m4af", "-b", bitrate]
        ]
        var lastError = ""
        for args in attempts {
            try? FileManager.default.removeItem(at: dest)
            let process = Process()
            process.executableURL = afconvert
            process.arguments = args
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = Pipe()
            try process.run()
            process.waitUntilExit()
            lastError = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if process.terminationStatus == 0, FileManager.default.fileExists(atPath: dest.path) {
                return
            }
        }
        throw AudioConversionError.failed(lastError.isEmpty ? "Conversione AAC fallita" : lastError)
    }

    private static func encodeMP3(from source: URL, to dest: URL, bitrate: String) throws {
        guard let bin = ffmpegBinary() else {
            throw AudioConversionError.failed("Serve ffmpeg (brew install ffmpeg) per MP3.")
        }
        let process = Process()
        process.executableURL = bin
        process.arguments = [
            "-y", "-i", source.path, "-vn",
            "-c:a", "libmp3lame", "-b:a", bitrate, "-ar", "44100", "-ac", "2",
            "-write_xing", "0", "-id3v2_version", "0", "-map_metadata", "-1",
            dest.path
        ]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: dest.path) else {
            throw AudioConversionError.failed("Conversione MP3 fallita")
        }
    }

    private static func remuxFaststart(from source: URL, to dest: URL) -> Bool {
        guard let bin = ffmpegBinary() else { return false }
        let process = Process()
        process.executableURL = bin
        process.arguments = ["-y", "-i", source.path, "-c", "copy", "-movflags", "+faststart", dest.path]
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: dest.path)
    }

    private static func ffmpegBinary() -> URL? {
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func sanitizeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = value.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Converted" : cleaned
    }
}
