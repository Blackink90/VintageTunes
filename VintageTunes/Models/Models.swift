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
    var contentHash: String? = nil

    var resolvedPath: URL?

    var displayArtist: String { artist.isEmpty ? "Artista sconosciuto" : artist }
    var displayTitle: String { title.isEmpty ? "Senza titolo" : title }
    var displayAlbum: String { album.isEmpty ? "Album sconosciuto" : album }
    var displayGenre: String { genre.isEmpty ? "—" : genre }
    var displayYear: String { year == 0 ? "—" : "\(year)" }

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

    var songCount: Int { trackIDs.count }

    func resolvedSongCount(using tracks: [Track]) -> Int {
        let known = Set(tracks.map(\.id))
        return trackIDs.filter { known.contains($0) }.count
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
    case playlists = "Playlist"
    case dropZone = "Aggiungi"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .songs: return "music.note.list"
        case .artists: return "person.2"
        case .albums: return "square.stack"
        case .genres: return "guitars"
        case .playlists: return "list.bullet.rectangle"
        case .dropZone: return "plus.circle"
        }
    }
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
