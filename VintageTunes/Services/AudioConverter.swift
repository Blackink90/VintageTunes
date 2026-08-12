import Foundation
import AppKit

enum AudioConversionError: LocalizedError {
    case afconvertMissing
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .afconvertMissing: return L10n.t("error.audio.afconvert_missing")
        case .failed(let m): return m
        case .cancelled: return L10n.t("error.audio.cancelled")
        }
    }
}

enum AudioConverter {
    /// Formati da convertire prima del sync stock (non riprodotti nativamente).
    static let convertibleExtensions: Set<String> = [
        "flac", "ogg", "opus", "wma", "aiff", "aif", "wav", "caf"
    ]

    private static let iPodAACBitrate = "256000"
    /// Framing grezzo come Vermilion (niente Xing/ID3); bitrate scelto in Impostazioni.
    private static let iPodMP3Bitrate320 = "320k"
    private static let iPodMP3Bitrate192 = "192k"

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

    /// True se il file è già riproduibile ma non nel contenitore/codec della preferenza (es. M4A con preferenza MP3).
    static func needsReformat(_ url: URL, to format: FlacConversionFormat) -> Bool {
        let ext = url.pathExtension.lowercased()
        switch format {
        case .mp3192, .mp3320:
            return ["m4a", "m4b", "mp4", "aac"].contains(ext)
        case .aac256:
            return ext == "mp3"
        case .alac:
            if ext == "mp3" { return true }
            if ["m4a", "m4b", "mp4", "aac"].contains(ext) {
                return probeAudioKind(url) != .alac
            }
            return false
        }
    }

    /// Prep on-device: remux M4A se serve; MP3 già pronti in pass-through; altro → destinazione tipica AAC.
    static func needsiPodAudioPrep(_ url: URL) -> Bool {
        ["m4a", "m4b", "mp4", "aac", "mp3"].contains(url.pathExtension.lowercased())
            || needsConversion(url)
    }

    /// Converte nella destinazione scelta (M4A AAC / ALAC / MP3 CBR).
    static func convertForiPod(
        _ source: URL,
        format: FlacConversionFormat = .aac256,
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
        let ext = format.fileExtension
        let archive = convertedFolderURL.appendingPathComponent("\(baseName).\(ext)")
        try? fm.removeItem(at: archive)

        switch format {
        case .aac256:
            progress?(L10n.tf("audio.convert_aac", source.lastPathComponent))
            try encodeAAC(from: source, to: archive, bitrate: iPodAACBitrate)
        case .alac:
            progress?(L10n.tf("audio.convert_alac", source.lastPathComponent))
            try encodeALAC(from: source, to: archive)
        case .mp3192:
            progress?(L10n.tf("audio.convert_mp3_192", source.lastPathComponent))
            try encodeMP3(from: source, to: archive, bitrate: iPodMP3Bitrate192)
        case .mp3320:
            progress?(L10n.tf("audio.convert_mp3_320", source.lastPathComponent))
            try encodeMP3(from: source, to: archive, bitrate: iPodMP3Bitrate320)
        }

        let tempDir = fm.temporaryDirectory.appendingPathComponent("VintageTunesConvert", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dest = tempDir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: archive, to: dest)
        return dest
    }

    /// Compat: stesso di `convertForiPod`.
    static func convertToM4A(
        _ source: URL,
        format: FlacConversionFormat = .aac256,
        preferredName: String? = nil,
        artist: String = "",
        album: String = "",
        artworkData: Data? = nil,
        progress: ((String) -> Void)? = nil
    ) async throws -> URL {
        try await convertForiPod(
            source,
            format: format,
            preferredName: preferredName,
            artist: artist,
            album: album,
            artworkData: artworkData,
            progress: progress
        )
    }

    static func convertToMP3(
        _ source: URL,
        preferredName: String? = nil,
        artist: String = "",
        album: String = "",
        artworkData: Data? = nil,
        progress: ((String) -> Void)? = nil
    ) async throws -> URL {
        try await convertForiPod(
            source,
            format: .mp3320,
            preferredName: preferredName,
            artist: artist,
            album: album,
            artworkData: artworkData,
            progress: progress
        )
    }

    /// Prep leggero prima della copia sull’iPod. La scelta M4A/MP3 avviene a monte in import.
    static func prepareM4AForiPod(_ source: URL, progress: ((String) -> Void)? = nil) throws -> URL {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("VintageTunesConvert", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let ext = source.pathExtension.lowercased()

        if ext == "mp3" {
            // Pass-through: non ri-encodare (evita perdita generazionale). L’MP3 320 nasce in convertForiPod.
            let dest = tempDir.appendingPathComponent("\(UUID().uuidString).mp3")
            try? fm.removeItem(at: dest)
            progress?(L10n.tf("audio.copy_mp3", source.lastPathComponent))
            try fm.copyItem(at: source, to: dest)
            return dest
        }

        let dest = tempDir.appendingPathComponent("\(UUID().uuidString).m4a")
        try? fm.removeItem(at: dest)

        if ["m4a", "m4b", "mp4", "aac"].contains(ext) {
            let kind = probeAudioKind(source)
            if kind == .alac {
                progress?(L10n.tf("audio.optimize_alac", source.lastPathComponent))
                if remuxFaststart(from: source, to: dest) {
                    return dest
                }
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: source, to: dest)
                return dest
            }
            if kind == .aac, isiPodFriendlyAACSampleRate(source), remuxFaststart(from: source, to: dest) {
                progress?(L10n.tf("audio.optimize_ipod", source.lastPathComponent))
                return dest
            }
            try? fm.removeItem(at: dest)
        }

        progress?(L10n.tf("audio.convert_aac", source.lastPathComponent))
        try encodeAAC(from: source, to: dest, bitrate: iPodAACBitrate)
        return dest
    }

