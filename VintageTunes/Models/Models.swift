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

    var resolvedPath: URL?

    var displayArtist: String { artist.isEmpty ? "Artista sconosciuto" : artist }
    var displayTitle: String { title.isEmpty ? "Senza titolo" : title }
    var displayAlbum: String { album.isEmpty ? "Album sconosciuto" : album }

    var durationLabel: String {
        let total = Int(durationMs / 1000)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

struct Playlist: Identifiable, Hashable {
    let id: UInt64
    var name: String
    var isMaster: Bool
    var trackIDs: [UInt32]

    var songCount: Int { trackIDs.count }
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
}

enum LibrarySection: String, CaseIterable, Identifiable {
    case songs = "Canzoni"
    case artists = "Artisti"
    case albums = "Album"
    case playlists = "Playlist"
    case dropZone = "Aggiungi"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .songs: return "music.note.list"
        case .artists: return "person.2"
        case .albums: return "square.stack"
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

struct ConversionPrompt: Identifiable, Equatable {
    let id = UUID()
    let convertibleURLs: [URL]
    let readyURLs: [URL]
    let rejectedNames: [String]

    var formatsLabel: String {
        let exts = Set(convertibleURLs.map { $0.pathExtension.uppercased() }).sorted()
        return exts.joined(separator: ", ")
    }

    var message: String {
        let n = convertibleURLs.count
        let formats = formatsLabel
        var text = n == 1
            ? "1 file (\(formats)) non è riproducibile sull'iPod stock."
            : "\(n) file (\(formats)) non sono riproducibili sull'iPod stock."
        text += " Vuoi convertirli in M4A (AAC) e trasferirli?"
        if !readyURLs.isEmpty {
            text += "\n\n\(readyURLs.count) file già compatibili verranno trasferiti comunque."
        }
        if !rejectedNames.isEmpty {
            text += "\n\nIgnorati: \(rejectedNames.prefix(3).joined(separator: ", "))"
            if rejectedNames.count > 3 { text += "…" }
        }
        return text
    }
}
