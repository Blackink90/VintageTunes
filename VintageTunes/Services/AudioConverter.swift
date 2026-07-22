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
            if remuxFaststart(from: source, to: dest) {
                return dest
            }
            try? fm.removeItem(at: dest)
        }

        progress?("Converto \(source.lastPathComponent) → M4A…")
        try encodeAAC(from: source, to: dest, bitrate: iPodAACBitrate)
        return dest
    }

    private static func encodeAAC(from source: URL, to dest: URL, bitrate: String) throws {
        let afconvert = URL(fileURLWithPath: "/usr/bin/afconvert")
        guard FileManager.default.isExecutableFile(atPath: afconvert.path) else {
            throw AudioConversionError.afconvertMissing
        }
        let process = Process()
        process.executableURL = afconvert
        process.arguments = [source.path, dest.path, "-d", "aac", "-f", "m4af", "-b", bitrate]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: dest.path) else {
            throw AudioConversionError.failed(errText.isEmpty ? "Conversione AAC fallita" : errText)
        }
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