    private enum AudioKind {
        case aac
        case alac
        case other
    }

    private static func probeAudioKind(_ url: URL) -> AudioKind {
        let text = afinfoText(url)
        if text.contains("alac") || text.contains("apple lossless") {
            return .alac
        }
        if text.contains("mpeg-4 aac") || text.contains(" aac") || text.contains("aac ")
            || text.hasPrefix("aac") || text.contains("\naac") {
            return .aac
        }
        if text.range(of: #"\baac\b"#, options: .regularExpression) != nil {
            return .aac
        }
        return .other
    }

    private static func isiPodFriendlyAACSampleRate(_ url: URL) -> Bool {
        let text = afinfoText(url)
        if text.contains("96000") || text.contains("88200") || text.contains("192000") {
            return false
        }
        return true
    }

    private static func afinfoText(_ url: URL) -> String {
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
            return ""
        }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .lowercased() ?? ""
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
        throw AudioConversionError.failed(lastError.isEmpty ? L10n.t("error.audio.aac_failed") : lastError)
    }

    private static func encodeALAC(from source: URL, to dest: URL) throws {
        let afconvert = URL(fileURLWithPath: "/usr/bin/afconvert")
        guard FileManager.default.isExecutableFile(atPath: afconvert.path) else {
            throw AudioConversionError.afconvertMissing
        }
        let attempts: [[String]] = [
            [source.path, dest.path, "-d", "alac", "-f", "m4af", "-c", "2"],
            [source.path, dest.path, "-d", "alac", "-f", "m4af"]
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
        throw AudioConversionError.failed(lastError.isEmpty ? L10n.t("error.audio.alac_failed") : lastError)
    }

    private static func encodeMP3(from source: URL, to dest: URL, bitrate: String) throws {
        guard let bin = ffmpegBinary() else {
            throw AudioConversionError.failed(L10n.t("error.audio.ffmpeg_mp3"))
        }
        let process = Process()
        process.executableURL = bin
        // Stesso profilo del Vermilion che suona fino in fondo sul 5.5G:
        // CBR LAME, frame MPEG crudi (niente Xing/ID3). Bitrate da afinfo → iTunesDB.
        process.arguments = [
            "-y", "-i", source.path, "-vn",
            "-c:a", "libmp3lame",
            "-b:a", bitrate,
            "-compression_level", "0",
            "-ar", "44100",
            "-ac", "2",
            "-write_xing", "0",
            "-id3v2_version", "0",
            "-map_metadata", "-1",
            dest.path
        ]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: dest.path) else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw AudioConversionError.failed(err.isEmpty ? L10n.t("error.audio.mp3_failed") : err)
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

    /// Se il M4A ha una track video/cover (es. JPEG 2000×2000), remux solo audio.
    /// Ritorna `true` se il file è stato sostituito.
    @discardableResult
    static func stripBloatedEmbeddedArtwork(at url: URL) throws -> Bool {
        guard hasEmbeddedCoverOrVideoStream(url) else { return false }
        guard let bin = ffmpegBinary() else {
            throw AudioConversionError.failed(L10n.t("error.audio.ffmpeg_strip_covers"))
        }
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("VintageTunesConvert", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dest = tempDir.appendingPathComponent("\(UUID().uuidString)-nocovr.m4a")
        try? fm.removeItem(at: dest)

        let process = Process()
        process.executableURL = bin
        process.arguments = [
            "-y", "-i", url.path,
            "-map", "0:a:0",
            "-c:a", "copy",
            "-movflags", "+faststart",
            dest.path
        ]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, fm.fileExists(atPath: dest.path) else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw AudioConversionError.failed(err.isEmpty ? L10n.t("error.audio.strip_covers_failed") : err)
        }

        let backup = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).bak.\(url.pathExtension)")
        try? fm.removeItem(at: backup)
        try fm.moveItem(at: url, to: backup)
        do {
            try fm.moveItem(at: dest, to: url)
            try? fm.removeItem(at: backup)
        } catch {
            try? fm.moveItem(at: backup, to: url)
            throw error
        }
        return true
    }

    private static func hasEmbeddedCoverOrVideoStream(_ url: URL) -> Bool {
        guard let bin = ffprobeBinary() else {
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return false }
            return data.range(of: Data("covr".utf8)) != nil
        }
        let process = Process()
        process.executableURL = bin
        process.arguments = [
            "-v", "error",
            "-select_streams", "v",
            "-show_entries", "stream=codec_type,codec_name,width,height",
            "-of", "csv=p=0",
            url.path
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !text.isEmpty
    }

    private static func ffmpegBinary() -> URL? {
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func ffprobeBinary() -> URL? {
        for path in ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]
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
