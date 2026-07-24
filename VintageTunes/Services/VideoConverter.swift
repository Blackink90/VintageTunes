import Foundation
import AVFoundation

enum VideoConversionError: LocalizedError {
    case ffmpegMissing
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .ffmpegMissing:
            return "Serve ffmpeg (brew install ffmpeg) per convertire i video per iPod."
        case .failed(let m): return m
        case .cancelled: return "Conversione video annullata."
        }
    }
}

/// Profilo encode per firmware stock Video 5G/5.5G e Classic.
enum iPodVideoEncodeProfile {
    /// Video 5G/5.5G: H.264 Baseline ≤640×480 @ ~1.5 Mbps + AAC.
    case video5G
    /// Classic: H.264 Main ≤640×480 @ ~2.5 Mbps + AAC.
    case classic

    var maxWidth: Int { 640 }
    var maxHeight: Int { 480 }
    var videoBitrate: String {
        switch self {
        case .video5G: return "1500k"
        case .classic: return "2500k"
        }
    }
    var audioBitrate: String {
        switch self {
        case .video5G: return "160k"
        case .classic: return "160k"
        }
    }
    var x264Profile: String {
        switch self {
        case .video5G: return "baseline"
        case .classic: return "main"
        }
    }
    var x264Level: String {
        switch self {
        case .video5G: return "3.0"
        case .classic: return "3.1"
        }
    }

    static func detect(for device: iPodDevice) -> iPodVideoEncodeProfile {
        let hint = device.modelHint.uppercased()
        if hint.contains("CLASSIC")
            || hint.contains("MA446")
            || hint.contains("MB147")
            || hint.contains("MB139") {
            return .classic
        }
        return .video5G
    }
}

enum VideoFileCollector {
    static let importableExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "webm", "mpg", "mpeg"
    ]

    static func collectVideoFiles(from urls: [URL]) -> [URL] {
        var collected: [URL] = []
        var seen = Set<String>()
        for url in urls {
            collect(from: url.standardizedFileURL, into: &collected, seen: &seen)
        }
        return collected.sorted {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }

    private static func collect(from url: URL, into collected: inout [URL], seen: inout Set<String>) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }

        if isDirectory.boolValue {
            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return }
            for case let item as URL in enumerator {
                var itemIsDir: ObjCBool = false
                guard fm.fileExists(atPath: item.path, isDirectory: &itemIsDir), !itemIsDir.boolValue else {
                    continue
                }
                appendIfVideo(item, into: &collected, seen: &seen)
            }
        } else {
            appendIfVideo(url, into: &collected, seen: &seen)
        }
    }

    private static func appendIfVideo(_ url: URL, into collected: inout [URL], seen: inout Set<String>) {
        let ext = url.pathExtension.lowercased()
        guard importableExtensions.contains(ext) else { return }
        let key = url.standardizedFileURL.path
        guard seen.insert(key).inserted else { return }
        collected.append(url.standardizedFileURL)
    }
}

enum VideoMetadataReader {
    static func read(url: URL) async -> ImportCandidate {
        let asset = AVURLAsset(url: url)
        let durationMs: UInt32
        do {
            let duration = try await asset.load(.duration)
            let ms = CMTimeGetSeconds(duration) * 1000
            durationMs = ms.isFinite && ms > 0 ? UInt32(clamping: Int(ms.rounded())) : 0
        } catch {
            durationMs = 0
        }

        let sizeBytes: UInt32
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber {
            sizeBytes = UInt32(clamping: size.intValue)
        } else {
            sizeBytes = 0
        }

        let base = url.deletingPathExtension().lastPathComponent
        return ImportCandidate(
            url: url,
            title: base,
            artist: "",
            album: "",
            genre: "Film",
            durationMs: durationMs,
            sizeBytes: sizeBytes,
            trackNumber: 0,
            year: 0,
            bitrate: 1500,
            sampleRate: 44100
        )
    }
}

enum VideoConverter {
    static var convertedFolderURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("VintageTunes", isDirectory: true)
            .appendingPathComponent("ConvertedVideo", isDirectory: true)
    }

    /// Sempre ricodifica in .m4v iPod-safe (evita file non riprodotti dal firmware).
    static func convertForiPod(
        _ source: URL,
        profile: iPodVideoEncodeProfile,
        preferredName: String? = nil,
        progress: ((String) -> Void)? = nil
    ) async throws -> URL {
        guard let bin = ffmpegBinary() else {
            throw VideoConversionError.ffmpegMissing
        }

        let fm = FileManager.default
        try fm.createDirectory(at: convertedFolderURL, withIntermediateDirectories: true)

        let baseName = sanitizeFilename(
            preferredName ?? source.deletingPathExtension().lastPathComponent
        )
        let archive = convertedFolderURL.appendingPathComponent("\(baseName).m4v")
        try? fm.removeItem(at: archive)

        progress?("Converto \(source.lastPathComponent) → video iPod…")

        let scale = "scale=\(profile.maxWidth):\(profile.maxHeight):force_original_aspect_ratio=decrease"
        let pad = "pad=\(profile.maxWidth):\(profile.maxHeight):(ow-iw)/2:(oh-ih)/2"
        let vf = "\(scale),\(pad),setsar=1"
        // Baseline LC: 1 ref, no B-frames, no CABAC (chipset 5G).
        let x264Params: String = {
            switch profile {
            case .video5G:
                return "ref=1:bframes=0:cabac=0:weightp=0:8x8dct=0"
            case .classic:
                return "ref=2:bframes=0"
            }
        }()

        let process = Process()
        process.executableURL = bin
        process.arguments = [
            "-y",
            "-i", source.path,
            "-map", "0:v:0",
            "-map", "0:a:0?",
            "-c:v", "libx264",
            "-profile:v", profile.x264Profile,
            "-level", profile.x264Level,
            "-pix_fmt", "yuv420p",
            "-vf", vf,
            "-r", "30",
            "-b:v", profile.videoBitrate,
            "-maxrate", profile.videoBitrate,
            "-bufsize", "3000k",
            "-x264-params", x264Params,
            "-c:a", "aac",
            "-b:a", profile.audioBitrate,
            "-ar", "44100",
            "-ac", "2",
            "-movflags", "+faststart",
            "-f", "ipod",
            archive.path
        ]

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        try process.run()

        // Attendi in background così possiamo propagare cancel.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                if process.terminationStatus == 0, FileManager.default.fileExists(atPath: archive.path) {
                    cont.resume()
                } else {
                    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let tail = err.split(separator: "\n").suffix(4).joined(separator: " ")
                    cont.resume(throwing: VideoConversionError.failed(
                        tail.isEmpty ? "Conversione video fallita" : tail
                    ))
                }
            }
        }

        let tempDir = fm.temporaryDirectory.appendingPathComponent("VintageTunesVideo", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dest = tempDir.appendingPathComponent("\(UUID().uuidString).m4v")
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: archive, to: dest)
        return dest
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
        return cleaned.isEmpty ? "Video" : cleaned
    }
}
