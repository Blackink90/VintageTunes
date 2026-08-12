import Foundation

enum FirmwareMode: String, Codable {
    case stock
    case rockbox
}

struct iPodDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let volumeURL: URL
    let capacityBytes: Int64
    let availableBytes: Int64
    let modelHint: String
    let firmwareMode: FirmwareMode
    let hasDatabase: Bool
    var isSimulated: Bool = false

    var controlURL: URL { volumeURL.appendingPathComponent("iPod_Control") }
    var musicURL: URL { controlURL.appendingPathComponent("Music") }
    var iTunesURL: URL { controlURL.appendingPathComponent("iTunes") }
    var databaseURL: URL { iTunesURL.appendingPathComponent("iTunesDB") }
    var rockboxURL: URL { volumeURL.appendingPathComponent(".rockbox") }

    /// Foto (Photo Database) solo su Video 5G/5.5G stock.
    var supportsPhotos: Bool { PhotoDeviceProfile.detect(for: self) != nil }

    /// Film/video in iTunesDB: Video 5G/5.5G e Classic stock (non nano / Rockbox).
    var supportsVideo: Bool {
        guard firmwareMode == .stock else { return false }
        let hint = modelHint.uppercased()
        if hint.contains("NANO") { return false }
        if supportsPhotos { return true }
        if hint.contains("CLASSIC")
            || hint.contains("MA446")
            || hint.contains("MB147")
            || hint.contains("MB139") {
            return true
        }
        return hint.contains("VIDEO")
    }

    /// Famiglia nano 1G/2G (cover F1027/F1031, iTunesDB tipicamente 0x74).
    var isNanoFamily: Bool {
        let hint = modelHint.uppercased()
        return hint.contains("NANO")
    }

    var usedBytes: Int64 { max(0, capacityBytes - availableBytes) }

    var usedFraction: Double {
        guard capacityBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(capacityBytes)
    }
}

struct Track: Identifiable, Hashable {
    let id: UInt32
    var title: String
    var artist: String
    var album: String
    var genre: String
    var location: String
    var durationMs: UInt32
    var sizeBytes: UInt32
    var trackNumber: UInt32
    var year: UInt32
    var bitrate: UInt32
    var sampleRate: UInt32
    var mediaType: UInt32
    /// Rating iPod/iTunes: 0…100 a passi di 20 (0 = nessuna, 100 = 5 stelle).
    var rating: UInt8 = 0
    /// Conteggio riproduzioni (iTunesDB mhit).
    var playCount: UInt32 = 0
    /// Ultima riproduzione in epoch Mac (secondi dal 1904-01-01); 0 = mai.
    var lastPlayedMacTime: UInt32 = 0
    /// ID stabile per collegare iTunesDB ↔ ArtworkDB (mhit @112).
    var dbid: UInt64 = 0
    /// 1 = mostra artwork, 2 = nessuna (mhit @164).
    var hasArtwork: UInt8 = 2
    /// Conteggio artwork (mhit @124).
    var artworkCount: UInt16 = 0
    /// Link all’mhii in ArtworkDB (mhit @352); 0 = usa solo dbid.
    var mhiiLink: UInt32 = 0
    var contentHash: String? = nil
    /// Testo canzone (iTunesDB MHOD type 27); nil = assente.
    var lyrics: String? = nil
    /// Raw mhit header + unmanaged MHODs; nil for tracks created in-app.
    var dbBlob: TrackDBBlob? = nil

    var resolvedPath: URL?

    /// true se c’è un testo non vuoto salvato.
    var hasLyrics: Bool {
        guard let lyrics else { return false }
        return !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Imposta il testo e rimuove eventuali MHOD 27 residui in `extraMhods`.
    mutating func setLyrics(_ text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        lyrics = (trimmed?.isEmpty == false) ? trimmed : nil
        guard var blob = dbBlob else { return }
        blob.extraMhods.removeAll { Self.mhodType(of: $0) == 27 }
        dbBlob = blob
    }

    private static func mhodType(of data: Data) -> UInt32? {
        guard data.count >= 16 else { return nil }
        return data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian
        }
    }

    var displayArtist: String { artist.isEmpty ? L10n.t("track.unknown_artist") : artist }
    var displayTitle: String { title.isEmpty ? L10n.t("track.untitled") : title }
    var displayAlbum: String { album.isEmpty ? L10n.t("track.unknown_album") : album }
    var displayGenre: String { genre.isEmpty ? "—" : genre }
    var displayYear: String { year == 0 ? "—" : "\(year)" }
    var displayPlayCount: String { playCount == 0 ? "—" : "\(playCount)" }

    /// libgpod: Movie=0x02, MusicVideo=0x20, TVShow=0x40 (bitflags).
    var isVideo: Bool {
        let t = mediaType
        return (t & 0x02) != 0 || (t & 0x20) != 0 || (t & 0x40) != 0
    }

    static let mediaTypeAudio: UInt32 = 0x01
    static let mediaTypeMovie: UInt32 = 0x02

