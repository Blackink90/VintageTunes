import Foundation
import AVFoundation
import CoreServices

enum AudioMetadataReader {
    static func read(url: URL) async -> ImportCandidate {
        let filename = url.deletingPathExtension().lastPathComponent
        let parsedName = parseFilename(filename)

        var title = parsedName.title
        var artist = parsedName.artist
        var album = ""
        var genre = ""
        var trackNumber: UInt32 = 0
        var year: UInt32 = 0
        var durationMs: UInt32 = 0
        var bitrate: UInt32 = 0
        var sampleRate: UInt32 = 44100

        // Spotlight / MDItem — often has tags AVFoundation misses on FLAC
        if let spot = readSpotlight(url: url) {
            if let t = spot.title, !t.isEmpty { title = t }
            if let a = spot.artist, !a.isEmpty { artist = a }
            if let al = spot.album, !al.isEmpty { album = al }
            if let g = spot.genre, !g.isEmpty { genre = g }
            if let d = spot.durationMs, d > 0 { durationMs = d }
            if let y = spot.year, y > 0 { year = y }
            if let tn = spot.trackNumber, tn > 0 { trackNumber = tn }
        }

        let asset = AVURLAsset(url: url)

        do {
            let duration = try await asset.load(.duration)
            if duration.isNumeric && !duration.isIndefinite {
                let ms = UInt32(max(0, CMTimeGetSeconds(duration) * 1000))
                if ms > 0 { durationMs = ms }
            }
        } catch {}

        do {
            let meta = try await asset.load(.commonMetadata)
            for item in meta {
                guard let key = item.commonKey else { continue }
                let value = try? await item.load(.stringValue)
                guard let value, !value.isEmpty else { continue }
                switch key {
                case .commonKeyTitle: title = value
                case .commonKeyArtist: artist = value
                case .commonKeyAlbumName: album = value
                case .commonKeyType: genre = value
                default: break
                }
            }
        } catch {}

        do {
            let all = try await asset.load(.metadata)
            for item in all {
                let id = (item.identifier?.rawValue ?? "").lowercased()
                let keySpace = item.keySpace?.rawValue.lowercased() ?? ""
                let key = "\(keySpace):\(id)"

                if artist.isEmpty, key.contains("artist") || key.contains("©art") || id.contains("tpe1") {
                    if let s = try? await item.load(.stringValue), !s.isEmpty { artist = s }
                }
                if album.isEmpty, key.contains("album") || key.contains("©alb") || id.contains("talb") {
                    if let s = try? await item.load(.stringValue), !s.isEmpty { album = s }
                }
                if title == filename || title == parsedName.title {
                    if key.contains("title") || key.contains("©nam") || id.contains("tit2") {
                        if let s = try? await item.load(.stringValue), !s.isEmpty { title = s }
                    }
                }
                if trackNumber == 0, id.contains("track") || id.contains("trck") {
                    if let n = try? await item.load(.numberValue) {
                        trackNumber = n.uint32Value
                    } else if let s = try? await item.load(.stringValue),
                              let n = UInt32(s.split(separator: "/").first ?? "") {
                        trackNumber = n
                    }
                }
                if year == 0, id.contains("date") || id.contains("tyer") || id.contains("year") || id.contains("©day") {
                    if let s = try? await item.load(.stringValue) {
                        year = UInt32(s.prefix(4)) ?? year
                    }
                }
                if genre.isEmpty, id.contains("genre") || id.contains("©gen") || id.contains("tcon") {
                    if let s = try? await item.load(.stringValue), !s.isEmpty { genre = s }
                }
            }
        } catch {}

        do {
            if let track = try await asset.loadTracks(withMediaType: .audio).first {
                if let desc = try await track.load(.formatDescriptions).first {
                    let audio = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
                    if let audio, audio.pointee.mSampleRate > 0 {
                        sampleRate = UInt32(audio.pointee.mSampleRate)
                    }
                }
                let rate = try await track.load(.estimatedDataRate)
                if rate > 0 {
                    bitrate = UInt32(rate / 1000)
                }
            }
        } catch {}

        if let af = afinfoTechnical(url: url) {
            if durationMs == 0, let d = af.durationMs, d > 0 { durationMs = d }
            if bitrate == 0, let b = af.bitrateKbps, b > 0 { bitrate = b }
            if let sr = af.sampleRate, sr > 0 { sampleRate = sr }
        }
        if durationMs == 0 {
            durationMs = afinfoDurationMs(url: url) ?? 0
        }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt32.init) ?? 0

