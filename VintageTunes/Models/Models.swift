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
    /// Raw mhit header + unmanaged MHODs; nil for tracks created in-app.
    var dbBlob: TrackDBBlob? = nil

    var resolvedPath: URL?

    var displayArtist: String { artist.isEmpty ? "Artista sconosciuto" : artist }
    var displayTitle: String { title.isEmpty ? "Senza titolo" : title }
    var displayAlbum: String { album.isEmpty ? "Album sconosciuto" : album }
    var displayGenre: String { genre.isEmpty ? "—" : genre }
    var displayYear: String { year == 0 ? "—" : "\(year)" }
    var displayPlayCount: String { playCount == 0 ? "—" : "\(playCount)" }

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
            return m == 0 ? "\(h) h" : "\(h) h \(m) min"
        }
        return "\(totalMinutes) min"
    }

    static func trackCountLabel(_ count: Int) -> String {
        count == 1 ? "1 brano" : "\(count) brani"
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
    case songs = "Canzoni"
    case artists = "Artisti"
    case albums = "Album"
    case genres = "Generi"
    case photos = "Foto"
    case playlists = "Playlist"
    case dropZone = "Aggiungi"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .songs: return "music.note.list"
        case .artists: return "person.2"
        case .albums: return "square.stack"
        case .genres: return "guitars"
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
    var displayArtist: String { artist.isEmpty ? "Artista sconosciuto" : artist }
    var displayAlbum: String { album.isEmpty ? "Album sconosciuto" : album }
}

struct AutoSyncPrompt: Identifiable, Equatable {
    let id = UUID()
    let candidates: [AutoSyncCandidate]
}