    /// Stelle 0…5.
    var starRating: Int { Int(rating) / 20 }

    static func rating(fromStars stars: Int) -> UInt8 {
        let clamped = max(0, min(5, stars))
        return UInt8(clamped * 20)
    }

    /// Epoch Mac ↔ Date.
    static func macTimestamp(from date: Date = Date()) -> UInt32 {
        UInt32(date.timeIntervalSince1970 + 2_082_844_800)
    }

    static func date(fromMacTimestamp stamp: UInt32) -> Date? {
        guard stamp > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(stamp) - 2_082_844_800)
    }

    var lastPlayedDate: Date? { Self.date(fromMacTimestamp: lastPlayedMacTime) }

    /// Chiave genere per raggruppamento (solo generi non vuoti).
    var genreKey: String? {
        let g = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        return g.isEmpty ? nil : g
    }

    /// Chiave logica per riconoscere la stessa canzone anche dopo conversione FLAC→M4A.
    var identityKey: String {
        Self.makeIdentityKey(artist: artist, title: title, durationMs: durationMs)
    }

    static func makeIdentityKey(artist: String, title: String, durationMs: UInt32) -> String {
        let a = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let seconds = durationMs / 1000
        return "\(a)|\(t)|\(seconds)"
    }

    var durationLabel: String {
        let total = Int(durationMs / 1000)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    /// Estensione file in forma breve (MP3, M4A, WAV…).
    var displayFormat: String {
        let raw: String
        if let path = resolvedPath {
            raw = path.pathExtension
        } else {
            raw = (location as NSString).pathExtension
        }
        let ext = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !ext.isEmpty else { return "—" }
        switch ext {
        case "mp3": return "MP3"
        case "m4a", "aac", "m4b": return "M4A"
        case "m4v": return "M4V"
        case "mp4": return "MP4"
        case "wav": return "WAV"
        case "aiff", "aif": return "AIFF"
        case "alac": return "ALAC"
        case "flac": return "FLAC"
        case "ogg", "oga": return "OGG"
        case "wma": return "WMA"
        case "opus": return "Opus"
        default: return ext.uppercased()
        }
    }

    var displayLyricsPresent: String {
        hasLyrics ? L10n.t("common.yes") : L10n.t("common.no")
    }

    var albumKey: String { "\(displayAlbum)|||\(displayArtist)" }

    /// Equality ignores opaque DB bytes so UI/metadata diffs stay meaningful.
    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.genre == rhs.genre
            && lhs.location == rhs.location
            && lhs.durationMs == rhs.durationMs
            && lhs.sizeBytes == rhs.sizeBytes
            && lhs.trackNumber == rhs.trackNumber
            && lhs.year == rhs.year
            && lhs.bitrate == rhs.bitrate
            && lhs.sampleRate == rhs.sampleRate
            && lhs.mediaType == rhs.mediaType
            && lhs.rating == rhs.rating
            && lhs.playCount == rhs.playCount
            && lhs.lastPlayedMacTime == rhs.lastPlayedMacTime
            && lhs.dbid == rhs.dbid
            && lhs.hasArtwork == rhs.hasArtwork
            && lhs.artworkCount == rhs.artworkCount
            && lhs.mhiiLink == rhs.mhiiLink
            && lhs.contentHash == rhs.contentHash
            && lhs.resolvedPath == rhs.resolvedPath
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(title)
        hasher.combine(artist)
        hasher.combine(album)
        hasher.combine(genre)
        hasher.combine(location)
        hasher.combine(durationMs)
        hasher.combine(sizeBytes)
        hasher.combine(trackNumber)
        hasher.combine(year)
        hasher.combine(bitrate)
        hasher.combine(sampleRate)
        hasher.combine(mediaType)
        hasher.combine(rating)
        hasher.combine(playCount)
        hasher.combine(lastPlayedMacTime)
        hasher.combine(dbid)
        hasher.combine(hasArtwork)
        hasher.combine(artworkCount)
        hasher.combine(mhiiLink)
        hasher.combine(contentHash)
        hasher.combine(resolvedPath)
    }
}

struct AlbumRef: Identifiable, Hashable {
    let name: String
    let artist: String
    let trackCount: Int

    var id: String { "\(name)|||\(artist)" }
}

struct GenreRef: Identifiable, Hashable {
    let name: String
    let trackCount: Int
    let artistCount: Int

    var id: String { name }
}

enum LibraryStats {
    /// Dimensione in stile filesystem (1024), come tipicamente mostrato per i volumi.
    static func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024.0 * 1024.0)
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024.0)
        }
        if mb >= 10 {
            return String(format: "%.0f MB", mb)
        }
        return String(format: "%.1f MB", mb)
    }

    static func formatTotalMinutes(durationMsSum: UInt64) -> String {
        let totalMinutes = Int(durationMsSum / 60_000)
        if totalMinutes >= 60 {
            let h = totalMinutes / 60
            let m = totalMinutes % 60
            return m == 0
                ? L10n.tf("stats.duration_hours", h)
                : L10n.tf("stats.duration_hours_mins", h, m)
        }
        return L10n.tf("stats.duration_mins", totalMinutes)
    }

    static func trackCountLabel(_ count: Int) -> String {
        count == 1 ? L10n.t("stats.track_one") : L10n.tf("stats.track_many", count)
    }
}

