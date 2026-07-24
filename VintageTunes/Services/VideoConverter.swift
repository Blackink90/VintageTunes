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
        let durationSeconds = await VideoDurationProbe.seconds(for: url) ?? 0
        let durationMs: UInt32 = durationSeconds > 0
            ? UInt32(clamping: Int((durationSeconds * 1000).rounded()))
            : 0

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

/// Durata video: AVFoundation spesso fallisce su webm/mkv → fallback ffprobe.
enum VideoDurationProbe {
    static func seconds(for url: URL) async -> Double? {
        if let av = await avFoundationSeconds(url), av > 0.5 { return av }
        if let ff = ffprobeSeconds(url), ff > 0.5 { return ff }
        return nil
    }

    private static func avFoundationSeconds(_ url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite && seconds > 0 ? seconds : nil
        } catch {
            return nil
        }
    }

    static func ffprobeSeconds(_ url: URL) -> Double? {
        guard let bin = ffprobeBinary() else { return nil }
        let process = Process()
        process.executableURL = bin
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let seconds = Double(text), seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    private static func ffprobeBinary() -> URL? {
        var candidates = [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe"
        ]
        if let ffmpeg = VideoConverter.ffmpegBinaryPath() {
            let sibling = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
            candidates.insert(sibling.path, at: 0)
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
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
    /// `progress` riceve frazione 0…1 e un messaggio (es. percentuale / fase).
    static func convertForiPod(
        _ source: URL,
        profile: iPodVideoEncodeProfile,
        preferredName: String? = nil,
        durationSeconds: Double? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil
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

        let totalSeconds: Double
        if let durationSeconds, durationSeconds > 0.5 {
            totalSeconds = durationSeconds
        } else {
            totalSeconds = await VideoDurationProbe.seconds(for: source) ?? 0
        }

        let label = source.lastPathComponent
        progress?(0, "Converto \(label) → video iPod…")

        let scale = "scale=\(profile.maxWidth):\(profile.maxHeight):force_original_aspect_ratio=decrease"
        let pad = "pad=\(profile.maxWidth):\(profile.maxHeight):(ow-iw)/2:(oh-ih)/2"
        let vf = "\(scale),\(pad),setsar=1"
        let x264Params: String = {
            switch profile {
            case .video5G:
                return "ref=1:bframes=0:cabac=0:weightp=0:8x8dct=0"
            case .classic:
                return "ref=2:bframes=0"
            }
        }()

        // File di progress: su pipe stdout ffmpeg spesso bufferizza e arriva tutto a fine encode.
        let progressFile = fm.temporaryDirectory
            .appendingPathComponent("VintageTunesVideo", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).progress")
        try fm.createDirectory(at: progressFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: progressFile)
        try Data().write(to: progressFile)

        let process = Process()
        process.executableURL = bin
        process.arguments = [
            "-y",
            "-hide_banner",
            "-nostats",
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
            "-progress", progressFile.path,
            "-stats_period", "0.25",
            "-f", "ipod",
            archive.path
        ]

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        try process.run()

        let readProgress = Task.detached(priority: .utility) {
            var lastReported = -1
            var lastSize = 0
            while !Task.isCancelled {
                if let data = try? Data(contentsOf: progressFile), !data.isEmpty {
                    if data.count != lastSize || process.isRunning {
                        lastSize = data.count
                        let text = String(data: data, encoding: .utf8) ?? ""
                        if let elapsed = Self.latestProgressSeconds(from: text) {
                            if totalSeconds > 0 {
                                let fraction = min(0.99, max(0, elapsed / totalSeconds))
                                let pct = Int((fraction * 100).rounded())
                                if pct != lastReported {
                                    lastReported = pct
                                    progress?(fraction, "Conversione \(label) · \(pct)%")
                                }
                            } else {
                                // Durata sconosciuta: avanza la barra in modo blando e mostra tempo elaborato.
                                let soft = min(0.92, log1p(elapsed) / log1p(elapsed + 90))
                                let pct = Int((soft * 100).rounded())
                                if pct != lastReported {
                                    lastReported = pct
                                    let clock = Self.formatClock(elapsed)
                                    progress?(soft, "Conversione \(label) · \(clock)")
                                }
                            }
                        }
                        if text.contains("progress=end"), lastReported < 100 {
                            lastReported = 100
                            progress?(1, "Conversione \(label) · 100%")
                        }
                    }
                }
                if !process.isRunning { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        process.waitUntilExit()
                        // Ultimo poll dopo exit.
                        Thread.sleep(forTimeInterval: 0.05)
                        readProgress.cancel()
                        if process.terminationStatus == 0,
                           FileManager.default.fileExists(atPath: archive.path) {
                            cont.resume()
                        } else if process.terminationReason == .uncaughtSignal {
                            cont.resume(throwing: VideoConversionError.cancelled)
                        } else {
                            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            let tail = err.split(separator: "\n").suffix(4).joined(separator: " ")
                            cont.resume(throwing: VideoConversionError.failed(
                                tail.isEmpty ? "Conversione video fallita" : String(tail)
                            ))
                        }
                    }
                }
            } onCancel: {
                if process.isRunning {
                    process.terminate()
                }
            }
        } catch {
            readProgress.cancel()
            if process.isRunning { process.terminate() }
            try? fm.removeItem(at: progressFile)
            throw error
        }

        try? fm.removeItem(at: progressFile)
        try Task.checkCancellation()

        let tempDir = fm.temporaryDirectory.appendingPathComponent("VintageTunesVideo", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dest = tempDir.appendingPathComponent("\(UUID().uuidString).m4v")
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: archive, to: dest)
        progress?(1, "Conversione \(label) · 100%")
        return dest
    }

    /// Ultimo `out_time_us` / `out_time_ms` dal file `-progress`.
    private static func latestProgressSeconds(from text: String) -> Double? {
        var best: Double?
        for line in text.split(whereSeparator: \.isNewline) {
            let s = String(line)
            if s.hasPrefix("out_time_us=") {
                let raw = String(s.dropFirst("out_time_us=".count))
                if let us = Double(raw), us >= 0 { best = us / 1_000_000 }
            } else if s.hasPrefix("out_time_ms=") {
                let raw = String(s.dropFirst("out_time_ms=".count))
                if let ms = Double(raw), ms >= 0 { best = ms / 1_000_000 }
            }
        }
        return best
    }

    private static func formatClock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    /// Esposto per trovare `ffprobe` accanto a `ffmpeg`.
    static func ffmpegBinaryPath() -> URL? { ffmpegBinary() }

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