        // Ultimo fallback bitrate: size / durata (evita il default 256 che sull’iPod taglia gli MP3 320).
        if bitrate == 0, durationMs > 0, size > 0 {
            let kbps = UInt32((UInt64(size) * 8) / UInt64(durationMs))
            if kbps > 0 { bitrate = min(kbps, 320) }
        }

        return ImportCandidate(
            url: url,
            title: title,
            artist: artist,
            album: album,
            genre: genre,
            durationMs: durationMs,
            sizeBytes: size,
            trackNumber: trackNumber,
            year: year,
            bitrate: bitrate,
            sampleRate: sampleRate == 0 ? 44100 : sampleRate
        )
    }

    /// Keep tags from `sourceMeta`, point to a new file (e.g. converted M4A).
    /// Durata/bitrate/sample rate restano del sorgente finché non si chiama `withTechnicalMetadata`.
    static func remapped(_ sourceMeta: ImportCandidate, to newURL: URL) -> ImportCandidate {
        let size = (try? newURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt32.init) ?? sourceMeta.sizeBytes
        return ImportCandidate(
            url: newURL,
            title: sourceMeta.title,
            artist: sourceMeta.artist,
            album: sourceMeta.album,
            genre: sourceMeta.genre,
            durationMs: sourceMeta.durationMs,
            sizeBytes: size,
            trackNumber: sourceMeta.trackNumber,
            year: sourceMeta.year,
            bitrate: sourceMeta.bitrate,
            sampleRate: sourceMeta.sampleRate,
            contentHash: sourceMeta.contentHash
        )
    }

    /// Sovrascrive durata/size/bitrate/sample rate dal file reale (quello che andrà sull’iPod).
    static func withTechnicalMetadata(_ meta: ImportCandidate, from fileURL: URL) async -> ImportCandidate {
        let tech = await read(url: fileURL)
        return ImportCandidate(
            url: fileURL,
            title: meta.title,
            artist: meta.artist,
            album: meta.album,
            genre: meta.genre,
            durationMs: tech.durationMs > 0 ? tech.durationMs : meta.durationMs,
            sizeBytes: tech.sizeBytes > 0 ? tech.sizeBytes : meta.sizeBytes,
            trackNumber: meta.trackNumber,
            year: meta.year,
            bitrate: tech.bitrate > 0 ? tech.bitrate : meta.bitrate,
            sampleRate: tech.sampleRate > 0 ? tech.sampleRate : meta.sampleRate,
            contentHash: meta.contentHash
        )
    }

    /// Aggiorna i campi tecnici di una traccia dal file sul dispositivo.
    @discardableResult
    static func applyTechnicalMetadata(to track: inout Track, from fileURL: URL) async -> Bool {
        let tech = await read(url: fileURL)
        var changed = false
        if tech.durationMs > 0, tech.durationMs != track.durationMs {
            track.durationMs = tech.durationMs
            changed = true
        }
        if tech.sizeBytes > 0, tech.sizeBytes != track.sizeBytes {
            track.sizeBytes = tech.sizeBytes
            changed = true
        }
        if tech.bitrate > 0, tech.bitrate != track.bitrate {
            track.bitrate = min(tech.bitrate, 320)
            changed = true
        }
        if tech.sampleRate > 0, tech.sampleRate != track.sampleRate {
            track.sampleRate = tech.sampleRate
            changed = true
        }
        return changed
    }

    static func isSupportedAudio(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "aiff", "aif", "wav", "alac"
    ]

    static let stockUnsupportedExtensions: Set<String> = [
        "flac", "ogg", "opus", "wma", "ape", "wv"
    ]

    static func rejectionMessage(for urls: [URL], firmware: FirmwareMode) -> String? {
        guard !urls.isEmpty else { return "Nessun file ricevuto." }

        let exts = urls.map { $0.pathExtension.lowercased() }
        let supported = urls.filter(isSupportedAudio)
        if !supported.isEmpty { return nil }

        if exts.contains(where: { stockUnsupportedExtensions.contains($0) }) {
            let bad = Set(exts.filter { stockUnsupportedExtensions.contains($0) }).sorted().joined(separator: ", ")
            if firmware == .rockbox && exts.contains("flac") {
                return "Import FLAC su Rockbox non è ancora abilitato in VintageTunes. Converti in MP3/M4A oppure chiedi di aggiungerlo."
            }
            return "Formato non supportato sull'iPod stock: \(bad). Usa MP3, M4A/AAC, WAV o AIFF."
        }

        return "Nessun file audio supportato (mp3, m4a, aac, wav, aiff)."
    }

    // MARK: - Helpers

    private struct SpotlightMeta {
        var title: String?
        var artist: String?
        var album: String?
        var genre: String?
        var durationMs: UInt32?
        var year: UInt32?
        var trackNumber: UInt32?
    }

    private static func readSpotlight(url: URL) -> SpotlightMeta? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }

        func stringAttr(_ key: CFString) -> String? {
            guard let value = MDItemCopyAttribute(item, key) else { return nil }
            if let s = value as? String, !s.isEmpty { return s }
            if let arr = value as? [String], let first = arr.first, !first.isEmpty { return first }
            return nil
        }

        func numberAttr(_ key: CFString) -> Double? {
            (MDItemCopyAttribute(item, key) as? NSNumber)?.doubleValue
        }

        var meta = SpotlightMeta()
        meta.title = stringAttr(kMDItemTitle) ?? stringAttr(kMDItemDisplayName)
        meta.artist = stringAttr(kMDItemAuthors) ?? stringAttr("kMDItemAlbumArtist" as CFString)
        meta.album = stringAttr("kMDItemAlbum" as CFString)
        meta.genre = stringAttr(kMDItemMusicalGenre)
        if let seconds = numberAttr(kMDItemDurationSeconds), seconds > 0 {
            meta.durationMs = UInt32(seconds * 1000)
        }
        if let y = numberAttr("kMDItemYear" as CFString), y > 0 {
            meta.year = UInt32(y)
        }
        if let tn = numberAttr("kMDItemAudioTrackNumber" as CFString), tn > 0 {
            meta.trackNumber = UInt32(tn)
        }
        return meta
    }

    private static func parseFilename(_ name: String) -> (artist: String, title: String) {
        // "Artist - Title" / "Artist – Title"
        let separators = [" - ", " – ", " — "]
        for sep in separators {
            if let range = name.range(of: sep) {
                let artist = String(name[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let title = String(name[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !artist.isEmpty, !title.isEmpty {
                    return (artist, title)
                }
            }
        }
        return ("", name)
    }

    private static func afinfoDurationMs(url: URL) -> UInt32? {
        afinfoTechnical(url: url)?.durationMs
    }

    private static func afinfoTechnical(url: URL) -> (durationMs: UInt32?, bitrateKbps: UInt32?, sampleRate: UInt32?)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afinfo")
        process.arguments = [url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            var durationMs: UInt32?
            var bitrateKbps: UInt32?
            var sampleRate: UInt32?
            for line in text.split(whereSeparator: \.isNewline) {
                let raw = String(line)
                let lower = raw.lowercased()
                if lower.contains("estimated duration") || (lower.contains("duration") && lower.contains("sec")) {
                    let nums = lower.split(whereSeparator: { !$0.isNumber && $0 != "." && $0 != "," })
                    if let first = nums.first,
                       let seconds = Double(first.replacingOccurrences(of: ",", with: ".")) {
                        durationMs = UInt32(seconds * 1000)
                    }
                }
                if lower.contains("bit rate") {
                    // "bit rate: 320000 bits per second" oppure "320 kbps"
                    if let match = lower.range(of: #"(\d+(?:\.\d+)?)\s*bits per second"#, options: .regularExpression) {
                        let n = Double(lower[match].split(whereSeparator: { !$0.isNumber && $0 != "." }).first.map(String.init) ?? "") ?? 0
                        if n > 0 { bitrateKbps = UInt32(n / 1000) }
                    } else if let match = lower.range(of: #"(\d+)\s*kb"#, options: .regularExpression) {
                        let n = UInt32(lower[match].split(whereSeparator: { !$0.isNumber }).first.map(String.init) ?? "") ?? 0
                        if n > 0 { bitrateKbps = n }
                    }
                }
                if lower.contains("hz") && (lower.contains("data format") || lower.contains(",")) {
                    // "2 ch,  44100 Hz, .mp3"
                    if let match = lower.range(of: #"(\d+)\s*hz"#, options: .regularExpression) {
                        let n = UInt32(lower[match].split(whereSeparator: { !$0.isNumber }).first.map(String.init) ?? "") ?? 0
                        if n > 0 { sampleRate = n }
                    }
                }
            }
            return (durationMs, bitrateKbps, sampleRate)
        } catch {
            return nil
        }
    }
}