struct Playlist: Identifiable, Hashable {
    let id: UInt64
    var name: String
    var isMaster: Bool
    var trackIDs: [UInt32]
    /// Raw mhyp header + unmanaged MHODs; nil for playlists created in-app.
    var dbBlob: PlaylistDBBlob? = nil

    var songCount: Int { trackIDs.count }

    func resolvedSongCount(using tracks: [Track]) -> Int {
        let known = Set(tracks.map(\.id))
        return trackIDs.filter { known.contains($0) }.count
    }

    /// Playlist On-The-Go creata dal firmware (eventualmente numerata).
    var isOnTheGo: Bool {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        if normalized == "on-the-go" { return true }
        // "on-the-go-1", "on-the-go1"
        guard normalized.hasPrefix("on-the-go") else { return false }
        let suffix = normalized.dropFirst("on-the-go".count)
        if suffix.isEmpty { return true }
        if suffix.first == "-" {
            return suffix.dropFirst().allSatisfy(\.isNumber) && !suffix.dropFirst().isEmpty
        }
        return suffix.allSatisfy(\.isNumber)
    }

    /// Nome in UI: On-The-Go senza numerazione.
    var displayName: String {
        isOnTheGo ? L10n.t("playlist.on_the_go") : name
    }

    static func == (lhs: Playlist, rhs: Playlist) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.isMaster == rhs.isMaster
            && lhs.trackIDs == rhs.trackIDs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(isMaster)
        hasher.combine(trackIDs)
    }
}

struct ImportCandidate: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var title: String
    var artist: String
    var album: String
    var genre: String
    var durationMs: UInt32
    var sizeBytes: UInt32
    var trackNumber: UInt32
    var year: UInt32
    var bitrate: UInt32
    var sampleRate: UInt32
    /// SHA del file *origine* (es. FLAC), non del M4A convertito.
    var contentHash: String? = nil

    var identityKey: String {
        Track.makeIdentityKey(artist: artist, title: title, durationMs: durationMs)
    }
}

enum LibrarySection: String, CaseIterable, Identifiable {
    case songs
    case artists
    case albums
    case genres
    case videos
    case photos
    case playlists
    case dropZone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .songs: return L10n.t("section.songs")
        case .artists: return L10n.t("section.artists")
        case .albums: return L10n.t("section.albums")
        case .genres: return L10n.t("section.genres")
        case .videos: return L10n.t("section.videos")
        case .photos: return L10n.t("section.photos")
        case .playlists: return L10n.t("section.playlists")
        case .dropZone: return L10n.t("section.add")
        }
    }

    var systemImage: String {
        switch self {
        case .songs: return "music.note.list"
        case .artists: return "person.2"
        case .albums: return "square.stack"
        case .genres: return "guitars"
        case .videos: return "film"
        case .photos: return "photo.on.rectangle"
        case .playlists: return "list.bullet.rectangle"
        case .dropZone: return "plus.circle"
        }
    }
}

struct DevicePhoto: Identifiable, Equatable, Hashable {
    let id: UInt32
    var title: String
    /// JPEG preview for the Mac UI (decoded from device RGB565 thumb).
    var previewJPEG: Data?
}

enum SyncStatus: Equatable {
    case idle
    case working(String)
    case success(String)
    case failure(String)
}

struct AutoSyncCandidate: Identifiable, Equatable, Hashable {
    var id: String { contentHash }
    let url: URL
    let title: String
    let artist: String
    let album: String
    let contentHash: String
    let needsConversion: Bool

    var displayTitle: String { title.isEmpty ? url.deletingPathExtension().lastPathComponent : title }
    var displayArtist: String { artist.isEmpty ? L10n.t("track.unknown_artist") : artist }
    var displayAlbum: String { album.isEmpty ? L10n.t("track.unknown_album") : album }
}

struct AutoSyncPrompt: Identifiable, Equatable {
    let id = UUID()
    let candidates: [AutoSyncCandidate]
}

/// Dialogo «Chiedi» durante conversione FLAC (e simili).
struct PendingFlacConversionAsk: Identifiable, Equatable {
    let id = UUID()
    let fileName: String
    let displayTitle: String
    let index: Int
    let total: Int

    var showsBatchScope: Bool { total > 1 }

    var headline: String {
        if total <= 1 {
            return L10n.t("conversion.ask_headline_one")
        }
        return L10n.tf("conversion.ask_headline_batch", index, total)
    }
}

struct FlacConversionAskDecision: Equatable {
    let format: FlacConversionFormat
    /// Se true, applica lo stesso formato ai file convertibili rimanenti del batch.
    let applyToAllRemaining: Bool
}
