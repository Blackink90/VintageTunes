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
    static let convertibleExtensions: Set<String> = [
        "flac", "ogg", "opus", "wma", "aiff", "aif", "wav", "caf"
    ]

    static var convertedFolderURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("VintageTunes", isDirectory: true)
            .appendingPathComponent("Converted", isDirectory: true)
    }

    static func needsConversion(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if AudioMetadataReader.isSupportedAudio(url) {
            return false
        }
        return convertibleExtensions.contains(ext)
    }

    /// Converte in M4A AAC 256 kbps via `afconvert`.
    /// Salva anche una copia con nome leggibile in `~/Library/Application Support/VintageTunes/Converted/`.
    static func convertToM4A(
        _ source: URL,
        preferredName: String? = nil,
        progress: ((String) -> Void)? = nil
    ) async throws -> URL {
        let afconvert = URL(fileURLWithPath: "/usr/bin/afconvert")
        guard FileManager.default.isExecutableFile(atPath: afconvert.path) else {
            throw AudioConversionError.afconvertMissing
        }

        let fm = FileManager.default
        try fm.createDirectory(at: convertedFolderURL, withIntermediateDirectories: true)

        let baseName = sanitizeFilename(
            preferredName
                ?? source.deletingPathExtension().lastPathComponent
        )
        let archive = convertedFolderURL.appendingPathComponent("\(baseName).m4a")
        try? fm.removeItem(at: archive)

        progress?("Converto \(source.lastPathComponent) → M4A…")

        let process = Process()
        process.executableURL = afconvert
        process.arguments = [
            source.path,
            archive.path,
            "-d", "aac",
            "-f", "m4af",
            "-b", "256000"
        ]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0, fm.fileExists(atPath: archive.path) else {
            throw AudioConversionError.failed(
                errText.isEmpty
                    ? "Conversione fallita per \(source.lastPathComponent)"
                    : errText
            )
        }

        // Copia di lavoro in temp (l'archivio in Converted resta consultabile)
        let tempDir = fm.temporaryDirectory.appendingPathComponent("VintageTunesConvert", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dest = tempDir.appendingPathComponent("\(UUID().uuidString).m4a")
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: archive, to: dest)

        return dest
    }

    private static func sanitizeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = value.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Converted" : cleaned
    }
}
